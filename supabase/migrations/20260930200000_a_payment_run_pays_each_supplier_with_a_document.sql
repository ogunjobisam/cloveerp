set lock_timeout = '30s';

-- =============================================================================
-- 20260930200000  A payment run pays each supplier with a document
-- -----------------------------------------------------------------------------
-- PR13 M3 (docs/spec/simplification-review.md §7 Finance, node F5): the
-- supplier side, on top of the cash receipt (20260930000000) and the
-- settlement statement's receipts (20260930100000).
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A payment run pays each bill with a journal (payment.made, Dr the payable
-- Cr the bank) that names no document. What a supplier was paid in one run,
-- and for which bills, is found only by reading the run's lines against the
-- journals, and there is nothing to send the supplier that says so: the
-- "remittance advice" the spec asks for has no document to be the printout
-- of.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A base type, cash_payment: finance, no flow, moves no stock and is
--     posted by nothing generic (its journals are the payment run's), needs a
--     party, and is raised under finance.post.
--   * Shipped as configuration from one helper, erp.cash_payment_pack_items():
--     a lifecycle (draft, then posted by one move, post), a numbering rule
--     (PMT-, never reset, not gapless; PAY- is the run's own reference, D13),
--     a document type, and an output template, remittance_advice, which is
--     the payment's printout. Installed by erp.configure_procurement_controls()
--     and offered as version 7 of procurement-controls, which owns the
--     supplier_payment rule, to an organisation on version 6. The
--     demonstration's catch-up already takes whatever version procurement
--     controls is at (20260929100000).
--   * Posted is terminal and not committed, as a receipt's is (D4).
--   * erp.pay_payment_run() opens one payment per supplier per run (D7), for
--     the first bill of that supplier it pays, through erp.open_document():
--     dated the run's payment date, with the run's reference as ours, and the
--     run in its attributes. Each bill it pays is a line with no item: the
--     bill's number and the supplier's reference for it, and the amount paid.
--     Every journal the payment writes names it, the write-off within the
--     tolerance among them. After the run, each payment is posted by the
--     system, derived from erp.cash_document_is_applied(), which now reads a
--     payment's bank credits as it reads a receipt's debits. The answer gains
--     payments: [{document_id, document_number, party_id, paid_minor}].
--   * erp_render_remittance_advice: the payment rendered for printing or
--     download through its organisation's remittance layout, authorised by
--     finance.post in the payment's company, the permission that paid it.
--     Nothing is stored and nothing is sent (D8).
--   * Nobody opens a payment, adds a line to one or posts one by hand, an
--     administrator included, by the refusals the receipt has; their register
--     entries now speak of both. A payment's party is a supplier (D16). The
--     reversal register routes it by_journal.
--   * An organisation still on procurement-controls version 6 has no payment
--     type, and pays a run exactly as before: no document, and an answer
--     without payments (D1).
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * A write-off within the tolerance names the payment on its journal but
--     is not a line. It banks nothing, and the lines are what the bank paid,
--     as a receipt's short written off is not a line (20260930000000). The
--     bill's line says what was paid; the bill is paid in full.
--   * One payment per supplier, company and currency: a run pays one
--     currency, and a document has one company, so for a run whose suppliers
--     are all one company's, as every run proposed today is, that is one per
--     supplier (D7).
--   * Sending the advice (D8): by email through document issue or an output
--     request is a follow-up. No screen: the Pay stage and the payment's
--     record view offer Print in M4; until then the door is registered as
--     waiting for its screen.
--   * No reversal (D10), and no backfill of past runs (D3).
--   * The figures docs/build_counts.sh checks (doors, pending-screen doors)
--     follow in a commit of their own.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds, and the cash document's three, of both sides
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NOT_A_CASH_PAYMENT',
  'Printing something as a remittance advice that is not a supplier payment.',
  'A remittance advice is the printout of a supplier payment: the bills one payment paid. Nothing else carries them.',
  'Open the payment the run made from Pay, and print its remittance advice from there.');

select erp.register_refusal('CLOVEERP_REMITTANCE_HAS_NO_TEMPLATE',
  'Printing a remittance advice in an organisation with no remittance layout.',
  'A remittance advice is printed from the organisation''s remittance advice layout, and this organisation has none in use.',
  'Restore the remittance advice layout on the Output screen, or upgrade procurement controls.');

select erp.register_refusal('CLOVEERP_CASH_DOCUMENT_IS_RAISED',
  'Opening a cash receipt or a supplier payment by hand.',
  'A cash receipt is the record of money the bank received and the invoices it paid, and a supplier payment of money the bank paid and the bills it paid; one opened by hand would carry no cash, name no journal and never be posted.',
  'Apply the cash from Cash in, or pay an approved run from Pay. Its document is opened and posted with it.');

select erp.register_refusal('CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH',
  'Adding a line to a cash receipt or a supplier payment, or changing one, by hand.',
  'Each line of a cash document is cash the bank received or paid, against an invoice or a bill or kept on account, and its lines total what the bank moved; a line written by hand would say the bank moved money it did not.',
  'Apply the further cash from Cash in or pay the further bills from Pay, or correct a misapplied one with a journal on the Journals screen.');

select erp.register_refusal('CLOVEERP_CASH_DOCUMENT_NOT_APPLIED',
  'Posting a cash receipt or a supplier payment whose cash is not applied.',
  'A cash document is posted when its lines total what its posted journals banked or paid, and by the cash route that wrote them; posted by hand it would say money moved that no journal records.',
  'Apply the cash from Cash in, or pay an approved run from Pay. Its document is posted with it.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The base type
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.document_type
  (code, name_key, module_code, flow, affects_stock, affects_finance, requires_party,
   requires_site, description, create_permission)
values
  ('cash_payment', 'document.cash_payment', 'finance', 'none', false, false, true, false,
   'A supplier payment: the money one payment run paid one supplier, and the bills it paid. Its '
   'journals are written by the run that opens it, erp.pay_payment_run(), and name it; nothing '
   'posts it generically, and it is posted by that run when its lines total what its journals '
   'paid. Its printout is the remittance advice (20260930200000).',
   'finance.post')
on conflict (code) do update
  set name_key = excluded.name_key, module_code = excluded.module_code, flow = excluded.flow,
      affects_stock = excluded.affects_stock, affects_finance = excluded.affects_finance,
      requires_party = excluded.requires_party, requires_site = excluded.requires_site,
      description = excluded.description, create_permission = excluded.create_permission;

do $base$
begin
  if (select count(*) from erp_ref.document_type bt
       where bt.code = 'cash_payment' and bt.module_code = 'finance' and bt.flow = 'none'
         and not bt.affects_stock and not bt.affects_finance and bt.requires_party
         and not bt.requires_site and bt.create_permission = 'finance.post') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: base type cash_payment is not the row this migration declares';
  end if;
end
$base$;

insert into erp_ref.resource (key, locale, value, description) values
  ('document.cash_payment', 'en', 'Supplier payment', 'Document base type name (20260930200000).'),
  ('document.cash_payment', 'de', 'Zahlungsausgang', null),
  ('output.template.remittance_advice', 'en', 'Remittance advice', 'Starter Content Packs §9.3 output template name (20260930200000).'),
  ('output.template.remittance_advice', 'de', 'Zahlungsavis', null),
  ('output.block.bills_paid', 'en', 'Bills paid', 'Starter Content Packs §9.3 output block heading (20260930200000).'),
  ('output.block.bills_paid', 'de', 'Bezahlte Rechnungen', null)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The payment, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cash_payment_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The supplier payment (20260930200000), read by
  -- erp.configure_procurement_controls() for a new install and by the upgrade
  -- register for an organisation on version 6, so the two cannot disagree. In
  -- the order a change set applies them: the lifecycle and the sequence
  -- before the type that names them, and the type before its printout.
  --
  -- The lifecycle is the payment run's, not a person's: opened by
  -- erp.pay_payment_run(), and posted by erp.post_cash_document() once its
  -- lines total what its journals paid, derived from
  -- erp.cash_document_is_applied(). Posted is terminal and not committed
  -- (D4): the journals are the run's.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'cash_payment', 'payload',
      jsonb_build_object(
        'code', 'cash_payment', 'object_type', 'document', 'name', 'Supplier payment',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','posted','name','Posted','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',20)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','finance.post','sort_order',10)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'cash_payment', 'payload',
      jsonb_build_object('code','cash_payment','prefix','PMT-','pad_to',6,
                         'reset_period','never','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'cash_payment', 'payload',
      jsonb_build_object('code','cash_payment','base_type','cash_payment',
                         'name','Supplier payment','numbering_rule','cash_payment',
                         'state_machine','cash_payment',
                         'create_permission','finance.post')),
    jsonb_build_object('kind', 'output_template', 'key', 'remittance_advice', 'payload',
      jsonb_build_object(
        'code','remittance_advice','name_key','output.template.remittance_advice',
        'kind','document','base_type','cash_payment','page','A4',
        'blocks', b.blocks,
        -- The template names the document, its version renders it (§15.2).
        'version', jsonb_build_object(
          'rendering_engine','pdf','required_permission','finance.post',
          'blocks', b.blocks))))
    from (select jsonb_build_array(
          jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
          jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name')),
          jsonb_build_object('kind','counterparty','fields',jsonb_build_array('party_name','party_address')),
          jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','our_reference','currency')),
          jsonb_build_object('kind','lines','label_key','output.block.bills_paid',
                             'fields',jsonb_build_array('line_no','description','net_amount')),
          jsonb_build_object('kind','totals','fields',jsonb_build_array('total_net'))) as blocks) b
$$;

comment on function erp.cash_payment_pack_items() is
  'The supplier payment (20260930200000): its lifecycle, numbering rule, document type and remittance '
  'advice, the items erp.configure_procurement_controls() and the procurement-controls upgrade register '
  'both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_procurement_controls(text,numeric,numeric,bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          'posting_rule','purchase_credit_note'))));$o$;
  v_new constant text := $n$          'posting_rule','purchase_credit_note')))
      -- The supplier payment (20260930200000), from its one helper.
      || erp.cash_payment_pack_items());$n$;
  v_hits integer;
