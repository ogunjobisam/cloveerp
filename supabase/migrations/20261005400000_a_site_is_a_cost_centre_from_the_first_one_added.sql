set lock_timeout = '30s';

-- =============================================================================
-- 20261005400000  A site is a cost centre from the first one added
-- -----------------------------------------------------------------------------
-- Found walking the product on live, 4 October. In the demonstration,
-- somebody added the organisation's first cost centre on Cost centres. From
-- that moment every document at every site refused:
--
--   CLOVEERP_DIMENSION_VALUE_UNKNOWN: COST_CENTRE has no value BHM-WH in
--   force on 2026-10-04
--
-- sending an order, issuing it, posting a receipt, all of it.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- The first cost centre creates the COST_CENTRE dimension
-- (erp.ensure_cost_centre_dimension), whose derivation falls back, last, to
-- the document's site code. erp.validate_dimensions then refuses a derived
-- value the dimension does not hold. 20260911005120 added every site and
-- department as a value for the organisations that existed that day, and the
-- screen still says so: "Every site and department already here becomes one
-- as soon as you add it above". Nothing did it for an organisation that came
-- later, nor for a site opened after the dimension existed.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.cost_centres_cover_sites(): in the organisation it is called in,
--      where the dimension exists, every active site and department that is
--      not a cost centre becomes one, under its own code and name. Nothing
--      already there is changed.
--   B. erp.ensure_cost_centre_dimension() calls it, so the first cost centre
--      brings the sites and departments with it, as the screen says.
--   C. A site or a department added afterwards becomes a cost centre as it is
--      added (a trigger on each).
--   D. Every organisation that has the dimension today is repaired here, and
--      the migration says which.
--
-- Proof: erp_test.first_cost_centre_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. Sites and departments, as cost centres
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.cost_centres_cover_sites()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_dim    uuid;
  v_n      integer := 0;
  v_m      integer := 0;
begin
  -- Every active site and department of this organisation that is not a
  -- cost centre becomes one (20261005400000): the dimension derives a
  -- document's cost centre from its department and, last, its site, and a
  -- derived value the dimension does not hold refuses the document.
  select d.id into v_dim from erp.dimension d
   where d.tenant_id = v_tenant and d.code = 'COST_CENTRE';
  if v_dim is null then
    return 0;
  end if;

  insert into erp.dimension_value (tenant_id, dimension_id, code, name)
  select s.tenant_id, v_dim, s.code, s.name
    from erp.site s
   where s.tenant_id = v_tenant and s.status = 'active'
  on conflict (tenant_id, dimension_id, code) do nothing;
  get diagnostics v_n = row_count;

  insert into erp.dimension_value (tenant_id, dimension_id, code, name)
  select dep.tenant_id, v_dim, dep.code, dep.name
    from erp.department dep
   where dep.tenant_id = v_tenant and dep.status = 'active'
  on conflict (tenant_id, dimension_id, code) do nothing;
  get diagnostics v_m = row_count;

  return v_n + v_m;
end;
$$;

revoke all on function erp.cost_centres_cover_sites() from public, anon;

comment on function erp.cost_centres_cover_sites() is
  'Makes every active site and department of the organisation a cost centre where it is not one, once the '
  'COST_CENTRE dimension exists (20261005400000). Called by erp.ensure_cost_centre_dimension().';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The first cost centre brings them
-- ═════════════════════════════════════════════════════════════════════════════

do $ensure$
declare
  v_sig  constant text := 'erp.ensure_cost_centre_dimension()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    returning id into v_id;
  end if;
  return v_id;$o$;
  v_new  constant text := $n$    returning id into v_id;
  end if;
  -- The sites and departments already here are cost centres too, as the
  -- screen says; without them the derivation's last resort, the document's
  -- site, refuses every document (20261005400000).
  perform erp.cost_centres_cover_sites();
  return v_id;$n$;
begin
  if strpos(v_src, '20261005400000') > 0 then
    raise notice '% already brings the sites; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a634239a6dbc10354f2a13254adc6074' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005400000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$ensure$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. A site or department added afterwards
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.site_becomes_a_cost_centre()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A site or a department added, or made active, once the organisation
  -- keeps cost centres: it becomes one, under its own code and name
  -- (20261005400000). Where there is no such dimension, nothing.
  if new.status = 'active' then
    insert into erp.dimension_value (tenant_id, dimension_id, code, name)
    select new.tenant_id, d.id, new.code, new.name
      from erp.dimension d
     where d.tenant_id = new.tenant_id and d.code = 'COST_CENTRE'
    on conflict (tenant_id, dimension_id, code) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function erp.site_becomes_a_cost_centre() from public, anon;

comment on function erp.site_becomes_a_cost_centre() is
  'Trigger on erp.site and erp.department: a row added or made active becomes a cost centre where the '
  'organisation has the COST_CENTRE dimension (20261005400000).';

drop trigger if exists t_site_cost_centre on erp.site;
create trigger t_site_cost_centre
  after insert or update of code, status on erp.site
  for each row execute function erp.site_becomes_a_cost_centre();

