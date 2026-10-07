set lock_timeout = '30s';

-- =============================================================================
-- 20261010100000  A plan holds what it was sold with
-- -----------------------------------------------------------------------------
-- Three Definition of Done cases the v1 gate (7 October) held as S2:
--
--   ENT-01 "Starter tenant attempts to open manufacturing and planning.
--   Expect: not available." A module that is not installed is hidden
--   (20261006170000), but nothing stopped a Starter organisation installing
--   production, planning or quality from Configuration: the installer,
--   erp.install_module_config(), never asked the plan. Switching a capability
--   on asks it (erp.set_capability, erp.require_capability_on_plan); installing
--   the module that carries it did not.
--
--   ENT-02 "Standard tenant opens production, MRP planning, forecasting,
--   traceability, quality and recall. Expect: all available. This is the
--   published price list and the database must match it." The plan's
--   capabilities were written once, at migration time, and nothing read them
--   against the price list again.
--
--   ENT-04 "Standard permits 3 companies and 10 sites, then blocks." Starter's
--   limits are refused at the doors and proved (erp_test.
--   entitlement_enforced_suite). Standard's were in the table and never tried.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_ref.module_installer.requires_capability: the capability a module's
--      first install needs. Production needs production, planning needs
--      planning_mrp, quality needs quality_inspection. Nothing else needs one.
--   B. erp.install_module_config() asks the plan before a first install of a
--      module that names one (CLOVEERP_CAPABILITY_NOT_ON_PLAN, which says to
--      raise the plan or add the feature by contract). A module already
--      installed upgrades as before, so no organisation loses one it has.
--      An organisation with no subscription is unmetered, as everywhere else.
--   C. The refusal is registered with its words.
--   D. erp_test.plan_holds_what_it_sold_suite proves all three cases: Starter
--      is refused the three modules and holds none of their capabilities,
--      Standard installs all three and holds every capability the price list
--      names, and Standard's third company and tenth site are created while
--      the fourth and the eleventh are refused.
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- Onboarding never installs these three, so it is untouched. The limits and
-- capabilities themselves are unchanged: the suite reads them, it does not
-- write them.
--
-- Production: one column on a reference table, three rows set, one routine
-- given a check before its first install. No organisation's rows change.
--
-- Proof: erp_test.plan_holds_what_it_sold_suite.
-- =============================================================================

select erp.register_refusal(
  'CLOVEERP_CAPABILITY_NOT_ON_PLAN',
  'Installing a module, or switching on a feature, that the organisation''s plan does not include.',
  'What an organisation can use is what its plan and contract sold it. Refusing says why, where hiding the switch '
  'would not.',
  'Move to a plan that includes it, or add the feature to the contract.');

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The capability a module's first install needs
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_ref.module_installer add column if not exists requires_capability text;

comment on column erp_ref.module_installer.requires_capability is
  'The capability an organisation''s plan or contract must include before this module is first installed '
  '(20261010100000). Null for a module every plan includes.';

update erp_ref.module_installer m
   set requires_capability = v.cap
  from (values ('production', 'production'),
               ('planning', 'planning_mrp'),
               ('quality', 'quality_inspection')) v(install_code, cap)
 where m.install_code = v.install_code
   and m.requires_capability is distinct from v.cap;

do $installers$
begin
  if (select count(*) from erp_ref.module_installer m
       where m.install_code in ('production', 'planning', 'quality')
         and m.requires_capability is not null) <> 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the production, planning and quality installers are not all registered';
  end if;
  if exists (select 1 from erp_ref.module_installer m
              where m.requires_capability is not null
                and not exists (select 1 from erp_meta.plan_capability pc
                                 where pc.capability_code = m.requires_capability)) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a module needs a capability no plan sells';
  end if;
end
$installers$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The installer asks the plan before a first install
-- ═════════════════════════════════════════════════════════════════════════════

do $install_module_config$
declare
  v_sig  constant text := 'erp.install_module_config(text, text, text, jsonb)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  v_cs := erp.create_change_set(p_code, p_name, p_description);
$o$;
  v_new  constant text := $n$  -- A module the plan does not include is refused before its first
  -- install (20261010100000): installing production on Starter was the one
  -- route to a feature its plan never sold. A module already installed
  -- upgrades as before, so nobody loses one they have.
  if not exists (select 1 from erp.module_installation i
                  where i.tenant_id = erp.require_tenant_id() and i.install_code = p_code) then
    perform erp.require_capability_on_plan(m.requires_capability)
       from erp_ref.module_installer m
      where m.install_code = p_code and m.requires_capability is not null;
  end if;

  v_cs := erp.create_change_set(p_code, p_name, p_description);
