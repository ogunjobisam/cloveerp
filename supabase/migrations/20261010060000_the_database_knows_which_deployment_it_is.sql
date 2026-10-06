set lock_timeout = '30s';

-- =============================================================================
-- 20261010060000  The database knows which deployment it is
-- -----------------------------------------------------------------------------
-- The owner's decision of 6 October: the demonstration organisation moves out
-- of production into a Supabase project of its own ("Clove ERP Demo",
-- demo.cloveerp.com), every release goes to it first, and production stops
-- making demonstrations. On 5 October the demonstration's history build ran
-- on production's small instance and took the database down for 77 minutes.
--
-- Two databases now run the same migrations, and a few things must behave
-- differently on each: production must refuse to make a demonstration (the
-- next migration), and the screens must offer production's visitors a link to
-- the demonstration instead of a button that makes one. Nothing in the schema
-- could tell the two apart. A project ref is not something a database knows,
-- and an organisation's code says what the organisation is, not where it runs.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Three refusals, registered.
--   B. erp.deployment_kind(): 'demonstration' or 'production', read from one
--      platform setting, deployment.kind. ABSENT MEANS PRODUCTION: a database
--      nobody marked behaves as production does today, so a deploy that never
--      reaches the marker leaves production as it is.
--   C. erp_meta.mark_deployment(kind): how the marker is written, by the
--      trusted build role only (no browser role, no service role).
--      .github/workflows/deploy.yml calls it for each target it releases to,
--      the demonstration's from-empty build calls it, and the schema build
--      marks its own database a demonstration before it seeds one
--      (supabase/ci/seed_demo.sql), as the demonstration project is marked.
--      Once said, a deployment's kind is not changed by a deploy: marking a
--      production database a demonstration, or the reverse, is refused, so a
--      connection string put in the wrong secret cannot turn production into
--      a place that makes demonstrations. And a database that holds a live
--      organisation is never marked a demonstration in the first place.
--   D. public.erp_platform_me() answers the deployment's kind beside who the
--      caller is, so the screens can tell production from the demonstration
--      without a door of their own.
--   E. erp_test.deployment_marker_suite, six cases, and its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No door, permission or screen string. On production: no row is written by
-- this migration. The first deploy after it writes one platform setting,
-- deployment.kind = "production", which says what absence already means.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_KIND_UNKNOWN',
  'Marking a deployment as something other than production or a demonstration.',
  'A deployment is either production, where organisations trade, or the demonstration, where prospects are shown '
  'invented ones. There is no third kind.',
  'Mark it production or demonstration.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_KIND_IS_SET',
  'Changing what kind of deployment a database is.',
  'A deployment says once whether it is production or the demonstration, and a deploy never changes it, so a '
  'connection string put in the wrong secret cannot turn production into a place that makes demonstrations.',
  'Check that the deploy is pointed at the database you meant. If the kind really is wrong, the platform owner '
  'removes the deployment.kind setting by hand and the next deploy writes it again.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_HOLDS_LIVE_ORGANISATIONS',
  'Marking a database that holds a live organisation as a demonstration.',
  'A demonstration deployment makes and trades invented organisations. A database where a real organisation is '
  'live is production, whatever the deploy was told.',
  'Check that the deploy is pointed at the demonstration''s database, not production''s.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Which deployment this is
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.deployment_kind()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- Absent means production (20261010060000): a database nobody marked
  -- behaves as production always has.
  select coalesce(
    (select s.value #>> '{}'
       from erp_meta.platform_setting s
      where s.key = 'deployment.kind'
        and s.value #>> '{}' in ('production', 'demonstration')),
    'production')
$$;

revoke all on function erp.deployment_kind() from public, anon;

comment on function erp.deployment_kind() is
  'Which deployment this database is: ''demonstration'' (the Clove ERP Demo project at demo.cloveerp.com, and the '
  'schema build) or ''production''. Read from the platform setting deployment.kind; absent means production '
  '(20261010060000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'deployment_kind',
        'Reads the one platform-wide deployment.kind setting in erp_meta, which no organisation owns and a signed-in '
        'caller cannot read. Answers production or demonstration about the deployment and nothing about any '
        'organisation or person.')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Saying which deployment this is
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.mark_deployment(p_kind text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_kind  text := lower(btrim(coalesce(p_kind, '')));
  v_now   text;
  v_live  text;
begin
  if v_kind not in ('production', 'demonstration') then
    raise exception 'CLOVEERP_DEPLOYMENT_KIND_UNKNOWN: a deployment is production or demonstration, not "%"', p_kind
      using errcode = '22023',
            hint = 'Mark it production or demonstration.';
  end if;

  select s.value #>> '{}' into v_now
    from erp_meta.platform_setting s
   where s.key = 'deployment.kind';

  if v_now = v_kind then
    return format('deployment: %s, as it already was', v_kind);
  end if;

  if v_now is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_KIND_IS_SET: this database is the % deployment and a deploy does not make it the %', v_now, v_kind
      using errcode = '55000',
            hint = 'Check that the deploy is pointed at the database you meant. If the kind really is wrong, the '
                   'platform owner removes the deployment.kind setting by hand and the next deploy writes it again.';
  end if;

  if v_kind = 'demonstration' then
    select string_agg(t.code, ', ' order by t.code) into v_live
      from erp.tenant t
     where t.status not in ('deleting', 'deleted')
       and exists (select 1 from erp.environment e
                    where e.tenant_id = t.id and e.is_self and e.is_live);
    if v_live is not null then
      raise exception 'CLOVEERP_DEPLOYMENT_HOLDS_LIVE_ORGANISATIONS: % is live here, so this database is not a demonstration', v_live
        using errcode = '55000',
              hint = 'Check that the deploy is pointed at the demonstration''s database, not production''s.';
    end if;
  end if;

  insert into erp_meta.platform_setting (key, value, reason, updated_at)
  values ('deployment.kind', to_jsonb(v_kind),
          'Written by the trusted build role (deploy.yml, the demonstration''s from-empty build, or the schema build) '
          'to say which deployment this database is (20261010060000).',
          now());

  return format('deployment: %s, marked', v_kind);
end;
$$;

revoke all on function erp_meta.mark_deployment(text) from public, anon, authenticated, service_role;

comment on function erp_meta.mark_deployment(text) is
  'Says once which deployment this database is, production or demonstration, for the trusted build role only '
  '(deploy.yml per target, the demonstration''s from-empty build, the schema build). Repeating the same kind changes '
  'nothing; changing it is refused, and a database holding a live organisation is never marked a demonstration '
  '(20261010060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The screens are told
-- ─────────────────────────────────────────────────────────────────────────────

do $me$
declare
  v_sig  constant text := 'public.erp_platform_me()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$'claimable', false);$o$;
  v_new1 constant text := $n$'claimable', false,
                              'deployment', erp.deployment_kind());$n$;
  v_old2 constant text := $o$'claimable', (not v_any));$o$;
  v_new2 constant text := $n$'claimable', (not v_any),
    -- Production or the demonstration (20261010060000): on production the
    -- screens offer a link to the demonstration instead of making one here.
    'deployment', erp.deployment_kind());$n$;
