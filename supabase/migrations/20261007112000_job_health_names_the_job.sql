set lock_timeout = '30s';

-- =============================================================================
-- 20261007112000  Job health names the job
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-114). Settings,
-- Recurring tasks, could not show whether a job had ever run, and named each
-- job by its raw code. erp.job_health() already answered each job's last
-- outcome and when it last finished; the screen drew neither. It could not
-- draw the job's name at all: erp.job_health() never answered erp.job.name.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.job_health() answers 'name', the job's name, beside its code.
--      Everything else it answers is unchanged. public.erp_job_health reads it
--      through to_jsonb, so the door answers 'name' with no change of its own.
--   B. erp_test.job_health_names_the_job_suite.
--
-- The screen's half is in src/routes/operations/jobs.tsx: the page is called
-- Recurring tasks, as its tile is; each job shows its name with the code
-- beneath; and a Last run column shows when it last finished and how, or
-- Never.
--
-- On production: one function is dropped and created again with one more
-- column (its result type changes, so it cannot be replaced in place). No
-- table is altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Job health answers the job's name
-- ─────────────────────────────────────────────────────────────────────────────

do $health$
declare
  v_sig  constant text := 'erp.job_health()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261007112000') > 0 then
    raise notice '% already names the job; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c38748d911917a7f97ace1cdf25ed8ce' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007112000 expects (md5 %)', v_sig, md5(v_src);
  end if;

  drop function erp.job_health();

  execute $def$
create function erp.job_health()
returns table(job_code text, name text, is_enabled boolean, is_failing boolean, is_killed boolean,
              in_outage boolean, next_run_at timestamp with time zone, running bigint, queued bigint,
              last_outcome erp.job_run_outcome, last_finished_at timestamp with time zone,
              last_success_at timestamp with time zone, runs_24h bigint, failures_24h bigint,
              skips_24h bigint)
language sql
stable
set search_path = ''
as $fn$
  -- The job's name beside its code (20261007112000, J-114).
  select j.code, j.name, j.is_enabled, j.is_failing,
         erp.is_killed('job', j.code),
         erp.in_outage_window(j.code, now(), false),
         j.next_run_at,
         count(*) filter (where r.outcome = 'running'),
         count(*) filter (where r.outcome = 'queued'),
         (select r2.outcome from erp.job_run r2
           where r2.tenant_id = j.tenant_id and r2.job_id = j.id
             and r2.finished_at is not null
           order by r2.finished_at desc limit 1),
         max(r.finished_at),
         max(r.finished_at) filter (where r.outcome = 'succeeded'),
         count(*) filter (where r.scheduled_for > now() - interval '24 hours'),
         count(*) filter (where r.scheduled_for > now() - interval '24 hours'
                            and r.outcome in ('failed', 'timed_out')),
         count(*) filter (where r.scheduled_for > now() - interval '24 hours'
                            and r.outcome = 'skipped')
    from erp.job j
    left join erp.job_run r
      on r.tenant_id = j.tenant_id and r.job_id = j.id
   where j.tenant_id = erp.require_tenant_id()
   group by j.tenant_id, j.id, j.code, j.name, j.is_enabled, j.is_failing, j.next_run_at
   order by j.code
$fn$
$def$;
end
$health$;

comment on function erp.job_health() is
  'Every job of the caller''s organisation by code and name, with its state, its next run, what is running and '
  'queued, how and when it last finished, and the last twenty-four hours (20261007112000, J-114).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.job_health_names_the_job_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  v_owner   text := current_user;
  v_step    text := 'provisioning';
  v_state   text;
  rb        record;
  v_run     bigint;
  v_claimed integer;
  v_read    jsonb;
  v_signed  jsonb;
  v_row     jsonb;
  v_unnamed text;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzjhn-' || v_tag, 'Job Health Names Suite',
      'admin@zzjhn-' || v_tag || '.test', 'Named Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzjhn-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    v_step := 'a job run by hand';
    perform erp.upsert_job('zzjhn', 'Tidy up by hand', 'platform.reclaim_stranded_work', 'manual');

    -- ── 1. A job never run is named, and has no last run ─────────────────────
    v_step := 'reading a job never run';
    v_read := public.erp_job_health();
    select x into v_row from jsonb_array_elements(v_read) x where x ->> 'job_code' = 'zzjhn';
    select string_agg(x ->> 'job_code', ', ') into v_unnamed
      from jsonb_array_elements(v_read) x
     where (x ->> 'name') is distinct from
           (select j.name from erp.job j where j.tenant_id = rb.tenant_id and j.code = x ->> 'job_code');
    v_cases := v_cases + 1;
    case_name := 'every job is answered with its name, and a job never run has no last run';
    passed := v_row ->> 'name' = 'Tidy up by hand'
          and v_unnamed is null
          and v_row -> 'last_finished_at' = 'null'::jsonb
          and v_row -> 'last_outcome' = 'null'::jsonb;
    detail := coalesce(v_state, format('%s job(s); zzjhn named %s, last finished %s; misnamed: %s',
                jsonb_array_length(v_read), v_row ->> 'name', v_row -> 'last_finished_at',
                coalesce(v_unnamed, 'none')));
    return next;

    -- ── 2. Once it has run, its last run is when and how it finished ─────────
    v_step := 'running the job once';
    v_run := erp.trigger_job('zzjhn', 'job health names suite');
    select count(*) into v_claimed from erp.claim_job_runs('zz-jhn-engine', 10);
    perform erp.complete_job_run(v_run, '{}'::jsonb);
    v_read := public.erp_job_health();
    select x into v_row from jsonb_array_elements(v_read) x where x ->> 'job_code' = 'zzjhn';
    v_cases := v_cases + 1;
    case_name := 'a job that has run answers when it last finished and that it succeeded';
    passed := v_row ->> 'last_outcome' = 'succeeded'
          and (v_row ->> 'last_finished_at')::timestamptz
              = (select r.finished_at from erp.job_run r where r.id = v_run)
          and v_row -> 'last_success_at' = v_row -> 'last_finished_at'
          and v_row ->> 'name' = 'Tidy up by hand';
    detail := coalesce(v_state, format('%s claimed; outcome %s, finished %s', v_claimed,
                v_row ->> 'last_outcome', v_row ->> 'last_finished_at'));
    return next;

    -- ── 3. Read alike signed in ──────────────────────────────────────────────
    v_step := 'reading signed in';
    set local role authenticated;
    v_signed := public.erp_job_health();
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'job health reads the same signed in';
    passed := v_signed = v_read;
    detail := coalesce(v_state, format('signed in alike %s', v_signed = v_read));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_JOB_HEALTH_NAMES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzjhn-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_JOB_HEALTH_NAMES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.job_health_names_the_job_suite() from public, anon;

comment on function erp_test.job_health_names_the_job_suite() is
  'Job health names the job (20261007112000, J-114): every job is answered with its name; a job never run has no '
  'last run; once it has run, when it last finished and that it succeeded; and the same signed in.';

create or replace function erp_test.assert_job_health_names_the_job_suite()
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
    from erp_test.job_health_names_the_job_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_JOB_HEALTH_NAMES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Recurring tasks would show a job by its code alone, or without its last run. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_JOB_HEALTH_NAMES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('job health names the job: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_job_health_names_the_job_suite() from public, anon;

comment on function erp_test.assert_job_health_names_the_job_suite() is
  'Job health answers each job''s name and its last run, as Recurring tasks shows them (20261007112000).';

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
