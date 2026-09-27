set lock_timeout = '30s';

-- =============================================================================
-- 20260930100000  A settlement statement's lines are receipts
-- -----------------------------------------------------------------------------
-- PR13 M2 (docs/spec/simplification-review.md §7 Finance, node F5): the item
-- route, on top of the cash receipt Apply cash opens (20260930000000).
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A settlement statement is a provider's payout: one line per customer
-- payment, each matched to the receivable it settles and applied through
-- erp.apply_cash_to_item(). Each line posts a cash journal that names no
-- document, so a payment that came in through a statement has no receipt,
-- where the same payment keyed at Apply cash has had one since
-- 20260930000000. The only way from the money to the line is the line's
-- applied_journal_id.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp.apply_cash_to_item() takes the receipt it applies the cash to, as a
--     trailing argument that defaults to none. Given one, it checks it is a
--     draft cash receipt of the item's customer, company and currency, writes
--     the line (the invoice's number and the amount applied), names it on its
--     journal, and names it on the journal the tolerance writes, with a line
--     for what the bank took over the item, kept on account or credited, so
--     the lines total what the bank was debited. A short written off banks
--     nothing and is not a line. Given none, it is as it was. Dropped and
--     made again with the same grants; every caller passes four arguments or
--     fewer and resolves to it unchanged.
--   * erp.apply_settlement_statement() opens one receipt per matched line
--     (D6): the line is one customer's payment, and already has its journal.
--     The receipt is the matched item's customer, company and currency, dated
--     the day the money moved (never after today, as the line's journal is),
--     with the provider's reference, statement and line as the customer's, and
--     the statement and line in its attributes. The route passes it to the item
--     route, then posts it through erp.post_cash_document(), derived as Apply
--     cash's is. A line whose item is another company's than the statement's
--     is that company's receipt, as its journal is that company's.
--   * applied_journal_id is unchanged; the line's receipt is its journal's
--     document_id.
--   * An organisation on receivables version 1 has no receipt type, and its
--     statements apply exactly as before (D1).
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No change to fees (S7, D14): the bank is still debited with the gross
--     of each line.
--   * The tolerance helpers keep their signatures, as in 20260930000000: each
--     returns its journal, which the item route names.
--   * The driver register is not restated. It names the routine that makes
--     the move, erp.post_cash_document(uuid), and the statement route makes
--     it through that routine, as Apply cash does; the row is still true.
--   * No new refusal. A receipt passed to the item route that is not the
--     item's customer's draft is refused as a line written by hand would be,
--     CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH.
--   * No screen, no new door, no client change: neither route is a public
--     function, and the statement door's answer is unchanged.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The base type says both routes write its journals
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.document_type
   set description =
     'A cash receipt: the money one payment brought in, and the invoices it paid. Its journals are '
     'written by the cash route that opens it, erp.apply_cash() (20260930000000) or a settlement '
     'statement''s line through erp.apply_cash_to_item() (20260930100000), and name it; nothing '
     'posts it generically, and it is posted by that route when its lines total what its journals '
     'banked.'
 where code = 'cash_receipt';

do $base$
begin
  if (select count(*) from erp_ref.document_type bt
       where bt.code = 'cash_receipt' and bt.description like '%erp.apply_cash_to_item()%') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: base type cash_receipt is not here to be described (20260930000000 declares it)';
  end if;
end
$base$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The item route applies cash to the receipt it is given
--
-- Edited, not rewritten: seven anchors over the body 20260929300000 left
-- (md5 f4134044…). Its arguments change, so it is dropped and made again with
-- the same grants, in one block.
-- ─────────────────────────────────────────────────────────────────────────────

do $item_route$
declare
  v_sig  constant text := 'erp.apply_cash_to_item(uuid,bigint,text,date)';
  v_src  text;
  v_def  text;
  v_pairs constant text[] := array[
    $o$CREATE OR REPLACE FUNCTION erp.apply_cash_to_item(p_subledger_item_id uuid, p_amount_minor bigint, p_reference text, p_received_on date DEFAULT CURRENT_DATE)$o$,
    $n$CREATE OR REPLACE FUNCTION erp.apply_cash_to_item(p_subledger_item_id uuid, p_amount_minor bigint, p_reference text, p_received_on date DEFAULT CURRENT_DATE, p_document_id uuid DEFAULT NULL::uuid)$n$,

    $o$  v_journal uuid;
begin$o$,
    $n$  v_journal uuid;
  -- The receipt's (20260930100000): the journal the tolerance writes, and
  -- whether what the bank took over the item was kept on account.
  v_diff_journal uuid;
  v_kept         boolean := false;
begin$n$,

    $o$  perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);
$o$,
    $n$  perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);

  -- The receipt this cash is a line of, if the caller opened one
  -- (20260930100000): a draft cash receipt of the item's customer, company
  -- and currency, or the line would say one customer's bank received another's
  -- money, or a posted receipt would gain a line.
  if p_document_id is not null
     and not exists (
       select 1 from erp.document d
         join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        where d.tenant_id = v_tenant and d.id = p_document_id
          and dt.base_type_code = 'cash_receipt'
          and d.party_id = si.party_id and d.entity_id = si.entity_id and d.currency = si.currency
          and erp.object_current_state('document', d.id) = 'draft') then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is not a draft cash receipt of this item''s customer, company and currency',
      coalesce((select d.document_number from erp.document d
                 where d.tenant_id = v_tenant and d.id = p_document_id), p_document_id::text)
      using errcode = '23514',
            hint = 'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.';
  end if;
$n$,

    $o$  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;
$o$,
    $n$  -- With a receipt, the journal names it and the cash applied is its line,
  -- with no item: the invoice's number and the amount (20260930100000).
  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
         document_id = coalesce(document_id, p_document_id)
   where id = v_journal;

  if p_document_id is not null then
    insert into erp.document_line (
      tenant_id, document_id, line_no, item_id, description, quantity,
      unit_price_minor, net_minor, currency)
    values (
      v_tenant, p_document_id,
      coalesce((select max(l.line_no) from erp.document_line l
                 where l.tenant_id = v_tenant and l.document_id = p_document_id), 0) + 10,
      null,
      coalesce((select inv.document_number from erp.document inv
                 where inv.tenant_id = v_tenant and inv.id = si.document_id), 'an open item'),
      1, v_take, v_take, si.currency);
  end if;
$n$,

    $o$    perform erp.post_settlement_difference(si.id, v_short, p_received_on, p_reference);$o$,
    $n$    v_diff_journal := erp.post_settlement_difference(si.id, v_short, p_received_on, p_reference);$n$,

    $o$      perform erp.post_settlement_difference(si.id, -v_excess, p_received_on, p_reference);
    else
      perform erp.post_cash_on_account(si.id, v_excess, p_received_on, p_reference);$o$,
    $n$      v_diff_journal := erp.post_settlement_difference(si.id, -v_excess, p_received_on, p_reference);
    else
      v_diff_journal := erp.post_cash_on_account(si.id, v_excess, p_received_on, p_reference);
      v_kept := true;$n$,

    $o$  -- This route names the document it settles, so there is one to ask
$o$,
    $n$  -- The difference is the receipt's too: its journal names it, and what the
  -- bank took over the item is a line, so the lines total what the bank was
  -- debited (20260930100000). A short written off banks nothing and is not a
  -- line.
  if p_document_id is not null and v_diff_journal is not null then
    update erp.journal j set document_id = p_document_id
     where j.tenant_id = v_tenant and j.id = v_diff_journal;
    if v_excess > 0 then
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity,
        unit_price_minor, net_minor, currency)
      values (
        v_tenant, p_document_id,
        coalesce((select max(l.line_no) from erp.document_line l
                   where l.tenant_id = v_tenant and l.document_id = p_document_id), 0) + 10,
        null,
        case when v_kept then 'kept on account'
             else 'over, within the settlement tolerance' end,
        1, v_excess, v_excess, si.currency);
    end if;
  end if;

  -- This route names the document it settles, so there is one to ask
