set lock_timeout = '30s';

-- =============================================================================
-- 20261005200000  What old bills took off goods received not invoiced
-- -----------------------------------------------------------------------------
-- Since 1 October the demonstration's September close has refused:
--
--   CLOVEERP_GRNI_DOES_NOT_RECONCILE: 2100 — open receipts 8345907, ledger
--   8185057 (out by -160850)
--
-- Read on live, 4 October, by the owner's leave and read only, all of it is
-- the first cause the check's own hint names. The demonstration's 106 bills
-- posted under purchase_invoice version 1 cleared 80,639,145 off 2100; the
-- order lines they bill, at the order's price, put 80,478,295 on it. The
-- difference, 160,850 over 24 bills, is each bill's price against its
-- order's: version 1 cleared the account at what the bill charged, and
-- version 2 (procurement-controls v4) clears it at what the receipt credited
-- and sends the rest to purchase price variance. The one bill posted under
-- version 2 differs by nothing.
--
-- The residue is not a defect still happening; it is the ledger version 1
-- left. 20260929000000 left it to an accountant: post the correction, or
-- waive the close task. In a live organisation that stays so. A
-- demonstration has no accountant, and its close is what a prospect is shown.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
--   * erp.clear_bill_price_residue(): in the organisation it is called in, if
--     it is not live, for each company: what its posted bills cleared off
--     goods received not invoiced, less what the order lines they bill put on
--     it at the order's price. Where that is not nothing, one journal moves it
--     to purchase price variance, as version 2 would have posted it, dated on
--     the last bill that differs. Once per company. Only bills that name the
--     order lines they bill are read, so nothing is guessed.
--   * This migration calls it in every organisation and says what it posted,
--     so the deploy's log is the record.
--
-- Proof: erp_test.bill_price_residue_suite.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.finance.bill_price_residue_cleared', 'en', 'Bill price residue cleared', 'finance',
   'Event raised when what old bills cleared off goods received not invoiced beyond the order price is moved to purchase price variance.'),
  ('event.finance.bill_price_residue_cleared', 'de', 'Preisabweichung alter Rechnungen umgebucht', 'finance',
   'Ereignis, wenn der über den Bestellpreis hinaus ausgebuchte Wareneingang auf die Preisabweichung umgebucht wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('finance.bill_price_residue_cleared', 1, 'journal', 'finance', 'event.finance.bill_price_residue_cleared',
        'What bills cleared off goods received not invoiced beyond the order price was moved to purchase price variance.',
        '{"type":"object","required":["value_minor","bills"],"properties":{"value_minor":{"type":"integer"},"bills":{"type":"integer"},"currency":{"type":"string"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if not exists (select 1 from erp_ref.event_type et
                  where et.code = 'finance.bill_price_residue_cleared' and et.version = 1 and et.is_current
                    and et.aggregate_type = 'journal') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: finance.bill_price_residue_cleared is declared already, and not as 20261005200000 declares it';
  end if;
end
$event$;

create or replace function erp.clear_bill_price_residue()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_grni    text := erp.tenant_account_code('goods_received_not_invoiced');
  v_ppv     text := erp.tenant_account_code('purchase_price_variance');
  v_total   bigint := 0;
  r         record;
  v_grni_id uuid;
  v_ppv_id  uuid;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_amount  bigint;
