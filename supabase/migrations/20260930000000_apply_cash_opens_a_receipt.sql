set lock_timeout = '30s';

-- =============================================================================
-- 20260930000000  Apply cash opens a receipt
-- -----------------------------------------------------------------------------
-- PR13 M1 (docs/spec/simplification-review.md §7 Finance, node F5): the cash
-- receipt, a document for the money Apply cash banks. On top of the part-paid
-- invoice (20260929100000), the cash tolerance (20260929300000) and the shape
-- the screens milestone gave erp.apply_cash()'s answer (20260929400000).
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- "Cash arrives as a bare subledger write through erp.apply_cash() with no
-- document." Not bare: it posts a journal (cash.applied, Dr bank Cr the
-- receivable), paired subledger rows and a settlement of the invoice's row.
-- What it does not have is a document. Every cash journal leaves
-- journal.document_id null, so a receipt has no number, nothing to open, and
-- nothing that says which invoices one payment paid; its only trace is a free
-- text reference and an event aggregated on the customer.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A base type, cash_receipt: finance, no flow, moves no stock and is
--     posted by nothing generic (its journals are the cash routes'), needs a
--     party, and is raised under finance.post.
--   * Shipped as configuration from one helper, erp.cash_receipt_pack_items():
--     a lifecycle (draft, then posted by one move, post), a numbering rule
--     (RCPT-, never reset, not gapless) and a document type. Installed by
--     erp.configure_receivables() and offered as version 2 of receivables,
--     its first upgrade, to an organisation on version 1 (D1).
--   * Posted is terminal and not committed (D4): a receipt posts nothing
--     through erp.transition_document(), which would otherwise try to post it,
--     and it does not count on the billed documents_posted meter.
--   * erp.apply_cash() opens one receipt per company the cash reaches (D5),
--     through erp.open_document(), dated the day the money arrived, with the
--     reference as the customer's. Each item the cash settles is a line of it,
--     with no item: the invoice's number and the amount applied. What is left
--     after every item, kept on account or credited within the tolerance, is
--     a line too, so the lines total what the bank was debited. Every journal
--     the receipt writes names it, the tolerance's among them. The receipt is
--     then posted by the system, derived from erp.cash_document_is_applied():
--     its lines are what its posted journals banked. A refusal of that move is
--     raised, not recorded: the cash and its receipt are one statement.
--   * The receipt's settling row names the invoice it settles (D2), as the
--     settlement statement's route always has. erp.ageing_balance gives the
--     same figures either way; what changes is that "what paid this invoice"
--     can be read.
--   * The answer gains document_id, the receipt of the row's company; the
--     remainder row carries the last company's. The three forms are made
--     again in one block, with the same arguments, grants and allowance.
--   * Nobody opens a receipt, adds a line to one or posts one by hand, even an
--     administrator: the two doors that open a named type refuse it, as does
--     the line door, a trigger holds a posted receipt's lines, and the move
--     by hand is refused while its fact does not hold.
--   * A receipt's party is placed as a customer: the party role kind is read
--     from the base type where the create permission is not a trade's (D16).
--   * The reversal register: by_journal. A misapplied or returned receipt is
--     corrected with a journal; the generic reversal stays refused.
--   * An organisation still on receivables version 1 has no receipt type, and
--     applies cash exactly as before: no document, and the settling row names
--     none (D1).
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * The settlement statement's lines (M2) and the payment run (M3) are
--     still documentless; their routes are unchanged here.
--   * No backfill (D3). Past cash stays without a document, and every reader
--     takes a cash journal that names none.
--   * The two F3 helpers keep their signatures. Each returns the journal it
--     writes, so erp.apply_cash() names the receipt on it and writes the
--     line: one statement fewer to drop and recreate than a new argument, on
--     a route that has had three bodies in a week. M2 and M3 can do the same.
--   * No screen. The desk reads document_id in M4; until then the client's
--     DOOR_ONLY_TRANSITIONS takes cash_receipt: post, in this pull request,
--     because src/lib/stage-records.test.ts holds it to the newest driver
--     register, which this restates.
--   * No reversal: a receipt is corrected by a journal, and the register says
--     so (D10).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_CASH_DOCUMENT_IS_RAISED',
  'Opening a cash receipt by hand.',
  'A cash receipt is the record of money the bank received and the invoices it paid; one opened by hand would carry no cash, name no journal and never be posted.',
  'Apply the cash from Cash in. Its receipt is opened and posted with it.');

select erp.register_refusal('CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH',
  'Adding a line to a cash receipt, or changing one, by hand.',
  'Each line of a cash receipt is cash the bank received, applied to an invoice or kept on the customer''s account, and its lines total what the bank was debited; a line written by hand would say the bank received money it did not.',
  'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.');

select erp.register_refusal('CLOVEERP_CASH_DOCUMENT_NOT_APPLIED',
  'Posting a cash receipt whose cash is not applied.',
  'A cash receipt is posted when its lines total what its posted journals banked, and by the cash route that wrote them; posted by hand it would say money arrived that no journal records.',
  'Apply the cash from Cash in. Its receipt is posted with it.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The base type
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.document_type
  (code, name_key, module_code, flow, affects_stock, affects_finance, requires_party,
   requires_site, description, create_permission)
values
  ('cash_receipt', 'document.cash_receipt', 'finance', 'none', false, false, true, false,
   'A cash receipt: the money one payment brought in, and the invoices it paid. Its journals are '
   'written by the cash route that opens it, erp.apply_cash(), and name it; nothing posts it '
   'generically, and it is posted by that route when its lines total what its journals banked '
   '(20260930000000).',
   'finance.post')
on conflict (code) do update
  set name_key = excluded.name_key, module_code = excluded.module_code, flow = excluded.flow,
      affects_stock = excluded.affects_stock, affects_finance = excluded.affects_finance,
      requires_party = excluded.requires_party, requires_site = excluded.requires_site,
      description = excluded.description, create_permission = excluded.create_permission;

do $base$
begin
  if (select count(*) from erp_ref.document_type bt
       where bt.code = 'cash_receipt' and bt.module_code = 'finance' and bt.flow = 'none'
         and not bt.affects_stock and not bt.affects_finance and bt.requires_party
         and not bt.requires_site and bt.create_permission = 'finance.post') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: base type cash_receipt is not the row this migration declares';
  end if;
end
$base$;

insert into erp_ref.resource (key, locale, value, description) values
  ('document.cash_receipt', 'en', 'Cash receipt', 'Document base type name (20260930000000).'),
  ('document.cash_receipt', 'de', 'Zahlungseingang', null)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The receipt, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cash_receipt_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The cash receipt (20260930000000), read by erp.configure_receivables() for
  -- a new install and by the upgrade register for an organisation on version
  -- 1, so the two cannot disagree. In the order a change set applies them: the
  -- lifecycle and the sequence before the type that names them.
  --
  -- The lifecycle is the cash route's, not a person's: opened by
  -- erp.apply_cash(), and posted by erp.post_cash_document() once its lines
  -- total what its journals banked, derived from erp.cash_document_is_applied().
  -- Posted is terminal and not committed (D4): the journals are the route's,
  -- and a receipt is not a document posted on the billed meter.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'cash_receipt', 'payload',
      jsonb_build_object(
        'code', 'cash_receipt', 'object_type', 'document', 'name', 'Cash receipt',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','posted','name','Posted','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',20)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','finance.post','sort_order',10)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'cash_receipt', 'payload',
      jsonb_build_object('code','cash_receipt','prefix','RCPT-','pad_to',6,
                         'reset_period','never','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'cash_receipt', 'payload',
      jsonb_build_object('code','cash_receipt','base_type','cash_receipt',
                         'name','Cash receipt','numbering_rule','cash_receipt',
                         'state_machine','cash_receipt',
                         'create_permission','finance.post')))