$n$];
  v_hits integer;
begin
  if to_regprocedure('erp.apply_cash_to_item(uuid,bigint,text,date,uuid)') is not null then
    raise notice 'erp.apply_cash_to_item() already takes its receipt; left as it is';
    return;
  end if;
  v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  if md5(v_src) <> 'f41340447e3fff07fb3e8a972b8caf1b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20260929300000 left (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;

  drop function erp.apply_cash_to_item(uuid, bigint, text, date);
  execute v_def;
end
$item_route$;

revoke all on function erp.apply_cash_to_item(uuid, bigint, text, date, uuid) from public, anon;
grant execute on function erp.apply_cash_to_item(uuid, bigint, text, date, uuid) to authenticated, service_role;

comment on function erp.apply_cash_to_item(uuid, bigint, text, date, uuid) is
  'Applies cash to one receivable item, the settlement statement''s route (20260906137000): its '
  'journal and paired rows name the item''s document, and the settlement tolerance decides the rest '
  '(20260929300000). Given a draft cash receipt of the item''s customer, company and currency, the '
  'cash is a line of it, and it names the receipt on every journal it writes, with a line for what '
  'the bank took over the item (20260930100000); given none, no document.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. A settlement statement opens one receipt per matched line, and posts it
--
-- Edited, not rewritten: three anchors over the body 20260919200000 left
-- (md5 21c95c2b…). Its arguments and answer are unchanged.
-- ─────────────────────────────────────────────────────────────────────────────

