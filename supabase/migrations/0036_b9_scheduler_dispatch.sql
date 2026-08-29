-- =============================================================================
-- ERPWare — B9 (part 2/3): claiming, completing and noticing silence
-- Spec 3.8, 5.11
--
-- The worker's entire vocabulary is here: claim, complete, fail, reclaim. As in
-- B8, a worker can do nothing that is not a claimed row, so the schedule
-- authorises every run and every run leaves evidence.
--
-- erp.silent_jobs() is the part worth reading. Everything else reports on runs
-- that happened; that one reports on runs that did not, which is the only way
-- to see a scheduler that has stopped.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Claiming
-- -----------------------------------------------------------------------------

create or replace function erp.claim_job_runs(
  p_worker     text default null,
  p_batch_size integer default 10,
  p_lease      interval default null
) returns setof erp.job_run
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_worker  text := coalesce(p_worker, current_user);
  j         erp.job%rowtype;
  v_running integer;
  v_run     erp.job_run%rowtype;
  v_claimed integer := 0;
begin
  for j in
    select * from erp.job job
     where job.tenant_id = v_tenant
       and job.is_enabled
       and job.schedule_kind <> 'manual'
       and job.next_run_at is not null
       and job.next_run_at <= now()
     order by job.next_run_at
     limit greatest(p_batch_size, 1) * 4
     for update skip locked
  loop
    exit when v_claimed >= greatest(p_batch_size, 1);

    -- Spec Part 7 via B6. A kill switch stops the job without losing its
    -- schedule: next_run_at is untouched, so clearing the switch resumes it.
    if erp.is_killed('job', j.code) then
      continue;
    end if;

    -- Spec 3.8: the planned-outage calendar suppresses the job. The tick is
    -- moved on rather than queued, because a maintenance window is not a
    -- backlog to work through the moment it ends.
    if erp.in_outage_window(j.code, now(), false) then
      insert into erp.job_run (
        tenant_id, job_id, scheduled_for, outcome, finished_at, skip_reason)
      values (v_tenant, j.id, j.next_run_at, 'skipped', now(),
              'suppressed by a planned outage window');

      update erp.job
         set next_run_at = erp.compute_next_run(
               j.schedule_kind, j.interval_seconds, j.at_time,
               j.days_of_week, j.day_of_month, j.timezone, now())
       where id = j.id;
      continue;
    end if;

    select count(*) into v_running
      from erp.job_run r
     where r.tenant_id = v_tenant and r.job_id = j.id and r.outcome = 'running';

    if v_running > 0 then
      -- Refusal 3: an overlapping tick is never dropped silently.
      if j.overlap_policy = 'skip' then
        insert into erp.job_run (
          tenant_id, job_id, scheduled_for, outcome, finished_at, skip_reason)
        values (v_tenant, j.id, j.next_run_at, 'skipped', now(),
                format('previous run still in progress (%s running)', v_running));

        update erp.job
           set next_run_at = erp.compute_next_run(
                 j.schedule_kind, j.interval_seconds, j.at_time,
                 j.days_of_week, j.day_of_month, j.timezone, now())
         where id = j.id;
        continue;

      elsif j.overlap_policy = 'queue' then
        -- Leave next_run_at where it is. The tick waits, and the next claim
        -- after the run finishes picks up exactly this slot.
        continue;

      elsif v_running >= j.max_concurrent_runs then
        -- 'allow', but at its ceiling. Same treatment as 'queue': wait rather
        -- than lose the tick.
        continue;
      end if;
    end if;

    insert into erp.job_run (
      tenant_id, job_id, scheduled_for, started_at, outcome, worker,
      lease_expires_at, attempt, correlation_id)
    values (
      v_tenant, j.id, j.next_run_at, now(), 'running', v_worker,
      now() + coalesce(p_lease, make_interval(secs => j.timeout_seconds)),
      j.consecutive_failures + 1, erp.current_correlation_id())
    returning * into v_run;

    -- Advanced at claim time, from the scheduled slot rather than from now, so
    -- a run that takes nineteen minutes does not push a twenty-minute schedule
    -- into drifting an hour a day.
    update erp.job
       set next_run_at = erp.compute_next_run(
             j.schedule_kind, j.interval_seconds, j.at_time,
             j.days_of_week, j.day_of_month, j.timezone, j.next_run_at)
     where id = j.id;

    v_claimed := v_claimed + 1;
    return next v_run;
  end loop;
