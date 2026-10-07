set lock_timeout = '30s';

-- =============================================================================
-- 20261010120000  Order to cash, proved in value
-- -----------------------------------------------------------------------------
-- Two Definition of Done cases the v1 gate (7 October) held as S2, both for
-- what nothing proved rather than for anything found wrong:
--
--   O2C-03 "Despatch 30 of 50 ordered. Expect: COGS and stock move for 30
--   only. Order shows 20 outstanding. Invoice raises for 30." Cost of sales
--   for a part despatch was asserted over the seeded month
--   (erp_test.demo_history_suite); the invoice was checked for its quantity
--   only, never its value, and only where the month happened to hold one.
--
--   O2C-05 "One standard-rated sale, one zero-rated, one to a non-UK
--   customer. Expect: each posts to the correct VAT control account at the
--   correct rate. VAT return figure reconciles to the control account."
--   Each treatment was proved on its own (erp_test.zero_rated_supply_suite,
--   erp_test.vat_return_suite); no case put the three in one organisation's
--   period and read the return against the ledger. The demonstration sells
--   no zero-rated product, by decision in 20260919840000, so the seeded
--   month never does.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
-- Nothing in the product. One suite, erp_test.order_to_cash_values_suite,
-- in one organisation registered for VAT in Great Britain, every invoice
-- issued the way a person issues it so the VAT is decided as it issues:
--
--   a hundred widgets received at ten pounds; fifty ordered at twenty pounds
--   by a customer at home; thirty despatched and invoiced. Stock and cost of
--   sales move by three hundred pounds, the order shows twenty outstanding,
--   and the invoice is six hundred pounds net, a hundred and twenty VAT, seven
--   hundred and twenty owed;
--
--   a standard-rated sale, a zero-rated sale at home and a sale to a
--   customer in Norway, invoiced the same day: twenty per cent to the tax
--   control account, nothing, and nothing, each by the rule that should
--   decide it;
--
--   the return for the period: box 1 is the output tax on the control
--   account, box 6 counts all four sales, and the return reports no
--   disagreement with the ledger.
--
-- Production: nothing. A function is added.
--
-- Proof: erp_test.order_to_cash_values_suite.
-- =============================================================================

create or replace function erp_test.order_to_cash_values_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  r        record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_country char(2);
  v_sup uuid; v_home uuid; v_away uuid;
  v_widget uuid; v_bread uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_loc uuid;
  v_so uuid; v_sol uuid; v_dn uuid; v_dnl uuid; v_inv uuid;
  v_std uuid; v_zero uuid; v_exp uuid;
  v_inv_acc text; v_cogs text; v_ar text; v_rev text; v_tax text;
  v_stock_cr bigint; v_cogs_dr bigint; v_moved numeric;
  v_ar_dr bigint; v_rev_cr bigint; v_tax_cr bigint; v_net bigint; v_qty numeric;
  v_outstanding numeric;
  v_t1 bigint; v_t2 bigint; v_t3 bigint;
  v_tax_period bigint;
  b record;