do $statement_route$
declare
  v_sig  constant text := 'erp.apply_settlement_statement(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_journal uuid;
begin$o$,
    $n$  v_journal uuid;
  -- The cash receipt (20260930100000): the organisation's type of one, and
  -- the line's receipt with the item it is matched to. No type, as on
  -- receivables version 1: no receipt, as before.
  v_receipt_type text;
  v_receipt      uuid;
  v_item         record;
begin$n$,

    $o$  for ln in
$o$,
    $n$  select dt.code into v_receipt_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'cash_receipt' and dt.status = 'active'
   order by (dt.entity_id is not null), dt.code
   limit 1;

  for ln in
$n$,

    $o$    v_journal := erp.apply_cash_to_item(ln.matched_subledger_item_id, ln.amount_minor,
                                        format('%s %s line %s', st.provider_code, st.statement_ref, ln.line_no),
                                        least(ln.occurred_on, current_date));
$o$,
    $n$    -- One receipt per line (D6): the line is one customer's payment. It is
    -- the matched item's customer's, company's and currency's, as the line's
    -- journal is, dated as that journal is, with the provider's reference as
    -- the customer's (20260930100000).
    v_receipt := null;
    if v_receipt_type is not null then
      select si.party_id, si.entity_id, si.currency into v_item
        from erp.subledger_item si
       where si.tenant_id = v_tenant and si.id = ln.matched_subledger_item_id;
      -- An item that is not there opens nothing: the item route refuses it
      -- by name below.
      if found then
        v_receipt := erp.open_document(v_receipt_type, v_item.party_id, v_item.entity_id, null,
                                       format('%s %s line %s', st.provider_code, st.statement_ref, ln.line_no),
                                       null, v_item.currency);
        update erp.document d
           set document_date = least(ln.occurred_on, current_date),
               attributes = d.attributes || jsonb_build_object(
                 'route', 'settlement_statement',
                 'settlement_statement_id', st.id,
                 'settlement_statement_line_id', ln.id),
               updated_at = now()
         where d.tenant_id = v_tenant and d.id = v_receipt;
      end if;
    end if;

    v_journal := erp.apply_cash_to_item(ln.matched_subledger_item_id, ln.amount_minor,
                                        format('%s %s line %s', st.provider_code, st.statement_ref, ln.line_no),
                                        least(ln.occurred_on, current_date), v_receipt);

    -- And posted, by the system, now that its lines total what its journals
    -- banked.
    if v_receipt is not null then
      perform erp.post_cash_document(v_receipt);
    end if;
$n$];
  v_hits integer;