$$;

comment on function erp.cash_receipt_pack_items() is
  'The cash receipt (20260930000000): its lifecycle, numbering rule and document type, the items '
  'erp.configure_receivables() and the receivables upgrade register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_receivables(integer,integer,integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          'levels', v_levels))));$o$;
  v_new constant text := $n$          'levels', v_levels)))
      -- The cash receipt (20260930000000), from its one helper.
      || erp.cash_receipt_pack_items());$n$;
  v_hits integer;
begin
  if strpos(v_def, 'erp.cash_receipt_pack_items()') > 0 then
    raise notice '% already installs the cash receipt; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % dunning levels anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The upgrade register: version 2 for an organisation on version 1
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 2,
       description = description
         || ' Version 2 (20260930000000): Apply cash opens a numbered cash receipt, posted '
         || 'with the cash, whose lines are the invoices it paid.'
 where install_code = 'receivables' and current_version = 1;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'receivables', 2, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.cash_receipt_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'receivables') is distinct from 2 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the receivables installer is not at version 2';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.cash_receipt_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'receivables' and ui.to_version = 2) <> 3
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'receivables' and ui.to_version = 2) <> 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 2 of receivables is not the three items the cash receipt ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. When a receipt is applied, and the routine that posts it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cash_document_is_applied(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A cash receipt is applied when it is a draft, at least one posted journal
  -- names it, and its lines total what those journals banked: the bank rows
  -- they wrote, debits less credits (20260930000000). Read by the routine that
  -- posts it and again by the engine, with the receipt's state locked, as the
  -- fact the post is derived from.
  with j as (
    select j.id from erp.journal j
     where j.tenant_id = erp.current_tenant_id() and j.document_id = p_document_id
       and j.status = 'posted')
  select erp.object_current_state('document', p_document_id) = 'draft'
     and exists (select 1 from j)
     and (select coalesce(sum(l.net_minor), 0) from erp.document_line l
           where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id
             and not l.is_cancelled)
       = (select coalesce(sum(si.debit_minor - si.credit_minor), 0) from erp.subledger_item si
           where si.tenant_id = erp.current_tenant_id() and si.control_kind = 'bank'
             and si.journal_id in (select j.id from j))
$$;

revoke all on function erp.cash_document_is_applied(uuid) from public, anon;

comment on function erp.cash_document_is_applied(uuid) is
  'True when a cash receipt is a draft whose lines total what the posted journals naming it banked '
  '(20260930000000).';

create or replace function erp.post_cash_document(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_prev text;
  v_to   text;
begin
  -- Posts a cash receipt its route has applied (20260930000000). The move is
  -- the system's, derived from erp.cash_document_is_applied(), named in
  -- erp.deriving_move immediately before it and put back after. A refusal is
  -- raised, not recorded: the cash and its receipt are one statement of fact,
  -- and cash banked with its receipt left a draft would be neither.
  if not erp.cash_document_is_applied(p_document_id) then
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
  'Posts a cash receipt once its cash is applied (20260930000000): the system''s move, derived from '
  'erp.cash_document_is_applied(). Refuses, rather than records, a receipt that is not.';

-- The fact the post is derived from, read again with the receipt's state
-- locked. Deployed body, asserted needle: one arm more in the document case.
do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$             then 'erp.count_sheet_is_finished'
$o$;
  v_new constant text := $n$             then 'erp.count_sheet_is_finished'
           -- A cash receipt's post, once its lines total what its journals
           -- banked (20260930000000), asked for by erp.post_cash_document().
           when dt.base_type_code = 'cash_receipt' and p_transition_code = 'post'
            and erp.cash_document_is_applied(p_object_id)
             then 'erp.cash_document_is_applied'
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'erp.cash_document_is_applied') > 0 then
    raise notice '% already derives a cash receipt''s post; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count sheet arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- By hand, a cash receipt does not move at all: its one move is the route's.
do $transition$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$o$;
  v_new constant text := $n$  -- A cash receipt is posted by the cash route that applied it
  -- (20260930000000): erp.post_cash_document() makes the move when its fact
  -- holds, and this refuses it to anybody else, an administrator included.
  if dt.base_type_code = 'cash_receipt'
     and erp.derived_move_fact('document', p_document_id, p_transition_code) is null then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED: % is a cash receipt, and moves only as the cash it records is applied (%)',
      coalesce(d.document_number, p_document_id::text), p_transition_code
      using errcode = '23514',
            hint = 'Apply the cash from Cash in. Its receipt is posted with it.';
  end if;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED') > 0 then
    raise notice '% already refuses a cash receipt moved by hand; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % context anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. A receipt's party is a customer (D16)
--
-- The create permission says which side of the trade a type is on, and a
-- finance.* permission says neither, so a receipt carried no party role.
-- Replaced whole, over the body 20260916042000 left.
-- ─────────────────────────────────────────────────────────────────────────────

do $anchor_role$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'erp.document_type_party_role_kind(uuid,uuid)'::regprocedure);
begin
  if position('cash_receipt' in v_src) > 0 then
    raise notice 'erp.document_type_party_role_kind(uuid,uuid) already places a cash receipt; replaced with the same body';
  elsif md5(v_src) <> 'fd420d46e227e7af4166240d2ea11fbf' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.document_type_party_role_kind(uuid,uuid) is not the body 20260916042000 left (md5 %)', md5(v_src);
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
  -- customer's (20260930000000).
  select case split_part(coalesce(dt.create_permission, bt.create_permission), '.', 1)
           when 'sales'       then 'customer'::erp.party_role_kind
           when 'procurement' then 'supplier'::erp.party_role_kind
           else case bt.code
                  when 'cash_receipt' then 'customer'::erp.party_role_kind
                  else null
                end
         end
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = p_tenant_id and dt.id = p_document_type_id;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. Nobody opens a receipt or writes its lines by hand
-- ─────────────────────────────────────────────────────────────────────────────