$n$;
  n integer;
begin
  if position('erp.require_capability_on_plan(m.requires_capability)' in v_def) > 0 then
    raise notice '% already asks the plan; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % change set line found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$install_module_config$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.plan_holds_what_it_sold_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  s_a      uuid := gen_random_uuid();
  s_b      uuid := gen_random_uuid();
  ra       record;
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_prod text; v_plan text; v_qual text;
  v_missing text; v_extra text;
  v_third text; v_fourth text; v_tenth text; v_eleventh text;
  v_n integer;
  i integer;
  -- The price list (Definition of Done ENT-02): Standard opens production,
  -- MRP planning, forecasting, traceability, quality and recall.
  c_standard constant text[] := array['production', 'planning_mrp', 'forecasting', 'batch_control',
                                      'quality_inspection', 'recall_management'];
begin
  begin
    v_step := 'an organisation on Starter and one on Standard, each with a subscription that says so';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzpls-a-' || v_tag, 'Plan Suite Starter',
                                               'admin@zzpls-a-' || v_tag || '.test', 'Starter Admin');
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    select * into rb from erp.provision_tenant('zzpls-b-' || v_tag, 'Plan Suite Standard',
                                               'admin@zzpls-b-' || v_tag || '.test', 'Standard Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;

    -- Written straight in, as erp_test.entitlement_enforced_suite writes it:
    -- inside the organisation's context, before anybody signs in.
    perform set_config('erp.job_tenant_id', ra.tenant_id::text, true);
    insert into erp_meta.subscription (tenant_id, tenant_code, plan_code, term_start, currency)
    values (ra.tenant_id, 'zzpls-a-' || v_tag, 'starter', current_date, 'GBP');
    perform set_config('erp.job_tenant_id', rb.tenant_id::text, true);
    insert into erp_meta.subscription (tenant_id, tenant_code, plan_code, term_start, currency)
    values (rb.tenant_id, 'zzpls-b-' || v_tag, 'standard', current_date, 'GBP');
    perform set_config('erp.job_tenant_id', '', true);

    insert into auth.users (id, email) values
      (s_a, 'admin@zzpls-a-' || v_tag || '.test'),
      (s_b, 'admin@zzpls-b-' || v_tag || '.test');

    -- ── 1–4. Starter: not available ─────────────────────────────────────────
    v_step := 'the Starter organisation installs what it was sold, then tries the rest';
    perform set_config('request.jwt.claims', json_build_object('sub', s_a)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');

    begin perform erp.configure_production(); v_prod := 'installed';
    exception when others then v_prod := left(sqlerrm, 200); end;
    begin perform erp.configure_planning(); v_plan := 'installed';
    exception when others then v_plan := left(sqlerrm, 200); end;
    begin perform erp.configure_quality(); v_qual := 'installed';
    exception when others then v_qual := left(sqlerrm, 200); end;

    v_cases := v_cases + 1;
    case_name := 'Starter is refused production, and the refusal names its plan';
    passed := v_state is null and v_prod like 'CLOVEERP_CAPABILITY_NOT_ON_PLAN:%starter%';
    detail := v_prod;
    return next;

    v_cases := v_cases + 1;
    case_name := 'Starter is refused planning and MRP';
    passed := v_state is null and v_plan like 'CLOVEERP_CAPABILITY_NOT_ON_PLAN:%';
    detail := v_plan;
    return next;

    v_cases := v_cases + 1;
    case_name := 'Starter is refused quality';
    passed := v_state is null and v_qual like 'CLOVEERP_CAPABILITY_NOT_ON_PLAN:%';
    detail := v_qual;
    return next;

    select count(*) into v_n from erp.module_installation mi
     where mi.tenant_id = ra.tenant_id and mi.install_code in ('production', 'planning', 'quality');
    select string_agg(c, ', ') into v_extra from unnest(c_standard) c
     where c <> 'batch_control' and erp.capability_on_plan(c);

    v_cases := v_cases + 1;
    case_name := 'so Starter holds none of the three, and its plan carries none of manufacturing, planning, forecasting, quality or recall';
    passed := v_state is null and v_n = 0 and v_extra is null;
    detail := format('%s of the three installed; on the plan anyway: %s', v_n, coalesce(v_extra, 'none'));
    return next;

    -- ── 5–6. Standard: all available ────────────────────────────────────────
    v_step := 'the Standard organisation installs production, planning and quality';
    perform set_config('request.jwt.claims', json_build_object('sub', s_b)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_production();
    perform erp.configure_planning();
    perform erp.configure_quality();

    select count(*) into v_n from erp.module_installation mi
     where mi.tenant_id = rb.tenant_id and mi.install_code in ('production', 'planning', 'quality');

    v_cases := v_cases + 1;
    case_name := 'Standard installs production, planning and quality';
    passed := v_state is null and v_n = 3;
    detail := format('%s of the three installed', v_n);
    return next;

    select string_agg(c, ', ') into v_missing from unnest(c_standard) c
     where not erp.capability_on_plan(c);

    v_cases := v_cases + 1;
    case_name := 'Standard holds every capability the price list names: production, MRP, forecasting, traceability, quality and recall';
    passed := v_state is null and v_missing is null;
    detail := format('missing from the plan: %s', coalesce(v_missing, 'nothing'));
    return next;

    -- ── 7–8. Standard's limits ──────────────────────────────────────────────
    v_step := 'Standard''s second and third companies, then a fourth';
    perform erp.create_entity('ZZPLS2', 'Second company', null, 'GBP', 'GB');
    begin
      perform erp.create_entity('ZZPLS3', 'Third company', null, 'GBP', 'GB');
      v_third := 'created';
    exception when others then v_third := left(sqlerrm, 160);
    end;
    begin
      perform erp.create_entity('ZZPLS4', 'Fourth company', null, 'GBP', 'GB');
      v_fourth := 'it was created';
    exception when others then v_fourth := left(sqlerrm, 160);
    end;

    v_cases := v_cases + 1;
    case_name := 'Standard''s third company is created and its fourth is refused, naming the plan';
    passed := v_state is null and v_third = 'created'
          and v_fourth like 'CLOVEERP_ENTITLEMENT_EXCEEDED%standard%'
          and erp.entitlement_usage('companies', rb.tenant_id) = 3;
    detail := format('third: %s; fourth: %s', v_third, v_fourth);
    return next;

    v_step := 'Standard''s sites up to ten, then an eleventh';
    v_n := erp.entitlement_usage('sites', rb.tenant_id)::integer;
    for i in v_n + 1 .. 9 loop
      perform erp.create_site('ZZPLS-S' || i, 'Site ' || i, 'warehouse');
    end loop;
    begin
      perform erp.create_site('ZZPLS-S10', 'Tenth site', 'warehouse');
      v_tenth := 'created';
    exception when others then v_tenth := left(sqlerrm, 160);
    end;
    begin
      perform erp.create_site('ZZPLS-S11', 'Eleventh site', 'warehouse');
      v_eleventh := 'it was created';
    exception when others then v_eleventh := left(sqlerrm, 160);
    end;

    v_cases := v_cases + 1;
    case_name := 'Standard''s tenth site is created and its eleventh is refused, naming the plan';
    passed := v_state is null and v_tenth = 'created'
          and v_eleventh like 'CLOVEERP_ENTITLEMENT_EXCEEDED%standard%'
          and erp.entitlement_usage('sites', rb.tenant_id) = 10;
    detail := format('tenth: %s; eleventh: %s', v_tenth, v_eleventh);
    return next;

    -- ── 9. The refusal has words ────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the refusal is registered with what was refused, why, and what to do';
    passed := v_state is null
          and exists (select 1 from erp_ref.refusal r
                       where r.code = 'CLOVEERP_CAPABILITY_NOT_ON_PLAN' and r.next_action like '%plan%');
    detail := coalesce((select r.next_action from erp_ref.refusal r
                         where r.code = 'CLOVEERP_CAPABILITY_NOT_ON_PLAN'), 'not registered');
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
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code like 'zzpls-_-' || v_tag)
        and not exists (select 1 from erp_meta.subscription s where s.tenant_code like 'zzpls-_-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (s_a, s_b));
  detail := coalesce(v_state, 'both organisations rolled back with their subscriptions');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PLAN_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_plan_holds_what_it_sold_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _plan_holds on commit drop as
    select * from erp_test.plan_holds_what_it_sold_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _plan_holds;
  drop table _plan_holds;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PLAN_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_PLAN_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a plan holds what it was sold with: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.plan_holds_what_it_sold_suite() from public, anon;
revoke all on function erp_test.assert_plan_holds_what_it_sold_suite() from public, anon;

comment on function erp_test.plan_holds_what_it_sold_suite() is
  'Definition of Done ENT-01, ENT-02 and ENT-04 (20261010100000): Starter is refused production, planning and '
  'quality; Standard installs them and holds every capability the price list names; Standard''s fourth company and '
  'eleventh site are refused.';

comment on function erp_test.assert_plan_holds_what_it_sold_suite() is
  'erp_test.plan_holds_what_it_sold_suite(), ten cases: ENT-01, ENT-02 and ENT-04.';

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
