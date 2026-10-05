set lock_timeout = '30s';

-- =============================================================================
-- 20261010054000  A template's versions are counted in its own organisation
-- -----------------------------------------------------------------------------
-- Found rehearsing the rebuild of the live demonstration, 5 October. Once a
-- second organisation held the stock count sheet and the remittance advice,
-- erp.platform_assurance() failed output_integrity with
--
--   an output template has more than one version in force [count_sheet]
--   an output template has more than one version in force [remittance_advice]
--
-- although each organisation had exactly one version of each in force.
-- erp.output_integrity_report() counted the versions in force grouped by the
-- template's code alone, so one version in each of two organisations read as
-- two versions of one template. On production today only demo-cbb10384 holds
-- either template; after the rebuild the suspended demonstration and the new
-- one both would, output_integrity is a platform-scope check the deploy's
-- "Prove the live database" step runs, and every deploy would fail. Any two
-- organisations with any template code in common would do the same.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.output_integrity_report(): that branch groups by organisation and
--      code, and its detail names the organisation, so a finding says where
--      the second version is. Every other branch already compares rows of one
--      organisation (tenant_id on both sides) or reads one row. The siblings
--      were read for the same fault and have none: erp.output_channels_report()
--      has no grouping and every clause correlates on tenant_id;
--      erp.output_health_report() reads the organisation in context;
--      erp.assert_output_templates_sound() reads the reference pack, which
--      has no organisation.
--   B. erp_test.output_versions_per_organisation_suite, two cases, and its
--      assertion. Inside one organisation a second version in force is
--      refused by output_template_version_one_active, so the branch is a
--      backstop and the suite proves the refusal rather than the finding.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- What counts as a finding inside one organisation: two versions in force of
-- one template are still found. No door, permission, refusal or screen string.
--
-- On production: one function is replaced and a suite added. No table is
-- altered and no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Counted in its own organisation
-- ─────────────────────────────────────────────────────────────────────────────

do $versions$
declare
  v_sig  constant text := 'erp.output_integrity_report()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select 'an output template has more than one version in force', t.code,
         format('%s versions effective today', count(*)::text)
    from erp.output_template t
    join erp.output_template_version tv
      on tv.tenant_id = t.tenant_id and tv.output_template_id = t.id
   where tv.status = 'active'
     and tv.effective_from <= current_date
     and (tv.effective_to is null or tv.effective_to > current_date)
   group by t.code
  having count(*) > 1
$o$;
  v_new  constant text := $n$  -- Counted in the template's own organisation (20261010054000): by code
  -- alone, one version in each of two organisations read as two in force.
  select 'an output template has more than one version in force', t.code,
         format('%s versions effective today in %s', count(*)::text,
                coalesce((select tn.code from erp.tenant tn where tn.id = t.tenant_id), 'its organisation'))
    from erp.output_template t
    join erp.output_template_version tv
      on tv.tenant_id = t.tenant_id and tv.output_template_id = t.id
   where tv.status = 'active'
     and tv.effective_from <= current_date
     and (tv.effective_to is null or tv.effective_to > current_date)
   group by t.tenant_id, t.code
  having count(*) > 1
$n$;
begin
  if strpos(v_src, '20261010054000') > 0 then
    raise notice '% already counts versions in their own organisation; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e03db09bf5e4e8d04a30c307160cb2ff' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010054000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$versions$;

revoke all on function erp.output_integrity_report() from public, anon;

comment on function erp.output_integrity_report() is
  'Specification v1.2 Part 15. Read by erp.assert_output_integrity(). Output findings: a template with no version, a template with more than one version in force in its own '
  'organisation (20261010054000), an active label version with no passing decode check, a render whose version has '
  'gone, a delivery to a suppressed address, a version requiring a permission that does not exist, and a label printer '
  'speaking a language no active label template renders.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.output_versions_per_organisation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  rb1      record;
  rb2      record;
  v_t1     uuid;
  v_t2     uuid;
  v_step   text := 'provisioning';
  v_state  text;
  v_found  text;
  v_n      integer;