begin
  if strpos(v_src, 'erp.post_cash_document(v_receipt)') > 0 then
    raise notice '% already opens a receipt per line; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '21c95c2b024764ab60da78f96bc25a46' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20260919200000 left (md5 %)', v_sig, md5(v_src);
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
$statement_route$;

comment on function erp.apply_settlement_statement(uuid) is
  'Applies a reconciled settlement statement: each matched line''s cash to the item it is matched to, '
  'through erp.apply_cash_to_item() (20260906137000). Where the organisation has a cash receipt type, '
  'each line is a receipt of its own, of the item''s customer and company, whose journals name it, '
  'posted with the cash (20260930100000).';

-- The capability register names the item route by its arguments, which
-- changed: the same capability, the new identity.
update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.apply_cash_to_item(uuid,bigint,text,date)',
                                 'erp.apply_cash_to_item(uuid,bigint,text,date,uuid)')
 where code = '5.7.accounts_receivable'
   and 'erp.apply_cash_to_item(uuid,bigint,text,date)' = any (artefacts);

do $capability$
begin
  if (select count(*) from erp_ref.part5_capability c, unnest(c.artefacts) a
       where c.code = '5.7.accounts_receivable'
         and a = 'erp.apply_cash_to_item(uuid,bigint,text,date,uuid)') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: 5.7.accounts_receivable does not name the item route once';
  end if;
