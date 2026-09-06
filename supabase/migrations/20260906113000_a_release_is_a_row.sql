-- A release is a row.
--
-- D28 called it "the release register" and D27 bound itself to
-- erp.assert_release_integrity(); neither existed as such. A deploy applied
-- migrations and proved the database, and left no record that a deploy had
-- happened: no commit, no time, no count. Rolling anything back meant knowing
-- from memory what had been where. And nothing anywhere compared the doors the
-- application names with the doors the schema has — the generated types file
-- is imported by nothing the app uses, and six invalidation keys in the app
-- already named doors that do not exist.
--
-- erp_meta.release is the register: one row per deploy, recorded by deploy.yml
-- after the migrations apply and before the database is proved, carrying the
-- commit, when the deploy started (the point-in-time-recovery target for a
-- rollback), and the migration ledger as it stood; proved_at is stamped once
-- the assurance step passes. erp.release_report() reads it beside the ledger,
-- and a ledger that has moved past the last recorded release is a finding of
-- erp.release_integrity_report() — a migration that reached live without a
-- deploy is exactly what the release route exists to prevent.
--
-- erp.door_manifest() lists every door with its arguments, and
-- erp.assert_app_doors_exist(text[]) refuses any name the application calls
-- that the schema does not have. supabase/ci/app_doors.sh extracts the names
-- from src on every build; a compat job compares them across the merge base,
-- so a door the application on main still calls cannot be removed by a pull
-- request without saying so.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.release (
  id                  uuid primary key default gen_random_uuid(),
  recorded_at         timestamptz not null default now(),
  deployed_at_start   timestamptz not null,
  git_sha             text not null check (git_sha ~ '^[0-9a-f]{7,40}$'),
  app_build           text,
  migrations_recorded integer not null check (migrations_recorded >= 0),
  migrations_high     text,
  recorded_by         text not null,
  proved_at           timestamptz,
  note                text,
  constraint release_proved_after_recorded check (proved_at is null or proved_at >= recorded_at)
);
create index if not exists release_recorded_idx on erp_meta.release (recorded_at desc);
comment on table erp_meta.release is
  'One row per deploy of main to live: the commit, when it started (the PITR target for a rollback), the migration ledger as it stood, and when the database was proved.';

-- The migration ledger, where the host keeps one. A build from empty has none.
create or replace function erp.migration_ledger_high()
returns table(recorded integer, high text)
language plpgsql
stable
set search_path = ''
as $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    return query select 0, null::text;
  else
    return query execute 'select count(*)::integer, max(version)::text from supabase_migrations.schema_migrations';
  end if;
end;
$$;
revoke all on function erp.migration_ledger_high() from public, anon, authenticated;

create or replace function erp.record_release(
  p_git_sha text, p_deployed_at_start timestamptz, p_app_build text default null,
  p_note text default null, p_recorded_by text default 'deploy.yml')
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id   uuid;
  v_n    integer;
  v_high text;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record a release', current_user
      using errcode = '42501',
            hint = 'deploy.yml records over the owner connection after the migrations apply.';
  end if;
  if p_git_sha !~ '^[0-9a-f]{7,40}$' then
    raise exception 'CLOVEERP_RELEASE_NEEDS_A_COMMIT: % is not a commit', coalesce(p_git_sha, 'null')
      using errcode = '22023',
            hint = 'Pass the commit that was deployed, as GITHUB_SHA gives it.';
  end if;
  select l.recorded, l.high into v_n, v_high from erp.migration_ledger_high() l;
  insert into erp_meta.release (deployed_at_start, git_sha, app_build, migrations_recorded, migrations_high, recorded_by, note)
  values (coalesce(p_deployed_at_start, now()), p_git_sha, nullif(btrim(p_app_build), ''), v_n, v_high, p_recorded_by, nullif(btrim(p_note), ''))
  returning id into v_id;
  insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
  values ('system', 'platform', 'platform.release_recorded', v_id::text, nullif(btrim(p_note), ''),
          jsonb_build_object('git_sha', p_git_sha, 'migrations_recorded', v_n, 'migrations_high', v_high,
                             'deployed_at_start', coalesce(p_deployed_at_start, now()), 'recorded_by', p_recorded_by));
  return v_id;
end;
$$;
revoke all on function erp.record_release(text, timestamptz, text, text, text) from public, anon, authenticated;

