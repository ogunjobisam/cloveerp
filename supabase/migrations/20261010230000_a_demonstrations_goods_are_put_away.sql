set lock_timeout = '30s';

-- =============================================================================
-- 20261010230000  A demonstration's goods are put away
-- -----------------------------------------------------------------------------
-- Found on the live demonstration on 7 October: Purchasing's Goods in step
-- held 33 pallets waiting in the receiving areas, every one "Waiting", the
-- catalogue nearly whole: 254 cartons, 129 shaft seals, 77 widgets. On the
-- build's seeded organisation, 8 pallets: 5 booked into NORTH-DC's
-- receiving area by the Wednesday lorry, 3 brought back to MAIN-WH's by the
-- Friday customer credit notes.
--
-- Why. The builder receives its suppliers' goods straight into the bulk
-- store, but two of its moves land stock in a receiving area: a transfer
-- booked in at the other site (20260918100000) and a customer's return
-- (20260918600000). Nothing in a demonstration ever puts them away, so they
-- wait there for ever, and Goods in reads as a warehouse nobody works.
--
-- Nothing in the product changes. The warehouse's own moves do it: Raise
-- putaway tasks (erp.raise_putaway_tasks), which sends each pallet where its
-- storage rules say, or the bulk store; and completing a task
-- (erp.complete_warehouse_task), which moves the stock within the site with
-- no journal, because its value does not change.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.put_away_demonstration_goods(day), in a demonstration that is not
--      live: raises the putaway tasks of every site, then completes each open
--      putaway task whose goods arrived before the day before. What arrived
--      yesterday or today keeps its task open, so Goods in and Put away show
--      what a warehouse has in hand.
--   B. erp.tidy_demonstration_books() does it where it bills (the catch-up's
--      tidy), and says how many in its result. Not on the builder's pay day:
--      a putaway is dated when it is done, and the builder builds months that
--      are history. The demonstration that exists is put right by its next
--      catch-up.
--   C. erp_test.demonstration_goods_put_away_suite proves it.
--
-- Production: production makes no demonstrations (20261010061000).
--
-- Proof: erp_test.demonstration_goods_put_away_suite.
-- =============================================================================

-- ── A. The goods are put away ────────────────────────────────────────────────

create or replace function erp.put_away_demonstration_goods(p_day date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  s          record;
  t          record;
  v_raised   integer := 0;
  v_put      integer := 0;
  v_refused  integer := 0;
  v_note     text;
begin
  if not erp.tenant_is_demonstration(v_tenant)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = v_tenant and e.is_self and e.is_live) then
    return jsonb_build_object('raised', 0, 'put_away', 0);
  end if;

  -- Raise Putaway tasks, site by site, as the warehouse presses it.
  for s in
    select st.id, st.code from erp.site st
     where st.tenant_id = v_tenant and st.status = 'active'::erp.record_status
     order by st.code
  loop
    begin
      v_raised := v_raised + erp.raise_putaway_tasks(s.id);
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('putaway at %s was not raised: %s', s.code, left(sqlerrm, 160)));
    end;
  end loop;

  -- And each task done, but for goods that arrived yesterday or today.
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

  return jsonb_build_object('raised', v_raised, 'put_away', v_put, 'refused', v_refused, 'note', v_note);
end;
$$;

revoke all on function erp.put_away_demonstration_goods(date) from public, anon, authenticated;

comment on function erp.put_away_demonstration_goods(date) is
  'In a demonstration that is not live (20261010230000): raises the putaway tasks of every site and completes each '
  'whose goods arrived before the day before, through the warehouse''s own moves. What arrived yesterday or today '
  'keeps its task open.';

-- ── B. The tidy puts them away ───────────────────────────────────────────────

do $tidy_demonstration_books$
declare
  v_sig  constant text := 'erp.tidy_demonstration_books(date, boolean)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_pass      integer;
$o$;
  v_new1 constant text := $n$  v_pass      integer;
  v_put       jsonb;
$n$;
  v_old2 constant text := $o$  -- ── The customers who pay ─────────────────────────────────────────────────
