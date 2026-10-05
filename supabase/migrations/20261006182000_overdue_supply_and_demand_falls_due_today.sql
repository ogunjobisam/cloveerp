set lock_timeout = '30s';

-- =============================================================================
-- 20261006182000  Overdue supply and demand falls due today
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-92). "Supply and
-- demand" on Planning answered a projection that started in April: one bucket
-- for every overdue sales order's original due date, each opening on today's
-- stock, so the first rows of "the projected balance across the horizon" were
-- months in the past and the balance they showed was never true on those days.
--
-- erp.supply_demand_position asks erp.scheduled_supply and erp.scheduled_demand
-- from today, but neither bounds what is already owed by a start date (a sales
-- order still owed is demand however late it is, and a purchase order still
-- open is supply however late it is), and the projection bucketed each on its
-- own date.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.supply_demand_position buckets each line on the later of its due
--      date and today. What is overdue is still owed and still counted, in
--      today's bucket, where it can still be met; the projection starts today
--      and opens on today's stock. A line due later keeps its own date.
--      erp.scheduled_supply and erp.scheduled_demand are unchanged, so the
--      planning run, its pegs and the stock forecast read what they read.
--   B. erp_test.overdue_supply_demand_suite.
--
-- The screen side (J-92 too) is in src/components/erp/inquiry.tsx: a list of
-- rows that share their fields is drawn as a table, its dates short.
--
-- On production: one routine is patched. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. What is overdue is owed today
-- ─────────────────────────────────────────────────────────────────────────────

do $position$
declare
  v_sig  constant text := 'erp.supply_demand_position(uuid,uuid,integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  for d in
    select x.d as due, sum(x.s) as sup, sum(x.dm) as dem$o$;
  v_new  constant text := $n$  -- What is overdue is still owed, and is owed today: a late line falls due
  -- today rather than opening the projection months in the past on today's
  -- stock (20261006182000, J-92).
  for d in
    select greatest(x.d, current_date) as due, sum(x.s) as sup, sum(x.dm) as dem$n$;
  v_old2 constant text := $o$     group by x.d order by x.d$o$;
  v_new2 constant text := $n$     group by greatest(x.d, current_date) order by greatest(x.d, current_date)$n$;
begin
  if strpos(v_src, '20261006182000') > 0 then
    raise notice '% already brings overdue lines to today; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '99c271cb1cfc97a6424d53d66bd269e3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006182000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % second anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old2, v_new2);
end
$position$;

comment on function erp.supply_demand_position(uuid, uuid, integer) is
  'The projected balance of one product at one site, a bucket for each day something is due across the '
  'horizon: opening, supply, demand, closing and whether it is below the reorder point. What is overdue is '
  'still owed and falls due today, so the projection starts today on today''s stock (20261006182000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.overdue_supply_demand_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_site   uuid;
  v_entity uuid;
  v_cust   uuid;
  v_item   uuid;
  v_uom    uuid;
  v_so     uuid;
  v_onhand numeric;
  v_rows   jsonb;
  v_today  jsonb;
  v_later  jsonb;