create or replace function erp.prove_release(p_release_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not prove a release', current_user
      using errcode = '42501',
            hint = 'deploy.yml proves the release after the assurance step passes.';
  end if;
  update erp_meta.release set proved_at = now() where id = p_release_id and proved_at is null;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_RELEASE: % is not an unproved release', p_release_id
      using errcode = '23503',
            hint = 'Prove the release erp.record_release() returned, once.';
  end if;
  insert into erp_meta.platform_audit (actor_email, actor_role, action, target, detail)
  values ('system', 'platform', 'platform.release_proved', p_release_id::text, '{}'::jsonb);
end;
$$;
revoke all on function erp.prove_release(uuid) from public, anon, authenticated;

create or replace function erp.release_report()
returns table(id uuid, recorded_at timestamptz, deployed_at_start timestamptz, git_sha text, app_build text,
              migrations_recorded integer, migrations_high text, proved boolean, recorded_by text,
              ledger_now text, moved_since boolean, note text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.recorded_at, r.deployed_at_start, r.git_sha, r.app_build,
         r.migrations_recorded, r.migrations_high, r.proved_at is not null, r.recorded_by,
         l.high, coalesce(l.high > r.migrations_high, false), r.note
    from erp_meta.release r
    cross join erp.migration_ledger_high() l
   order by r.recorded_at desc, r.migrations_high desc nulls last
   limit 50
$$;
revoke all on function erp.release_report() from public, anon, authenticated;
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'release_report',
   'Reads erp_meta.release, which is platform-internal; the platform console reads it through erp_platform_deployment_state and erp_platform_run_check, both gated on platform staff.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('release_register', 'Releases recorded', 'report', 'platform',
   'release_report', '', null, '',
   'Every deploy of main to live: the commit, when it started, the migration ledger as it stood, and whether the database was proved afterwards. A ledger that has moved since the last release is a finding of release integrity.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- Release integrity learns about releases. The deployed body is asserted first.
do $integrity$
declare v_def text := pg_get_functiondef('erp.release_integrity_report()'::regprocedure);
begin
  if position('a restore drill names a commitment that does not exist' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.release_integrity_report is not the body this migration re-emits';
  end if;
end
$integrity$;

create or replace function erp.release_integrity_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- §16.1: every tier states what it guarantees.
  select 'an environment tier states no guarantee', t.code, t.name
    from erp_ref.environment_tier t
   where coalesce(btrim(t.guarantee), '') = ''

  union all

  -- §16.1: "If it cannot be rebuilt from nothing, it is not an environment."
  select 'an environment tier cannot be rebuilt from nothing', t.code,
         'then by §16.1 it is not an environment'
    from erp_ref.environment_tier t
   where not t.rebuilt_from_empty

  union all

  -- §16.5: a commitment with a cadence is one somebody has to prove; a
  -- commitment with neither cadence nor a reason to lack one is a sentence.
  select 'a continuity commitment names no source clause', c.code, c.title
    from erp_meta.continuity_commitment c
   where coalesce(btrim(c.derived_from), '') = ''

  union all

  -- §16.5: a drill claiming to have passed without running assertions. Also a
  -- constraint; checked here because a row predating the constraint would
  -- still be here, and because this is the finding worth reading.
  select 'a restore drill passed without running assertions', d.id::text,
         d.restored_from || ' → ' || d.restored_to
    from erp_meta.restore_drill d
   where d.outcome = 'passed'
     and (cardinality(d.assertions_run) = 0 or coalesce(d.assertions_failed, 0) > 0)

  union all

  -- A drill naming a commitment that has gone.
  select 'a restore drill names a commitment that does not exist',
         d.id::text, d.commitment_code
    from erp_meta.restore_drill d
   where not exists (select 1 from erp_meta.continuity_commitment c
                      where c.code = d.commitment_code)

  union all

  -- D27/D28: the migration ledger has moved past the last recorded release —
  -- a migration reached this database without a deploy. Only where a release
  -- has ever been recorded and the host keeps a ledger; a build from empty has
  -- neither.
  select 'the migration ledger is ahead of the last recorded release', r.git_sha,
         format('release recorded the ledger at %s; it now stands at %s — record the release (deploy.yml does after apply, or erp.record_release() over the owner connection)',
                coalesce(r.migrations_high, '(none)'), l.high)
    from (select * from erp_meta.release order by recorded_at desc, migrations_high desc nulls last limit 1) r
    cross join erp.migration_ledger_high() l
   where l.high is not null and l.high > coalesce(r.migrations_high, '')

  union all

  -- A release the audit trail does not know.
  select 'a release names a commit the audit trail does not', r.git_sha, r.id::text
    from erp_meta.release r
   where not exists (select 1 from erp_meta.platform_audit a
                      where a.action = 'platform.release_recorded' and a.target = r.id::text)

  order by 1, 2
$$;

-- The deployment screen reads the last releases beside the ledger.
do $state$
declare
  v_def text := pg_get_functiondef('public.erp_platform_deployment_state()'::regprocedure);
  v_n   text := '    ''generated_at'', now());';
begin
  if (select count(*) from regexp_matches(v_def, '''generated_at'', now\(\)\);', 'g')) <> 1 then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: erp_platform_deployment_state is not the body this migration patches';
  end if;
  execute replace(v_def, v_n,
       E'    ''releases'', (select coalesce(jsonb_agg(to_jsonb(r) order by r.recorded_at desc), ''[]''::jsonb)\n'
    || E'                    from (select * from erp.release_report() limit 5) r),\n'
    || v_n);
end
$state$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The doors the application names
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.door_manifest()
returns table(door text, args text, is_writer boolean)
language sql
stable
set search_path = ''
as $$
  select p.proname::text, pg_get_function_identity_arguments(p.oid), p.provolatile = 'v'
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'erp\_%'
   order by 1
$$;
revoke all on function erp.door_manifest() from public, anon, authenticated;

create or replace function erp.assert_app_doors_exist(p_doors text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_missing text[];
  v_n       integer := coalesce(cardinality(p_doors), 0);
begin
  if v_n = 0 then
    raise exception 'CLOVEERP_APP_NAMES_NO_DOORS: the list of door names is empty'
      using errcode = '22023',
            hint = 'supabase/ci/app_doors.sh extracts every erp_* literal from src; an empty list means the extraction found nothing, which is not a pass.';
  end if;
  select array_agg(d order by d) into v_missing
    from unnest(p_doors) as d
   where not exists (select 1 from erp.door_manifest() m where m.door = d);
  if v_missing is not null then
    raise exception E'CLOVEERP_APP_DOOR_MISSING: % name(s) the application calls do not exist:\n  %',
      cardinality(v_missing), array_to_string(v_missing, E'\n  ')
      using errcode = 'P0001',
            hint = 'Create the door in a migration, or rename the call in src to a door that exists.';
  end if;
  return format('app doors: %s named, all exist', v_n);
end;
$$;
revoke all on function erp.assert_app_doors_exist(text[]) from public, anon, authenticated;

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_app_doors_exist', null,
   'Takes the door names supabase/ci/app_doors.sh extracts from the application source; only the build can know what the application names, and it calls this with that list.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_app_doors_exist',
   'Takes the list of door names the application source contains. A console button has no such list; the build extracts it and calls this.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.release_register_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_id     uuid;
  v_ok     boolean;
  v_msg    text;
  v_n      integer;
  v_had    boolean;
  v_high   text;
begin
  begin
    v_had := to_regclass('supabase_migrations.schema_migrations') is not null;
    if not v_had then
      execute 'create schema if not exists supabase_migrations';
      execute 'create table supabase_migrations.schema_migrations (version text primary key, name text, statements text[])';
      execute 'insert into supabase_migrations.schema_migrations (version, name) values (''20260906113000'', ''a_release_is_a_row'')';
    end if;

    -- 1
    v_id := erp.record_release('0123abc', now() - interval '3 minutes', 'suite build', 'recorded by the suite', 'suite');
    select l.high into v_high from erp.migration_ledger_high() l;
    case_name := 'a trusted session records a release reading the ledger';
    passed := v_id is not null
          and exists (select 1 from erp_meta.release r where r.id = v_id and r.migrations_high = v_high
                         and r.migrations_recorded > 0 and r.proved_at is null and r.recorded_by = 'suite');
    detail := format('release %s at ledger %s', v_id, coalesce(v_high, 'none'));
    return next;

    -- 2
    perform erp.prove_release(v_id);
    case_name := 'proving it stamps the time';
    passed := exists (select 1 from erp_meta.release r where r.id = v_id and r.proved_at is not null)
          and exists (select 1 from erp_meta.platform_audit a where a.action = 'platform.release_proved' and a.target = v_id::text);
    detail := 'proved_at set; audit row present';
    return next;

    -- 3
    case_name := 'proving it twice is refused';
    begin
      perform erp.prove_release(v_id);
      v_ok := false; v_msg := 'a release was proved twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_RELEASE%'; v_msg := left(sqlerrm, 80);
    end;
    passed := v_ok; detail := v_msg;
    return next;

    -- 4
    case_name := 'an untrusted session may not record a release';
    begin
      execute 'set local role authenticated';
      perform erp.record_release('0123abc', now());
      execute 'reset role';
      v_ok := false; v_msg := 'an untrusted session recorded a release';
    exception when others then
      execute 'reset role';
      v_ok := sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION%' or sqlstate = '42501'; v_msg := left(sqlerrm, 80);
    end;
    passed := v_ok; detail := v_msg;
    return next;

    -- 5
    case_name := 'a ledger ahead of the last release is a finding, and recording the release clears it';
    execute 'insert into supabase_migrations.schema_migrations (version, name) values (''99999999999999'', ''zz_suite_future'')';
    select count(*) into v_n from erp.release_integrity_report() f where f.finding = 'the migration ledger is ahead of the last recorded release';
    v_ok := v_n = 1;
    perform erp.record_release('0123abd', now(), 'suite build', 'the release that carries the future migration', 'suite');
    select count(*) into v_n from erp.release_integrity_report() f where f.finding = 'the migration ledger is ahead of the last recorded release';
    passed := v_ok and v_n = 0;
    detail := format('finding before recording: %s; after: %s', v_ok, v_n);
    return next;

    -- 6
    case_name := 'a release the audit trail does not know is a finding';
    insert into erp_meta.release (deployed_at_start, git_sha, migrations_recorded, recorded_by) values (now(), 'deadbeef', 0, 'suite-direct');
    select count(*) into v_n from erp.release_integrity_report() f where f.finding = 'a release names a commit the audit trail does not';
    passed := v_n = 1;
    detail := format('%s finding(s) for a release written around the writer', v_n);
    return next;

    -- 7
    case_name := 'the door manifest names every public door and the assertion accepts them';
    select count(*) into v_n from erp.door_manifest();
    v_msg := erp.assert_app_doors_exist((select array_agg(m.door) from erp.door_manifest() m));
    passed := v_n > 400 and v_msg like 'app doors: % named, all exist';
    detail := format('%s doors; %s', v_n, v_msg);
    return next;

    -- 8
    case_name := 'and refuses a name that is not a door';
    begin
      perform erp.assert_app_doors_exist(array['erp_tenants', 'erp_zz_not_a_door']);
      v_ok := false; v_msg := 'a name that is not a door was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_APP_DOOR_MISSING%' and sqlerrm like '%erp_zz_not_a_door%'; v_msg := left(sqlerrm, 90);
    end;
    passed := v_ok; detail := v_msg;
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 200);
      return next;
    end if;
  end;

  -- 9
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp_meta.release r where r.recorded_by like 'suite%')
        and (v_had or to_regclass('supabase_migrations.schema_migrations') is null);
  detail := 'releases and the suite''s ledger rolled back';
  return next;
end;
$$;
revoke all on function erp_test.release_register_suite() from public, anon, authenticated;

create or replace function erp_test.assert_release_register_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _release_register on commit drop as
    select * from erp_test.release_register_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _release_register;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_RELEASE_REGISTER_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_RELEASE_REGISTER_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('release register: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_release_register_suite() from public, anon, authenticated;

-- D27 is bound to what now exists.
update erp_ref.product_decision_check
   set note = 'Releases are rows: deploy.yml records each deploy in erp_meta.release, a migration ledger ahead of the last recorded release is a finding, and a pushed migration is immutable (supabase/ci/migrations_immutable.sh).'
 where decision_code = 'D27' and schema_name = 'erp' and routine_name = 'assert_release_integrity';
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note)
values ('D27', 'erp_test', 'assert_release_register_suite',
        'A release is recorded from the ledger and proved once; a ledger that moved without a release is a finding; every door the application names exists.')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_release_register_suite();
select erp_test.assert_release_suite();
select erp_test.assert_superadmin_suite();
select erp.assert_release_integrity();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_no_dead_configuration();
select erp.assert_scheduler_integrity();
select erp.assert_job_handlers_resolvable();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