begin
  if strpos(v_def, 'erp.cash_payment_pack_items()') > 0 then
    raise notice '% already installs the supplier payment; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % credit note type anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The upgrade register: version 7 for an organisation on version 6
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 7,
       description = description
         || ' Version 7 (20260930200000): a payment run pays each supplier with a numbered '
         || 'payment, posted with the run, whose lines are the bills it paid and whose printout '
         || 'is the remittance advice.'
 where install_code = 'procurement-controls' and current_version = 6;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-controls', 7, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.cash_payment_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-controls') is distinct from 7 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement controls installer is not at version 7';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.cash_payment_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'procurement-controls' and ui.to_version = 7) <> 4
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'procurement-controls' and ui.to_version = 7) <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 7 of procurement controls is not the four items the supplier payment ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. When a payment is applied, and the routine that posts it
--
-- The receipt's fact and routine (20260930000000), taught the payment: a
-- receipt's lines are what its journals banked, a payment's what its
-- journals paid. Each is replaced whole over the body 20260930000000 left.
-- ─────────────────────────────────────────────────────────────────────────────

do $anchor_fact$
declare
  v_pairs constant text[] := array[
    'erp.cash_document_is_applied(uuid)',   'c0a41435227c16c6bfbe52cf89400ce5',
    'erp.post_cash_document(uuid)',         'e9c1d37391a32519ddfe0e99fc09c412',
    'erp.protect_posted_cash_document()',   '83f7f06f8169b8d86daca582ea871b9b'];
  v_src text;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_pairs[2*v_i - 1]::regprocedure);
    if position('cash_payment' in v_src) > 0 then
      raise notice '% already knows a supplier payment; replaced with the same body', v_pairs[2*v_i - 1];
    elsif md5(v_src) <> v_pairs[2*v_i] then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20260930000000 left (md5 %)',
        v_pairs[2*v_i - 1], md5(v_src);
    end if;
  end loop;
end
$anchor_fact$;

create or replace function erp.cash_document_is_applied(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A cash document is applied when it is a draft, at least one posted
  -- journal names it, and its lines total what those journals moved through
  -- the bank: for a cash receipt the bank rows' debits less credits
  -- (20260930000000), for a supplier payment their credits less debits
  -- (20260930200000). Read by the routine that posts it and again by the
  -- engine, with the document's state locked, as the fact the post is
  -- derived from.
  with j as (
    select j.id from erp.journal j
     where j.tenant_id = erp.current_tenant_id() and j.document_id = p_document_id
       and j.status = 'posted'),
  s as (
    select case dt.base_type_code when 'cash_payment' then -1 else 1 end as sign
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id)
  select erp.object_current_state('document', p_document_id) = 'draft'
     and exists (select 1 from j)
     and (select coalesce(sum(l.net_minor), 0) from erp.document_line l
           where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id
             and not l.is_cancelled)
       = coalesce((select s.sign from s), 1)
         * (select coalesce(sum(si.debit_minor - si.credit_minor), 0) from erp.subledger_item si
             where si.tenant_id = erp.current_tenant_id() and si.control_kind = 'bank'
               and si.journal_id in (select j.id from j))
$$;

revoke all on function erp.cash_document_is_applied(uuid) from public, anon;

comment on function erp.cash_document_is_applied(uuid) is
  'True when a cash document is a draft whose lines total what the posted journals naming it moved '
  'through the bank: a receipt''s debits (20260930000000), a supplier payment''s credits (20260930200000).';

create or replace function erp.post_cash_document(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_prev text;
  v_to   text;
  v_base text;
begin
  -- Posts a cash receipt (20260930000000) or a supplier payment
  -- (20260930200000) its route has applied. The move is the system's,
  -- derived from erp.cash_document_is_applied(), named in erp.deriving_move
  -- immediately before it and put back after. A refusal is raised, not
  -- recorded: the cash and its document are one statement of fact.
  if not erp.cash_document_is_applied(p_document_id) then
    select dt.base_type_code into v_base
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id;
    if v_base = 'cash_payment' then
      raise exception
        'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED: % is not a draft supplier payment whose lines total what its journals paid',
        coalesce((select d.document_number from erp.document d
                   where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id),
                 p_document_id::text)
        using errcode = '23514',
              hint = 'Pay an approved run from Pay. Its payments are posted with it.';
    end if;
    raise exception
      'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED: % is not a draft cash receipt whose lines total what its journals banked',
      coalesce((select d.document_number from erp.document d
                 where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id),
               p_document_id::text)
      using errcode = '23514',
            hint = 'Apply the cash from Cash in. Its receipt is posted with it.';
  end if;

  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', p_document_id::text || ':post', true);
  v_to := erp.transition_document(p_document_id, 'post', 'the cash it records is applied');
  perform set_config('erp.deriving_move', v_prev, true);
  return v_to;
end;
$$;

revoke all on function erp.post_cash_document(uuid) from public, anon;

comment on function erp.post_cash_document(uuid) is
  'Posts a cash receipt or a supplier payment once its cash is applied (20260930000000, '
  '20260930200000): the system''s move, derived from erp.cash_document_is_applied(). Refuses, rather '
  'than records, one that is not.';

create or replace function erp.protect_posted_cash_document()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_doc    uuid := coalesce(new.document_id, old.document_id);
  v_tenant uuid := coalesce(new.tenant_id, old.tenant_id);
  v_number text;
  v_base   text;
begin
  -- A posted cash receipt's (20260930000000) or supplier payment's
  -- (20260930200000) lines stay what its route wrote.
  select d.document_number, dt.base_type_code into v_number, v_base
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = v_doc and dt.base_type_code in ('cash_receipt', 'cash_payment');

  if found
     and nullif(current_setting('erp.purge_tenant_id', true), '') is null
     and coalesce(erp.object_current_state('document', v_doc), 'draft') <> 'draft' then
    if v_base = 'cash_payment' then
      raise exception
        'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is posted, and its lines are the bills it paid',
        coalesce(v_number, v_doc::text)
        using errcode = '23514',
              hint = 'Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.';
    end if;
    raise exception
      'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is posted, and its lines are the cash applied',
      coalesce(v_number, v_doc::text)
      using errcode = '23514',
            hint = 'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function erp.protect_posted_cash_document() from public, anon;

comment on function erp.protect_posted_cash_document() is
  'Refuses any write to a line of a posted cash receipt or supplier payment (20260930000000, '
  '20260930200000): the route writes its lines while it is a draft, and nothing changes them after.';

-- The fact the post is derived from, read again with the payment's state
-- locked. Deployed body, asserted needle: one arm more in the document case.
do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$           when dt.base_type_code = 'cash_receipt' and p_transition_code = 'post'
            and erp.cash_document_is_applied(p_object_id)
             then 'erp.cash_document_is_applied'
$o$;
  v_new constant text := $n$           when dt.base_type_code = 'cash_receipt' and p_transition_code = 'post'
            and erp.cash_document_is_applied(p_object_id)
             then 'erp.cash_document_is_applied'
           -- A supplier payment's post, once its lines total what its
           -- journals paid (20260930200000), asked for by
           -- erp.post_cash_document() as the payment run ends.
           when dt.base_type_code = 'cash_payment' and p_transition_code = 'post'
            and erp.cash_document_is_applied(p_object_id)
             then 'erp.cash_document_is_applied'
$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$dt.base_type_code = 'cash_payment'$x$) > 0 then
    raise notice '% already derives a supplier payment''s post; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % cash receipt arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- By hand, a payment does not move at all: its one move is the run's.
do $transition$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$            hint = 'Apply the cash from Cash in. Its receipt is posted with it.';
  end if;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$o$;
  v_new constant text := $n$            hint = 'Apply the cash from Cash in. Its receipt is posted with it.';
  end if;
  -- And a supplier payment by the run that paid it (20260930200000).
  if dt.base_type_code = 'cash_payment'
     and erp.derived_move_fact('document', p_document_id, p_transition_code) is null then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED: % is a supplier payment, and moves only as the run that paid it ends (%)',
      coalesce(d.document_number, p_document_id::text), p_transition_code
      using errcode = '23514',
            hint = 'Pay an approved run from Pay. Its payments are posted with it.';
  end if;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$dt.base_type_code = 'cash_payment'$x$) > 0 then
    raise notice '% already refuses a supplier payment moved by hand; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % cash receipt refusal found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. A payment's party is a supplier (D16)