end
$capability$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.cash_receipt_suite, eight cases more
--
-- The suite 20260930000000 made, edited by anchors: its statement cases go
-- before the organisation is put back to version 1, its version 1 statement
-- after it, and the two companies after the ledger checks, because their
-- open items are written straight to the subledger, as the suite that proves
-- the party route across companies writes them (document_value_and_cash_suite),
-- and would not tie to a control account. It counts 25.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.cash_receipt_statement(
  p_ref text, p_ccy character, p_lines jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_batch  uuid;
  v_st     uuid;
begin
  -- A settlement statement from 'stripe', one line per element of p_lines
  -- ({reference, amount_minor, occurred_on}), through the import pipeline, so
  -- it is loaded and reconciled as a provider's file is (20260930100000).
  v_batch := erp.stage_import('settlement_statement',
    (select jsonb_agg(jsonb_build_object(
              'provider', 'stripe', 'statement_ref', p_ref, 'statement_date', current_date,
              'currency', p_ccy, 'reference', x ->> 'reference',
              'amount_minor', (x ->> 'amount_minor')::bigint,
              'occurred_on', coalesce(x ->> 'occurred_on', (current_date - 1)::text))
              order by o)
       from jsonb_array_elements(p_lines) with ordinality as t(x, o)),
    'ZRS-' || p_ref);
  perform erp.validate_import(v_batch);
  perform erp.preview_import(v_batch);
  perform erp.load_import(v_batch);
  select s.id into v_st from erp.settlement_statement s
   where s.tenant_id = v_tenant and s.provider_code = 'stripe' and s.statement_ref = p_ref;
  return v_st;
end;
$$;

revoke all on function erp_test.cash_receipt_statement(text, character, jsonb) from public, anon;

comment on function erp_test.cash_receipt_statement(text, character, jsonb) is
  'A settlement statement loaded and reconciled through the import pipeline, for the cash receipt '
  'suite (20260930100000).';

do $receipt_suite$
declare
  v_sig constant text := 'erp_test.cash_receipt_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 17;$o$,
    $n$  -- Twenty-five since 20260930100000: a statement's lines are receipts.
  c_expected constant integer := 25;$n$,

    $o$  v_planned text;
begin$o$,
    $n$  v_planned text;
  -- The statement's cases (20260930100000).
  v_st uuid; v_st_ref text; v_item_row uuid; v_e2 uuid; v_site2 uuid; v_inv3 uuid;
  v_gross3 bigint; v_n4 integer; v_n5 integer; v_cases_seen integer; v_cust2 uuid;
begin$n$,

    $o$    -- ── 11. An organisation on version 1, and its upgrade ───────────────────
$o$,
    $n$    -- ── 18. A statement of two lines is two receipts ────────────────────────
    v_step := 'a settlement statement of two lines, applied';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRS18A', 50000);
    v_inv2 := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRS18B', 30000);
    v_st_ref := 'ZRS18-' || v_tag;
    v_st := erp_test.cash_receipt_statement(v_st_ref, v_ccy, jsonb_build_array(
      jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_inv),
                         'amount_minor', (select dv.gross_minor from erp.document_view dv where dv.id = v_inv),
                         'occurred_on', current_date - 1),
      jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_inv2),
                         'amount_minor', (select dv.gross_minor from erp.document_view dv where dv.id = v_inv2),
                         'occurred_on', current_date - 2)));
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    v_n3 := erp.apply_settlement_statement(v_st);
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    -- Each applied line's journal names a posted receipt of its own, of the
    -- matched item's customer, company and currency, dated the day the money
    -- moved, whose one line is the line's cash and names the invoice.
    select count(*), count(distinct j.document_id) into v_n4, v_cases_seen
      from erp.settlement_statement_line l
      join erp.journal j on j.id = l.applied_journal_id
                        and j.source_code = 'cash.applied' and j.status = 'posted'
      join erp.document d on d.id = j.document_id
      join erp.document_type dt on dt.id = d.document_type_id and dt.base_type_code = 'cash_receipt'
      join erp.subledger_item si on si.id = l.matched_subledger_item_id
     where l.statement_id = v_st and l.status = 'applied'
       and d.party_id = si.party_id and d.entity_id = si.entity_id and d.currency = si.currency
       and d.document_date = l.occurred_on
       and d.their_reference = format('stripe %s line %s', v_st_ref, l.line_no)
       and d.attributes ->> 'route' = 'settlement_statement'
       and d.attributes ->> 'settlement_statement_id' = v_st::text
       and d.attributes ->> 'settlement_statement_line_id' = l.id::text
       and d.document_number like 'RCPT-%'
       and erp.object_current_state('document', d.id) = 'posted'
       and (select lg.guard_data #>> '{derived,fact}' from erp.state_transition_log lg
             where lg.tenant_id = rb.tenant_id and lg.object_type = 'document' and lg.object_id = d.id
               and lg.transition_code = 'post') = 'erp.cash_document_is_applied'
       and (select count(*) from erp.document_line x where x.document_id = d.id) = 1
       and (select x.net_minor = l.amount_minor and x.item_id is null
                   and x.description = (select i.document_number from erp.document i where i.id = si.document_id)
              from erp.document_line x where x.document_id = d.id);
    v_cases := v_cases + 1;
    case_name := 'a statement of two lines applied makes two posted receipts, each named by its line''s journal, of the line''s customer, dated the day the money moved, whose one line is the line''s cash';
    passed := v_state is null
          and v_n3 = 2
          and v_n2 = v_n + 2
          and v_n4 = 2 and v_cases_seen = 2
          and erp.object_current_state('document', v_inv) = 'paid'
          and erp.object_current_state('document', v_inv2) = 'paid';
    detail := coalesce(v_state, format('%s line(s) applied; receipts %s then %s; %s line(s) with a receipt as it should be, %s distinct',
      v_n3, v_n, v_n2, v_n4, v_cases_seen));
    return next;

    -- ── 19. Over, kept on account; 20. short, written off ───────────────────
    v_step := 'a statement whose lines pay one invoice £100 over and one a penny short';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRS19', 50000);
    v_inv2 := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRS20', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    v_st_ref := 'ZRS19-' || v_tag;
    v_st := erp_test.cash_receipt_statement(v_st_ref, v_ccy, jsonb_build_array(
      jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_inv),
                         'amount_minor', v_gross + 10000),
      jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_inv2),
                         'amount_minor', v_gross2 - 1)));
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    perform erp.apply_settlement_statement(v_st);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    select j.document_id into v_rcpt
      from erp.settlement_statement_line l join erp.journal j on j.id = l.applied_journal_id
     where l.statement_id = v_st and l.line_no = 1;
    select j.document_id into v_rcpt2
      from erp.settlement_statement_line l join erp.journal j on j.id = l.applied_journal_id
     where l.statement_id = v_st and l.line_no = 2;
    begin
      v_err := erp.assert_ageing_equals_control();
      v_err := 'ties';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a statement line £100 over keeps the rest on account on its receipt: a line of £100 kept on account, the on-account journal names it, its lines total what its journals banked, and the ageing ties';
    passed := v_state is null
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt) = 2
          and exists (select 1 from erp.document_line l
                       where l.document_id = v_rcpt and l.description = 'kept on account'
                         and l.net_minor = 10000 and l.item_id is null)
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = v_gross + 10000
          and (select sum(si.debit_minor - si.credit_minor) from erp.subledger_item si
                where si.control_kind = 'bank'
                  and si.journal_id in (select j.id from erp.journal j where j.document_id = v_rcpt)) = v_gross + 10000
          and (select string_agg(j.source_code, ',' order by j.source_code) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt) = 'cash.applied,cash.on_account'
          and (select b.outstanding_minor from erp.ageing_balance b
                where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null) = -10000
          and erp.object_current_state('document', v_inv) = 'paid'
          and v_err = 'ties';
    detail := coalesce(v_state, format('lines %s; journals %s; %s',
      (select string_agg(l.description || ' ' || l.net_minor, ', ' order by l.line_no) from erp.document_line l where l.document_id = v_rcpt),
      (select string_agg(j.source_code, ',') from erp.journal j where j.document_id = v_rcpt), v_err));
    return next;

    v_cases := v_cases + 1;
    case_name := 'a statement line a penny short at £1 writes the penny off: the write-off journal names its receipt, whose one line is the cash, the lines of both receipts total the bank, and the invoice is Paid';
    passed := v_state is null
          and v_rcpt2 is distinct from v_rcpt
          and erp.object_current_state('document', v_rcpt2) = 'posted'
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt2) = 1
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt2) = v_gross2 - 1
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt2
                  and j.source_code = 'cash.settlement_difference_posted') = 1
          and (select sum(l.net_minor) from erp.document_line l where l.document_id in (v_rcpt, v_rcpt2))
            = v_b1 - v_b0
          and v_b1 - v_b0 = v_gross + 10000 + v_gross2 - 1
          and erp.object_current_state('document', v_inv2) = 'paid';
    detail := coalesce(v_state, format('bank moved %s; journals %s; invoice %s', v_b1 - v_b0,
      (select string_agg(j.source_code, ',') from erp.journal j where j.document_id = v_rcpt2),
      erp.object_current_state('document', v_inv2)));
    return next;

    -- ── 21. Not twice ───────────────────────────────────────────────────────
    v_step := 'the statement applied again';
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    begin
      perform erp.apply_settlement_statement(v_st);
      v_err := 'applied twice';
    exception when others then v_err := left(sqlerrm, 160); end;
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    v_cases := v_cases + 1;
    case_name := 'a statement applied twice is still refused, and opens no receipt';
    passed := v_state is null
          and v_err like 'CLOVEERP_SETTLEMENT_ALREADY_APPLIED:%'
          and v_n2 = v_n;
    detail := coalesce(v_state, format('%s; receipts %s then %s', v_err, v_n, v_n2));
    return next;

    -- ── 22. The item route takes only its customer's draft ──────────────────
    v_step := 'the item route given a receipt that is not its customer''s draft';
    v_inv3 := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRS22', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross3, v_cust2
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv3;
    select si.id into v_item_row from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv3
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    -- A pound of it paid at Apply cash: the customer's own receipt, posted.
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust2, 100, v_ccy, 'ZRS22-POUND') x;
    v_rcpt2 := (v_rows -> 0 ->> 'document_id')::uuid;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    begin
      perform erp.apply_cash_to_item(v_item_row, v_gross3 - 100, 'ZRS22-POSTED', current_date, v_rcpt2);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 160); end;
    -- A draft, opened past the doors, of another customer.
    v_draft := erp.open_document('cash_receipt', v_cust, v_entity, null, 'ZRS22-OTHER', null, v_ccy);
    begin
      perform erp.apply_cash_to_item(v_item_row, v_gross3 - 100, 'ZRS22-OTHER', current_date, v_draft);
      v_err2 := 'applied';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_cases := v_cases + 1;
    case_name := 'the item route refuses a receipt that is posted, even its own customer''s, or another customer''s draft, by name, and banks nothing';
    passed := v_state is null
          and erp.object_current_state('document', v_rcpt2) = 'posted'
          and v_err like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_err2 like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_b1 = v_b0
          and (select coalesce(si.settled_minor, 0) from erp.subledger_item si where si.id = v_item_row) = 100
          and (select count(*) from erp.document_line l where l.document_id = v_rcpt2) = 1
          and not exists (select 1 from erp.document_line l where l.document_id = v_draft)
          and erp.object_current_state('document', v_inv3) = 'part_paid';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, format('bank moved %s', v_b1 - v_b0)));
    return next;

    -- ── 11. An organisation on version 1, and its upgrade ───────────────────