begin
  begin
    v_step := 'an organisation registered for VAT in Great Britain, buying, holding and selling';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzotc-' || v_tag, 'Order To Cash Values Suite',
      'admin@zzotc-' || v_tag || '.test', 'Order To Cash Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzotc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_tax('GB', 20);

    v_entity := rb.entity_id;
    select e.base_currency, e.country_code into v_ccy, v_country
      from erp.entity e where e.id = v_entity;
    -- Registered for VAT since a year ago: an unregistered company charges none.
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                             registration_type, registration_number, valid_from)
    values (rb.tenant_id, v_entity, 'GB', 'VAT', 'GB123456789', current_date - 365);

    v_inv_acc := erp.tenant_account_code('inventory');
    v_cogs    := erp.tenant_account_code('cost_of_sales');
    v_ar      := erp.tenant_account_code('trade_receivable');
    v_rev     := erp.tenant_account_code('revenue');
    v_tax     := erp.tenant_account_code('tax_control');

    v_step := 'its site, places, unit, a supplier, a customer at home and one abroad, two products';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZTEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, v_entity, 'ZTSITE', 'Order to cash suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZT-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZT-BULK', 'Bulk', 'bulk');

    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZTSUP', 'Order To Cash Supplier', v_country, 'active') returning id into v_sup;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZTHOME', 'Customer at home', v_country, 'active') returning id into v_home;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZTAWAY', 'Customer in Norway',
            case when v_country = 'NO' then 'NZ' else 'NO' end, 'active') returning id into v_away;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active'),
           (rb.tenant_id, v_home, 'customer', 'active'),
           (rb.tenant_id, v_away, 'customer', 'active');

    insert into erp.item (tenant_id, code, name, item_class, tax_class, stock_uom_id, lifecycle, status)
    values (rb.tenant_id, 'ZT-WIDGET', 'A widget', 'finished_good', 'standard', v_uom, 'active', 'active')
    returning id into v_widget;
    insert into erp.item (tenant_id, code, name, item_class, tax_class, stock_uom_id, lifecycle, status)
    values (rb.tenant_id, 'ZT-BREAD', 'A loaf of bread', 'finished_good', 'zero_rated', v_uom, 'active', 'active')
    returning id into v_bread;

    v_step := 'a hundred widgets received at ten pounds';
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_widget, 100, 1000, 'a hundred widgets');
    perform erp.transition_document(v_po, 'submit', 'order to cash suite');
    perform erp_test.approve_document(v_po, 'order to cash suite');
    perform erp.transition_document(v_po, 'send', 'order to cash suite');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'order to cash suite');
    select m.to_location_id into v_loc
      from erp.stock_movement m
     where m.tenant_id = rb.tenant_id and m.document_id = v_grn and m.to_location_id is not null
     order by m.recorded_at desc limit 1;

    -- ── 1–5. O2C-03: thirty of fifty ────────────────────────────────────────
    v_step := 'fifty ordered at twenty pounds, thirty despatched';
    v_so := erp.create_document('sales_order', v_entity, v_site, v_home, current_date, v_ccy,
                                'ZT-SO', '{}'::jsonb);
    v_sol := erp.add_document_line(v_so, v_widget, 50, 2000, 'fifty widgets', current_date + 7);
    perform erp.transition_document(v_so, 'submit', 'order to cash suite');
    perform erp.approve_my_document_tasks(v_so, 'order to cash suite');
    if erp.document_state_code(v_so) <> 'approved' then
      perform erp.transition_document(v_so, 'approve', 'order to cash suite');
    end if;
    if coalesce((select cp.on_hold from erp.credit_position(v_home) cp), false) then
      perform erp.release_credit_hold(v_so, 'order to cash suite: a new customer');
    end if;

    v_dn := (erp.create_delivery_from_order(
               v_so, jsonb_build_array(jsonb_build_object('line_id', v_sol, 'quantity', 30)), null)
             ->> 'document_id')::uuid;
    select dl.id into v_dnl from erp.document_line dl
     where dl.tenant_id = rb.tenant_id and dl.document_id = v_dn order by dl.line_no limit 1;
    perform erp.set_line_stock_identity(v_dnl, null, v_loc, null);
    perform erp.transition_document(v_dn, 'post', 'order to cash suite');

    select coalesce(sum(m.quantity), 0) into v_moved
      from erp.stock_movement m
     where m.tenant_id = rb.tenant_id and m.document_id = v_dn and m.from_location_id is not null;
    select coalesce(sum(jl.credit_minor) filter (where a.code = v_inv_acc), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_cogs), 0)
      into v_stock_cr, v_cogs_dr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted'
       and (j.document_id = v_dn or j.source_event_id in (
             select m.event_id from erp.stock_movement m
              where m.tenant_id = rb.tenant_id and m.document_id = v_dn));

    v_cases := v_cases + 1;
    case_name := 'despatching thirty of fifty moves thirty out of stock';
    passed := v_state is null and v_moved = 30;
    detail := format('%s out of stock', trim_scale(v_moved));
    return next;

    v_cases := v_cases + 1;
    case_name := 'and stock and cost of sales move by thirty at what they cost, three hundred pounds';
    passed := v_state is null and v_stock_cr = 30000 and v_cogs_dr = 30000;
    detail := format('%s credited to %s, %s debited to %s', v_stock_cr, v_inv_acc, v_cogs_dr, v_cogs);
    return next;

    select ol.quantity - coalesce(ol.quantity_fulfilled, 0) into v_outstanding
      from erp.document_line ol where ol.id = v_sol;

    v_cases := v_cases + 1;
    case_name := 'the order shows twenty outstanding';
    passed := v_state is null and v_outstanding = 20;
    detail := format('%s outstanding of 50', trim_scale(v_outstanding));
    return next;

    v_step := 'the thirty invoiced';
    v_inv := erp.invoice_from_delivery(v_dn, true, null);
    perform erp.transition_document(v_inv, 'issue', 'order to cash suite');

    select coalesce(sum(l.quantity), 0), coalesce(sum(l.net_minor), 0) into v_qty, v_net
      from erp.document_line l where l.tenant_id = rb.tenant_id and l.document_id = v_inv
       and not coalesce(l.is_cancelled, false);
    select coalesce(sum(jl.debit_minor) filter (where a.code = v_ar), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_rev), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_tax), 0)
      into v_ar_dr, v_rev_cr, v_tax_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_inv and j.status = 'posted';

    v_cases := v_cases + 1;
    case_name := 'the invoice raises for thirty, at six hundred pounds net';
    passed := v_state is null and v_qty = 30 and v_net = 60000;
    detail := format('%s at %s net', trim_scale(v_qty), v_net);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and posts seven hundred and twenty owed: six hundred revenue and a hundred and twenty VAT';
    passed := v_state is null and v_ar_dr = 72000 and v_rev_cr = 60000 and v_tax_cr = 12000;
    detail := format('%s debited to %s; %s to %s and %s to %s', v_ar_dr, v_ar, v_rev_cr, v_rev, v_tax_cr, v_tax);
    return next;

    -- ── 6–9. O2C-05: three treatments and the return ────────────────────────
    v_step := 'a standard-rated sale, a zero-rated sale and an export, invoiced';
    v_std := erp.create_document('sales_invoice', v_entity, v_site, v_home, current_date, v_ccy, 'ZT-STD', '{}'::jsonb);
    perform erp.add_document_line(v_std, v_widget, 1, 10000, 'a widget');
    v_zero := erp.create_document('sales_invoice', v_entity, v_site, v_home, current_date, v_ccy, 'ZT-ZERO', '{}'::jsonb);
    perform erp.add_document_line(v_zero, v_bread, 1, 10000, 'a loaf of bread');
    v_exp := erp.create_document('sales_invoice', v_entity, v_site, v_away, current_date, v_ccy, 'ZT-EXP', '{}'::jsonb);
    perform erp.add_document_line(v_exp, v_widget, 1, 10000, 'a widget shipped to Norway');
    -- Issued as a person issues them: the VAT is decided as each one issues.
    for r in select x.id from (values (v_std), (v_zero), (v_exp)) x(id) loop
      perform erp.transition_document(r.id, 'issue', 'order to cash suite');
    end loop;

    select coalesce(sum(jl.credit_minor - jl.debit_minor) filter (where j.document_id = v_std), 0),
           coalesce(sum(jl.credit_minor - jl.debit_minor) filter (where j.document_id = v_zero), 0),
           coalesce(sum(jl.credit_minor - jl.debit_minor) filter (where j.document_id = v_exp), 0)
      into v_t1, v_t2, v_t3
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_tax
       and j.document_id in (v_std, v_zero, v_exp);

    v_cases := v_cases + 1;
    case_name := 'the standard-rated sale puts twenty per cent on the tax control account, the zero-rated and the export nothing';
    passed := v_state is null and v_t1 = 2000 and v_t2 = 0 and v_t3 = 0;
    detail := format('standard %s, zero-rated %s, export %s to %s', v_t1, v_t2, v_t3, v_tax);
    return next;

    select string_agg(format('%s:%s@%s', d.their_reference, td.treatment, td.rate_pct), ', '
                      order by d.their_reference) into detail
      from erp.tax_determination td
      join erp.document_line l on l.tenant_id = td.tenant_id and l.id = td.document_line_id
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
     where td.tenant_id = rb.tenant_id and d.id in (v_std, v_zero, v_exp);

    v_cases := v_cases + 1;
    case_name := 'each is decided by its own rule: standard, zero-rated at home, and export';
    passed := v_state is null
          and exists (select 1 from erp.tax_determination td join erp.document_line l on l.id = td.document_line_id
                       where l.document_id = v_std and td.treatment = 'standard' and td.rate_pct = 20)
          and exists (select 1 from erp.tax_determination td join erp.document_line l on l.id = td.document_line_id
                       where l.document_id = v_zero and td.treatment = 'zero_rated' and td.rate_pct = 0
                         and td.rule_code <> 'export_zero')
          and exists (select 1 from erp.tax_determination td join erp.document_line l on l.id = td.document_line_id
                       where l.document_id = v_exp and td.rule_code = 'export_zero' and td.rate_pct = 0);
    return next;

    v_step := 'the return for the period';
    select * into b from erp.vat_return_boxes(v_entity, current_date - 1, current_date + 1);
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_tax_period
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
      join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_tax
       and dt.base_type_code = 'invoice_reference' and dt.code = 'sales_invoice';

    v_cases := v_cases + 1;
    case_name := 'box 1 is the output tax on the control account, and box 6 counts all four sales';
    passed := v_state is null
          and b.box1_minor = v_tax_period and b.box1_minor = 14000
          and b.box6_pounds = 900;
    detail := format('box 1 %s against %s on %s; box 6 %s pounds', b.box1_minor, v_tax_period, v_tax, b.box6_pounds);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the return reports no disagreement with the ledger';
    passed := v_state is null and coalesce(b.ledger_disagreements, -1) = 0
          and coalesce(b.unknown_side, -1) = 0;
    detail := format('%s ledger disagreement(s), %s entry(ies) of unknown side, %s entries',
                     b.ledger_disagreements, b.unknown_side, b.entries);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzotc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzotc rolled back with its orders, deliveries and invoices');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ORDER_TO_CASH_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_order_to_cash_values_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _order_to_cash_values on commit drop as
    select * from erp_test.order_to_cash_values_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _order_to_cash_values;
  drop table _order_to_cash_values;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ORDER_TO_CASH_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_ORDER_TO_CASH_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('order to cash, proved in value: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.order_to_cash_values_suite() from public, anon;
revoke all on function erp_test.assert_order_to_cash_values_suite() from public, anon;

comment on function erp_test.order_to_cash_values_suite() is
  'Definition of Done O2C-03 and O2C-05 (20261010120000): thirty of fifty despatched move stock and cost of sales '
  'for thirty, leave twenty outstanding and invoice six hundred pounds net; a standard-rated, a zero-rated and an '
  'export sale post twenty per cent, nothing and nothing to tax control, and the return agrees with the ledger.';

comment on function erp_test.assert_order_to_cash_values_suite() is
  'erp_test.order_to_cash_values_suite(), ten cases: O2C-03 and O2C-05.';

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