drop trigger if exists t_department_cost_centre on erp.department;
create trigger t_department_cost_centre
  after insert or update of code, status on erp.department
  for each row execute function erp.site_becomes_a_cost_centre();

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.first_cost_centre_suite()
returns table(case_name text, passed boolean, detail text)
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
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_po uuid; v_po2 uuid;
  v_sites  integer; v_missing integer;
  v_res    text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with sites and no cost centres';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzfcc-' || v_tag, 'First Cost Centre Suite',
      'admin@zzfcc-' || v_tag || '.test', 'Centre Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzfcc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZFCOAT', 'Centre Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZFBRAND');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZFO1', false);
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 5, 9000, 'ZFO2', false);
    select count(*) into v_sites from erp.site s where s.tenant_id = rb.tenant_id and s.status = 'active';

    -- ── 1. Before: no dimension, and an order goes ──────────────────────────
    v_step := 'sending an order before any cost centre exists';
    perform public.erp_send_purchase_order(v_po, 'orders@zfbrand-' || v_tag || '.test', null, null, null);
    v_cases := v_cases + 1;
    case_name := 'an organisation with sites and no cost centre has no cost centre dimension, and sends an order';
    passed := v_state is null and v_sites > 0
          and not exists (select 1 from erp.dimension d where d.tenant_id = rb.tenant_id and d.code = 'COST_CENTRE')
          and erp.object_current_state('document', v_po) = 'sent';
    detail := coalesce(v_state, format('%s active site(s)', v_sites));
    return next;

    -- ── 2. The first cost centre brings the sites ───────────────────────────
    v_step := 'adding the first cost centre';
    perform public.erp_upsert_cost_centre('ZZ-FIRST', 'The first cost centre');
    select count(*) into v_missing
      from (select s.code from erp.site s where s.tenant_id = rb.tenant_id and s.status = 'active'
            union
            select dep.code from erp.department dep where dep.tenant_id = rb.tenant_id and dep.status = 'active') c
     where not exists (select 1 from erp.dimension_value dv
                         join erp.dimension d on d.id = dv.dimension_id and d.code = 'COST_CENTRE'
                        where dv.tenant_id = rb.tenant_id and dv.code = c.code and dv.status = 'active');
    v_cases := v_cases + 1;
    case_name := 'adding the first cost centre makes every active site and department a cost centre beside it';
    passed := v_state is null and v_missing = 0
          and exists (select 1 from erp.dimension_value dv where dv.tenant_id = rb.tenant_id and dv.code = 'ZZ-FIRST');
    detail := coalesce(v_state, format('%s site(s) or department(s) left without one', v_missing));
    return next;

    -- ── 3. And an order still goes ──────────────────────────────────────────
    v_step := 'sending an order once a cost centre exists';
    begin
      perform public.erp_send_purchase_order(v_po2, 'orders@zfbrand-' || v_tag || '.test', null, null, null);
      v_res := erp.object_current_state('document', v_po2);
    exception when others then
      v_res := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'an order at a site is still sent once the organisation keeps cost centres';
    passed := v_state is null and v_res = 'sent';
    detail := coalesce(v_state, left(v_res, 300));
    return next;

    -- ── 4. A site opened afterwards ─────────────────────────────────────────
    v_step := 'opening a site after the dimension exists';
    insert into erp.site (tenant_id, entity_id, code, name, site_type)
    select rb.tenant_id, v_entity, 'ZZ-LATER', 'A later site', s.site_type
      from erp.site s where s.id = v_site;
    v_cases := v_cases + 1;
    case_name := 'a site opened afterwards is a cost centre as it is added';
    passed := v_state is null
          and exists (select 1 from erp.dimension_value dv
                        join erp.dimension d on d.id = dv.dimension_id and d.code = 'COST_CENTRE'
                       where dv.tenant_id = rb.tenant_id and dv.code = 'ZZ-LATER' and dv.status = 'active');
    detail := coalesce(v_state, 'ZZ-LATER');
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
    raise exception 'CLOVEERP_FIRST_COST_CENTRE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.first_cost_centre_suite() from public, anon;

comment on function erp_test.first_cost_centre_suite() is
  'A site is a cost centre from the first one added (20261005400000): the first cost centre brings every '
  'site and department with it, documents still post, and a later site becomes one as it is added.';

create or replace function erp_test.assert_first_cost_centre_suite()
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
    from erp_test.first_cost_centre_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_FIRST_COST_CENTRE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Adding a cost centre would stop every document at every site. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_FIRST_COST_CENTRE_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('first cost centre: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_first_cost_centre_suite() from public, anon;

comment on function erp_test.assert_first_cost_centre_suite() is
  'The first cost centre brings every site and department, and documents still post (20261005400000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- E. Repaired where it is, and said
-- ═════════════════════════════════════════════════════════════════════════════

do $repair$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null
              and exists (select 1 from erp.dimension d where d.tenant_id = tn.id and d.code = 'COST_CENTRE')
            order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.cost_centres_cover_sites();
    if v_n > 0 then
      raise warning 'cost centres: % site(s) and department(s) of % became cost centres', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