$o$;
  v_new2 constant text := $n$  -- ── The goods put away (20261010230000) ──────────────────────────────────
  -- Where this tidy bills, the catch-up's: a putaway is dated when it is
  -- done, so not on the builder's pay day in a month that is history.
  if p_bill then
    v_put := erp.put_away_demonstration_goods(p_day);
    v_note := coalesce(v_note, v_put ->> 'note');
  end if;

  -- ── The customers who pay ─────────────────────────────────────────────────
$n$;
  v_old3 constant text := $o$    'orders_cancelled', coalesce((v_finished ->> 'cancelled')::integer, 0),
$o$;
  v_new3 constant text := $n$    'orders_cancelled', coalesce((v_finished ->> 'cancelled')::integer, 0),
    'pallets_put_away', coalesce((v_put ->> 'put_away')::integer, 0),
$n$;
  v_olds text[] := array[v_old1, v_old2, v_old3];
  v_news text[] := array[v_new1, v_new2, v_new3];
  i integer;
  n integer;
begin
  if position('erp.put_away_demonstration_goods(' in v_def) > 0 then
    raise notice '% already puts the goods away; left as it is', v_sig;
    return;
  end if;
  for i in 1 .. 3 loop
    n := (length(v_def) - length(replace(v_def, v_olds[i], ''))) / length(v_olds[i]);
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i, n;
    end if;
  end loop;
  for i in 1 .. 3 loop
    v_def := replace(v_def, v_olds[i], v_news[i]);
  end loop;
  execute v_def;
end
$tidy_demonstration_books$;

-- ── C. The proof ─────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_goods_put_away_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_recv uuid; v_bulk uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_line uuid; v_grn uuid;
  v_res jsonb; v_again jsonb;
  v_in_recv numeric; v_in_bulk numeric; v_open integer;
  v_journals_before bigint; v_journals_after bigint;