--
-- Replaced whole, over the body 20260930000000 left.
-- ─────────────────────────────────────────────────────────────────────────────

do $anchor_role$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'erp.document_type_party_role_kind(uuid,uuid)'::regprocedure);
begin
  if position('cash_payment' in v_src) > 0 then
    raise notice 'erp.document_type_party_role_kind(uuid,uuid) already places a supplier payment; replaced with the same body';
  elsif md5(v_src) <> 'a48768b0b4e99838f24c54cfcec725ee' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.document_type_party_role_kind(uuid,uuid) is not the body 20260930000000 left (md5 %)', md5(v_src);
  end if;
end
$anchor_role$;

create or replace function erp.document_type_party_role_kind(p_tenant_id uuid, p_document_type_id uuid)
returns erp.party_role_kind
language sql
stable
set search_path = ''
as $$
  -- The permission a type requires already says which side of the trade it is.
  -- Reading it here means a type added tomorrow is placed by the module it
  -- belongs to, with nothing to remember to update. A finance permission says
  -- neither side, so there the base type does: a cash receipt is a
  -- customer's (20260930000000), a supplier payment a supplier's
  -- (20260930200000).
  select case split_part(coalesce(dt.create_permission, bt.create_permission), '.', 1)
           when 'sales'       then 'customer'::erp.party_role_kind
           when 'procurement' then 'supplier'::erp.party_role_kind
           else case bt.code
                  when 'cash_receipt' then 'customer'::erp.party_role_kind
                  when 'cash_payment' then 'supplier'::erp.party_role_kind
                  else null
                end
         end
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = p_tenant_id and dt.id = p_document_type_id;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. Nobody opens a payment or writes its lines by hand
-- ─────────────────────────────────────────────────────────────────────────────

do $create$
declare
  v_doors constant text[] := array[
    'public.erp_create_document(text,uuid,uuid,text,date,uuid,text,uuid)',
    'erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)'];
  v_old constant text := $o$            hint = 'Apply the cash from Cash in. Its receipt is opened and posted with it.';
  end if;
$o$;
  v_new constant text := $n$            hint = 'Apply the cash from Cash in. Its receipt is opened and posted with it.';
  end if;
  -- A supplier payment is opened by paying the run it records (20260930200000).
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = erp.current_tenant_id() and dt.code = p_type_code
                and dt.base_type_code = 'cash_payment') then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_IS_RAISED: % is a supplier payment, opened when the run it records is paid',
      p_type_code
      using errcode = '23514',
            hint = 'Pay an approved run from Pay. Its payments are opened and posted with it.';
  end if;
$n$;
  v_def text;
  v_hits integer;
begin
  foreach v_def in array v_doors loop
    declare
      v_sig text := v_def;
      v_body text := pg_get_functiondef(v_def::regprocedure);
    begin
      if strpos(v_body, $x$dt.base_type_code = 'cash_payment'$x$) > 0 then
        raise notice '% already refuses a supplier payment; left as it is', v_sig;
        continue;
      end if;
      v_hits := (length(v_body) - length(replace(v_body, v_old, ''))) / length(v_old);
      if v_hits <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % cash receipt refusal found % time(s)', v_sig, v_hits;
      end if;
      execute replace(v_body, v_old, v_new);
    end;
  end loop;
end
$create$;

do $lines$
declare
  v_sig constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$            hint = 'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.';
  end if;
$o$;
  v_new constant text := $n$            hint = 'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.';
  end if;

  -- Each line of a supplier payment is a bill the run paid, and
  -- erp.pay_payment_run() writes them (20260930200000).
  if v_base = 'cash_payment' then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is a supplier payment, and its lines are the bills it paid',
      d.document_number
      using errcode = '23514',
            hint = 'Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.';
  end if;
$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$v_base = 'cash_payment'$x$) > 0 then
    raise notice '% already refuses a line on a supplier payment; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % cash receipt refusal found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lines$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. The reversal register: by journal
-- ─────────────────────────────────────────────────────────────────────────────

do $route$
declare
  v_sig constant text := 'erp.document_reversal_route()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$A reversal of its own, which unsettles what the receipt paid, is PR13 D10.')
    ) as v(base_type_code, route, next_action, rationale)$o$;
  v_new constant text := $n$A reversal of its own, which unsettles what the receipt paid, is PR13 D10.'),

      ('cash_payment', 'by_journal',
       'A supplier payment is corrected with a journal on the Journals screen: a payment returned by the bank or made to the wrong supplier is reversed there, against the bank and the payable it reached. Reversing a payment is not built.',
       'Its journals are written by the payment run that opened it (20260930200000), not by the document''s posting rule, so reversing the document''s posting would unmake nothing the run settled; erp_reverse_journal() refuses a payment journal too. A reversal of its own, which unsettles what the payment paid, is PR13 D10.')
    ) as v(base_type_code, route, next_action, rationale)$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$('cash_payment', 'by_journal',$x$) > 0 then
    raise notice '% already routes a supplier payment; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % cash receipt row found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$route$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. A payment run opens a payment per supplier, and posts it
--
-- Edited, not rewritten: seven anchors over the body 20260929300000 left
-- (md5 fa8617b6…). Its arguments and its answer's type are unchanged; the
-- answer gains a key where the organisation has a payment type.
-- ─────────────────────────────────────────────────────────────────────────────

do $pay_run$
declare
  v_sig  constant text := 'erp.pay_payment_run(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_docs    integer := 0;
begin$o$,
    $n$  v_docs    integer := 0;
  -- The supplier payment (20260930200000): the organisation's type of one,
  -- and one payment per supplier the run pays, kept by supplier, company and
  -- currency. No type, as on procurement-controls version 6: no payment, as
  -- before.
  v_payment_type text;
  v_payments     jsonb := '{}'::jsonb;
  v_payment      uuid;
  v_key          text;
  v_diff_journal uuid;
  v_answer       jsonb;
begin$n$,

    $o$  for r in
    select l.* from erp.payment_proposal_line l
$o$,
    $n$  select dt.code into v_payment_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'cash_payment' and dt.status = 'active'
   order by (dt.entity_id is not null), dt.code
   limit 1;

  for r in
    select l.* from erp.payment_proposal_line l
$n$,

    $o$    perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);
