set lock_timeout = '30s';

-- =============================================================================
-- 20261007141000  Valuation reads in order
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-88). Stock's
-- Valuation report listed its rows in no order anybody could follow: one
-- product's sites apart, products neither by code nor by value.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- public.erp_stock_valuation gathered erp.stock_valuation_report() with
-- jsonb_agg and no order, so the rows came back in whatever order the
-- grouping inside the report left them.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_stock_valuation answers by product code, then site code.
--   B. erp_test.valuation_reads_in_order_suite.
--
-- The rest of J-88 is the screen's: reports sit one to a row below the widest
-- screens (src/components/erp/module-page.tsx), and a table wider than its
-- card shows a shadow at the edge it scrolls to (src/components/erp/panel.tsx,
-- src/styles.css).
--
-- On production: one door is edited where it aggregates. No table is altered
-- and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. By product, then site
-- ─────────────────────────────────────────────────────────────────────────────

do $door$
declare
  v_sig  constant text := 'public.erp_stock_valuation(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$ select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb)$o$;
  v_new  constant text := $n$ -- By product, then site (20261007141000, J-88).
 select coalesce(jsonb_agg(to_jsonb(v) order by v.item_code, v.site_code, v.item_id, v.site_id), '[]'::jsonb)$n$;
begin
  if strpos(v_src, '20261007141000') > 0 then
    raise notice '% already reads in order; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c9e1f067bdaca25b0a2d154fc7a62abf' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007141000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$door$;

comment on function public.erp_stock_valuation(uuid) is
  'Cost basis by product and site, for the site the header names or for every site when it names none, by product '
  'code and then site code (20261007141000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.valuation_reads_in_order_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_ccy    char(3);
  v_uom    uuid;
  s_a      uuid; s_b uuid; l_a uuid; l_b uuid;
  v_item   uuid;
  k        record;
  v_all    jsonb; v_one jsonb;
  v_got    text; v_want text;
  v_got2   text; v_want2 text;
begin
  begin
    -- ── The fixture: products made in reverse, held at two sites ────────────
    v_step := 'an organisation';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzvo-' || v_tag, 'Valuation Order Suite', 'admin@zzvo-' || v_tag || '.test', 'Valuation Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzvo-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = rb.entity_id;

    v_step := 'two sites, five products, stock at both';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (rb.tenant_id, rb.entity_id, 'ZZVO-B', 'Second', 'warehouse', 'GB', 'active') returning id into s_b;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (rb.tenant_id, rb.entity_id, 'ZZVO-A', 'First', 'warehouse', 'GB', 'active') returning id into s_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (rb.tenant_id, s_a, 'ZZVO-A-BULK', 'A bulk', 'bulk', true, 'active') returning id into l_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (rb.tenant_id, s_b, 'ZZVO-B-BULK', 'B bulk', 'bulk', true, 'active') returning id into l_b;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    for k in select g as n from generate_series(5, 1, -1) g loop
      insert into erp.item (tenant_id, code, name, stock_uom_id, status)
      values (rb.tenant_id, 'ZZVO-' || k.n, 'Valued widget ' || k.n, v_uom, 'active') returning id into v_item;
      perform erp.receive_cost(v_item, s_b, 10 * k.n, 100 * k.n, v_ccy);
      perform erp.receive_cost(v_item, s_a, 20 * k.n, 100 * k.n, v_ccy);
      insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
        to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
      values (rb.tenant_id, rb.entity_id, s_b, 'receipt_no_order', v_item, l_b, 'available', 10 * k.n, v_uom,
              100 * k.n, v_ccy, 'OPENING'),
             (rb.tenant_id, rb.entity_id, s_a, 'receipt_no_order', v_item, l_a, 'available', 20 * k.n, v_uom,
              100 * k.n, v_ccy, 'OPENING');
    end loop;

    -- ── 1. Every site: by product, then site ────────────────────────────────
    v_step := 'reading the valuation';
    v_all := public.erp_stock_valuation(null);
    select string_agg((e ->> 'item_code') || '@' || (e ->> 'site_code'), ',' order by n) into v_got
      from jsonb_array_elements(v_all) with ordinality as a(e, n)
     where e ->> 'item_code' like 'ZZVO-%';
    v_want := 'ZZVO-1@ZZVO-A,ZZVO-1@ZZVO-B,ZZVO-2@ZZVO-A,ZZVO-2@ZZVO-B,ZZVO-3@ZZVO-A,ZZVO-3@ZZVO-B,'
           || 'ZZVO-4@ZZVO-A,ZZVO-4@ZZVO-B,ZZVO-5@ZZVO-A,ZZVO-5@ZZVO-B';
    select string_agg((e ->> 'item_code') || '@' || (e ->> 'site_code'), ',' order by n),
           string_agg((e ->> 'item_code') || '@' || (e ->> 'site_code'), ','
                      order by e ->> 'item_code', e ->> 'site_code')
      into v_got2, v_want2
      from jsonb_array_elements(v_all) with ordinality as a(e, n);
    v_cases := v_cases + 1;
    case_name := 'the valuation reads by product code, then site code, the whole of it';
    passed := v_state is null and v_got = v_want and v_got2 = v_want2;
    detail := coalesce(v_state, format('read %s', v_got));
    return next;

    -- ── 2. One site: by product ─────────────────────────────────────────────
    v_step := 'reading one site''s valuation';
    v_one := public.erp_stock_valuation(s_b);
    select string_agg(e ->> 'item_code', ',' order by n) into v_got
      from jsonb_array_elements(v_one) with ordinality as a(e, n)
     where e ->> 'item_code' like 'ZZVO-%';
    v_cases := v_cases + 1;
    case_name := 'one site''s valuation reads by product code, and holds that site alone';
    passed := v_state is null and v_got = 'ZZVO-1,ZZVO-2,ZZVO-3,ZZVO-4,ZZVO-5'
          and not exists (select 1 from jsonb_array_elements(v_one) e where e ->> 'site_id' <> s_b::text);
    detail := coalesce(v_state, format('read %s', v_got));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_VALUATION_ORDER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzvo-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_VALUATION_ORDER_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.valuation_reads_in_order_suite() from public, anon;

comment on function erp_test.valuation_reads_in_order_suite() is
  'Valuation reads in order (20261007141000, J-88): the stock valuation answers by product code and then site code, '
  'for every site and for one.';

create or replace function erp_test.assert_valuation_reads_in_order_suite()
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
    from erp_test.valuation_reads_in_order_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VALUATION_ORDER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The stock valuation would read in no order. Read the case that failed.';
  end if;
  if v_total <> 2 then
    raise exception 'CLOVEERP_VALUATION_ORDER_SUITE_SHRANK: % case(s), expected 2', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('valuation reads in order: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_valuation_reads_in_order_suite() from public, anon;

comment on function erp_test.assert_valuation_reads_in_order_suite() is
  'The stock valuation answers by product, then site (20261007141000).';

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