begin
  v_code := 'zz_otv_' || v_tag;
  begin
    -- ── The fixture: one template code, one version in force, in each of two
    --    organisations ───────────────────────────────────────────────────────
    v_step := 'two organisations with the same template';
    perform set_config('request.jwt.claims', '', true);
    select * into rb1 from erp.provision_tenant(
      'zzotva-' || v_tag, 'Output Versions Suite A', 'admin@zzotva-' || v_tag || '.test', 'Versions Admin A');
    select * into rb2 from erp.provision_tenant(
      'zzotvb-' || v_tag, 'Output Versions Suite B', 'admin@zzotvb-' || v_tag || '.test', 'Versions Admin B');

    -- Not live, so a template may be written directly rather than promoted.
    update erp.environment set is_live = false
     where tenant_id in (rb1.tenant_id, rb2.tenant_id) and is_self;

    perform erp.set_job_tenant(rb1.tenant_id);
    insert into erp.output_template (tenant_id, code, name_key, kind)
    values (rb1.tenant_id, v_code, 'output.' || v_code, 'extract')
    returning id into v_t1;
    insert into erp.output_template_version (tenant_id, output_template_id, version, status)
    values (rb1.tenant_id, v_t1, 1, 'active');

    perform erp.set_job_tenant(rb2.tenant_id);
    insert into erp.output_template (tenant_id, code, name_key, kind)
    values (rb2.tenant_id, v_code, 'output.' || v_code, 'extract')
    returning id into v_t2;
    insert into erp.output_template_version (tenant_id, output_template_id, version, status)
    values (rb2.tenant_id, v_t2, 1, 'active');

    -- ── 1. One each is no finding ───────────────────────────────────────────
    v_step := 'the report over both';
    select count(*), string_agg(r.detail, '; ') into v_n, v_found
      from erp.output_integrity_report() r
     where r.finding = 'an output template has more than one version in force' and r.reference = v_code;
    v_cases := v_cases + 1;
    case_name := 'two organisations that each have one version of the same template in force are not a finding';
    passed := v_state is null and v_n = 0;
    detail := coalesce(v_state, coalesce('found: ' || v_found, 'nothing found for ' || v_code));
    return next;

    -- ── 2. Two in one organisation cannot be put in ─────────────────────────
    -- output_template_version_one_active refuses a second version in force of
    -- one template in one organisation, so the report's branch is the backstop
    -- for rows from before that index, and one organisation is all it counts.
    v_step := 'a second version in force in one organisation';
    begin
      insert into erp.output_template_version (tenant_id, output_template_id, version, status)
      values (rb2.tenant_id, v_t2, 2, 'active');
      v_found := 'it was accepted';
    exception when unique_violation then
      v_found := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a second version in force of one template in one organisation is refused by the database, so the report counts one organisation''s versions and that is all it needs to';
    passed := v_state is null and v_found like '%output_template_version_one_active%';
    detail := coalesce(v_state, v_found);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_OUTPUT_VERSIONS_PER_ORGANISATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.output_versions_per_organisation_suite() from public, anon;

comment on function erp_test.output_versions_per_organisation_suite() is
  'Output versions in force are counted in their own organisation (20261010054000): one version of the same template '
  'in each of two organisations is no finding, and a second in force in one organisation is refused by the database.';

create or replace function erp_test.assert_output_versions_per_organisation_suite()
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
    from erp_test.output_versions_per_organisation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_OUTPUT_VERSIONS_PER_ORGANISATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The output integrity report counts template versions across organisations, or a second version in force in one organisation is accepted. Read the case that failed.';
  end if;
  if v_total <> 2 then
    raise exception 'CLOVEERP_OUTPUT_VERSIONS_PER_ORGANISATION_SUITE_SHRANK: % case(s), expected 2', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('output versions per organisation: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_output_versions_per_organisation_suite() from public, anon;

comment on function erp_test.assert_output_versions_per_organisation_suite() is
  'A template''s versions in force are counted in its own organisation, so two organisations sharing a template code '
  'are not a finding (20261010054000).';

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
