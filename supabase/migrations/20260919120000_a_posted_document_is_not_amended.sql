set lock_timeout = '30s';

-- =============================================================================
-- 20260919100000  A posted document is not amended
-- -----------------------------------------------------------------------------
-- DAT-03. An issued sales invoice's lines could be changed from a button on the
-- record screen, and the ledger did not follow.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What was wrong
--
-- erp.amendment_allowed() has been as 20260829280000 wrote it since 29 August.
-- It names three cut-offs: a stock movement against the document, a picked
-- allocation against it, and
--
--     v_state in ('despatched', 'invoiced', 'closed', 'cancelled')
--
-- Those four are sales-order state codes. A sales invoice's states are draft,
-- issued, paid, credited and cancelled; a purchase invoice's are draft,
-- registered, paid, disputed and cancelled (20260904150000). Only 'cancelled'
-- is shared, so an issued sales invoice and a registered purchase invoice both
-- came back allowed. The despatch movement belongs to the DELIVERY, not to the
-- invoice, and nothing picks against an invoice, so neither of the other two
-- cut-offs bit either.
--
-- erp.amend_document_line() then updated quantity and recomputed net_minor on a
-- document whose journal was already written. Journals are immutable: the
-- ledger, the subledger, the ageing and the PDF kept the old figure while
-- erp.document_value_minor() returned the new one. The screen offered it —
-- src/routes/documents/$documentId.tsx renders an Amend dialog on every line of
-- a committed document — so this was reachable by anyone who could open an
-- invoice.
--
-- And the same function authorised every amendment on sales.order, whatever the
-- document was. Amending a purchase invoice line was authorised on a sales
-- permission: the wrong module, and a permission a buyer does not hold.
--
-- Whether any amendment was in fact made to a posted document in a real
-- organisation is not restated here, because this migration does not know. It
-- changes nothing that has already happened: no journal is rewritten and no
-- line is put back. What it does is refuse the next one, from today.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The obvious fix, and why it is not taken
--
-- The obvious fix is to cut off on the state's own is_committed flag instead of
-- four hard-coded codes. It would be a regression dressed as a fix. This
-- function exists so a SALES ORDER can be amended after it is confirmed — the
-- customer rings up and reduces the quantity — and 'confirmed' is is_committed.
-- Cutting off at is_committed forbids the one thing the feature is for.
--
-- The second trap is one step further in. "Nothing that has reached the ledger"
-- is the right instinct, but a journal against the document is not by itself
-- evidence of it: confirming a sales order raises one. The sales_order base
-- type carries affects_finance, erp.transition_document() posts on the first
-- committed state, and the sales_commitment rule writes into the COMMIT ledger
-- (erp.ledger_kind = 'management'). A plain "does a journal name this document"
-- test refuses every confirmed sales order — which is to say, the feature.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The invariant this lands on
--
--     A document may be amended only while it is still only ours.
--
-- Five cut-offs, in the order they bite, each one a fact about this document
-- rather than a word from one document family's vocabulary:
--
--   1. stock_has_moved     a stock movement names it. The warehouse acted.
--   2. picking_started     a picked allocation against it. The warehouse is
--                          holding it.
--   3. ledger_posted       a journal names it in a ledger that keeps the
--                          books. NEW, and the whole point: this is what an
--                          issued sales invoice and a registered purchase
--                          invoice both have and a confirmed sales order does
--                          not. "Keeps the books" is read from
--                          erp.ledger.ledger_kind and excludes the two
--                          memorandum kinds, 'management' and 'budget', so a
--                          commitment memo does not bite and a statutory,
--                          group or tax ledger does. A kind added later counts
--                          as real until somebody says otherwise, which is the
--                          safe direction to be wrong in.
--   4. document_derived    another document has been raised from it and is not
--                          cancelled — a delivery from an order, an invoice
--                          from a delivery, a call-off from a blanket. NEW,
--                          and this is what replaces 'despatched' and
--                          'invoiced'. Amending the lines a delivery note was
--                          built from makes the two disagree, and the other
--                          party holds the delivery note. It is stricter than
--                          the codes it replaces in one place: an order that
--                          has been PART delivered is now refused where it was
--                          allowed. That is the honest answer — what shipped
--                          shipped, and the way back is a credit or a return,
--                          not a smaller order.
--   5. terminal_state      the state is terminal, or the document is
--                          cancelled. NEW, and this is what replaces 'closed'
--                          and 'cancelled'. Nothing finished is amended,
--                          whatever else is true of it.
--
-- Cut-offs 3 to 5 read erp.journal, erp.ledger, erp.document_relation and
-- erp.state.is_terminal. None of them names a state code, so a document type
-- added tomorrow is judged by what has happened to it rather than by whether
-- somebody remembered to add its vocabulary here.
--
-- What this deliberately does NOT do: an order transitioned straight to
-- 'despatched' with no delivery document, no movement and no relation is now
-- amendable where the state-code list refused it. Nothing has left the
-- warehouse in that case and no document was built on it, so there is nothing
-- for an amendment to contradict. The refusal was the vocabulary talking, not
-- the facts.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And the permission is the document's own
--
-- erp.amend_document_line() now authorises coalesce(dt.create_permission,
-- bt.create_permission) for the document's own type — the same read
-- erp.add_document_line() has used since 20260831130000, and the same one
-- erp.document_type_party_role_kind() reads to decide which side of the trade a
-- type is on. Writing a line and changing one are the same act, so they ask for
-- the same thing. A sales order still asks sales.order. A purchase invoice asks
-- procurement.match (20260912224000 put it there). The entity and site go with
-- it, as they do on erp.add_document_line(), so a grant scoped to one company
-- is scoped here too.
--
-- erp.assert_app_gates_match() counts a door that authorises from data rather
-- than judging it, which this now is; the desk declares no permission beside
-- this door, so no pair moves.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Proved by
--
-- erp_test.amendment_cut_off_suite(), which builds its own organisation and,
-- for each family, amends a draft line, is refused by name once the document
-- has posted, and — the case that matters most — amends a CONFIRMED sales
-- order that carries its commitment journal, which is the regression the
-- is_committed fix and the naive ledger test would each have caused.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The cut-offs
-- ═════════════════════════════════════════════════════════════════════════════