$o$,
    $n$    perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);

    -- The supplier's payment, opened for the first bill of theirs the run
    -- pays, through the door every document is opened by: dated the run's
    -- payment date, with the run's reference as ours (20260930200000). A
    -- document has one company and one currency, so a run reaching a
    -- supplier's bills in two companies pays each company's with its own.
    v_payment := null;
    if v_payment_type is not null then
      v_key := si.party_id::text || ':' || si.entity_id::text || ':' || si.currency;
      v_payment := nullif(v_payments ->> v_key, '')::uuid;
      if v_payment is null then
        v_payment := erp.open_document(v_payment_type, si.party_id, si.entity_id, null,
                                       null, null, si.currency);
        update erp.document d
           set document_date = coalesce(pp.payment_date, current_date),
               our_reference = pp.reference,
               attributes = d.attributes || jsonb_build_object(
                 'route', 'payment_run', 'payment_proposal_id', pp.id),
               updated_at = now()
         where d.tenant_id = v_tenant and d.id = v_payment;
        v_payments := v_payments || jsonb_build_object(v_key, v_payment);
      end if;
    end if;
$n$,

    $o$    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;
$o$,
    $n$    -- With a payment, the journal names it and the bill paid is its line,
    -- with no item: the bill's number, the supplier's reference for it, and
    -- the amount paid (20260930200000).
    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
           document_id = coalesce(document_id, v_payment)
     where id = v_journal;

    if v_payment is not null then
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity,
        unit_price_minor, net_minor, currency)
      values (
        v_tenant, v_payment,
        coalesce((select max(l.line_no) from erp.document_line l
                   where l.tenant_id = v_tenant and l.document_id = v_payment), 0) + 10,
        null,
        coalesce((select b.document_number
                         || coalesce(', your ref ' || nullif(b.their_reference, ''), '')
                    from erp.document b
                   where b.tenant_id = v_tenant and b.id = si.document_id), 'an open item'),
        1, v_amount, v_amount, si.currency);
    end if;
$n$,

    $o$      perform erp.post_settlement_difference(si.id, v_short, coalesce(pp.payment_date, current_date), pp.reference);
$o$,
    $n$      v_diff_journal := erp.post_settlement_difference(si.id, v_short, coalesce(pp.payment_date, current_date), pp.reference);
      -- The write-off is the payment's too, and names it; it pays nothing
      -- through the bank, so it is not a line (20260930200000).
      if v_payment is not null and v_diff_journal is not null then
        update erp.journal j set document_id = v_payment
         where j.tenant_id = v_tenant and j.id = v_diff_journal;
      end if;
$n$,

    $o$  update erp.payment_proposal
     set status = 'paid', total_minor = v_paid, updated_at = now()
   where id = p_proposal_id;