end;
$$;

comment on function erp.claim_job_runs is
  'The scheduler worker''s only input. Honours kill switches, outage windows, '
  'overlap policy and concurrency, and records a skipped tick rather than '
  'dropping one.';

-- Triggering a job by hand. Separate from the schedule so an ad-hoc run is
-- visibly ad-hoc in the evidence, and so a manual-only job has a way in.
create or replace function erp.trigger_job(
  p_job_code text,
  p_reason   text default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  j        erp.job%rowtype;
  v_id     bigint;
begin
  perform erp.authorise('administration.jobs', null, null, null, 'job', null);

  select * into j from erp.job where tenant_id = v_tenant and code = p_job_code;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_JOB: %', p_job_code using errcode = '23503';
  end if;

  if erp.is_killed('job', j.code) then
    raise exception
      'ERPWARE_JOB_KILLED: % is stopped by a kill switch; clear it deliberately '
      'rather than working around it', p_job_code
      using errcode = '42501';
  end if;

  insert into erp.job_run (
    tenant_id, job_id, scheduled_for, outcome, lease_expires_at, worker,
    started_at, correlation_id, triggered_by, summary)
  values (
    v_tenant, j.id, now(), 'running',
    now() + make_interval(secs => j.timeout_seconds), null, now(),
    erp.current_correlation_id(), erp.current_principal_id(),
    jsonb_strip_nulls(jsonb_build_object('triggered_manually', true,
                                         'reason', p_reason)))
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Finishing
-- -----------------------------------------------------------------------------

create or replace function erp.complete_job_run(
  p_run_id  bigint,
  p_summary jsonb default '{}'::jsonb
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_job    uuid;
begin
  update erp.job_run
     set outcome = 'succeeded', finished_at = now(), lease_expires_at = null,
         summary = coalesce(p_summary, '{}'::jsonb), error = null
   where tenant_id = v_tenant and id = p_run_id and outcome = 'running'
  returning job_id into v_job;

  if v_job is null then
    raise exception
      'ERPWARE_JOB_RUN_NOT_RUNNING: % was not claimed, or has already finished',
      p_run_id
      using errcode = '23514';
  end if;

  -- A success clears the failure streak and the failing flag together: the
  -- condition is over, and leaving the flag up would train people to ignore it.
  update erp.job
     set consecutive_failures = 0, is_failing = false
   where id = v_job;
end;
$$;

create or replace function erp.fail_job_run(
  p_run_id    bigint,
  p_error     text,
  p_summary   jsonb default '{}'::jsonb,
  p_retryable boolean default true
) returns erp.job_run_outcome
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.job_run%rowtype;
  j        erp.job%rowtype;
  v_fails  integer;
begin
  select * into r from erp.job_run
   where tenant_id = v_tenant and id = p_run_id for update;

  if not found or r.outcome <> 'running' then
    raise exception
      'ERPWARE_JOB_RUN_NOT_RUNNING: % was not claimed, or has already finished',
      p_run_id
      using errcode = '23514';
  end if;

  select * into j from erp.job where id = r.job_id;

  update erp.job_run
     set outcome = 'failed', finished_at = now(), lease_expires_at = null,
         error = p_error, summary = coalesce(p_summary, '{}'::jsonb)
   where id = p_run_id;

  v_fails := j.consecutive_failures + 1;

  update erp.job
     set consecutive_failures = v_fails,
         -- Out of attempts: stop the retry cadence and put the job back on its
         -- ordinary schedule, but raise the flag. A job hammering a broken
         -- dependency every minute is its own outage.
         is_failing = (v_fails >= j.max_attempts),
         next_run_at = case
           when j.schedule_kind = 'manual' then null
           when not p_retryable or v_fails >= j.max_attempts
             then erp.compute_next_run(
                    j.schedule_kind, j.interval_seconds, j.at_time,
                    j.days_of_week, j.day_of_month, j.timezone, now())
           else now() + make_interval(
                  secs => least(j.retry_backoff_seconds * power(2, v_fails - 1),
                                3600))
         end
   where id = j.id;

  return 'failed';
end;
$$;

comment on function erp.fail_job_run is
  'Records the failure and decides what happens next: a backoff retry, or back '
  'to the ordinary schedule with the failing flag raised. A worker never '
  'decides that itself.';

-- A worker that dies mid-run leaves a run holding a lease nobody will renew.
-- Without this the job looks permanently in-flight, and under 'skip' or 'queue'
-- overlap policy that silently stops it running ever again.
create or replace function erp.reclaim_timed_out_runs()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_count  integer := 0;
begin
  for r in
    select run.id, run.job_id, run.worker, run.lease_expires_at
      from erp.job_run run
     where run.tenant_id = v_tenant
       and run.outcome = 'running'
       and run.lease_expires_at < now()
     for update skip locked
  loop
    update erp.job_run
       set outcome = 'timed_out', finished_at = now(), lease_expires_at = null,
           error = format('lease expired at %s; worker %s did not report',
                          r.lease_expires_at, coalesce(r.worker, 'unknown'))
     where id = r.id;

    -- A timeout counts as a failure: it is one, and not counting it would let a
    -- job that always times out never trip its own failure threshold.
    update erp.job
       set consecutive_failures = consecutive_failures + 1,
           is_failing = (consecutive_failures + 1 >= max_attempts)
     where id = r.job_id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Health, and the thing that matters: silence
-- -----------------------------------------------------------------------------

-- How long this job may reasonably go without a successful run. Explicit
-- tolerance wins; otherwise derive it from the schedule, because a job that
-- runs hourly and a job that runs monthly are not overdue at the same point.
create or replace function erp.job_silence_tolerance(p_job erp.job)
returns interval
language sql
stable
set search_path = ''
as $$
  select case
    when p_job.max_silence_seconds is not null
      then make_interval(secs => p_job.max_silence_seconds)
    when p_job.schedule_kind = 'interval'
      -- Three missed intervals, floored at fifteen minutes so a job running
      -- every thirty seconds does not alert on one slow afternoon.
      then greatest(make_interval(secs => p_job.interval_seconds * 3),
                    interval '15 minutes')
    when p_job.schedule_kind = 'daily'   then interval '2 days'
    when p_job.schedule_kind = 'weekly'  then interval '9 days'
    when p_job.schedule_kind = 'monthly' then interval '35 days'
    else null  -- manual jobs are never overdue; nothing promised they would run
  end
$$;

create or replace function erp.silent_jobs()
returns table (
  job_code        text,
  handler_code    text,
  schedule        text,
  last_success_at timestamptz,
  silent_for      interval,
  tolerance       interval,
  is_failing      boolean,
  finding         text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with j as (
    -- The whole row is passed, not its columns: erp.job_silence_tolerance()
    -- takes an erp.job, so `jb` rather than `jb.*`.
    select jb.*, erp.job_silence_tolerance(jb) as tol
      from erp.job jb
     where jb.tenant_id = erp.require_tenant_id()
       and jb.is_enabled
       and jb.schedule_kind <> 'manual'
  ),
  last_ok as (
    select r.job_id, max(r.finished_at) as at
      from erp.job_run r
     where r.tenant_id = erp.require_tenant_id() and r.outcome = 'succeeded'
     group by r.job_id
  )
  select j.code, j.handler_code, j.schedule_kind::text,
         last_ok.at,
         now() - coalesce(last_ok.at, j.created_at),
         j.tol,
         j.is_failing,
         case
           when last_ok.at is null
             then 'enabled and has never completed successfully'
           else 'no successful run within its tolerance'
         end
    from j
    left join last_ok on last_ok.job_id = j.id
   where j.tol is not null
     and now() - coalesce(last_ok.at, j.created_at) > j.tol
     -- Spec 3.8: the outage calendar suppresses the alerts as well as the jobs.
     -- Reporting silence caused by a window we deliberately opened would train
     -- people to ignore the report.
     and not erp.in_outage_window(j.code, now(), true)
   order by (now() - coalesce(last_ok.at, j.created_at)) desc
$$;

comment on function erp.silent_jobs() is
  'Spec 3.8: "a job that stops running raises an alert". Everything else here '
  'reports on runs that happened; this reports on runs that did not, which is '
  'the only way to see a scheduler that has quietly stopped.';

create or replace function erp.job_health()
returns table (
  job_code        text,
  is_enabled      boolean,
  is_failing      boolean,
  is_killed       boolean,
  in_outage       boolean,
  next_run_at     timestamptz,
  running         bigint,
  last_outcome    erp.job_run_outcome,
  last_finished_at timestamptz,
  last_success_at timestamptz,
  runs_24h        bigint,
  failures_24h    bigint,
  skips_24h       bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select j.code, j.is_enabled, j.is_failing,
         erp.is_killed('job', j.code),
         erp.in_outage_window(j.code, now(), false),
         j.next_run_at,
         count(*) filter (where r.outcome = 'running'),
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
   group by j.tenant_id, j.id, j.code, j.is_enabled, j.is_failing, j.next_run_at
   order by j.code
$$;

-- -----------------------------------------------------------------------------
-- Build-time invariants
-- -----------------------------------------------------------------------------

create or replace function erp.scheduler_integrity_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Refusal 1, checked rather than trusted: every schedule kind the enum
  -- offers must be one erp.compute_next_run() can actually compute. A kind
  -- added to the type without a branch is a schedule that silently never fires.
  select 'a schedule kind has no implementation in erp.compute_next_run()',
         e.enumlabel,
         'a job configured with it would look scheduled and never run'
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
   where t.typname = 'job_schedule_kind'
     and t.typnamespace = 'erp'::regnamespace
     and position('''' || e.enumlabel || '''' in
                  (select p.prosrc from pg_catalog.pg_proc p
                    where p.pronamespace = 'erp'::regnamespace
                      and p.proname = 'compute_next_run')) = 0
  union all
  select 'erp.job_run has no guard against editing a finished run', 'erp.job_run',
         'run evidence could be revised after the fact'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.job_run'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.guard_finished_job_run()'::regprocedure)
  union all
  select 'erp.job has no schedule-maintenance trigger', 'erp.job',
         'next_run_at would be whatever a caller happened to write'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.job'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.maintain_job_schedule()'::regprocedure)
  union all
  -- Data: an enabled scheduled job with nowhere to go.
  select 'an enabled job has no next run', j.code,
         'it is enabled and scheduled but will never be claimed'
    from erp.job j
   where j.is_enabled and j.schedule_kind <> 'manual' and j.next_run_at is null
  union all
  -- Data: a run in flight far beyond any plausible lease.
  select 'a job run has been in flight for over a day', r.id::text,
         format('claimed by %s', coalesce(r.worker, 'unknown'))
    from erp.job_run r
   where r.outcome = 'running' and r.started_at < now() - interval '1 day'
$$;

create or replace function erp.assert_scheduler_integrity()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.scheduler_integrity_report();

  if v_count > 0 then
    raise exception 'ERPWARE_SCHEDULER_INTEGRITY: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

select erp.assert_scheduler_integrity();
select erp.assert_isolation();