begin
  -- What posted bills took off goods received not invoiced beyond what the
  -- order lines they bill put on it, moved to purchase price variance
  -- (20261005200000). Version 1 of purchase_invoice cleared the account at
  -- the bill's price; version 2 clears it at the receipt's and posts the rest
  -- as a variance. Nothing in a live organisation, whose accountant decides.
  if erp.tenant_is_live() then
    return 0;
  end if;

  for r in
    with cleared as (
      select j.entity_id, j.ledger_id, j.document_id, max(j.posting_date) as on_date,
             sum(l.debit_minor - l.credit_minor) as grni
        from erp.journal j
        join erp.journal_line l on l.tenant_id = j.tenant_id and l.journal_id = j.id
        join erp.account a on a.id = l.account_id and a.code = v_grni
        join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
        join erp.document_type dt on dt.id = d.document_type_id
       where j.tenant_id = v_tenant and j.status = 'posted' and dt.code = 'purchase_invoice'
       group by 1, 2, 3
    ),
    at_order as (
      select rel.from_document_id as document_id,
             sum(round(rel.quantity * ol.unit_price_minor)) as ordered
        from erp.document_relation rel
        join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
        join erp.document od on od.tenant_id = ol.tenant_id and od.id = ol.document_id
        join erp.document_type odt on odt.id = od.document_type_id and odt.base_type_code = 'purchase_order'
       where rel.tenant_id = v_tenant and rel.relation_kind = 'invoices'
       group by 1
    )
    select c.entity_id, c.ledger_id, e.code as entity_code, e.base_currency,
           sum(c.grni - o.ordered)::bigint as residue,
           count(*) filter (where c.grni <> o.ordered) as bills,
           max(c.on_date) filter (where c.grni <> o.ordered) as on_date
      from cleared c
      join at_order o using (document_id)
      join erp.entity e on e.id = c.entity_id
     group by 1, 2, 3, 4
  loop
    v_amount := abs(r.residue);
    continue when v_amount = 0;
    continue when exists (
      select 1 from erp.journal j
       where j.tenant_id = v_tenant and j.entity_id = r.entity_id
         and j.source_code = 'finance.bill_price_residue_cleared' and j.status = 'posted');

    select a.id into v_grni_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = r.entity_id and a.code = v_grni and a.status = 'active';
    select a.id into v_ppv_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = r.entity_id and a.code = v_ppv and a.status = 'active';
    if v_grni_id is null or v_ppv_id is null then
      raise warning 'bill price residue: % in company % is not cleared; it has no % or no %',
        r.residue, r.entity_code, v_grni, v_ppv;
      continue;
    end if;

    -- The rule in force, which posts the variance this is.
    select pr.id, pr.version into v_rule, v_version
      from erp.posting_rule pr
     where pr.tenant_id = v_tenant and pr.code = 'purchase_invoice' and pr.status = 'active'
       and (pr.entity_id is null or pr.entity_id = r.entity_id)
     order by pr.version desc limit 1;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status)
    values (v_tenant, r.entity_id, r.ledger_id, 'finance.bill_price_residue_cleared', r.on_date,
            format('What %s bill(s) cleared off goods received not invoiced beyond the order price, '
                   'to purchase price variance', r.bills), 'draft')
    returning id into v_journal;

    v_event := erp.append_event(
      'finance.bill_price_residue_cleared', 'journal', v_journal,
      jsonb_build_object('value_minor', r.residue, 'bills', r.bills, 'currency', r.base_currency),
      r.entity_id, null);
    update erp.journal set source_event_id = v_event where id = v_journal;

    -- Cleared too much: the account is owed it back and the variance takes
    -- it. Too little, the other way round.
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, 1, case when r.residue > 0 then v_ppv_id else v_grni_id end,
            v_amount, 0, r.base_currency, v_amount, 0, 1, v_rule, v_version, v_event,
            case when r.residue > 0 then 'Purchase price variance the bills'' rule did not post'
                 else 'Goods received not invoiced the bills did not clear' end),
           (v_tenant, v_journal, 2, case when r.residue > 0 then v_grni_id else v_ppv_id end,
            0, v_amount, r.base_currency, 0, v_amount, 1, v_rule, v_version, v_event,
            case when r.residue > 0 then 'Goods received not invoiced the bills cleared beyond the order price'
                 else 'Purchase price variance the bills'' rule did not post' end);

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;

    v_total := v_total + r.residue;
  end loop;

  return v_total;
end;
$$;

revoke all on function erp.clear_bill_price_residue() from public, anon;