-- The two doors that open a document of a type the caller names refuse it,
-- beside the count sheet's refusal; erp.apply_cash() opens its receipts
-- through erp.open_document().
do $create$
declare
  v_doors constant text[] := array[
    'public.erp_create_document(text,uuid,uuid,text,date,uuid,text,uuid)',
    'erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)'];
  v_old constant text := $o$            hint = 'Raise the programme from Counting. Its sheet is opened with its counts.';
  end if;
$o$;
  v_new constant text := $n$            hint = 'Raise the programme from Counting. Its sheet is opened with its counts.';
  end if;
  -- A cash receipt is opened by applying the cash it records (20260930000000).
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = erp.current_tenant_id() and dt.code = p_type_code
                and dt.base_type_code = 'cash_receipt') then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_IS_RAISED: % is a cash receipt, opened when the cash it records is applied',
      p_type_code
      using errcode = '23514',
            hint = 'Apply the cash from Cash in. Its receipt is opened and posted with it.';
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
      if strpos(v_body, 'CLOVEERP_CASH_DOCUMENT_IS_RAISED') > 0 then
        raise notice '% already refuses a cash receipt; left as it is', v_sig;
        continue;
      end if;
      v_hits := (length(v_body) - length(replace(v_body, v_old, ''))) / length(v_old);
      if v_hits <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % count sheet refusal found % time(s)', v_sig, v_hits;
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
  v_old constant text := $o$            hint = 'Raise a count for the place from Counting. It goes on a sheet of its own.';
  end if;
$o$;
  v_new constant text := $n$            hint = 'Raise a count for the place from Counting. It goes on a sheet of its own.';
  end if;

  -- Each line of a cash receipt is cash the bank received, and
  -- erp.apply_cash() writes them (20260930000000).
  if v_base = 'cash_receipt' then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is a cash receipt, and its lines are the cash applied',
      d.document_number
      using errcode = '23514',
            hint = 'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.';
  end if;
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH') > 0 then
    raise notice '% already refuses a line on a cash receipt; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count sheet refusal found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lines$;

-- A posted receipt's lines stay what its route wrote. The route writes them
-- while the receipt is a draft, in the statement that posts it; after that,
-- the doors that amend a line, move its stock identity or reserve for it would
-- change what the bank is said to have received. One trigger holds every door.
create or replace function erp.protect_posted_cash_document()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_doc    uuid := coalesce(new.document_id, old.document_id);
  v_tenant uuid := coalesce(new.tenant_id, old.tenant_id);
  v_number text;
begin
  select d.document_number into v_number
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = v_doc and dt.base_type_code = 'cash_receipt';

  if found
     and nullif(current_setting('erp.purge_tenant_id', true), '') is null
     and coalesce(erp.object_current_state('document', v_doc), 'draft') <> 'draft' then
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
  'Refuses any write to a line of a posted cash receipt (20260930000000): erp.apply_cash() writes '
  'its lines while it is a draft, and nothing changes them after.';

drop trigger if exists t_document_line_cash_document on erp.document_line;
create trigger t_document_line_cash_document
  before insert or update or delete on erp.document_line
  for each row execute function erp.protect_posted_cash_document();

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. The reversal register: by journal
-- ─────────────────────────────────────────────────────────────────────────────

do $route$
declare
  v_sig constant text := 'erp.document_reversal_route()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$this row is reported.')
    ) as v(base_type_code, route, next_action, rationale)$o$;
  v_new constant text := $n$this row is reported.'),

      ('cash_receipt', 'by_journal',
       'A cash receipt is corrected with a journal on the Journals screen: a returned payment or cash applied to the wrong customer is reversed there, against the bank and the receivable it reached. Reversing a receipt is not built.',
       'Its journals are written by the cash route that opened it (20260930000000), not by the document''s posting rule, so reversing the document''s posting would unmake nothing the route settled; erp_reverse_journal() refuses a cash journal too. A reversal of its own, which unsettles what the receipt paid, is PR13 D10.')
    ) as v(base_type_code, route, next_action, rationale)$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$('cash_receipt', 'by_journal',$x$) > 0 then
    raise notice '% already routes a cash receipt; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % last row anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$route$;

-- Its coverage report knows the route.
do $coverage$
declare
  v_sig constant text := 'erp.document_reversal_coverage_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                         'is_itself_a_reversal', 'not_installed', 'posts_nothing')$o$;
  v_new constant text := $n$                         'is_itself_a_reversal', 'not_installed', 'posts_nothing',
                         'by_journal')$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$'by_journal'$x$) > 0 then
    raise notice '% already knows by_journal; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % route list found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$coverage$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. Apply cash opens a receipt per company, and posts it
--
-- The dated form is edited, not rewritten: eight anchors over the body
-- 20260929400000 left. Its answer gains a column, which is part of its type,
-- so the three forms are dropped and made again with the same arguments,
-- grants and comments, in one block, as 20260929400000 did, so the raises of
-- the dated form stay where erp.refusal_report() and preflight rule B read
-- them. Every caller reads the rows by name or performs them;
-- public.erp_apply_cash() keeps its allowance, which is by name.
-- ─────────────────────────────────────────────────────────────────────────────

do $apply_cash$
declare
  v_sig  constant text := 'erp.apply_cash(uuid,bigint,character,text,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$RETURNS TABLE(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint)$o$,
    $n$RETURNS TABLE(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint, document_id uuid)$n$,

    $o$  v_kept          bigint := 0;
begin$o$,
    $n$  v_kept          bigint := 0;
  -- The cash receipt (20260930000000): the organisation's type of one, and
  -- one receipt per company the cash reaches, kept by company id beside the
  -- journals. No type, as on receivables version 1: no receipt, as before.
  v_receipt_type text;
  v_receipts     jsonb := '{}'::jsonb;
  v_receipt      uuid;
  v_diff_journal uuid;
begin$n$,

    $o$  -- Oldest first, which is the only allocation defensible without an
$o$,
    $n$  select dt.code into v_receipt_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'cash_receipt' and dt.status = 'active'
   order by (dt.entity_id is not null), dt.code
   limit 1;

  -- Oldest first, which is the only allocation defensible without an
$n$,

    $o$    else
      v_event := (v_events ->> v_entity::text)::uuid;
    end if;
$o$,
    $n$    else
      v_event := (v_events ->> v_entity::text)::uuid;
    end if;

    -- The company's receipt, opened for the first item of that company the
    -- cash reaches, through the door every document is opened by: dated the
    -- day the money arrived, with the customer's reference (20260930000000).
    v_receipt := null;
    if v_receipt_type is not null then
      v_receipt := nullif(v_receipts ->> v_entity::text, '')::uuid;
      if v_receipt is null then
        v_receipt := erp.open_document(v_receipt_type, p_party_id, v_entity, null,
                                       p_reference, null, p_currency);
        update erp.document d
           set document_date = p_received_on,
               attributes = d.attributes || jsonb_build_object('route', 'apply_cash'),
               updated_at = now()
         where d.tenant_id = v_tenant and d.id = v_receipt;
        v_receipts := v_receipts || jsonb_build_object(v_entity::text, v_receipt);
      end if;
    end if;
