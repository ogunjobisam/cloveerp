set lock_timeout = '30s';

-- =============================================================================
-- 20261010240000  A pallet waits only for what just arrived
-- -----------------------------------------------------------------------------
-- Found on the live demonstration on 7 October, after 20261010230000 was
-- released: Goods in fell from 33 pallets to 4, but two of the four held the
-- year's whole run of the Wednesday lorry at NORTH-DC, 1,374 and 759 widgets,
-- each with its task raised and not done.
--
-- Why. erp.put_away_demonstration_goods() left a task open when the goods
-- had arrived yesterday or today, reading "arrived" as the latest movement
-- into the pallet's place, by the moment it was written. Two things were
-- wrong with that. A pallet that something arrives on every week never ages
-- out, however much of it is old. And a stock movement is written when it is
-- made, not on its document's day: the live demonstration's year of history
-- was built on 5 and 6 October, so every movement in it reads as written
-- then, which on the 7th is "yesterday".
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.put_away_demonstration_goods(day) completes each open putaway
--      task for all of its pallet but what came in yesterday or today, in
--      part where some did. An arrival is dated by the document that brought
--      it, the receipt, the transfer or the return, and by the moment it was
--      written only where it has none. Nothing else changes.
--   B. erp_test.pallet_waits_suite proves it.
--
-- Production: production makes no demonstrations (20261010061000).
--
-- Proof: erp_test.pallet_waits_suite.
-- =============================================================================

do $put_away_demonstration_goods$
declare
  v_sig  constant text := 'erp.put_away_demonstration_goods(date)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- And each task done, but for goods that arrived yesterday or today.
  for t in
    select x.id from (
      select wt.id, wt.created_at,
             (select max(m.occurred_at) from erp.stock_movement m
               where m.tenant_id = wt.tenant_id and m.to_location_id = wt.from_location_id
                 and m.item_id = wt.item_id
                 and coalesce(m.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                     = coalesce(wt.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)) as arrived
        from erp.warehouse_task wt
       where wt.tenant_id = v_tenant and wt.kind = 'putaway' and wt.status = 'open') x
     where x.arrived is null or x.arrived::date < p_day - 1
     order by x.created_at, x.id
  loop
    begin
      perform erp.complete_warehouse_task(t.id, null);
      v_put := v_put + 1;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('a putaway task was not completed: %s', left(sqlerrm, 160)));
    end;
  end loop;
