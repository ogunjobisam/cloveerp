set lock_timeout = '30s';

-- =============================================================================
-- 20261010160000  A stock adjustment says why
-- -----------------------------------------------------------------------------
-- Definition of Done INV-01: "Write off 5 units. Expect: stock reduces at
-- current cost, write-off posts to the P&L, movement is on the audit trail
-- with a reason." The v1 gate (7 October) held it as S3: the value, the
-- account and the reason on the movement were proved
-- (erp_test.stock_adjustment_suite), but no case raised an adjustment with no
-- reason (CLOVEERP_ADJUSTMENT_NEEDS_A_REASON appeared in no suite) and none
-- checked a reason the organisation set up to need a note.
--
-- Nothing in the product changes. erp_test.stock_adjustment_reason_suite
-- writes off five widgets held at five pounds and proves every leg of the
-- case as written, and both refusals.
--
-- Proof: erp_test.stock_adjustment_reason_suite.
-- =============================================================================

create or replace function erp_test.stock_adjustment_reason_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  r        record;
  v_step   text := 'provisioning';
  v_state  text;
  v_ccy char(3); v_site uuid; v_bulk uuid; v_uom uuid; v_item uuid;
  v_msg1 text; v_msg2 text; v_msg3 text;
  res jsonb; v_adj uuid;
  v_before numeric; v_after numeric; v_moved bigint;
  v_pl_dr bigint; v_inv_cr bigint; v_pl_type text;
  v_reason text; v_audited bigint;