$n$,

    $o$      party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, v_entity, r.ledger_id, 'receivable', r.control_account_id,
            p_party_id, v_journal, p_currency, 0, v_take, p_received_on),
           (v_tenant, v_entity, r.ledger_id, 'bank', v_bank,
            null, v_journal, p_currency, v_take, 0, p_received_on);$o$,
    $n$      party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    -- With a receipt, the settling row names the invoice it settles, as the
    -- settlement statement's always has (D2, 20260930000000). The ageing is
    -- the same either way; this says what paid it.
    values (v_tenant, v_entity, r.ledger_id, 'receivable', r.control_account_id,
            p_party_id, case when v_receipt is not null then r.document_id end,
            v_journal, p_currency, 0, v_take, p_received_on),
           (v_tenant, v_entity, r.ledger_id, 'bank', v_bank,
            null, null, v_journal, p_currency, v_take, 0, p_received_on);$n$,

    $o$     where id = r.id;
$o$,
    $n$     where id = r.id;

    -- What the cash applied to this item is a line of the receipt, with no
    -- item: the invoice's number and the amount.
    if v_receipt is not null then
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity,
        unit_price_minor, net_minor, currency)
      values (
        v_tenant, v_receipt,
        coalesce((select max(l.line_no) from erp.document_line l
                   where l.tenant_id = v_tenant and l.document_id = v_receipt), 0) + 10,
        null,
        coalesce((select inv.document_number from erp.document inv
                   where inv.tenant_id = v_tenant and inv.id = r.document_id), 'an open item'),
        1, v_take, v_take, p_currency);
    end if;
$n$,

    $o$    on_account_minor := 0;
    return next;$o$,
    $n$    on_account_minor := 0;
    document_id := v_receipt;
    return next;$n$,

    $o$  update erp.journal
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where tenant_id = v_tenant
     and id in (select (jsonb_each_text(v_journals)).value::uuid);$o$,
    $n$  -- Each company's journal names that company's receipt, if it has one.
  update erp.journal j
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
         document_id = coalesce(j.document_id, nullif(v_receipts ->> j.entity_id::text, '')::uuid)
   where j.tenant_id = v_tenant
     and j.id in (select (jsonb_each_text(v_journals)).value::uuid);$n$,

    $o$  if v_short_written > 0 then
    perform erp.post_settlement_difference(v_last, v_short_written, p_received_on, p_reference);
  elsif v_left > 0 then
    if v_left <= erp.settlement_tolerance_minor(v_last_entity, v_applied) then
      perform erp.post_settlement_difference(v_last, -v_left, p_received_on, p_reference);
      v_over_written := v_left;
    else
      perform erp.post_cash_on_account(v_last, v_left, p_received_on, p_reference);
      v_kept := v_left;
    end if;
  end if;
$o$,
    $n$  if v_short_written > 0 then
    v_diff_journal := erp.post_settlement_difference(v_last, v_short_written, p_received_on, p_reference);
  elsif v_left > 0 then
    if v_left <= erp.settlement_tolerance_minor(v_last_entity, v_applied) then
      v_diff_journal := erp.post_settlement_difference(v_last, -v_left, p_received_on, p_reference);
      v_over_written := v_left;
    else
      v_diff_journal := erp.post_cash_on_account(v_last, v_left, p_received_on, p_reference);
      v_kept := v_left;
    end if;
  end if;

  -- The difference is the last company's, and so is its receipt: the journal
  -- names it, and a remainder the bank took is a line of it, so the lines
  -- total what the bank was debited (20260930000000). A short written off
  -- banks nothing and is not a line.
  v_receipt := nullif(v_receipts ->> v_last_entity::text, '')::uuid;
  if v_receipt is not null and v_diff_journal is not null then
    update erp.journal j set document_id = v_receipt
     where j.tenant_id = v_tenant and j.id = v_diff_journal;
    if v_left > 0 then
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity,
        unit_price_minor, net_minor, currency)
      values (
        v_tenant, v_receipt,
        coalesce((select max(l.line_no) from erp.document_line l
                   where l.tenant_id = v_tenant and l.document_id = v_receipt), 0) + 10,
        null,
        case when v_kept > 0 then 'kept on account'
             else 'over, within the settlement tolerance' end,
        1, v_left, v_left, p_currency);
    end if;
  end if;
$n$,

    $o$      v_doc, format('settled by %s', coalesce(p_reference, 'cash received')));
  end loop;
$o$,
    $n$      v_doc, format('settled by %s', coalesce(p_reference, 'cash received')));
  end loop;

  -- And each receipt is posted, by the system, now that its lines total what
  -- its journals banked (20260930000000).
  for v_receipt in select (e.value #>> '{}')::uuid from jsonb_each(v_receipts) e loop
    perform erp.post_cash_document(v_receipt);
  end loop;
$n$,

    $o$    on_account_minor := v_kept;
    return next;$o$,
    $n$    on_account_minor := v_kept;
    document_id := nullif(v_receipts ->> v_last_entity::text, '')::uuid;
    return next;$n$];
  v_hits integer;
begin
  if pg_catalog.pg_get_function_result(v_sig::regprocedure) like '%document_id uuid%' then
    raise notice '% already opens a receipt; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd03c264663f82e1de89d77d730047b60' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20260929400000 left (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;

  drop function public.erp_apply_cash(uuid, bigint, character, text);
  drop function erp.apply_cash(uuid, bigint, character, text);
  drop function erp.apply_cash(uuid, bigint, character, text, date);
  execute v_def;

  -- The undated form and the desk's door, as they were, in the new shape.
  -- Made here, with the dated form, because each is dropped with it and a
  -- second run of this migration finds all three made already.
  execute $w$
    create function erp.apply_cash(
      p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text default null)
    returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint,
                  written_off_minor bigint, on_account_minor bigint, document_id uuid)
    language sql
    set search_path = ''
    as $b$
      select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference, current_date);
    $b$
  $w$;
  execute $w$
    create function public.erp_apply_cash(
      p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text default null)
    returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint,
                  written_off_minor bigint, on_account_minor bigint, document_id uuid)
    language sql
    set search_path = ''
    as $b$ select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference) $b$
  $w$;
end
$apply_cash$;

comment on function erp.apply_cash(uuid, bigint, character, text, date) is
  'Applies a receipt against a party''s open receivables, oldest first across every company the party '
  'owes. Each company''s share is posted in that company''s ledger against its own bank account, because '
  'cash banked in another company''s name is a receipt that reconciles nowhere. A document the receipt '
  'leaves owing nothing is settled in the same transaction (20260919200000). The whole receipt is '
  'banked, and the settlement tolerance decides the rest (20260929300000). A row per item it reached, '
  'and one for a remainder; written_off_minor on the item row whose short was written off within the '
  'tolerance, or on the remainder row credited to settlement differences, and on_account_minor on the '
  'remainder row kept on the customer''s account (20260929400000). Where the organisation has a cash '
  'receipt type, one receipt per company, whose lines are what the cash paid and kept and whose '
  'journals name it, posted with the cash; document_id is the row''s company''s receipt, and the '
  'remainder row''s the last company''s (20260930000000).';