-- The live body first. erp.amendment_allowed() has never been redefined and
-- carries only the sweep 20260904980000 ran over every routine, so what is in
-- the database is 20260829280000's text with CLOVEERP_ where ERPWARE_ was. If
-- that is not what is there, something replaced it and this migration is
-- written against a body that no longer exists.
do $anchor$
declare
  v_sig constant text := 'erp.amendment_allowed(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_n   constant text := $n$elsif v_state in ('despatched', 'invoiced', 'closed', 'cancelled') then$n$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_AMENDMENT_ALLOWED_UNRECOGNISED: % does not hold the four state codes this migration removes', v_sig
      using hint = 'Read the live body with pg_get_functiondef before rewriting it.';
  end if;
  if position($n$cut_off := 'stock_has_moved';$n$ in v_def) = 0
     or position($n$cut_off := 'picking_started';$n$ in v_def) = 0 then
    raise exception 'CLOVEERP_AMENDMENT_ALLOWED_UNRECOGNISED: % does not hold the two cut-offs this migration keeps', v_sig;
  end if;
  if position('ERPWARE_' in v_def) > 0 then
    raise exception 'CLOVEERP_AMENDMENT_ALLOWED_UNRECOGNISED: % still carries the retired prefix, so 20260904980000 did not reach it', v_sig;
  end if;
end
$anchor$;