comment on function erp.clear_bill_price_residue() is
  'Moves what posted bills cleared off goods received not invoiced beyond the order price to purchase price '
  'variance, once per company, in an organisation that is not live (20261005200000). Called by this migration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bill_price_residue_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_po uuid; v_bill uuid;
  v_rule   erp.posting_rule%rowtype;
  v_before bigint; v_after bigint; v_again bigint; v_live bigint;
  v_err    text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation billing under version 1''s shape';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzbpr-' || v_tag, 'Bill Price Residue Suite',
      'admin@zzbpr-' || v_tag || '.test', 'Residue Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzbpr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZBCOAT', 'Residue Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZBBRAND');

    -- Version 1's shape: the account cleared at what the bill charges.
    select * into v_rule from erp.posting_rule pr
     where pr.tenant_id = rb.tenant_id and pr.code = 'purchase_invoice' and pr.status = 'active'
     order by pr.version desc limit 1;
    update erp.posting_rule set status = 'superseded' where id = v_rule.id;
    insert into erp.posting_rule
    select * from jsonb_populate_record(null::erp.posting_rule, to_jsonb(v_rule) || jsonb_build_object(
      'id', gen_random_uuid(), 'version', v_rule.version + 1,
      'posting_lines', jsonb_build_array(
        jsonb_build_object('account', erp.tenant_account_code('goods_received_not_invoiced'),
                           'side', 'debit', 'rate', 1, 'basis', 'document_value'),
        jsonb_build_object('account', erp.tenant_account_code('tax_control'),
                           'side', 'debit', 'rate', 1, 'basis', 'document_tax'),
        jsonb_build_object('account', erp.tenant_account_code('trade_payable'),
                           'side', 'credit', 'balancing', true))));

    -- Ten coats ordered at 90.00, billed at 91.00: inside the match's
    -- tolerance, so it posts, clearing 10.00 more than the receipt put on.
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZBO1', false);
    perform public.erp_send_purchase_order(v_po, 'orders@zbbrand-' || v_tag || '.test', null, null, null);
    v_bill := erp_test.prepayment_bill(v_po, 10, 'ZB-BILL-1', 9100);
    select max(r.ledger_minor) - sum(g.open_value_minor) into v_before
      from erp.grni_reconciliation() r, lateral (select coalesce(sum(x.open_value_minor), 0) as open_value_minor
                                                  from erp.grni_report() x) g;

    -- ── 1. The residue it leaves ────────────────────────────────────────────
    v_step := 'reading the residue';
    v_cases := v_cases + 1;
    case_name := 'a bill cleared at its own price leaves goods received not invoiced short by the price difference, and the close''s check refuses';
    begin
      perform erp.assert_grni_reconciles();
      v_err := 'reconciled';
    exception when others then v_err := sqlerrm; end;
    passed := v_state is null and v_before = -1000 and v_err like 'CLOVEERP_GRNI_DOES_NOT_RECONCILE:%';
    detail := coalesce(v_state, format('ledger less open %s | %s', v_before, left(v_err, 200)));
    return next;

    -- ── 2. A live organisation is its accountant's ──────────────────────────
    v_step := 'clearing in a live organisation';
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_live := erp.clear_bill_price_residue();
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    v_cases := v_cases + 1;
    case_name := 'nothing is posted in a live organisation';
    passed := v_state is null and v_live = 0
          and not exists (select 1 from erp.journal j
                           where j.tenant_id = rb.tenant_id and j.source_code = 'finance.bill_price_residue_cleared');
    detail := coalesce(v_state, format('cleared %s', v_live));
    return next;

    -- ── 3. Cleared to the variance ──────────────────────────────────────────
    v_step := 'clearing the residue';
    v_after := erp.clear_bill_price_residue();
    v_cases := v_cases + 1;
    case_name := 'the residue moves to purchase price variance in one balanced journal on the bill''s date, and the account reconciles';
    begin
      perform erp.assert_grni_reconciles();
      v_err := 'reconciled';
    exception when others then v_err := sqlerrm; end;
    passed := v_state is null and v_after = 1000 and v_err = 'reconciled'
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.source_code = 'finance.bill_price_residue_cleared'
                  and j.status = 'posted'
                  and j.posting_date = (select d.document_date from erp.document d where d.id = v_bill)) = 1
          and (select sum(l.debit_minor) from erp.journal_line l
                 join erp.journal j on j.id = l.journal_id
                 join erp.account a on a.id = l.account_id
                where j.source_code = 'finance.bill_price_residue_cleared' and j.tenant_id = rb.tenant_id
                  and a.code = erp.tenant_account_code('purchase_price_variance')) = 1000;
    detail := coalesce(v_state, format('cleared %s | %s', v_after, left(v_err, 200)));
    return next;

    -- ── 4. Once ─────────────────────────────────────────────────────────────
    v_step := 'clearing again';
    v_again := erp.clear_bill_price_residue();
    v_cases := v_cases + 1;
    case_name := 'called again, it posts nothing more';
    passed := v_state is null and v_again = 0
          and (select count(*) from erp.journal j
                where j.tenant_id = rb.tenant_id and j.source_code = 'finance.bill_price_residue_cleared') = 1;
    detail := coalesce(v_state, format('again %s', v_again));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzbpr-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzbpr rolled back');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_BILL_PRICE_RESIDUE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.bill_price_residue_suite() from public, anon;

comment on function erp_test.bill_price_residue_suite() is
  'What old bills took off goods received not invoiced (20261005200000): a bill cleared at its own price '
  'leaves a residue the close refuses; it moves to purchase price variance once, and never in a live organisation.';

create or replace function erp_test.assert_bill_price_residue_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.bill_price_residue_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_BILL_PRICE_RESIDUE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A residue would stay on goods received not invoiced, or be posted where an accountant decides. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_BILL_PRICE_RESIDUE_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('bill price residue: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_bill_price_residue_suite() from public, anon;

comment on function erp_test.assert_bill_price_residue_suite() is
  'What version 1 bills cleared off goods received not invoiced beyond the order price is moved to purchase '
  'price variance in a demonstration (20261005200000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleared where it is, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $clear$
declare
  r       record;
  v_n     bigint;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.clear_bill_price_residue();
    if v_n <> 0 then
      raise warning 'bill price residue: % moved from goods received not invoiced to purchase price variance in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$clear$;

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
select erp.assert_personal_data_register_sound();