begin
  begin
    v_step := 'an organisation with the demonstration''s configuration';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-sar-' || v_tag, 'Stock adjustment reason suite',
      'a@zz-sar-' || v_tag || '.test', 'Suite Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'a@zz-sar-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;

    v_step := 'a site holding a hundred widgets at five pounds';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-SAR', 'Reason depot', 'warehouse', 'GB', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, v_site, 'ZZ-SAR-BULK', 'Reason bulk', 'bulk', true, 'active') returning id into v_bulk;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, v_site, 'ZZ-SAR-IN', 'Reason goods in', 'receiving', false, 'active');
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-SAR-1', 'Countable widget', v_uom, 'active') returning id into v_item;
    perform erp.receive_cost(v_item, v_site, 100, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, v_site, 'receipt_no_order', v_item, v_bulk, 'available', 100, v_uom, 500,
      v_ccy, 'OPENING');

    -- A reason the organisation keeps that insists on a note.
    insert into erp.reason_code (tenant_id, category_code, code, name, requires_note, requires_approval, status, seq)
    values (r.tenant_id, 'STOCK_ADJUSTMENT', 'ZZ_SAR_NOTED', 'Damaged in handling, say how', true, false, 'active', 990)
    on conflict do nothing;

    select coalesce(sum(b.quantity), 0) into v_before
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;

    -- ── 1–3. Refused without a reason, or without the note it needs ─────────
    v_step := 'five written off with no reason, a blank one, and one that needs a note given none';
    begin
      perform erp.raise_stock_adjustment(v_site, null,
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)));
      v_msg1 := 'it was raised';
    exception when others then v_msg1 := left(sqlerrm, 200);
    end;
    begin
      perform erp.raise_stock_adjustment(v_site, '   ',
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)));
      v_msg2 := 'it was raised';
    exception when others then v_msg2 := left(sqlerrm, 200);
    end;
    begin
      perform erp.raise_stock_adjustment(v_site, 'ZZ_SAR_NOTED',
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)));
      v_msg3 := 'it was raised';
    exception when others then v_msg3 := left(sqlerrm, 200);
    end;
    select coalesce(sum(b.quantity), 0) into v_after
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;

    v_cases := v_cases + 1;
    case_name := 'a write-off with no reason is refused, in words';
    passed := v_state is null and v_msg1 like 'CLOVEERP_ADJUSTMENT_NEEDS_A_REASON:%';
    detail := v_msg1;
    return next;

    v_cases := v_cases + 1;
    case_name := 'and so is one whose reason is blank';
    passed := v_state is null and v_msg2 like 'CLOVEERP_ADJUSTMENT_NEEDS_A_REASON:%';
    detail := v_msg2;
    return next;

    v_cases := v_cases + 1;
    case_name := 'a reason set up to need a note is refused without one, and nothing moved';
    passed := v_state is null and v_msg3 like 'CLOVEERP_REASON_NEEDS_A_NOTE:%' and v_after = v_before;
    detail := format('%s; stock %s before and after', v_msg3, trim_scale(v_after));
    return next;

    -- ── 4–6. INV-01 as written ──────────────────────────────────────────────
    v_step := 'five written off with the reason and its note';
    res := erp.raise_stock_adjustment(v_site, 'ZZ_SAR_NOTED',
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -5, 'location_id', v_bulk)),
             null, 'Forklift tines went through the carton', 'ZZ-SAR-1');
    v_adj := (res ->> 'document_id')::uuid;
    select coalesce(sum(b.quantity), 0) into v_after
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;
    select coalesce(sum(m.cost_minor), 0), max(m.reason_code) into v_moved, v_reason
      from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.document_id = v_adj and not m.is_reversal;

    v_cases := v_cases + 1;
    case_name := 'five written off reduce stock by five at its current cost, twenty-five pounds';
    passed := v_state is null and res ->> 'state' = 'posted'
          and v_before - v_after = 5 and abs(v_moved) = 2500;
    detail := format('%s, stock %s to %s, %s at cost', res ->> 'state', trim_scale(v_before), trim_scale(v_after), v_moved);
    return next;

    select coalesce(sum(jl.debit_minor) filter (where a.code = erp.tenant_account_code('stock_adjustment')), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = erp.tenant_account_code('inventory')), 0),
           max(a.account_type::text) filter (where a.code = erp.tenant_account_code('stock_adjustment'))
      into v_pl_dr, v_inv_cr, v_pl_type
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = r.tenant_id and j.status = 'posted' and j.source_code = 'stock.adjusted';

    v_cases := v_cases + 1;
    case_name := 'the write-off posts twenty-five pounds to the profit and loss, against inventory';
    passed := v_state is null and v_pl_dr = 2500 and v_inv_cr = 2500
          and v_pl_type in ('expense', 'cost_of_sales', 'other_expense');
    detail := format('%s debited to the stock adjustments account (%s), %s credited to inventory',
                     v_pl_dr, coalesce(v_pl_type, 'no type'), v_inv_cr);
    return next;

    select count(*) into v_audited
      from erp.audit_entry ae
     where ae.tenant_id = r.tenant_id
       and (ae.object_id = v_adj
            or ae.object_key in (select m.id::text from erp.stock_movement m
                                  where m.tenant_id = r.tenant_id and m.document_id = v_adj));

    v_cases := v_cases + 1;
    case_name := 'the movement carries its reason, and the adjustment is on the audit trail';
    passed := v_state is null and v_reason = 'ZZ_SAR_NOTED' and v_audited > 0;
    detail := format('reason %s; %s audit entr(y/ies)', coalesce(v_reason, 'none'), v_audited);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zz-sar-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zz-sar rolled back with its stock and its adjustment');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_STOCK_ADJUSTMENT_REASON_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_stock_adjustment_reason_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _stock_adjustment_reason on commit drop as
    select * from erp_test.stock_adjustment_reason_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _stock_adjustment_reason;
  drop table _stock_adjustment_reason;
  if v_fail > 0 then
    raise exception E'CLOVEERP_STOCK_ADJUSTMENT_REASON_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_STOCK_ADJUSTMENT_REASON_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a stock adjustment says why: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.stock_adjustment_reason_suite() from public, anon;
revoke all on function erp_test.assert_stock_adjustment_reason_suite() from public, anon;

comment on function erp_test.stock_adjustment_reason_suite() is
  'Definition of Done INV-01 (20261010160000): a write-off with no reason, a blank one, or a noted reason with no '
  'note is refused and moves nothing; five written off reduce stock at current cost, post to the profit and loss '
  'against inventory, carry their reason, and are on the audit trail.';

comment on function erp_test.assert_stock_adjustment_reason_suite() is
  'erp_test.stock_adjustment_reason_suite(), seven cases: INV-01.';

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