comment on function erp.apply_cash(uuid, bigint, character, text) is
  'erp.apply_cash() dated today. The form every existing caller uses; the dated form is the one that does the work.';

revoke all on function erp.apply_cash(uuid, bigint, character, text, date) from public, anon;
revoke all on function erp.apply_cash(uuid, bigint, character, text) from public, anon;
revoke all on function public.erp_apply_cash(uuid, bigint, character, text) from public, anon;
grant execute on function erp.apply_cash(uuid, bigint, character, text, date) to authenticated, service_role;
grant execute on function erp.apply_cash(uuid, bigint, character, text) to authenticated, service_role;
grant execute on function public.erp_apply_cash(uuid, bigint, character, text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The driver register, restated whole as every change to it is
--
-- The receipt's one move is a routine's, so it is not a button
-- (src/components/erp/available-transitions.ts reads the newest restatement).
-- Otherwise as 20260929100000 left it.
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
-- B3. The suites that pinned what this moves, re-pinned on purpose
--
--   * erp_test.cash_settlement_suite, case 2, netted the invoice's own rows
--     less what was settled against them, on the ground that Apply cash's
--     settling row names no document. With a receipt it names the invoice
--     (D2), as the statement route's always has, so the invoice's rows net to
--     nothing and settled_minor says by how much: the case asks that, and the
--     ageing's nil, which is unchanged.
--   * erp_test.close_and_cash_screens_suite, case 12, pinned the answer's
--     five columns; it is six, the same across the three forms.
--   * erp_test.sales_order_progress_suite paid each invoice what its rows
--     net to, which a receipt naming the other invoice made nought; below.
-- ─────────────────────────────────────────────────────────────────────────────

do $settlement_suite$
declare
  v_sig constant text := 'erp_test.cash_settlement_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    -- Asked twice, of the two things that have to agree. A receipt applied
    -- across a party names no document on the row it writes — that is why
    -- settled_minor exists and why erp.ageing_balance has the shape it has —
    -- so the invoice's own rows still add up to what it was raised for, and
    -- what is owed on it is that less what was settled against it. Netting the
    -- rows alone would say the whole invoice is still outstanding.
$o$,
    $n$    -- Asked twice, of the two things that have to agree. Where the
    -- organisation has a cash receipt, the receipt's settling row names the
    -- invoice it settles (20260930000000, D2), so the invoice's own rows net
    -- to nothing, and settled_minor says the whole of it was settled. An
    -- organisation without one writes the row naming no document, and
    -- erp.ageing_balance reads the same nil either way.
$n$,
    $o$    select coalesce(sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0)), 0),
           coalesce(sum(coalesce(si.settled_minor, 0)), 0)
      into v_bal, v_settled$o$,
    $n$    select coalesce(sum(si.debit_minor - si.credit_minor), 0),
           coalesce(sum(coalesce(si.settled_minor, 0)), 0)
      into v_bal, v_settled$n$,
    $o$the invoice''s own rows owe %s, with %s of %s settled against them$o$,
    $n$the invoice''s own rows net to %s, with %s of %s settled against them$n$];
  v_hits integer;
begin
  if strpos(v_def, '20260930000000, D2') > 0 then
    raise notice '% already reads the receipt''s settling row; left as it is', v_sig;
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
$settlement_suite$;

do $screens_suite$
declare
  v_sig constant text := 'erp_test.close_and_cash_screens_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    case_name := 'the dated form, the undated form and the desk''s door answer in the same five columns';$o$,
    $n$    -- Six since 20260930000000: document_id, the receipt.
    case_name := 'the dated form, the undated form and the desk''s door answer in the same six columns';$n$,
    $o$            like '%written_off_minor bigint, on_account_minor bigint)';$o$,
    $n$            like '%written_off_minor bigint, on_account_minor bigint, document_id uuid)';$n$];
  v_hits integer;
begin
  if strpos(v_def, 'on_account_minor bigint, document_id uuid)') > 0 then
    raise notice '% already pins six columns; left as it is', v_sig;
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
$screens_suite$;