$o$,
    $n$  update erp.payment_proposal
     set status = 'paid', total_minor = v_paid, updated_at = now()
   where id = p_proposal_id;

  -- And each payment is posted, by the system, now that its lines total what
  -- its journals paid (20260930200000).
  for v_payment in select (e.value #>> '{}')::uuid from jsonb_each(v_payments) e loop
    perform erp.post_cash_document(v_payment);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'document_id', d.id, 'document_number', d.document_number, 'party_id', d.party_id,
           'paid_minor', (select coalesce(sum(l.net_minor), 0) from erp.document_line l
                           where l.tenant_id = v_tenant and l.document_id = d.id and not l.is_cancelled))
           order by d.document_number), '[]'::jsonb)
    into v_answer
    from erp.document d
   where d.tenant_id = v_tenant
     and d.id in (select (e.value #>> '{}')::uuid from jsonb_each(v_payments) e);
$n$,

    $o$  return jsonb_build_object(
    'proposal_id', p_proposal_id, 'reference', pp.reference,$o$,
    $n$  -- The answer as it was, and the payments where the organisation has a
  -- type of one (20260930200000); on version 6 the answer is unchanged.
  return case when v_payment_type is null then '{}'::jsonb
              else jsonb_build_object('payments', v_answer) end
    || jsonb_build_object(
    'proposal_id', p_proposal_id, 'reference', pp.reference,$n$];
  v_hits integer;
begin
  if strpos(v_src, 'v_payment_type') > 0 then
    raise notice '% already opens a payment per supplier; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'fa8617b6fe6f5e61a11aa4ea01913f6c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20260929300000 left (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$pay_run$;

comment on function erp.pay_payment_run(uuid) is
  'Pays an approved payment run: each unheld line''s bill, by the supplier_payment rule, from the '
  'company''s bank, with a bill paid short within the settlement tolerance written off '
  '(20260929300000) and a bill left owing nothing settled. Where the organisation has a supplier '
  'payment type, one payment per supplier, whose lines are the bills it paid and whose journals name '
  'it, posted with the run; the answer lists them under payments (20260930200000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The remittance advice, rendered by whoever may pay (D8)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.render_remittance_advice(p_document_id uuid, p_locale text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  v_template text;
begin
  select doc.* into d
    from erp.document doc
    join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
   where doc.tenant_id = v_tenant and doc.id = p_document_id and dt.base_type_code = 'cash_payment';
  if not found then
    raise exception 'CLOVEERP_NOT_A_CASH_PAYMENT: % is not a supplier payment in this organisation', p_document_id
      using errcode = '23503',
            hint = 'Open the payment the run made from Pay, and print its remittance advice from there.';
  end if;

  -- What paying the run asked, in the payment's own company: whoever may pay
  -- a supplier may print what they paid them. The configuration preview asks
  -- administration.configure, which a payer does not need.
  perform erp.authorise('finance.post', d.entity_id, null, null,
                        'document', p_document_id);

  select ot.code into v_template
    from erp.output_template ot
   where ot.tenant_id = v_tenant and ot.base_type_code = 'cash_payment'
     and ot.kind = 'document' and ot.status = 'active'
   order by (ot.code = 'remittance_advice') desc, ot.code
   limit 1;
  if v_template is null then
    raise exception 'CLOVEERP_REMITTANCE_HAS_NO_TEMPLATE: this organisation has no remittance advice layout to print % with',
      d.document_number
      using errcode = '23503',
            hint = 'Restore the remittance advice layout on the Output screen, or upgrade procurement controls.';
  end if;

  -- Rendered, not stored and not sent (D8).
  return erp.render_output_template(v_template, p_document_id,
    coalesce(p_locale, erp.resolve_locale('document', d.entity_id)));
end;
$$;

revoke all on function erp.render_remittance_advice(uuid, text) from public, anon;

comment on function erp.render_remittance_advice(uuid, text) is
  'Renders a supplier payment''s remittance advice for printing or download through its '
  'organisation''s remittance layout (20260930200000). Authorises finance.post in the payment''s '
  'company. Stores and sends nothing.';

create or replace function public.erp_render_remittance_advice(p_document_id uuid, p_locale text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.render_remittance_advice(p_document_id, p_locale) $$;

revoke all on function public.erp_render_remittance_advice(uuid, text) from public, anon;
grant execute on function public.erp_render_remittance_advice(uuid, text) to authenticated, service_role;

comment on function public.erp_render_remittance_advice(uuid, text) is
  'A supplier payment''s remittance advice, rendered for printing or download (20260930200000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_render_remittance_advice', 'erp.render_remittance_advice',
   'Renders a supplier payment''s remittance advice through the organisation''s remittance layout and returns it; authorises finance.post in the payment''s company. Volatile for the access-log row erp.authorise() writes; the render is not stored and not sent.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- Until the Pay stage offers it.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_render_remittance_advice', 'pending_screen', '/finance',
   'Renders the remittance advice of a payment a run made, for the supplier. Belongs as Print remittance advice on the payment''s record and in the Pay stage''s outcome, which do not show payments yet (PR13 M4).')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

select erp_meta.add_help_actions('/finance', array['erp_render_remittance_advice']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A supplier payment''s remittance advice, printed from Pay (20260930200000).'
  from (values
    ('Remittance advice'),
    ('Print the remittance advice'),
    ('The bills this payment paid, for the supplier. Printed or downloaded here; nothing is sent.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The driver register, restated whole as every change to it is
--
-- The payment's one move is a routine's, so it is not a button
-- (src/components/erp/available-transitions.ts reads the newest restatement).
-- Otherwise as 20260930000000 left it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      -- Version 6 (20260929100000): paid in part, and then the rest, both
      -- the payment run's through erp.settle_paid_document(). Part paid is
      -- derived from erp.document_is_part_paid() and refused by hand.
      ('purchase_invoice',   'part_pay',               'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'pay_rest',               'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part_picked',   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_rest',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      -- Version 4 (20260929100000): paid in part and then the rest, both the
      -- cash's through erp.settle_paid_document(), part paid derived from
      -- erp.document_is_part_paid() and refused by hand; and credited in full
      -- out of part paid, the credit note's.
      ('sales_invoice',      'part_settle',            'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'settle_rest',            'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit_rest',            'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      -- Version 1 (20260917130000) and version 2 (20260928200000) of the
      -- transfer order. Documents in flight stay on version 1, so its rows
      -- stay while an organisation holds it; the moves both versions share
      -- are the despatch and receive doors', which is where the goods move.
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'routine', 'erp.despatch_transfer(uuid)'),
      ('transfer_order',     'in_transit',             'routine', 'erp.despatch_transfer(uuid)'),
      ('transfer_order',     'received',               'routine', 'erp.receive_transfer(uuid)'),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),
      -- Version 2: submitted as it is raised, and again by hand after a
      -- rejection; approved by somebody the chain asked, or derived from
      -- erp.approval_asked_nobody() when it asked nobody; closed derived from
      -- erp.transfer_is_received_in_full(), which a close asked for by hand
      -- also reaches, through the receiving site's routine. Neither derived
      -- move is a button.
      ('transfer_order',     'submit',                 'screen', ''),
      ('transfer_order',     'approve',                'screen', ''),
      ('transfer_order',     'reject',                 'screen', ''),
      ('transfer_order',     'approve_within_threshold', 'routine', 'erp.approve_transfer_within_threshold(uuid)'),
      ('transfer_order',     'close',                  'routine', 'erp.close_transfer_when_received(uuid,text,boolean)'),
      ('transfer_order',     'cancel',                 'screen', ''),
      ('transfer_order',     'cancel_approved',        'screen', ''),

      -- Version 1 (20260918810000) and version 2 (20260928500000) of the
      -- stock adjustment. A count's own adjustment is approved and posted by
      -- erp.post_count(), through erp.raise_count_adjustment(), both moves
      -- derived from erp.count_task_is_approved() whatever permission the
      -- organisation puts on them (20260927200000): version 1's approve from
      -- draft, version 2's approve_with_count. A hand-typed version 1
      -- adjustment is approved here and confirmed on the Stock adjustments
      -- screen; a version 2 one is submitted as it is raised, approved within
      -- its threshold derived from erp.approval_asked_nobody() or here by
      -- somebody the chain asked, and posted by the approval. The post is
      -- the line routine's on either version: the move is refused over stock
      -- nothing has written (20260928000000), so it is never a button.
      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'routine', 'erp.post_adjustment_lines(uuid,timestamp with time zone,date)'),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),
      ('stock_adjustment',   'submit',                 'screen', ''),
      ('stock_adjustment',   'reject',                 'screen', ''),
      ('stock_adjustment',   'approve_within_threshold', 'routine', 'erp.approve_adjustment_within_threshold(uuid)'),
      ('stock_adjustment',   'approve_with_count',     'routine', 'erp.raise_count_adjustment(uuid)'),
      ('stock_adjustment',   'cancel_approved',        'screen', ''),

      -- ── The count sheet (20260927100000) ──────────────────────────────────
      -- Issued by the raise that opens it, once every place is on it; closed
      -- by the last of its counts to be posted or cancelled, derived from
      -- erp.count_sheet_is_finished() whatever permission the organisation
      -- puts on the move. Neither is a button.
      ('count_sheet',        'issue',                  'routine', 'erp.raise_count_tasks(text)'),
      ('count_sheet',        'close',                  'routine', 'erp.close_count_sheet_when_finished(uuid)'),

      -- ── The cash receipt (20260930000000) ─────────────────────────────────
      -- Opened by the cash route that applies it and posted by that route once
      -- its lines total what its journals banked, derived from
      -- erp.cash_document_is_applied(). Not a button: refused by hand.
      ('cash_receipt',       'post',                   'routine', 'erp.post_cash_document(uuid)'),

      -- ── The supplier payment (20260930200000) ─────────────────────────────
      -- Opened by the payment run that pays it and posted by that run once
      -- its lines total what its journals paid, derived from
      -- erp.cash_document_is_applied(). Not a button: refused by hand.
      ('cash_payment',       'post',                   'routine', 'erp.post_cash_document(uuid)'),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which only the inventory
      -- installer ships since 20260928200000 (D8). None of them is left to a
      -- door, so the document page draws every move each one declares. An
      -- organisation that applied the pack before then keeps them.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
   -- Version 1 of the transfer order's moves that version 2 does not declare
   -- are kept only while a version in use declares them (20260928200000): an
   -- organisation still on version 1, or a transfer still on it. Once none is,
   -- the rows go, and the register reads as version 2's alone.
   -- And version 1 of the stock adjustment's one move version 2 does not
   -- declare, the same way (20260928500000).
   where not ((x.machine_code = 'transfer_order'
               and x.transition_code in ('approved', 'closed',
                                         'draft_to_discrepancy', 'approved_to_discrepancy', 'issued_to_discrepancy',
                                         'in_transit_to_discrepancy', 'received_to_discrepancy', 'discrepancy_to_received',
                                         'draft_to_cancelled', 'approved_to_cancelled', 'issued_to_cancelled',
                                         'in_transit_to_cancelled', 'received_to_cancelled'))
              or (x.machine_code = 'stock_adjustment'
                  and x.transition_code = 'approved_to_cancelled'))
      or erp.transition_in_use(x.machine_code, x.transition_code)
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The suite that pinned what this moves, re-pinned on purpose
--
--   * erp_test.settlement_is_derived_suite, case 1, pinned a new
--     organisation's procurement controls at version 6, the version that
--     installed part paid. A new organisation is installed at 7 now; the
--     case asks what it always asked, that nothing is left to upgrade.
-- ─────────────────────────────────────────────────────────────────────────────

do $derived_suite$
declare
  v_sig constant text := 'erp_test.settlement_is_derived_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 6
$o$,
    $n$                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls')
              -- Seven since 20260930200000: the supplier payment.
              = 7
$n$];
  v_hits integer;
begin
  if strpos(v_def, 'Seven since 20260930200000') > 0 then
    raise notice '% already pins version 7; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$derived_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C2. The proof: erp_test.cash_receipt_suite, eight cases more
--
-- The suite 20260930000000 made and 20260930100000 extended, edited by
-- anchors. The payment cases go before the organisation is put back to
-- receivables version 1; the one on procurement-controls version 6 puts the
-- organisation back to it and upgrades it again, so the ledger checks after
-- it read an organisation on version 7 with payments posted. It counts 33.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.cash_payment_supplier(p_code text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_supp   uuid;
begin
  -- A supplier of the case's own (20260930200000).
  insert into erp.party (tenant_id, code, name, status)
  values (v_tenant, p_code, 'Cash Payment ' || p_code, 'active') returning id into v_supp;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (v_tenant, v_supp, 'supplier', 'active');
  return v_supp;
end;
$$;

revoke all on function erp_test.cash_payment_supplier(text) from public, anon;

comment on function erp_test.cash_payment_supplier(text) is
  'A supplier for the cash receipt suite''s payment cases (20260930200000).';

create or replace function erp_test.cash_payment_bill(
  p_entity uuid, p_site uuid, p_item uuid, p_supplier uuid, p_price bigint, p_ref text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_po  uuid;
  v_pol uuid;
  v_grn uuid;
begin
  -- One bill from the supplier, registered, through the order, the receipt
  -- and the match, as a bill is (20260930200000). p_ref is the supplier's
  -- own reference for it.
  v_po := erp.open_document('purchase_order', p_supplier, p_entity, p_site);
  v_pol := erp.add_document_line(v_po, p_item, 1, p_price, 'bought for ' || p_ref);
  perform erp.transition_document(v_po, 'submit', null);
  perform erp_test.approve_document(v_po, 'cash receipt suite');
  perform erp.transition_document(v_po, 'send', null);
  v_grn := erp.open_document('goods_receipt', p_supplier, p_entity, p_site);
  perform erp.receive_against(v_grn, v_pol, 1, null);
  perform erp.transition_document(v_grn, 'post', null);
  return erp.bill_from_receipt(v_grn, p_ref, current_date, current_date + 30, true);
end;
$$;

revoke all on function erp_test.cash_payment_bill(uuid, uuid, uuid, uuid, bigint, text) from public, anon;

comment on function erp_test.cash_payment_bill(uuid, uuid, uuid, uuid, bigint, text) is
  'A registered supplier bill for the cash receipt suite''s payment cases (20260930200000).';

create or replace function erp_test.cash_payment_run(
  p_bills uuid[], p_proposer uuid, p_payer uuid, p_short bigint default 0)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_prop   uuid;
  v_pay    jsonb;
begin
  -- A payment run proposed by one administrator and approved and paid by
  -- another (20260930200000). It pays the bills named, p_short less each;
  -- every other open bill the proposal offers is held, so an earlier case's
  -- bill is on no later case's payment.
  perform set_config('request.jwt.claims', json_build_object('sub', p_proposer)::text, true);
  v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
  update erp.payment_proposal_line l
     set is_held = true, hold_reason = 'not this case''s'
   where l.tenant_id = v_tenant and l.payment_proposal_id = v_prop
     and not (l.document_id = any (p_bills));
  update erp.payment_proposal_line l
     set amount_minor = l.amount_minor - p_short
   where l.tenant_id = v_tenant and l.payment_proposal_id = v_prop and not l.is_held;
  perform set_config('request.jwt.claims', json_build_object('sub', p_payer)::text, true);
  perform erp.approve_payment_run(v_prop);
  v_pay := erp.pay_payment_run(v_prop);
  perform set_config('request.jwt.claims', json_build_object('sub', p_proposer)::text, true);
  return v_pay;
end;
$$;

revoke all on function erp_test.cash_payment_run(uuid[], uuid, uuid, bigint) from public, anon;

comment on function erp_test.cash_payment_run(uuid[], uuid, uuid, bigint) is
  'A payment run proposed by one administrator and paid by another, of the bills named, for the '
  'cash receipt suite (20260930200000).';

do $receipt_suite$
declare
  v_sig constant text := 'erp_test.cash_receipt_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  -- Twenty-five since 20260930100000: a statement's lines are receipts.
  c_expected constant integer := 25;$o$,
    $n$  -- Thirty-three since 20260930200000: a payment run pays each supplier
  -- with a document, and prints its remittance advice.
  c_expected constant integer := 33;$n$,

    $o$  v_gross3 bigint; v_n4 integer; v_n5 integer; v_cases_seen integer; v_cust2 uuid;
begin$o$,
    $n$  v_gross3 bigint; v_n4 integer; v_n5 integer; v_cases_seen integer; v_cust2 uuid;
  -- The payment cases (20260930200000).
  a2 uuid := gen_random_uuid();
  v_second uuid; v_tok2 text;
  v_sa uuid; v_sb uuid; v_sc uuid; v_sd uuid; v_se uuid;
  v_ba1 uuid; v_ba2 uuid; v_bb1 uuid; v_bc1 uuid; v_bd1 uuid; v_be1 uuid; v_be2 uuid;
  v_ga1 bigint; v_ga2 bigint; v_gb1 bigint; v_gd1 bigint;
  v_pay jsonb; v_pay2 jsonb; v_pmt uuid; v_pmt2 uuid; v_pmts text; v_render jsonb;
begin$n$,

    $o$    -- ── 11. An organisation on version 1, and its upgrade ───────────────────
$o$,
    $n$    -- ── 26. The supplier payment: declared, installed at version 7, alive ───
    v_step := 'a second administrator, because a payment run is not approved by its proposer';
    insert into auth.users (id, email) values (a2, 'second@zzcrc-' || v_tag || '.test');
    res := public.erp_invite_principal('second@zzcrc-' || v_tag || '.test', 'Cash Receipt Second');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok2 := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'the payment type, its installer, its printout and the configuration checks';
    select count(*) into v_n from erp.dead_configuration_report() c
     where c.reference like '%cash\_payment%' or c.detail like '%cash\_payment%'
        or c.reference like '%remittance%' or c.detail like '%remittance%';
    select count(*) into v_n2 from erp.undriven_transition_report() c
     where c.reference like 'cash\_payment%';
    begin
      v_err := erp.assert_output_templates_sound();
      v_err := 'sound';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'the supplier payment is declared, installed with procurement controls at version 7 from one helper with its remittance advice, driven by a routine, placed as a supplier''s, and nothing of it is dead configuration';
    passed := v_state is null
          and (select count(*) from erp_ref.module_upgrade_item ui
                 join jsonb_array_elements(erp.cash_payment_pack_items()) i
                   on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
                  and i.value -> 'payload' = ui.payload
                where ui.install_code = 'procurement-controls' and ui.to_version = 7) = 4
          and (select mi.current_version from erp_ref.module_installer mi
                where mi.install_code = 'procurement-controls') = 7
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 7
          and exists (select 1 from erp.document_type dt
                        join erp.numbering_rule nr on nr.id = dt.numbering_rule_id and nr.prefix = 'PMT-'
                       where dt.tenant_id = rb.tenant_id and dt.code = 'cash_payment' and dt.status = 'active'
                         and dt.base_type_code = 'cash_payment' and dt.state_machine_code = 'cash_payment'
                         and dt.create_permission = 'finance.post'
                         and dt.stock_movement_type is null and dt.posting_rule_code is null
                         and erp.document_type_party_role_kind(rb.tenant_id, dt.id) = 'supplier')
          and exists (select 1 from erp.output_template ot
                       where ot.tenant_id = rb.tenant_id and ot.code = 'remittance_advice'
                         and ot.base_type_code = 'cash_payment' and ot.kind = 'document' and ot.status = 'active'
                         and exists (select 1 from erp.output_template_version tv
                                      where tv.tenant_id = ot.tenant_id and tv.output_template_id = ot.id
                                        and tv.status = 'active' and tv.required_permission = 'finance.post'))
          and exists (select 1 from jsonb_array_elements(erp.transition_driver_register()) x
                       where x ->> 'machine_code' = 'cash_payment' and x ->> 'transition_code' = 'post'
                         and x ->> 'driver' = 'routine' and x ->> 'detail' = 'erp.post_cash_document(uuid)')
          and (select r2.route from erp.document_reversal_route() r2 where r2.base_type_code = 'cash_payment') = 'by_journal'
          and v_n = 0 and v_n2 = 0 and v_err = 'sound';
    detail := coalesce(v_state, format('%s dead, %s undriven; templates %s', v_n, v_n2, v_err));
    return next;

    -- ── 27. Three bills of two suppliers, two payments ──────────────────────
    v_step := 'three bills of two suppliers, and a fourth of a third, held, in one run';
    v_sa := erp_test.cash_payment_supplier('ZPA');
    v_sb := erp_test.cash_payment_supplier('ZPB');
    v_sc := erp_test.cash_payment_supplier('ZPC');
    v_ba1 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sa, 20000, 'ZPA-INV-1');
    v_ba2 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sa, 30000, 'ZPA-INV-2');
    v_bb1 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sb, 40000, 'ZPB-INV-1');
    v_bc1 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sc, 10000, 'ZPC-INV-1');
    select dv.gross_minor::bigint into v_ga1 from erp.document_view dv where dv.id = v_ba1;
    select dv.gross_minor::bigint into v_ga2 from erp.document_view dv where dv.id = v_ba2;
    select dv.gross_minor::bigint into v_gb1 from erp.document_view dv where dv.id = v_bb1;
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment';
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    v_pay := erp_test.cash_payment_run(array[v_ba1, v_ba2, v_bb1], a1, a2);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment';
    select d.id into v_pmt from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment' and d.party_id = v_sa;
    select d.id into v_pmt2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment' and d.party_id = v_sb;
    select string_agg(d.document_number, ',' order by d.document_number) into v_pmts
      from erp.document d where d.id in (v_pmt, v_pmt2);
    -- Each payment: posted by the system, the run's, the supplier's, and its
    -- lines what its own journals paid through the bank.
    select count(*) into v_n3
      from erp.document d
     where d.id in (v_pmt, v_pmt2)
       and erp.object_current_state('document', d.id) = 'posted'
       and (select lg.guard_data #>> '{derived,fact}' from erp.state_transition_log lg
             where lg.tenant_id = rb.tenant_id and lg.object_type = 'document' and lg.object_id = d.id
               and lg.transition_code = 'post') = 'erp.cash_document_is_applied'
       and d.our_reference = v_pay ->> 'reference'
       and d.document_date = current_date and d.entity_id = v_entity and d.currency = v_ccy
       and d.party_role_id is not null
       and d.attributes ->> 'payment_proposal_id' = v_pay ->> 'proposal_id'
       and d.attributes ->> 'route' = 'payment_run'
       and (select sum(l.net_minor) from erp.document_line l where l.document_id = d.id)
         = (select sum(si.credit_minor - si.debit_minor) from erp.subledger_item si
             where si.control_kind = 'bank'
               and si.journal_id in (select j.id from erp.journal j where j.document_id = d.id))
       and not exists (select 1 from erp.document_line l where l.document_id = d.id and l.item_id is not null);
    v_cases := v_cases + 1;
    case_name := 'a run paying three bills of two suppliers makes two posted payments, PMT-000001 and PMT-000002, posted by the system; each supplier''s lines are its bills and total what the bank paid it, every payment journal names its payment, and the bills are Paid';
    passed := v_state is null
          and v_n2 = v_n + 2
          and v_pmts = 'PMT-000001,PMT-000002'
          and v_n3 = 2
          and (select count(*) from erp.document_line l where l.document_id = v_pmt) = 2
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_pmt) = v_ga1 + v_ga2
          and (select string_agg(l.description, ' / ' order by l.description) from erp.document_line l
                where l.document_id = v_pmt)
              = (select string_agg(b.document_number || ', your ref ' || b.their_reference, ' / '
                                   order by b.document_number || ', your ref ' || b.their_reference)
                   from erp.document b where b.id in (v_ba1, v_ba2))
          and (select count(*) from erp.document_line l where l.document_id = v_pmt2) = 1
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_pmt2) = v_gb1
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.document_id = v_pmt
                  and j.source_code = 'payment.made' and j.status = 'posted') = 2
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.document_id = v_pmt2
                  and j.source_code = 'payment.made' and j.status = 'posted') = 1
          and v_b0 - v_b1 = v_ga1 + v_ga2 + v_gb1
          and erp.object_current_state('document', v_ba1) = 'paid'
          and erp.object_current_state('document', v_ba2) = 'paid'
          and erp.object_current_state('document', v_bb1) = 'paid';
    detail := coalesce(v_state, format('payments %s then %s, numbered %s, %s as they should be; bank paid %s; answer %s',
      v_n, v_n2, coalesce(v_pmts, 'none'), v_n3, v_b0 - v_b1, left(coalesce(v_pay::text, 'none'), 300)));
    return next;

    -- ── 28. The run's answer lists them ─────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the run''s answer lists both payments, with their numbers, suppliers and what each was paid, beside what it answered before';
    passed := v_state is null
          and jsonb_array_length(v_pay -> 'payments') = 2
          and v_pay -> 'payments' @> jsonb_build_array(
                jsonb_build_object('document_id', v_pmt, 'document_number',
                                   (select d.document_number from erp.document d where d.id = v_pmt),
                                   'party_id', v_sa, 'paid_minor', v_ga1 + v_ga2))
          and v_pay -> 'payments' @> jsonb_build_array(
                jsonb_build_object('document_id', v_pmt2, 'document_number',
                                   (select d.document_number from erp.document d where d.id = v_pmt2),
                                   'party_id', v_sb, 'paid_minor', v_gb1))
          and (select string_agg(x ->> 'document_number', ',' order by o)
                 from jsonb_array_elements(v_pay -> 'payments') with ordinality t(x, o)) = v_pmts
          and (v_pay ->> 'lines_paid')::integer = 3
          and (v_pay ->> 'paid_minor')::bigint = v_ga1 + v_ga2 + v_gb1
          and (v_pay ->> 'written_off_minor')::bigint = 0
          and (v_pay ->> 'documents_settled')::integer = 3
          and (v_pay ->> 'held')::integer = 1
          and v_pay ?& array['proposal_id', 'reference', 'currency'];
    detail := coalesce(v_state, left(coalesce(v_pay::text, 'none'), 400));
    return next;

    -- ── 29. A held line is on no payment ────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a held line is on no payment: its supplier has none, no line names its bill, and the bill is still owed';
    passed := v_state is null
          and not exists (select 1 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                           where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment'
                             and d.party_id = v_sc)
          and not exists (select 1 from erp.document_line l
                            join erp.document d on d.id = l.document_id
                            join erp.document_type dt on dt.id = d.document_type_id
                           where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment'
                             and l.description like (select b.document_number from erp.document b where b.id = v_bc1) || '%')
          and erp.object_current_state('document', v_bc1) = 'registered'
          and exists (select 1 from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.document_id = v_bc1);
    detail := coalesce(v_state, format('the held bill is %s', erp.object_current_state('document', v_bc1)));
    return next;

    -- ── 30. A penny short, within the tolerance ─────────────────────────────
    v_step := 'a bill paid a penny short';
    v_sd := erp_test.cash_payment_supplier('ZPD');
    v_bd1 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sd, 50000, 'ZPD-INV-1');
    select dv.gross_minor::bigint into v_gd1 from erp.document_view dv where dv.id = v_bd1;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    v_pay2 := erp_test.cash_payment_run(array[v_bd1], a1, a2, 1);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_rcpt := (v_pay2 -> 'payments' -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a bill paid a penny short at £1: the payment''s one line is what was paid, the write-off journal names the payment, the lines total the bank, and the bill is Paid';
    passed := v_state is null
          and jsonb_array_length(v_pay2 -> 'payments') = 1
          and (select d.party_id from erp.document d where d.id = v_rcpt) = v_sd
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt) = 1
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_gd1 - 1
          and v_b0 - v_b1 = v_gd1 - 1
          and v_d1 - v_d0 = -1
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt
                  and j.source_code = 'cash.settlement_difference_posted') = 1
          and (v_pay2 ->> 'written_off_minor')::bigint = 1
          and erp.object_current_state('document', v_bd1) = 'paid';
    detail := coalesce(v_state, format('bank paid %s, 7900 moved %s; journals %s; bill %s; answer %s', v_b0 - v_b1, v_d1 - v_d0,
      (select string_agg(j.source_code, ',') from erp.journal j where j.document_id = v_rcpt),
      erp.object_current_state('document', v_bd1), left(coalesce(v_pay2::text, 'none'), 200)));
    return next;

    -- ── 31. The remittance advice ───────────────────────────────────────────
    v_step := 'the remittance advice of the first supplier''s payment';
    v_render := public.erp_render_remittance_advice(v_pmt, 'en');
    select jsonb_agg(b) into v_rows from jsonb_array_elements(v_render -> 'blocks') b
     where b ->> 'kind' = 'lines';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_render_remittance_advice(v_pmt, 'en');
      v_err := 'rendered';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      perform public.erp_render_remittance_advice(
        (select d.id from erp.document d join erp.document_type dt on dt.id = d.document_type_id
          where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt' limit 1), 'en');
      v_err2 := 'rendered';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin
      update erp.output_template set status = 'inactive'
       where tenant_id = rb.tenant_id and base_type_code = 'cash_payment';
      begin
        perform public.erp_render_remittance_advice(v_pmt, 'en');
        v_err3 := 'rendered';
      exception when others then v_err3 := left(sqlerrm, 160); end;
      raise exception 'CLOVEERP_TEMPLATE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_TEMPLATE_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'the remittance advice renders for finance.post: the payment''s number, our reference, each bill paid by number with its amount, and the total; refused to finance.read, for a receipt, and with no layout';
    passed := v_state is null
          and v_render ->> 'template' = 'remittance_advice'
          and v_render ->> 'title' = 'Remittance advice'
          and (v_render ->> 'document_id')::uuid = v_pmt
          and (select string_agg(b ->> 'kind', ',' order by o) from jsonb_array_elements(v_render -> 'blocks') with ordinality t(b, o))
              = 'title,issuer,counterparty,summary,lines,totals'
          and v_render -> 'blocks' -> 0 -> 'fields' -> 0 ->> 'value' = (select d.document_number from erp.document d where d.id = v_pmt)
          and exists (select 1 from jsonb_array_elements(v_render -> 'blocks' -> 3 -> 'fields') f
                       where f ->> 'field' = 'our_reference' and f ->> 'value' = v_pay ->> 'reference')
          and exists (select 1 from jsonb_array_elements(v_render -> 'blocks' -> 2 -> 'fields') f
                       where f ->> 'field' = 'party_name' and f ->> 'value' = 'Cash Payment ZPA')
          and v_rows -> 0 ->> 'label' = 'Bills paid'
          and jsonb_array_length(v_rows -> 0 -> 'rows') = 2
          and (select string_agg(x ->> 'description' || '=' || (x ->> 'net_amount'), ' / ' order by x ->> 'description')
                 from jsonb_array_elements(v_rows -> 0 -> 'rows') x)
              = (select string_agg(b.document_number || ', your ref ' || b.their_reference || '='
                                   || (select dv.gross_minor::bigint from erp.document_view dv where dv.id = b.id),
                                   ' / ' order by b.document_number || ', your ref ' || b.their_reference)
                   from erp.document b where b.id in (v_ba1, v_ba2))
          and (v_render -> 'blocks' -> 5 -> 'fields' -> 0 ->> 'value')::bigint = v_ga1 + v_ga2
          and erp.render_output_template('remittance_advice', v_pmt, 'en') -> 'blocks' = v_render -> 'blocks'
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.post%'
          and v_err2 like 'CLOVEERP_NOT_A_CASH_PAYMENT:%'
          and v_err3 like 'CLOVEERP_REMITTANCE_HAS_NO_TEMPLATE:%';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, left(coalesce(v_render::text, 'nothing'), 400)));
    return next;

    -- ── 32. Nothing by hand ─────────────────────────────────────────────────
    v_step := 'a payment opened, written, posted and reversed by hand';
    v_line := (select l.id from erp.document_line l where l.document_id = v_pmt order by l.line_no limit 1);
    begin
      perform public.erp_create_document('cash_payment', v_sa, null, 'by hand', null, v_entity, null, null);
      v_err := 'opened';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform erp.create_document_full('cash_payment', v_sa, null, 'by hand', null, null, '[]'::jsonb, null);
      v_err2 := 'opened';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin
      update erp.document_line set net_minor = net_minor + 100 where id = v_line;
      v_err4 := 'amended';
    exception when others then v_err4 := left(sqlerrm, 160); end;
    v_draft := erp.open_document('cash_payment', v_sa, v_entity, null, 'by hand', null, v_ccy);
    begin
      perform erp.add_document_line(v_draft, v_item, 1, 100, 'by hand');
      v_err3 := 'added';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    begin
      perform erp.transition_document(v_draft, 'post', 'by hand');
      v_err5 := 'posted';
    exception when others then v_err5 := left(sqlerrm, 160); end;
    begin
      perform erp.post_cash_document(v_draft);
      v_planned := 'posted';
    exception when others then v_planned := left(sqlerrm, 160); end;
    begin
      perform erp.reverse_document_posting(v_pmt, 'The bank returned it');
      v_fact := 'reversed';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_fact := left(sqlerrm, 160);
    end;
    v_cases := v_cases + 1;
    case_name := 'opening a payment, adding or changing a line of one, posting one or reversing one by hand is refused by name, to an administrator; a payment is corrected with a journal';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_DOCUMENT_IS_RAISED:%'
          and v_err2 like 'CLOVEERP_CASH_DOCUMENT_IS_RAISED:%'
          and v_err3 like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_err4 like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_err5 like 'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED:%'
          and v_planned like 'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED:%'
          and v_fact like 'CLOVEERP_DOCUMENT_NOT_REVERSIBLE:%'
          and v_hint like 'A supplier payment is corrected with a journal%'
          and erp.object_current_state('document', v_draft) = 'draft'
          and not exists (select 1 from erp.document_line l where l.document_id = v_draft)
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_pmt) = v_ga1 + v_ga2;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_planned, v_fact, v_hint));
    return next;

    -- ── 33. An organisation on version 6, and its upgrade ───────────────────
    v_step := 'putting the organisation back to procurement controls version 6';
    update erp.document_type set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'cash_payment';
    update erp.state_machine set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'cash_payment';
    update erp.output_template set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'remittance_advice';
    update erp.module_installation i set installer_version = 6
     where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls';
    v_se := erp_test.cash_payment_supplier('ZPE');
    v_be1 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_se, 50000, 'ZPE-INV-1');
    v_be2 := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_se, 60000, 'ZPE-INV-2');
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment';
    v_pay2 := erp_test.cash_payment_run(array[v_be1], a1, a2);
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_payment';
    v_step := 'upgrading procurement controls to version 7';
    select string_agg(p.object_kind || ' ' || p.object_key, ', ' order by p.seq)
      into v_planned
      from erp.plan_module_upgrade('procurement-controls') p;
    res := erp.upgrade_module_configuration('procurement-controls');
    v_pay := erp_test.cash_payment_run(array[v_be2], a1, a2);
    v_pmt := (v_pay -> 'payments' -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'an organisation still on procurement controls version 6 pays a run as before, with no payment and an answer without one; the upgrade to version 7 installs the payment and its printout, and the next run opens one';
    passed := v_state is null
          and v_n2 = v_n
          and not (v_pay2 ? 'payments')
          and (v_pay2 ->> 'paid_minor')::bigint = (select dv.gross_minor::bigint from erp.document_view dv where dv.id = v_be1)
          and (select count(*) from erp.journal j
                join erp.subledger_item si on si.journal_id = j.id and si.control_kind = 'payable'
               where j.tenant_id = rb.tenant_id and j.source_code = 'payment.made'
                 and si.document_id = v_be1 and j.document_id is null) = 1
          and erp.object_current_state('document', v_be1) = 'paid'
          and strpos(coalesce(v_planned, ''), 'document_type cash_payment') > 0
          and strpos(coalesce(v_planned, ''), 'output_template remittance_advice') > 0
          and (res ->> 'to_version')::integer = 7 and (res ->> 'promoted')::boolean
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 7
          and not exists (select 1 from erp.plan_module_upgrade('procurement-controls'))
          and erp.object_current_state('document', v_pmt) = 'posted'
          and (select d.party_id from erp.document d where d.id = v_pmt) = v_se
          and public.erp_render_remittance_advice(v_pmt, 'en') ->> 'template' = 'remittance_advice';
    detail := coalesce(v_state, format('payments %s then %s; v6 answer %s; planned %s; %s; v7 answer %s', v_n, v_n2,
      left(coalesce(v_pay2::text, 'none'), 200), coalesce(v_planned, 'nothing'), res::text,
      left(coalesce(v_pay::text, 'none'), 200)));
    return next;

    -- ── 11. An organisation on version 1, and its upgrade ───────────────────
$n$];
  v_hits integer;