begin
  begin
    -- ── The fixture: an order owed three weeks ago and a line due next week ─
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzods-' || v_tag, 'Overdue Supply Demand Suite',
      'admin@zzods-' || v_tag || '.test', 'Overdue Supply Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzods-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a sales order with one line overdue and one due next week';
    select s.id, s.entity_id into v_site, v_entity
      from erp.site s where s.tenant_id = rb.tenant_id and s.status = 'active' order by s.code limit 1;
    select pr.party_id into v_cust
      from erp.party_role pr where pr.tenant_id = rb.tenant_id and pr.role_kind = 'customer' and pr.status = 'active'
     order by pr.party_id limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZODS-ITEM', 'Owed and late', v_uom, 'active'::erp.record_status)
    returning id into v_item;
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    perform erp.add_document_line(v_so, v_item, 7, 100, 'the overdue supply and demand suite', current_date - 21);
    perform erp.add_document_line(v_so, v_item, 4, 100, 'the overdue supply and demand suite', current_date + 7);
    perform erp.transition_document(v_so, 'submit', 'the overdue supply and demand suite');
    perform erp_test.approve_document(v_so, 'the overdue supply and demand suite');

    v_step := 'a planned purchase that should have arrived last week';
    insert into erp.planned_order (tenant_id, entity_id, site_id, item_id, order_kind,
                                   quantity, uom_id, required_by, release_on, status)
    values (rb.tenant_id, v_entity, v_site, v_item, 'purchase', 5, v_uom,
            current_date - 7, current_date - 14, 'suggested');

    v_step := 'the projection read';
    select coalesce(sum(b.quantity), 0) into v_onhand
      from erp.stock_balance b where b.tenant_id = rb.tenant_id and b.item_id = v_item and b.site_id = v_site;
    select coalesce(jsonb_agg(to_jsonb(p) order by p.bucket_start), '[]'::jsonb) into v_rows
      from erp.supply_demand_position(v_item, v_site, 30) p;
    select x into v_today from jsonb_array_elements(v_rows) x where (x ->> 'bucket_start')::date = current_date;
    select x into v_later from jsonb_array_elements(v_rows) x where (x ->> 'bucket_start')::date = current_date + 7;

    -- ── 1. Nothing before today ─────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the projection starts today: no bucket falls before it, though a line was due three weeks ago';
    passed := v_state is null
          and erp.object_current_state('document', v_so) = 'confirmed'
          and jsonb_array_length(v_rows) = 2
          and not exists (select 1 from jsonb_array_elements(v_rows) x
                           where (x ->> 'bucket_start')::date < current_date);
    detail := coalesce(v_state, format('order %s; %s', erp.object_current_state('document', v_so), left(v_rows::text, 400)));
    return next;

    -- ── 2. What is overdue is owed today, from today's stock ────────────────
    v_cases := v_cases + 1;
    case_name := 'the overdue demand and the late supply are counted today, opening on today''s stock';
    passed := v_state is null
          and v_today is not null
          and (v_today ->> 'demand')::numeric = 7
          and (v_today ->> 'supply')::numeric = 5
          and (v_today ->> 'opening')::numeric = v_onhand
          and (v_today ->> 'closing')::numeric = v_onhand + 5 - 7;
    detail := coalesce(v_state, format('on hand %s; today %s', v_onhand, coalesce(v_today::text, 'no bucket')));
    return next;

    -- ── 3. What is due later keeps its own day ──────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a line due next week keeps its own day and opens on what today left';
    passed := v_state is null
          and v_later is not null
          and (v_later ->> 'demand')::numeric = 4
          and (v_later ->> 'opening')::numeric = v_onhand + 5 - 7
          and (v_later ->> 'closing')::numeric = v_onhand + 5 - 7 - 4;
    detail := coalesce(v_state, coalesce(v_later::text, 'no bucket'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_OVERDUE_SUPPLY_DEMAND_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.overdue_supply_demand_suite() from public, anon;

comment on function erp_test.overdue_supply_demand_suite() is
  'Overdue supply and demand falls due today (20261006182000, J-92): the projection starts today, an overdue '
  'sales order line and a late planned purchase are counted today on today''s stock, and a line due later '
  'keeps its own day.';

create or replace function erp_test.assert_overdue_supply_demand_suite()
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
    from erp_test.overdue_supply_demand_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_OVERDUE_SUPPLY_DEMAND_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Supply and demand projects a day in the past, or loses what is overdue. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_OVERDUE_SUPPLY_DEMAND_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('overdue supply and demand falls due today: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_overdue_supply_demand_suite() from public, anon;

comment on function erp_test.assert_overdue_supply_demand_suite() is
  'erp.supply_demand_position starts today and counts what is overdue in today''s bucket (20261006182000).';

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