$o$;
  v_new  constant text := $n$  -- And each task done for all of its pallet but what came in yesterday or
  -- today (20261010240000). An arrival is dated by the document that
  -- brought it, the receipt, the transfer or the return, not by the moment
  -- the movement was written: a history built in one go wrote every one of
  -- them that day. A task is done in part where the rest just arrived.
  for t in
    select wt.id,
           wt.quantity - wt.quantity_done as left_to_move,
           coalesce((select sum(sb.quantity) from erp.stock_balance sb
                      where sb.tenant_id = wt.tenant_id and sb.location_id = wt.from_location_id
                        and sb.item_id = wt.item_id and sb.stock_status = wt.stock_status
                        and coalesce(sb.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                            = coalesce(wt.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)), 0)
           - coalesce((select sum(m.quantity) from erp.stock_movement m
                         left join erp.document d on d.tenant_id = m.tenant_id and d.id = m.document_id
                        where m.tenant_id = wt.tenant_id and m.to_location_id = wt.from_location_id
                          and m.item_id = wt.item_id
                          and coalesce(m.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                              = coalesce(wt.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                          and coalesce(d.document_date, m.occurred_at::date) >= p_day - 1), 0) as settled
      from erp.warehouse_task wt
     where wt.tenant_id = v_tenant and wt.kind = 'putaway' and wt.status = 'open'
     order by wt.created_at, wt.id
  loop
    continue when least(t.left_to_move, t.settled) <= 0;
    begin
      perform erp.complete_warehouse_task(t.id, least(t.left_to_move, t.settled));
      v_put := v_put + 1;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('a putaway task was not completed: %s', left(sqlerrm, 160)));
    end;
  end loop;$n$;
  n integer;
begin
  if position('20261010240000' in v_def) > 0 then
    raise notice '% already waits only for what just arrived; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % completion loop found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$put_away_demonstration_goods$;

comment on function erp.put_away_demonstration_goods(date) is
  'In a demonstration that is not live (20261010230000): raises the putaway tasks of every site and completes each '
  'for all of its pallet but what came in yesterday or today, by the day of the document that brought it '
  '(20261010240000), through the warehouse''s own moves.';

create or replace function erp_test.pallet_waits_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_recv uuid; v_bulk uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_line uuid; v_grn uuid;
  v_res jsonb;
  v_in_recv numeric; v_in_bulk numeric; v_left numeric;
begin
  begin
    v_step := 'a demonstration organisation with finance, procurement and inventory';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzwait' || v_tag, 'Pallet Waits Suite',
      'admin@demo-zzwait' || v_tag || '.test', 'Pallet Waits Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzwait' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();
    -- Next year's months as well, so a receipt dated two days on posts on the
    -- last days of December too.
    insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number, starts_on, ends_on, status)
    select fp.tenant_id, fp.ledger_id,
           (fp.fiscal_year + 1)::text || '-' || lpad(fp.period_number::text, 2, '0'),
           fp.fiscal_year + 1, fp.period_number,
           (fp.starts_on + interval '1 year')::date,
           ((fp.ends_on + 1) + interval '1 year')::date - 1,
           'open'
      from erp.fiscal_period fp
     where fp.tenant_id = rb.tenant_id
       and fp.fiscal_year = (select max(f2.fiscal_year) from erp.fiscal_period f2 where f2.tenant_id = rb.tenant_id)
       and not exists (select 1 from erp.fiscal_period f3
                        where f3.tenant_id = fp.tenant_id and f3.ledger_id = fp.ledger_id
                          and f3.fiscal_year = fp.fiscal_year + 1);

    v_step := 'its own unit, site, receiving area, bulk store, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZWEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZWSITE', 'Pallet waits suite site', 'warehouse', 'active')
    returning id into v_site;
    v_recv := erp.create_location(v_site, 'ZW-RECV', 'Goods in', 'receiving');
    v_bulk := erp.create_location(v_site, 'ZW-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZWSUP', 'Pallet Waits Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZWWID', 'Pallet Waits Suite Widget', v_uom, 'active')
    returning id into v_item;

    v_step := 'thirty widgets received today and ten more on a receipt dated two days on';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_line := erp.add_document_line(v_po, v_item, 40, 1000, 'forty widgets');
    perform erp.transition_document(v_po, 'submit', 'pallet waits suite');
    perform erp_test.approve_document(v_po, 'pallet waits suite');
    perform erp.transition_document(v_po, 'send', 'pallet waits suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    v_line := erp.receive_against(v_grn, (select l.id from erp.document_line l where l.document_id = v_po), 30, null);
    update erp.document_line set location_id = v_recv where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'pallet waits suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    update erp.document set document_date = current_date + 2 where id = v_grn;
    v_line := erp.receive_against(v_grn, (select l.id from erp.document_line l where l.document_id = v_po), 10, null);
    update erp.document_line set location_id = v_recv where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'pallet waits suite');

    -- ── 1. Three days on, what came two days on waits ───────────────────────
    -- Both movements were written today. By their receipts' days, thirty came
    -- three days before the tidy and ten the day before it.
    v_step := 'put away three days on';
    v_res := erp.put_away_demonstration_goods(current_date + 3);
    select coalesce(sum(sb.quantity), 0) into v_in_recv from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_recv and sb.item_id = v_item;
    select coalesce(sum(sb.quantity), 0) into v_in_bulk from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_bulk and sb.item_id = v_item;
    select coalesce(sum(wt.quantity - wt.quantity_done), 0) into v_left from erp.warehouse_task wt
     where wt.tenant_id = rb.tenant_id and wt.kind = 'putaway' and wt.status = 'open';

    v_cases := v_cases + 1;
    case_name := 'a pallet is put away but for what came in the day before, by its receipt''s day, and its task stays open for that';
    passed := v_state is null and v_in_bulk = 30 and v_in_recv = 10 and v_left = 10
          and (v_res ->> 'put_away')::integer = 1;
    detail := format('%s in bulk, %s in goods-in, %s left on the task; %s', v_in_bulk, v_in_recv, v_left, v_res);
    return next;

    -- ── 2. A day later the rest goes ────────────────────────────────────────
    v_step := 'put away four days on';
    v_res := erp.put_away_demonstration_goods(current_date + 4);
    select coalesce(sum(sb.quantity), 0) into v_in_recv from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_recv and sb.item_id = v_item;
    select count(*) into v_left from erp.warehouse_task wt
     where wt.tenant_id = rb.tenant_id and wt.kind = 'putaway' and wt.status = 'open';

    v_cases := v_cases + 1;
    case_name := 'a day later the rest is put away and the task is done';
    passed := v_state is null and v_in_recv = 0 and v_left = 0 and (v_res ->> 'put_away')::integer = 1;
    detail := format('%s in goods-in, %s open task(s); %s', v_in_recv, v_left, v_res);
    return next;

    -- ── 3. Nothing more ─────────────────────────────────────────────────────
    v_res := erp.put_away_demonstration_goods(current_date + 5);
    v_cases := v_cases + 1;
    case_name := 'run again, nothing more is raised or put away';
    passed := v_state is null and (v_res ->> 'raised')::integer = 0 and (v_res ->> 'put_away')::integer = 0;
    detail := v_res::text;
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzwait' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'demo-zzwait rolled back with its receipts and tasks');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PALLET_WAITS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_pallet_waits_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _pallet_waits on commit drop as
    select * from erp_test.pallet_waits_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _pallet_waits;
  drop table _pallet_waits;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PALLET_WAITS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_PALLET_WAITS_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a pallet waits only for what just arrived: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.pallet_waits_suite() from public, anon;
revoke all on function erp_test.assert_pallet_waits_suite() from public, anon;

comment on function erp_test.pallet_waits_suite() is
  'A pallet waits only for what just arrived (20261010240000): of two receipts written the same moment, the one '
  'dated earlier is put away and the one dated the day before the tidy waits on its task; a day later it goes; a '
  'third run does nothing.';

comment on function erp_test.assert_pallet_waits_suite() is
  'erp_test.pallet_waits_suite(), four cases.';

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