begin
  if strpos(v_def, 'c_expected constant integer := 33;') > 0 then
    raise notice '% already proves the supplier payment; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$receipt_suite$;

comment on function erp_test.cash_receipt_suite() is
  'Apply cash opens a cash receipt per company, numbered RCPT-, whose lines are what the cash paid '
  'and kept, whose journals name it, and which the system posts (20260930000000). Paid, part paid '
  'and the tolerance are kept; the ageing is what it was; nobody opens, writes or posts one by hand; '
  'the billed meter does not move; an organisation on receivables version 1 applies cash as before '
  'and takes the receipt from the upgrade. A settlement statement''s matched line is a receipt of '
  'its own, of the matched item''s customer and company, and cash reaching two companies is a '
  'receipt in each (20260930100000). A payment run pays each supplier with a payment, numbered '
  'PMT-, whose lines are the bills it paid and whose journals name it, posted by the system and '
  'printed as a remittance advice by finance.post; an organisation on procurement controls version 6 '
  'pays as before and takes the payment from the upgrade (20260930200000).';

do $receipt_assert$
declare
  v_sig constant text := 'erp_test.assert_cash_receipt_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  if v_total <> 25 then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_SHRANK: % case(s), expected 25', v_total$o$,
    $n$  if v_total <> 33 then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_SHRANK: % case(s), expected 33', v_total$n$];
  v_hits integer;
begin
  if strpos(v_def, 'expected 33') > 0 then
    raise notice '% already expects 33 cases; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$receipt_assert$;
-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