create or replace function erp.amendment_allowed(p_document_id uuid)
returns table (allowed boolean, cut_off text, detail text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  v_state    text;
  v_terminal boolean;
  v_picked   numeric;
  v_moved    boolean;
  v_books    integer;
  v_ledgers  text;
  v_derived  integer;
  v_names    text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select s.code, s.is_terminal into v_state, v_terminal
    from erp.object_state os join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_document_id;

  select exists (select 1 from erp.stock_movement m
                  where m.tenant_id = v_tenant and m.document_id = p_document_id)
    into v_moved;

  select coalesce(sum(al.quantity), 0) into v_picked
    from erp.allocation a
    join erp.allocation_line al on al.allocation_id = a.id
   where a.tenant_id = v_tenant and a.document_id = p_document_id
     and al.status = 'picked';

  -- The books, and only the books. A confirmed sales order raises a journal
  -- too — the sales_commitment rule, into the COMMIT ledger — and that is a
  -- memorandum of the very thing an amendment changes, re-derivable from the
  -- order. The two memorandum kinds are named and everything else counts, so a
  -- ledger kind added later is treated as real until somebody decides it is
  -- not.
  select count(*), string_agg(distinct l.code, ', ')
    into v_books, v_ledgers
    from erp.journal j
    join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id
   where j.tenant_id = v_tenant and j.document_id = p_document_id
     and l.ledger_kind not in ('management', 'budget');

  -- What has been built on it. erp.document_relation points from the document
  -- that was derived TO the one it came from, so this is "what has been raised
  -- from this". A cancelled one has been withdrawn and holds nothing.
  select count(*), string_agg(q.document_number, ', ')
    into v_derived, v_names
    from (select distinct x.document_number
            from erp.document_relation rel
            join erp.document x
              on x.tenant_id = rel.tenant_id and x.id = rel.from_document_id
           where rel.tenant_id = v_tenant and rel.to_document_id = p_document_id
             and not x.is_cancelled
           order by 1) q;

  -- Five cut-offs, in the order they bite, each named. "The document is too
  -- far along" is not a cut-off; these are. None of them is a state code:
  -- 20260919100000 took those out because they belonged to the sales order and
  -- were being asked of every document type there is.
  if v_moved then
    allowed := false;
    cut_off := 'stock_has_moved';
    detail := 'stock has left against this document; amend by returning it, not '
              'by editing the document';
  elsif v_picked > 0 then
    allowed := false;
    cut_off := 'picking_started';
    detail := format('%s already picked; the warehouse is holding it', v_picked);
  elsif coalesce(v_books, 0) > 0 then
    allowed := false;
    cut_off := 'ledger_posted';
    detail := format('%s journal(s) in %s name this document; a journal is not '
                     'rewritten, so raise a credit or a reversal rather than '
                     'changing what was posted',
                     v_books, coalesce(v_ledgers, 'the ledger'));
  elsif coalesce(v_derived, 0) > 0 then
    allowed := false;
    cut_off := 'document_derived';
    detail := format('%s has been raised from this document; amending it now '
                     'would make the two disagree', left(coalesce(v_names, 'another document'), 200));
  elsif coalesce(v_terminal, false) or d.is_cancelled then
    allowed := false;
    cut_off := 'terminal_state';
    detail := format('the document is %s',
                     case when d.is_cancelled then 'cancelled'
                          else coalesce(v_state, 'finished') end);
  else
    allowed := true;
    cut_off := null;
    detail := 'amendable';
  end if;

  return next;
end;
$$;

comment on function erp.amendment_allowed(uuid) is
  'Whether a document may still be amended, and if not, which cut-off stops it. '
  'Five facts about the document — stock moved, picking started, a journal in a '
  'ledger that keeps the books, a document raised from it, a terminal state — '
  'and not one state code, so a document type added tomorrow is judged by what '
  'has happened to it. 20260919100000.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the permission is the document's own
-- ═════════════════════════════════════════════════════════════════════════════

do $perm$
declare
  v_sig  constant text := 'erp.amend_document_line(uuid,numeric,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_dec  constant text := $n$  l        erp.document_line%rowtype;
  a        record;
begin$n$;
  v_dec_new constant text := $n$  l        erp.document_line%rowtype;
  a        record;
  -- The document and the permission its type asks for (20260919100000).
  d        erp.document%rowtype;
  v_perm   text;
begin$n$;
  v_auth constant text := $n$  perform erp.authorise('sales.order', null, null, null, 'document_line', p_line_id);$n$;
  v_auth_new constant text := $n$  -- Writing a line and changing one are the same act, so they ask for the
  -- same thing: the permission this document's own type requires, read the way
  -- erp.add_document_line() has read it since 20260831130000. A sales order
  -- still asks sales.order; a purchase invoice asks procurement.match. Before
  -- 20260919100000 every amendment on every document type was authorised on
  -- sales.order, which a buyer does not hold and which says the wrong module.
  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  select coalesce(dt.create_permission, bt.create_permission) into v_perm
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  perform erp.authorise(v_perm, d.entity_id, d.site_id, null, 'document_line', p_line_id);$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_dec, ''))) / length(v_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_AMEND_LINE_UNRECOGNISED: % ends its declarations % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_auth, ''))) / length(v_auth);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_AMEND_LINE_UNRECOGNISED: % authorises sales.order % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;
  if position('ERPWARE_' in v_def) > 0 then
    raise exception 'CLOVEERP_AMEND_LINE_UNRECOGNISED: % still carries the retired prefix, so 20260904980000 did not reach it', v_sig;
  end if;

  execute replace(replace(v_def, v_dec, v_dec_new), v_auth, v_auth_new);

  -- The rest of the body is still the body: the cut-off it raises on, and the
  -- reservation it releases rather than leaving to hold stock the document no
  -- longer wants. Each phrase is one the original wrote on a SINGLE line — a
  -- comment broken over two lines is never a substring of the body, and the
  -- first attempt at this migration probed for one that was.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('CLOVEERP_PAST_AMENDMENT_CUT_OFF' in v_def) = 0
     or position('that silently re-reserves can quietly take stock from another order' in v_def) = 0
     or position('update erp.allocation' in v_def) = 0
     or position('erp.authorise(v_perm, d.entity_id, d.site_id' in v_def) = 0 then
    raise exception 'CLOVEERP_AMEND_LINE_UNRECOGNISED: % lost part of its body, or did not take this patch', v_sig;
  end if;