begin
  begin
    v_step := 'a demonstration organisation with finance, procurement and inventory';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzput' || v_tag, 'Goods Put Away Suite',
      'admin@demo-zzput' || v_tag || '.test', 'Put Away Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzput' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_step := 'its own unit, site, receiving area, bulk store, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZPEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZPSITE', 'Put away suite site', 'warehouse', 'active')
    returning id into v_site;
    v_recv := erp.create_location(v_site, 'ZP-RECV', 'Goods in', 'receiving');
    v_bulk := erp.create_location(v_site, 'ZP-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZPSUP', 'Put Away Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPWID', 'Put Away Suite Widget', v_uom, 'active')
    returning id into v_item;

    v_step := 'thirty widgets received into goods-in today';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_line := erp.add_document_line(v_po, v_item, 30, 1000, 'thirty widgets');
    perform erp.transition_document(v_po, 'submit', 'put away suite');
    perform erp_test.approve_document(v_po, 'put away suite');
    perform erp.transition_document(v_po, 'send', 'put away suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    v_line := erp.receive_against(v_grn, v_line, 30, null);
    update erp.document_line set location_id = v_recv where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'put away suite');

    -- ── 1. Arrived today, it has its task and waits ─────────────────────────
    v_step := 'put away the day it arrived';
    v_res := erp.put_away_demonstration_goods(current_date);
    select coalesce(sum(sb.quantity), 0) into v_in_recv from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_recv and sb.item_id = v_item;
    select count(*) into v_open from erp.warehouse_task wt
     where wt.tenant_id = rb.tenant_id and wt.kind = 'putaway' and wt.status = 'open';
    v_cases := v_cases + 1;
    case_name := 'goods that arrived today have their putaway task raised and wait in goods-in';
    passed := v_state is null and v_in_recv = 30 and v_open = 1
          and (v_res ->> 'raised')::integer = 1 and (v_res ->> 'put_away')::integer = 0;
    detail := format('%s in goods-in, %s open task(s); %s', v_in_recv, v_open, v_res);
    return next;

    -- ── 2. Not on the builder's pay day ─────────────────────────────────────
    v_step := 'the builder''s pay-day tidy three days on';
    v_res := erp.tidy_demonstration_books(current_date + 3, false);
    select coalesce(sum(sb.quantity), 0) into v_in_recv from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_recv and sb.item_id = v_item;
    v_cases := v_cases + 1;
    case_name := 'the builder''s pay-day tidy puts nothing away';
    passed := v_state is null and v_in_recv = 30
          and coalesce((v_res ->> 'pallets_put_away')::integer, 0) = 0;
    detail := format('%s in goods-in; %s', v_in_recv, v_res);
    return next;

    -- ── 3–4. Two days on, the catch-up's tidy puts it away ──────────────────
    v_step := 'the catch-up''s tidy three days on';
    select count(*) into v_journals_before from erp.journal j where j.tenant_id = rb.tenant_id;
    v_res := erp.tidy_demonstration_books(current_date + 3);
    select count(*) into v_journals_after from erp.journal j where j.tenant_id = rb.tenant_id;
    select coalesce(sum(sb.quantity), 0) into v_in_recv from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_recv and sb.item_id = v_item;
    select coalesce(sum(sb.quantity), 0) into v_in_bulk from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_bulk and sb.item_id = v_item;
    select count(*) into v_open from erp.warehouse_task wt
     where wt.tenant_id = rb.tenant_id and wt.kind = 'putaway' and wt.status = 'open';

    v_cases := v_cases + 1;
    case_name := 'two days on, the catch-up''s tidy completes the task: the widgets are in the bulk store and goods-in is empty';
    passed := v_state is null and v_in_recv = 0 and v_in_bulk = 30 and v_open = 0
          and (v_res ->> 'pallets_put_away')::integer = 1;
    detail := format('%s in goods-in, %s in bulk, %s open; %s', v_in_recv, v_in_bulk, v_open, v_res);
    return next;

    v_cases := v_cases + 1;
    case_name := 'putting away moves stock within the site and posts no journal';
    passed := v_state is null and v_journals_after = v_journals_before;
    detail := format('%s journal(s) before, %s after', v_journals_before, v_journals_after);
    return next;

    -- ── 5. Twice is once ────────────────────────────────────────────────────
    v_again := erp.put_away_demonstration_goods(current_date + 4);
    v_cases := v_cases + 1;
    case_name := 'run again, nothing more is raised or put away';
    passed := v_state is null and (v_again ->> 'raised')::integer = 0 and (v_again ->> 'put_away')::integer = 0;
    detail := v_again::text;
    return next;

    -- ── 6. Never in a live organisation ─────────────────────────────────────
    v_step := 'ten more widgets received, then the demonstration made live';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_line := erp.add_document_line(v_po, v_item, 10, 1000, 'ten widgets');
    perform erp.transition_document(v_po, 'submit', 'put away suite');
    perform erp_test.approve_document(v_po, 'put away suite');
    perform erp.transition_document(v_po, 'send', 'put away suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    v_line := erp.receive_against(v_grn, v_line, 10, null);
    update erp.document_line set location_id = v_recv where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'put away suite');
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_again := erp.put_away_demonstration_goods(current_date + 30);
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    select coalesce(sum(sb.quantity), 0) into v_in_recv from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.location_id = v_recv and sb.item_id = v_item;
    v_cases := v_cases + 1;
    case_name := 'a demonstration that is live has nothing put away for it';
    passed := v_state is null and v_in_recv = 10 and (v_again ->> 'raised')::integer = 0;
    detail := format('%s in goods-in; %s', v_in_recv, v_again);
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzput' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'demo-zzput rolled back with its receipts and tasks');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_GOODS_PUT_AWAY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_demonstration_goods_put_away_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_goods_put_away on commit drop as
    select * from erp_test.demonstration_goods_put_away_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_goods_put_away;
  drop table _demo_goods_put_away;
  if v_fail > 0 then
    raise exception E'CLOVEERP_GOODS_PUT_AWAY_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_GOODS_PUT_AWAY_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a demonstration''s goods are put away: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.demonstration_goods_put_away_suite() from public, anon;
revoke all on function erp_test.assert_demonstration_goods_put_away_suite() from public, anon;

comment on function erp_test.demonstration_goods_put_away_suite() is
  'A demonstration''s goods are put away (20261010230000): goods that arrived today have their task and wait; the '
  'builder''s pay day puts nothing away; two days on the catch-up''s tidy completes the task with no journal; a '
  'second run does nothing; a live organisation is untouched.';

comment on function erp_test.assert_demonstration_goods_put_away_suite() is
  'erp_test.demonstration_goods_put_away_suite(), seven cases.';

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