begin
  if strpos(v_src, '20261010060000') > 0 then
    raise notice '% already answers the deployment; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '74fe6b2d265e13a409498b4b5ddc86a6' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$me$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.deployment_marker_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step   text := 'clearing the marker';
  v_state  text;
  v_got    text;
  v_me     jsonb;
  rb       record;
begin
  begin
    -- Whatever this database was marked, it is unmarked for the length of the
    -- suite and put back by the undo at the end.
    delete from erp_meta.platform_setting where key = 'deployment.kind';

    -- ── 1. Unmarked is production ───────────────────────────────────────────
    v_step := 'reading an unmarked database';
    v_got := erp.deployment_kind();
    v_cases := v_cases + 1;
    case_name := 'a database nobody marked is production';
    passed := v_got = 'production';
    detail := v_got;
    return next;

    -- ── 2. Marked a demonstration, and the screens are told ─────────────────
    v_step := 'marking a demonstration';
    perform erp_meta.mark_deployment('demonstration');
    v_me := public.erp_platform_me();
    v_cases := v_cases + 1;
    case_name := 'a database with no live organisation is marked a demonstration, and erp_platform_me says so';
    passed := erp.deployment_kind() = 'demonstration' and v_me ->> 'deployment' = 'demonstration';
    detail := erp.deployment_kind() || ' / ' || coalesce(v_me ->> 'deployment', 'no deployment in erp_platform_me');
    return next;

    -- ── 3. Saying it again changes nothing ──────────────────────────────────
    v_step := 'marking it again';
    v_got := erp_meta.mark_deployment('demonstration');
    v_cases := v_cases + 1;
    case_name := 'marking a demonstration a demonstration again changes nothing';
    passed := v_got like '%as it already was%' and erp.deployment_kind() = 'demonstration';
    detail := v_got;
    return next;

    -- ── 4. A deploy does not change the kind ────────────────────────────────
    v_step := 'marking the demonstration production';
    begin
      perform erp_meta.mark_deployment('production');
      v_got := 'it was marked production';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a demonstration is not re-marked production by a deploy';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_KIND_IS_SET%' and erp.deployment_kind() = 'demonstration';
    detail := v_got;
    return next;

    -- ── 5. No third kind ────────────────────────────────────────────────────
    v_step := 'marking a third kind';
    begin
      perform erp_meta.mark_deployment('staging');
      v_got := 'it was accepted';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment is production or a demonstration and nothing else';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_KIND_UNKNOWN%';
    detail := v_got;
    return next;

    -- ── 6. A live organisation means production ─────────────────────────────
    -- provision_tenant leaves the organisation live, as every real one is.
    v_step := 'a live organisation';
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdep-' || v_tag, 'Deployment Marker Suite', 'admin@zzdep-' || v_tag || '.test', 'Deployment Admin');
    begin
      perform erp_meta.mark_deployment('demonstration');
      v_got := 'it was marked a demonstration';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a database where an organisation is live is never marked a demonstration';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_HOLDS_LIVE_ORGANISATIONS%' and erp.deployment_kind() = 'production';
    detail := v_got;
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
    raise exception 'CLOVEERP_DEPLOYMENT_MARKER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.deployment_marker_suite() from public, anon;

comment on function erp_test.deployment_marker_suite() is
  'Which deployment a database is (20261010060000): unmarked is production; a database with no live organisation is '
  'marked a demonstration and erp_platform_me says so; saying it again changes nothing; a deploy never changes the '
  'kind; there is no third kind; a database with a live organisation is never a demonstration.';

create or replace function erp_test.assert_deployment_marker_suite()
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
    from erp_test.deployment_marker_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_MARKER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The database misreads which deployment it is, or the marker can be changed by a deploy. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_DEPLOYMENT_MARKER_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment marker: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_deployment_marker_suite() from public, anon;

comment on function erp_test.assert_deployment_marker_suite() is
  'A database knows whether it is production or the demonstration, absent means production, and a deploy cannot '
  'change which (20261010060000).';

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