end
$perm$;

comment on function erp.amend_document_line(uuid, numeric, text) is
  'Changes a line quantity under the permission the document''s own type '
  'requires, and refuses once the document has moved stock, been picked, '
  'reached a ledger that keeps the books, had another document raised from it, '
  'or finished. 20260919100000.';

-- The register that describes the door said "under sales.order", which was
-- true and is not any more. The gate is unchanged: the door still calls
-- erp.amend_document_line() and nothing else.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_amend_document_line', 'erp.amend_document_line',
   'Changes a line quantity under the permission the document''s own type '
   'requires — sales.order for a sales order, procurement.match for a purchase '
   'invoice. Refuses once the document has moved stock, been picked, reached a '
   'ledger that keeps the books, had another document raised from it, or '
   'finished.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.amendment_cut_off_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_admin constant uuid := '00000000-0000-4000-8000-0000000000f9';
  c_sales constant uuid := '00000000-0000-4000-8000-0000000000fb';
  c_buyer constant uuid := '00000000-0000-4000-8000-0000000000fc';
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_cust   uuid; v_supp uuid;
  v_sinv   uuid; v_sinv_l uuid;
  v_pinv   uuid; v_pinv_l uuid;
  v_so     uuid; v_so_l uuid;
  v_so_c   uuid; v_so_c_l uuid;
  v_so_p   uuid; v_so_p_l uuid;
  v_pinv_p uuid; v_pinv_p_l uuid;
  v_dn     jsonb;
  v_role_s uuid; v_role_p uuid;
  v_user_s uuid; v_user_p uuid;
  v_tok_s  text; v_tok_p text;
  res      jsonb;
  -- The verdict, read out of erp.amendment_allowed() into plain variables so a
  -- case that never reached the call cannot read the last case's answer.
  v_allowed boolean; v_cut text; v_det text;
  v_commit integer; v_books integer;
  v_committed boolean;
  v_ok     boolean; v_msg text; v_msg2 text; v_err text;
  v_qty    numeric;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-amendment-cut-off', 'Amendment cut-off suite',
                              'admin@zz-amendment-cut-off.test', 'Amendment Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values
    (c_admin, 'admin@zz-amendment-cut-off.test'),
    (c_sales, 'seller@zz-amendment-cut-off.test'),
    (c_buyer, 'buyer@zz-amendment-cut-off.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', c_admin)::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;
  select p.id into v_supp from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- ── 1. A draft sales invoice is amendable ─────────────────────────────────
  -- Every case that builds something captures what it is doing rather than
  -- letting it out: a fixture that falls over must report a failed case with
  -- the reason in it, not take the whole suite down and say nothing.
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null;
  begin
    v_sinv := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZZAMEND-SALE', '{}'::jsonb);
    v_sinv_l := erp.add_document_line(v_sinv, v_item, 10, 5000, 'ten of them');
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_sinv) a;
    perform erp.amend_document_line(v_sinv_l, 8, 'suite: before it was issued');
  exception when others then v_err := left(sqlerrm, 200);
  end;
  v_qty := (select l.quantity from erp.document_line l where l.id = v_sinv_l);
  case_name := 'a draft sales invoice line is amended';
  passed := v_err is null and coalesce(v_allowed, false) and v_qty = 8;
  detail := coalesce(v_err, format('%s; the line reads %s',
                                   coalesce(v_det, 'no verdict'),
                                   coalesce(v_qty::text, 'nothing')));
  return next;

  -- ── 2. An issued one is not ───────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null; v_ok := false;
  begin
    perform erp.transition_document(v_sinv, 'issue', 'amendment cut-off suite');
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_sinv) a;
    begin
      perform erp.amend_document_line(v_sinv_l, 3, 'suite: after it was issued');
      v_ok := false; v_msg := 'the issued invoice was amended';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: ledger_posted%';
      v_msg := left(sqlerrm, 160);
    end;
  exception when others then v_err := left(sqlerrm, 200);
  end;
  v_qty := (select l.quantity from erp.document_line l where l.id = v_sinv_l);
  case_name := 'an issued sales invoice is refused by name at the ledger, and its line is untouched';
  passed := v_err is null and v_ok and v_cut = 'ledger_posted' and v_qty = 8
        and exists (select 1 from erp.journal j
                     where j.tenant_id = v_tenant and j.document_id = v_sinv);
  detail := coalesce(v_err, format('%s; the line still reads %s', v_msg,
                                   coalesce(v_qty::text, 'nothing')));
  return next;

  -- ── 3. A draft purchase invoice is amendable ──────────────────────────────
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null;
  begin
    v_pinv := erp.create_document('purchase_invoice', v_entity, v_site, v_supp,
                                  current_date, v_ccy, 'ZZAMEND-BILL', '{}'::jsonb);
    v_pinv_l := erp.add_document_line(v_pinv, v_item, 10, 2000, 'ten of theirs');
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_pinv) a;
    perform erp.amend_document_line(v_pinv_l, 6, 'suite: before it was registered');
  exception when others then v_err := left(sqlerrm, 200);
  end;
  v_qty := (select l.quantity from erp.document_line l where l.id = v_pinv_l);
  case_name := 'a draft purchase invoice line is amended';
  passed := v_err is null and coalesce(v_allowed, false) and v_qty = 6;
  detail := coalesce(v_err, format('%s; the line reads %s',
                                   coalesce(v_det, 'no verdict'),
                                   coalesce(v_qty::text, 'nothing')));
  return next;

  -- ── 4. A registered one is not ────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null; v_ok := false;
  begin
    perform erp.transition_document(v_pinv, 'register', 'amendment cut-off suite');
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_pinv) a;
    begin
      perform erp.amend_document_line(v_pinv_l, 2, 'suite: after it was registered');
      v_ok := false; v_msg := 'the registered bill was amended';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: ledger_posted%';
      v_msg := left(sqlerrm, 160);
    end;
  exception when others then v_err := left(sqlerrm, 200);
  end;
  v_qty := (select l.quantity from erp.document_line l where l.id = v_pinv_l);
  case_name := 'a registered purchase invoice is refused by name at the ledger, and its line is untouched';
  passed := v_err is null and v_ok and v_cut = 'ledger_posted' and v_qty = 6
        and exists (select 1 from erp.journal j
                     where j.tenant_id = v_tenant and j.document_id = v_pinv);
  detail := coalesce(v_err, format('%s; the line still reads %s', v_msg,
                                   coalesce(v_qty::text, 'nothing')));
  return next;

  -- ── 5. The regression case: a confirmed sales order is still amendable ────
  -- It carries a journal of its own. The sales_order base type declares
  -- affects_finance, erp.transition_document() posts on the first committed
  -- state, and the sales_commitment rule writes into the COMMIT ledger — a
  -- memorandum of the commitment, re-derivable from the order, and not the
  -- books. A ledger cut-off that did not read the ledger's kind would refuse
  -- this, which is to say it would refuse the feature this function exists for.
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null;
  v_commit := null; v_books := null; v_committed := null;
  begin
    v_so := erp.create_document('sales_order', v_entity, v_site, v_cust,
                                current_date, v_ccy, 'ZZAMEND-ORDER', '{}'::jsonb);
    v_so_l := erp.add_document_line(v_so, v_item, 100, 5000, 'a hundred, to start with');
    perform erp.transition_document(v_so, 'submit', 'amendment cut-off suite');
    -- The fixture helper rather than the raw transition: the order type carries
    -- an approval chain, and 20260914062000 wrote the one routine that decides
    -- whatever tasks it raised before approving.
    perform erp_test.approve_document(v_so, 'amendment cut-off suite');
    select count(*) filter (where l.ledger_kind = 'management'),
           count(*) filter (where l.ledger_kind not in ('management', 'budget'))
      into v_commit, v_books
      from erp.journal j
      join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id
     where j.tenant_id = v_tenant and j.document_id = v_so;
    select s.is_committed into v_committed
      from erp.object_state os join erp.state s on s.id = os.current_state_id
     where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_so;
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_so) a;
    perform erp.amend_document_line(v_so_l, 60, 'suite: the customer reduced it');
  exception when others then v_err := left(sqlerrm, 200);
  end;
  v_qty := (select l.quantity from erp.document_line l where l.id = v_so_l);
  case_name := 'a confirmed sales order carries its commitment journal and is amended anyway';
  passed := v_err is null and coalesce(v_committed, false)
        and coalesce(v_commit, 0) > 0 and coalesce(v_books, -1) = 0
        and coalesce(v_allowed, false) and v_qty = 60;
  detail := coalesce(v_err,
              format('%s commitment journal(s), %s in the books; committed is %s; the line reads %s',
                     coalesce(v_commit::text, 'no'), coalesce(v_books::text, 'no'),
                     coalesce(v_committed::text, 'unknown'),
                     coalesce(v_qty::text, 'nothing')));
  return next;

  -- ── 6. Until a delivery is raised from it ─────────────────────────────────
  -- This is what replaces 'despatched' and 'invoiced'. The order's state does
  -- not move; what changes is that a delivery note now exists that was built
  -- from these lines.
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null; v_ok := false; v_dn := null;
  begin
    v_dn := erp.create_delivery_from_order(v_so);
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_so) a;
    begin
      perform erp.amend_document_line(v_so_l, 20, 'suite: after the delivery exists');
      v_ok := false; v_msg := 'the order was amended under its delivery';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: document_derived%';
      v_msg := left(sqlerrm, 160);
    end;
  exception when others then v_err := left(sqlerrm, 200);
  end;
  v_qty := (select l.quantity from erp.document_line l where l.id = v_so_l);
  case_name := 'and once a delivery has been raised from it, the order is refused by name';
  passed := v_err is null and v_ok and v_cut = 'document_derived' and v_qty = 60
        and (v_dn ->> 'document_id') is not null;
  detail := coalesce(v_err, format('%s; the delivery is %s', v_msg,
                                   coalesce(v_dn ->> 'document_number', 'missing')));
  return next;

  -- ── 7. A finished document is refused whatever else is true ───────────────
  v_cases := v_cases + 1;
  v_err := null; v_allowed := null; v_cut := null; v_det := null; v_ok := false;
  begin
    v_so_c := erp.create_document('sales_order', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZZAMEND-CANCELLED', '{}'::jsonb);
    v_so_c_l := erp.add_document_line(v_so_c, v_item, 5, 5000, 'five, briefly');
    perform erp.transition_document(v_so_c, 'cancel', 'amendment cut-off suite');
    select a.allowed, a.cut_off, a.detail into v_allowed, v_cut, v_det
      from erp.amendment_allowed(v_so_c) a;
    begin
      perform erp.amend_document_line(v_so_c_l, 4, 'suite: after it was cancelled');
      v_ok := false; v_msg := 'a cancelled order was amended';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAST_AMENDMENT_CUT_OFF: terminal_state%';
      v_msg := left(sqlerrm, 160);
    end;
  exception when others then v_err := left(sqlerrm, 200);
  end;
  case_name := 'a finished document is refused at its terminal state, with no state code asked for by name';
  passed := v_err is null and v_ok and v_cut = 'terminal_state';
  detail := coalesce(v_err, v_msg);
  return next;

  -- ── The two people, each holding one module's write permission ────────────
  -- Both can read everything a light seat reads, in both modules, so the only
  -- thing that differs between them is which module's write permission they
  -- hold: a refusal below is about the permission and nothing else.
  v_err := null;
  begin
    insert into erp.role (tenant_id, code, name, status)
    values (v_tenant, 'zz_amend_seller', 'Suite seller', 'active')
    returning id into v_role_s;
    insert into erp.role (tenant_id, code, name, status)
    values (v_tenant, 'zz_amend_buyer', 'Suite buyer', 'active')
    returning id into v_role_p;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select v_tenant, r.id, p.code
      from (values (v_role_s), (v_role_p)) r(id)
      cross join (values ('sales.read'), ('procurement.read'), ('finance.read'),
                         ('inventory.read'), ('master_data.read'), ('reporting.read')) p(code);
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (v_tenant, v_role_s, 'sales.order'),
      (v_tenant, v_role_p, 'procurement.match');

    res := public.erp_invite_principal('seller@zz-amendment-cut-off.test', 'Sam Seller');
    v_user_s := (res ->> 'app_user_id')::uuid;
    v_tok_s := res ->> 'token';
    perform erp.grant_role(v_user_s, 'zz_amend_seller', null, null, 'suite: sells and nothing else');
    res := public.erp_invite_principal('buyer@zz-amendment-cut-off.test', 'Bea Buyer');
    v_user_p := (res ->> 'app_user_id')::uuid;
    v_tok_p := res ->> 'token';
    perform erp.grant_role(v_user_p, 'zz_amend_buyer', null, null, 'suite: buys and nothing else');

    -- Two draft documents for them to try, one on each side of the trade.
    v_so_p := erp.create_document('sales_order', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZZAMEND-PERM-ORDER', '{}'::jsonb);
    v_so_p_l := erp.add_document_line(v_so_p, v_item, 12, 5000, 'a dozen');
    v_pinv_p := erp.create_document('purchase_invoice', v_entity, v_site, v_supp,
                                    current_date, v_ccy, 'ZZAMEND-PERM-BILL', '{}'::jsonb);
    v_pinv_p_l := erp.add_document_line(v_pinv_p, v_item, 12, 2000, 'a dozen of theirs');
  exception when others then v_err := left(sqlerrm, 200);
  end;

  -- ── 8. Sales permission does not amend a purchase document ────────────────
  v_cases := v_cases + 1;
  v_ok := false; v_msg := null; v_msg2 := null;
  if v_err is null then
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', c_sales)::text, true);
      perform erp.claim_invitation(v_tok_s);
      begin
        perform erp.amend_document_line(v_pinv_p_l, 9, 'suite: a seller changes a bill');
        v_ok := false; v_msg := 'the seller amended the bill';
      exception when others then
        v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED: procurement.match%';
        v_msg := left(sqlerrm, 120);
      end;
      begin
        perform erp.amend_document_line(v_so_p_l, 9, 'suite: a seller changes an order');
        v_msg2 := 'the order was amended';
      exception when others then
        v_ok := false; v_msg2 := left(sqlerrm, 120);
      end;
    exception when others then v_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', c_admin)::text, true);
  end if;
  case_name := 'somebody holding sales.order is refused a purchase document by name, and amends a sales one';
  passed := v_err is null and v_ok
        and (select l.quantity from erp.document_line l where l.id = v_so_p_l) = 9
        and (select l.quantity from erp.document_line l where l.id = v_pinv_p_l) = 12;
  detail := coalesce(v_err, format('the bill said %s; the order: %s',
                                   coalesce(v_msg, 'nothing'), coalesce(v_msg2, 'nothing')));
  return next;

  -- ── 9. And procurement permission does not amend a sales document ─────────
  v_cases := v_cases + 1;
  v_ok := false; v_msg := null; v_msg2 := null;
  if v_err is null then
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', c_buyer)::text, true);
      perform erp.claim_invitation(v_tok_p);
      begin
        perform erp.amend_document_line(v_so_p_l, 4, 'suite: a buyer changes an order');
        v_ok := false; v_msg := 'the buyer amended the order';
      exception when others then
        v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED: sales.order%';
        v_msg := left(sqlerrm, 120);
      end;
      begin
        perform erp.amend_document_line(v_pinv_p_l, 7, 'suite: a buyer changes a bill');
        v_msg2 := 'the bill was amended';
      exception when others then
        v_ok := false; v_msg2 := left(sqlerrm, 120);
      end;
    exception when others then v_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', c_admin)::text, true);
  end if;
  case_name := 'somebody holding procurement.match is refused a sales document by name, and amends a purchase one';
  passed := v_err is null and v_ok
        and (select l.quantity from erp.document_line l where l.id = v_so_p_l) = 9
        and (select l.quantity from erp.document_line l where l.id = v_pinv_p_l) = 7;
  detail := coalesce(v_err, format('the order said %s; the bill: %s',
                                   coalesce(v_msg, 'nothing'), coalesce(v_msg2, 'nothing')));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 10. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-amendment-cut-off')
        and not exists (select 1 from auth.users
                         where id in ('00000000-0000-4000-8000-0000000000f9',
                                      '00000000-0000-4000-8000-0000000000fb',
                                      '00000000-0000-4000-8000-0000000000fc'));
  detail := 'zz-amendment-cut-off rolled back with its documents, roles and people';
  return next;

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: amendment_cut_off_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.amendment_cut_off_suite() from public, anon;

create or replace function erp_test.assert_amendment_cut_off_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_all    integer;
  v_fail   integer;
  v_detail text;
begin
  create temp table if not exists _amendment_cut_off on commit drop as
    select * from erp_test.amendment_cut_off_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _amendment_cut_off;
  drop table _amendment_cut_off;
  if v_all <> c_expected then
    -- The failing cases come with the count: a fixture that fell over returns
    -- its cases failed rather than missing, and the reason is in them.
    raise exception E'CLOVEERP_AMENDMENT_CUT_OFF_SUITE_SHRANK: % case(s), expected %\n%',
      v_all, c_expected,
      coalesce(v_detail, '  every case passed; the count itself moved')
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_fail > 0 then
    raise exception E'CLOVEERP_AMENDMENT_CUT_OFF_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'A posted document was amended, or a document that should '
                   'still be amendable was refused.';
  end if;
  return format('amendment cut-offs: %s/%s cases passed', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_amendment_cut_off_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_document_create_permissions();
select erp.assert_writes_name_their_rows();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp_test.assert_amendment_cut_off_suite();