$n$,

    $o$    v_step := 'upgrading receivables to version 2';
$o$,
    $n$    -- ── 23. A statement on version 1 ────────────────────────────────────────
    v_step := 'a statement applied on receivables version 1';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZRS23', 50000);
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_inv;
    v_st_ref := 'ZRS23-' || v_tag;
    v_st := erp_test.cash_receipt_statement(v_st_ref, v_ccy, jsonb_build_array(
      jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_inv),
                         'amount_minor', v_gross + 10000)));
    select count(*) into v_n from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    select count(*) into v_n4 from erp.journal j
     where j.tenant_id = rb.tenant_id and j.source_code in ('cash.applied', 'cash.on_account') and j.document_id is null;
    v_n3 := erp.apply_settlement_statement(v_st);
    select count(*) into v_n2 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt';
    select count(*) into v_n5 from erp.journal j
     where j.tenant_id = rb.tenant_id and j.source_code in ('cash.applied', 'cash.on_account') and j.document_id is null;
    v_cases := v_cases + 1;
    case_name := 'an organisation still on receivables version 1 applies a statement as before: no receipt, and the line''s journal and the on-account journal name no document';
    passed := v_state is null
          and v_n3 = 1
          and v_n2 = v_n
          and (select j.document_id is null and j.status = 'posted' and j.source_code = 'cash.applied'
                 from erp.settlement_statement_line l join erp.journal j on j.id = l.applied_journal_id
                where l.statement_id = v_st and l.line_no = 1)
          and v_n5 = v_n4 + 2
          and erp.object_current_state('document', v_inv) = 'paid';
    detail := coalesce(v_state, format('%s line(s); receipts %s then %s; documentless cash journals %s then %s', v_n3, v_n, v_n2, v_n4, v_n5));
    return next;

    v_step := 'upgrading receivables to version 2';