-- The sales order progress suite pays each invoice what its rows net to. The
-- party route pays the oldest first, and the two invoices are as old, so the
-- first receipt may pay the second; with a receipt, its settling row names
-- the second invoice (D2), whose rows then net to nothing, and the second
-- payment was nought (found on the full build, one run in two). Each is
-- paid what it was raised for, as the case always meant.
do $order_progress_suite$
declare
  v_sig constant text := 'erp_test.sales_order_progress_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    perform erp.apply_cash(v_cust, (select sum(si.debit_minor - si.credit_minor) from erp.subledger_item si
                                     where si.tenant_id = r.tenant_id and si.document_id = v_inv1
                                       and si.control_kind = 'receivable')::bigint,$o$,
    $n$    -- What each invoice was raised for, whichever the cash reaches first
    -- (20260930000000).
    perform erp.apply_cash(v_cust, (select dv.gross_minor from erp.document_view dv
                                     where dv.tenant_id = r.tenant_id and dv.id = v_inv1)::bigint,$n$,
    $o$    perform erp.apply_cash(v_cust, (select sum(si.debit_minor - si.credit_minor) from erp.subledger_item si
                                     where si.tenant_id = r.tenant_id and si.document_id = v_inv2
                                       and si.control_kind = 'receivable')::bigint,$o$,
    $n$    perform erp.apply_cash(v_cust, (select dv.gross_minor from erp.document_view dv
                                     where dv.tenant_id = r.tenant_id and dv.id = v_inv2)::bigint,$n$];
  v_hits integer;
begin
  if strpos(v_def, 'whichever the cash reaches first') > 0 then
    raise notice '% already pays each invoice its gross; left as it is', v_sig;
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
$order_progress_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The proof: erp_test.cash_receipt_suite
--
-- One organisation, configured from now on, so it is on receivables version 2
-- and settles within £1. Each case has a customer of its own, because the
-- party route pays the oldest invoice first.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.cash_receipt_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_item uuid;
  v_bank uuid; v_diff uuid;
  v_inv uuid; v_inv2 uuid; v_cust uuid; v_gross bigint; v_gross2 bigint;
  v_rows jsonb; v_rcpt uuid; v_rcpt2 uuid; v_draft uuid; v_line uuid;
  v_b0 bigint; v_b1 bigint; v_d0 bigint; v_d1 bigint; v_m0 numeric; v_m1 numeric;
  v_n integer; v_n2 integer; v_n3 integer;
  v_num text; v_fact text; v_lines text;
  v_new_shape jsonb; v_old_shape jsonb;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_hint text;
  v_planned text;
begin
  begin
    -- ── The fixture: an organisation configured as the demonstration is ─────
    v_step := 'an organisation that invoices and banks receipts, configured from now on';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcrc-' || v_tag, 'Cash Receipt Suite',
      'admin@zzcrc-' || v_tag || '.test', 'Cash Receipt Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzcrc-' || v_tag || '.test'),
           (s_read, 'reader@zzcrc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a person who may read the books but not post cash';
    res := public.erp_invite_principal('reader@zzcrc-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit and product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZRMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRWID', 'Cash Receipt Widget', v_uom, 'active') returning id into v_item;
    v_bank := erp.company_bank_account(v_entity);
    v_diff := erp.settlement_difference_account(v_entity);

    -- ── 1. Declared, installed at version 2, and alive ──────────────────────
    v_step := 'the type, its installer and the configuration checks';
    select count(*) into v_n from erp.dead_configuration_report() c
     where c.reference like '%cash\_receipt%' or c.detail like '%cash\_receipt%';
    select count(*) into v_n2 from erp.undriven_transition_report() c
     where c.reference like 'cash\_receipt%';
    v_cases := v_cases + 1;
    case_name := 'the cash receipt is declared, installed with receivables at version 2 from one helper, driven by a routine, and nothing of it is dead configuration';
    passed := v_state is null
          and (select count(*) from erp_ref.module_upgrade_item ui
                 join jsonb_array_elements(erp.cash_receipt_pack_items()) i
                   on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
                  and i.value -> 'payload' = ui.payload
                where ui.install_code = 'receivables' and ui.to_version = 2) = 3
          and (select mi.current_version from erp_ref.module_installer mi
                where mi.install_code = 'receivables') = 2
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'receivables') = 2
          and exists (select 1 from erp.document_type dt
                        join erp.numbering_rule nr on nr.id = dt.numbering_rule_id and nr.prefix = 'RCPT-'
                       where dt.tenant_id = rb.tenant_id and dt.code = 'cash_receipt' and dt.status = 'active'
                         and dt.base_type_code = 'cash_receipt' and dt.state_machine_code = 'cash_receipt'
                         and dt.create_permission = 'finance.post'
                         and dt.stock_movement_type is null and dt.posting_rule_code is null)
          and exists (select 1 from jsonb_array_elements(erp.transition_driver_register()) x
                       where x ->> 'machine_code' = 'cash_receipt' and x ->> 'transition_code' = 'post'
                         and x ->> 'driver' = 'routine' and x ->> 'detail' = 'erp.post_cash_document(uuid)')
          and v_n = 0 and v_n2 = 0;
    detail := coalesce(v_state, format('%s dead, %s undriven', v_n, v_n2));
    return next;

    -- ── 2. One invoice paid in full ─────────────────────────────────────────
    v_step := 'an invoice paid in full through the desk''s door';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC2', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross, v_ccy, 'ZRC2-PAID') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    select d.document_number into v_num from erp.document d where d.id = v_rcpt;
    select l.guard_data #>> '{derived,fact}' into v_fact
      from erp.state_transition_log l
     where l.tenant_id = rb.tenant_id and l.object_type = 'document' and l.object_id = v_rcpt
       and l.transition_code = 'post';
    v_cases := v_cases + 1;
    case_name := 'Apply cash paying one invoice in full opens RCPT-000001, posted by the system with nobody pressing; one line of the cash naming the invoice, its journal names it, and the invoice is Paid';
    passed := v_state is null
          and v_num = 'RCPT-000001'
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and v_fact = 'erp.cash_document_is_applied'
          and (select d.party_id = v_cust and d.their_reference = 'ZRC2-PAID' and d.document_date = current_date
                      and d.currency = v_ccy and d.entity_id = v_entity and d.party_role_id is not null
                      and d.attributes ->> 'route' = 'apply_cash'
                 from erp.document d where d.id = v_rcpt)
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt) = 1
          and (select l.item_id is null and l.net_minor = v_gross and l.quantity = 1
                      and l.description = (select i.document_number from erp.document i where i.id = v_inv)
                 from erp.document_line l where l.document_id = v_rcpt)
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt
                  and j.source_code = 'cash.applied' and j.status = 'posted') = 1
          and erp.object_current_state('document', v_inv) = 'paid';
    detail := coalesce(v_state, format('%s is %s, derived from %s; rows %s', coalesce(v_num, 'no receipt'),
      coalesce(erp.object_current_state('document', v_rcpt), 'in no state'), coalesce(v_fact, 'nothing'),
      left(coalesce(v_rows::text, 'none'), 300)));
    return next;

    -- ── 3. Half an invoice ──────────────────────────────────────────────────
    v_step := 'half an invoice';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC3', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross / 2, v_ccy, 'ZRC3-HALF') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'half an invoice: the receipt is Posted and the invoice is Part paid';
    passed := v_state is null
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and erp.object_current_state('document', v_inv) = 'part_paid'
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_gross / 2;
    detail := coalesce(v_state, format('receipt %s, invoice %s',
      erp.object_current_state('document', v_rcpt), erp.object_current_state('document', v_inv)));
    return next;

    -- ── 8. The settling row names the invoice, and the ageing is the same ────
    -- On the half-paid invoice: its ageing, the customer's, is read as the
    -- receipt left it, and again with the settling row naming no document, as
    -- the old shape wrote it, and put back.
    v_step := 'the ageing read in both shapes';
    select jsonb_agg(jsonb_build_array(b.document_id, b.outstanding_minor) order by b.document_id nulls first)
      into v_new_shape
      from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.party_id = v_cust;
    begin
      update erp.subledger_item si set document_id = null
       where si.tenant_id = rb.tenant_id and si.control_kind = 'receivable'
         and si.journal_id in (select j.id from erp.journal j
                                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt);
      select jsonb_agg(jsonb_build_array(b.document_id, b.outstanding_minor) order by b.document_id nulls first)
        into v_old_shape
        from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.party_id = v_cust;
      raise exception 'CLOVEERP_SHAPE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SHAPE_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'the receipt''s settling row names the invoice, and the ageing is what the old shape gave: the invoice owes the other half and nothing stands unallocated';
    passed := v_state is null
          and (select count(*) from erp.subledger_item si
                where si.tenant_id = rb.tenant_id and si.control_kind = 'receivable' and si.document_id = v_inv
                  and si.credit_minor = v_gross / 2
                  and si.journal_id in (select j.id from erp.journal j
                                         where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt)) = 1
          and v_new_shape = v_old_shape
          and v_new_shape = jsonb_build_array(jsonb_build_array(v_inv, v_gross - v_gross / 2));
    detail := coalesce(v_state, format('receipt shape %s; old shape %s', v_new_shape, v_old_shape));
    return next;

    -- ── 4. Two invoices, one receipt ────────────────────────────────────────
    v_step := 'two invoices to one customer';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC4', 30000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_inv2 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZRC4-INV2', '{}'::jsonb);
    perform erp.add_document_line(v_inv2, v_item, 1, 20000, 'a second sale to ZRC4');
    perform erp.transition_document(v_inv2, 'issue', 'cash receipt suite');
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + v_gross2, v_ccy, 'ZRC4-BOTH') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    select string_agg(l.description, ', ' order by l.line_no) into v_lines
      from erp.document_line l where l.document_id = v_rcpt;
    v_cases := v_cases + 1;
    case_name := 'two invoices paid by one receipt: one receipt with a line for each, and both are Paid';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and (v_rows -> 1 ->> 'document_id')::uuid = v_rcpt
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt) = 2
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_gross + v_gross2
          and exists (select 1 from erp.document_line l join erp.document i on i.id = v_inv
                       where l.document_id = v_rcpt and l.description = i.document_number)
          and exists (select 1 from erp.document_line l join erp.document i on i.id = v_inv2
                       where l.document_id = v_rcpt and l.description = i.document_number)
          and erp.object_current_state('document', v_inv) = 'paid'
          and erp.object_current_state('document', v_inv2) = 'paid';
    detail := coalesce(v_state, format('lines %s; rows %s', coalesce(v_lines, 'none'), left(coalesce(v_rows::text, 'none'), 300)));
    return next;

    -- ── 5. A penny short ────────────────────────────────────────────────────
    v_step := 'an invoice paid a penny short';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC5', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross - 1, v_ccy, 'ZRC5-SHORT') x;
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a penny short at £1: the receipt''s one line is the cash, the write-off journal names the receipt, and the invoice is Paid';
    passed := v_state is null
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt) = 1
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_gross - 1
          and v_b1 - v_b0 = v_gross - 1
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt
                  and j.source_code = 'cash.settlement_difference_posted') = 1
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and erp.object_current_state('document', v_inv) = 'paid';
    detail := coalesce(v_state, format('bank moved %s; journals %s; invoice %s', v_b1 - v_b0,
      (select string_agg(j.source_code, ',') from erp.journal j where j.document_id = v_rcpt),
      erp.object_current_state('document', v_inv)));
    return next;

    -- ── 6. £100 over ────────────────────────────────────────────────────────
    v_step := 'an invoice paid £100 over';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC6', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZRC6-OVER') x;
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    begin
      v_err := erp.assert_ageing_equals_control();
      v_err := 'ties';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := '£100 over: the receipt has a line of £100 kept on account, its lines total the bank debit, the ageing carries −£100 unallocated, and the ageing ties to the control account';
    passed := v_state is null
          and exists (select 1 from erp.document_line l
                       where l.document_id = v_rcpt and l.description = 'kept on account'
                         and l.net_minor = 10000 and l.item_id is null)
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_b1 - v_b0
          and v_b1 - v_b0 = v_gross + 10000
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt
                  and j.source_code in ('cash.applied', 'cash.on_account')) = 2
          and (v_rows -> 1 ->> 'document_id')::uuid = v_rcpt
          and (select b.outstanding_minor from erp.ageing_balance b
                where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null) = -10000
          and v_err = 'ties';
    detail := coalesce(v_state, format('bank moved %s, lines %s; %s', v_b1 - v_b0,
      (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt), v_err));
    return next;

    -- ── 7. A penny over ─────────────────────────────────────────────────────
    v_step := 'an invoice paid a penny over';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC7', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 1, v_ccy, 'ZRC7-PENNY') x;
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a penny over at £1: the credit to settlement differences names the receipt, and the lines total the bank';
    passed := v_state is null
          and v_d1 - v_d0 = -1
          and exists (select 1 from erp.journal j
                        join erp.journal_line jl on jl.journal_id = j.id
                       where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt
                         and j.source_code = 'cash.settlement_difference_posted'
                         and jl.account_id = v_diff and jl.credit_minor = 1)
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_b1 - v_b0
          and v_b1 - v_b0 = v_gross + 1
          and erp.object_current_state('document', v_rcpt) = 'posted';
    detail := coalesce(v_state, format('7900 moved %s, bank %s, lines %s', v_d1 - v_d0, v_b1 - v_b0,
      (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt)));
    return next;

    -- ── 9. Nothing by hand ──────────────────────────────────────────────────
    v_step := 'a receipt opened, written and posted by hand';
    v_line := (select l.id from erp.document_line l where l.document_id = v_rcpt order by l.line_no limit 1);
    begin
      perform public.erp_create_document('cash_receipt', v_cust, null, 'by hand', null, v_entity, null, null);
      v_err := 'opened';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform erp.create_document_full('cash_receipt', v_cust, null, 'by hand', null, null, '[]'::jsonb, null);
      v_err2 := 'opened';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin
      -- Beneath every door that changes a line: the trigger holds them all.
      update erp.document_line set quantity = 7 where id = v_line;
      v_err4 := 'amended';
    exception when others then v_err4 := left(sqlerrm, 160); end;
    -- A draft nobody applied cash to, opened past the doors, is not posted by
    -- hand or by the routine.
    v_draft := erp.open_document('cash_receipt', v_cust, v_entity, null, 'by hand', null, v_ccy);
    -- A line on it, through the line door: the door's refusal, not the
    -- trigger's, which holds a posted receipt.
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
      v_hint := 'posted';
    exception when others then v_hint := left(sqlerrm, 160); end;
    v_cases := v_cases + 1;
    case_name := 'opening a receipt, adding or changing a line of one, or posting one by hand is refused by name, to an administrator';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_DOCUMENT_IS_RAISED:%'
          and v_err2 like 'CLOVEERP_CASH_DOCUMENT_IS_RAISED:%'
          and v_err3 like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_err4 like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_err5 like 'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED:%'
          and v_hint like 'CLOVEERP_CASH_DOCUMENT_NOT_APPLIED:%'
          and erp.object_current_state('document', v_draft) = 'draft'
          and not exists (select 1 from erp.document_line l where l.document_id = v_draft)
          and (select l.quantity from erp.document_line l where l.id = v_line) = 1;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_hint));
    return next;

    -- ── 10. The answer's shape ──────────────────────────────────────────────
    v_step := 'the answer of the three forms';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC10', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross, v_ccy, 'ZRC10-SHAPE') x;
    v_cases := v_cases + 1;
    case_name := 'erp_apply_cash''s five columns answer as they did, and a sixth, document_id, is the receipt; the three forms agree';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0) - 'document_id' = jsonb_build_object(
                'subledger_item_id', (select si.id from erp.subledger_item si
                                       where si.document_id = v_inv and si.control_kind = 'receivable'
                                         and si.debit_minor > 0),
                'applied_minor', v_gross, 'remaining_minor', 0,
                'written_off_minor', 0, 'on_account_minor', 0)
          and exists (select 1 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                       where d.id = (v_rows -> 0 ->> 'document_id')::uuid and dt.base_type_code = 'cash_receipt')
          and pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text,date)'::regprocedure)
            = pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text)'::regprocedure)
          and pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text)'::regprocedure)
            = pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text)'::regprocedure)
          and pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text)'::regprocedure)
            = 'TABLE(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint, document_id uuid)';
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 12. The meter, and the reader ───────────────────────────────────────
    v_step := 'the billed meter across a receipt, and a reader who may not post';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC12', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select coalesce(sum(m.quantity), 0) into v_m0 from erp_meta.usage_meter m
     where m.tenant_id = rb.tenant_id and m.meter_code = 'documents_posted';
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_apply_cash(v_cust, v_gross, v_ccy, 'ZRC12-READER');
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross, v_ccy, 'ZRC12-PAID') x;
    select coalesce(sum(m.quantity), 0) into v_m1 from erp_meta.usage_meter m
     where m.tenant_id = rb.tenant_id and m.meter_code = 'documents_posted';
    v_cases := v_cases + 1;
    case_name := 'a receipt does not move the billed documents_posted meter, and finance.read is refused Apply cash and opens nothing';
    passed := v_state is null
          and v_m1 = v_m0
          and erp.object_current_state('document', (v_rows -> 0 ->> 'document_id')::uuid) = 'posted'
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.post%'
          and v_n2 = v_n;
    detail := coalesce(v_state, format('meter %s then %s; reader: %s; receipts %s then %s', v_m0, v_m1, v_err, v_n, v_n2));
    return next;

    -- ── 13. Reversal, and the reader of a document ──────────────────────────
    v_step := 'a receipt reversed, and read';
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    begin
      perform erp.reverse_document_posting(v_rcpt, 'The cheque bounced');
      v_err := 'reversed';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_err := left(sqlerrm, 160);
    end;
    v_cases := v_cases + 1;
    case_name := 'a receipt is not reversed as a document, the refusal says to correct it with a journal, and the reversal register holds';
    passed := v_state is null
          and v_err like 'CLOVEERP_DOCUMENT_NOT_REVERSIBLE:%'
          and v_hint like 'A cash receipt is corrected with a journal%'
          and (select r2.route from erp.document_reversal_route() r2 where r2.base_type_code = 'cash_receipt') = 'by_journal'
          and not exists (select 1 from erp.document_reversal_coverage_report());
    detail := coalesce(v_state, v_err || ' / ' || coalesce(v_hint, 'no hint'));
    return next;

    res := public.erp_document(v_rcpt);
    v_cases := v_cases + 1;
    case_name := 'the document reader shows a receipt''s itemless line with its amount and the invoice it paid';
    passed := v_state is null
          and jsonb_array_length(res -> 'lines') = 1
          and jsonb_typeof(res -> 'lines' -> 0 -> 'item') = 'null'
          and (res -> 'lines' -> 0 ->> 'net_minor')::bigint = v_gross
          and res -> 'lines' -> 0 ->> 'description' = (select i.document_number from erp.document i where i.id = v_inv);
    detail := coalesce(v_state, left(coalesce((res -> 'lines')::text, res::text, 'nothing'), 300));
    return next;

    -- ── 11. An organisation on version 1, and its upgrade ───────────────────
    v_step := 'putting the organisation back to receivables version 1';
    update erp.document_type set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'cash_receipt';
    update erp.state_machine set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'cash_receipt';
    update erp.module_installation i set installer_version = 1
     where i.tenant_id = rb.tenant_id and i.install_code = 'receivables';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC11', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZRC11-V1') x;
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    v_cases := v_cases + 1;
    case_name := 'an organisation still on receivables version 1 applies cash as before: no receipt, its journals name no document, and the settling row names none';
    passed := v_state is null
          and v_n2 = v_n
          and jsonb_array_length(v_rows) = 2
          and not exists (select 1 from jsonb_array_elements(v_rows) x where jsonb_typeof(x -> 'document_id') <> 'null')
          and (v_rows -> 1 ->> 'on_account_minor')::bigint = 10000
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.source_code in ('cash.applied', 'cash.on_account')
                  and j.document_id is null) = 2
          and (select count(*) from erp.subledger_item si
                where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.control_kind = 'receivable'
                  and si.credit_minor > 0 and si.document_id is not null) = 0
          and erp.object_current_state('document', v_inv) = 'paid';
    detail := coalesce(v_state, format('receipts %s then %s; rows %s', v_n, v_n2, left(coalesce(v_rows::text, 'none'), 300)));
    return next;

    v_step := 'upgrading receivables to version 2';
    select string_agg(p.object_kind || ' ' || p.object_key, ', ' order by p.seq)
      into v_planned
      from erp.plan_module_upgrade('receivables') p;
    res := erp.upgrade_module_configuration('receivables');
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRC11B', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross, v_ccy, 'ZRC11B-V2') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'the upgrade to receivables version 2 installs the receipt, and the next cash applied opens one';
    passed := v_state is null
          and strpos(coalesce(v_planned, ''), 'document_type cash_receipt') > 0
          and (res ->> 'to_version')::integer = 2 and (res ->> 'promoted')::boolean
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'receivables') = 2
          and not exists (select 1 from erp.plan_module_upgrade('receivables'))
          and erp.object_current_state('document', v_rcpt) = 'posted';
    detail := coalesce(v_state, format('planned %s; %s; rows %s', coalesce(v_planned, 'nothing'), res::text,
      left(coalesce(v_rows::text, 'none'), 200)));
    return next;

    -- ── 14. The checks, with receipts posted ────────────────────────────────
    v_step := 'the configuration and ledger checks, with receipts posted';
    begin
      v_err := erp.assert_every_transition_is_driven();
      v_err := erp.assert_no_dead_configuration();
      v_err := erp.assert_every_posting_can_be_undone();
      v_err := erp_test.assert_no_state_side_doors();
      v_err := erp.assert_ageing_equals_control();
      v_err := 'passed';
    exception when others then v_err := 'refused: ' || left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'the driver register, dead configuration, reversal, side doors and the ageing tie all pass with receipts posted';
    passed := v_state is null and v_err = 'passed';
    detail := coalesce(v_state, v_err);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzcrc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzcrc rolled back with its invoices, receipts and journals');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.cash_receipt_suite() from public, anon;

comment on function erp_test.cash_receipt_suite() is
  'Apply cash opens a cash receipt per company, numbered RCPT-, whose lines are what the cash paid '
  'and kept, whose journals name it, and which the system posts (20260930000000). Paid, part paid '
  'and the tolerance are kept; the ageing is what it was; nobody opens, writes or posts one by hand; '
  'the billed meter does not move; an organisation on receivables version 1 applies cash as before '
  'and takes the receipt from the upgrade.';

create or replace function erp_test.assert_cash_receipt_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.cash_receipt_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Cash would be banked with no receipt, or a receipt would say what the bank did not receive. Read the case that failed.';
  end if;
  if v_total <> 17 then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_SHRANK: % case(s), expected 17', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('cash receipt: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_cash_receipt_suite() from public, anon;

comment on function erp_test.assert_cash_receipt_suite() is
  'Apply cash opens and posts a numbered cash receipt per company, naming its journals, where the '
  'organisation is on receivables version 2, and applies cash as before where it is not (20260930000000).';

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