$n$,

    $o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';$o$,
    $n$    -- ── 24. Two companies, one receipt each ─────────────────────────────────
    -- Apply cash reaching open items in two companies (D5, 20260930000000):
    -- the items are written straight to the subledger, as the suite proving
    -- the party route across companies writes them, and so come after the
    -- ledger checks above.
    v_step := 'a second company, and cash that reaches both';
    perform erp.create_entity('ZRC2CO', 'Cash Receipt Second', null, v_ccy, 'GB');
    select e.id into v_e2 from erp.entity e where e.tenant_id = rb.tenant_id and e.code = 'ZRC2CO';
    perform erp.configure_finance(extract(year from current_date)::integer, v_ccy, v_e2);
    select s.id into v_site2 from erp.site s where s.tenant_id = rb.tenant_id and s.entity_id = v_e2
     order by s.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRC24', 'Cash Receipt Two Companies', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');
    -- The second company's the older, so it is paid first.
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select rb.tenant_id, v_e2, l.id, 'receivable', a.id, v_cust, v_ccy, 40000, 0, current_date - 30, current_date - 30
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = rb.tenant_id and l.entity_id = v_e2 and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     order by a.code limit 1;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select rb.tenant_id, v_entity, l.id, 'receivable', a.id, v_cust, v_ccy, 60000, 0, current_date - 10, current_date - 10
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = rb.tenant_id and l.entity_id = v_entity and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     order by a.code limit 1;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, 100000, v_ccy, 'ZRC24-BOTH') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_rcpt2 := (v_rows -> 1 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'Apply cash reaching two companies opens a receipt in each: each is posted, its journal is its company''s and names it, and its one line is what that company was paid';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and v_rcpt is not null and v_rcpt2 is not null and v_rcpt <> v_rcpt2
          and (select d.entity_id from erp.document d where d.id = v_rcpt) = v_e2
          and (select d.entity_id from erp.document d where d.id = v_rcpt2) = v_entity
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and erp.object_current_state('document', v_rcpt2) = 'posted'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt
                  and j.entity_id = v_e2 and j.source_code = 'cash.applied') = 1
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.document_id = v_rcpt2
                  and j.entity_id = v_entity and j.source_code = 'cash.applied') = 1
          and not exists (select 1 from erp.journal j where j.tenant_id = rb.tenant_id
                            and j.document_id in (v_rcpt, v_rcpt2)
                            and j.entity_id <> (select d.entity_id from erp.document d where d.id = j.document_id))
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = 40000
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt2) = 60000
          and (select d.document_number from erp.document d where d.id = v_rcpt)
              <> (select d.document_number from erp.document d where d.id = v_rcpt2);
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 25. A statement line of the other company ───────────────────────────
    v_step := 'a statement line matched to the second company''s invoice';
    v_inv3 := erp.open_document('sales_invoice', v_cust, v_e2, v_site2);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select rb.tenant_id, v_e2, l.id, 'receivable', a.id, v_cust, v_inv3, v_ccy, 30000, 0, current_date - 5, current_date + 25
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = rb.tenant_id and l.entity_id = v_e2 and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     order by a.code limit 1;
    v_st_ref := 'ZRS25-' || v_tag;
    v_st := erp_test.cash_receipt_statement(v_st_ref, v_ccy, jsonb_build_array(
      jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_inv3),
                         'amount_minor', 30000)));
    perform erp.apply_settlement_statement(v_st);
    select j.document_id into v_rcpt
      from erp.settlement_statement_line l join erp.journal j on j.id = l.applied_journal_id
     where l.statement_id = v_st and l.line_no = 1;
    v_cases := v_cases + 1;
    case_name := 'a statement line matched to another company''s invoice is that company''s receipt, as its journal is, whichever company the statement banks for';
    passed := v_state is null
          and (select s.entity_id from erp.settlement_statement s where s.id = v_st) <> v_e2
          and (select d.entity_id from erp.document d where d.id = v_rcpt) = v_e2
          and (select j.entity_id from erp.settlement_statement_line l join erp.journal j on j.id = l.applied_journal_id
                where l.statement_id = v_st and l.line_no = 1) = v_e2
          and erp.object_current_state('document', v_rcpt) = 'posted'
          and (select l.description from erp.document_line l where l.document_id = v_rcpt)
              = (select d.document_number from erp.document d where d.id = v_inv3);
    detail := coalesce(v_state, format('statement in %s, receipt %s in %s',
      (select s.entity_id from erp.settlement_statement s where s.id = v_st),
      coalesce((select d.document_number from erp.document d where d.id = v_rcpt), 'none'),
      (select d.entity_id from erp.document d where d.id = v_rcpt)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';$n$];
  v_hits integer;
begin
  if strpos(v_def, 'c_expected constant integer := 25;') > 0 then
    raise notice '% already proves the statement''s receipts; left as it is', v_sig;
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
  'receipt in each (20260930100000).';

do $receipt_assert$
declare
  v_sig constant text := 'erp_test.assert_cash_receipt_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  if v_total <> 17 then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_SHRANK: % case(s), expected 17', v_total$o$,
    $n$  if v_total <> 25 then
    raise exception 'CLOVEERP_CASH_RECEIPT_SUITE_SHRANK: % case(s), expected 25', v_total$n$];
  v_hits integer;
begin
  if strpos(v_def, 'expected 25') > 0 then
    raise notice '% already expects 25 cases; left as it is', v_sig;
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
