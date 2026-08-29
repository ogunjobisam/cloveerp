-- =============================================================================
-- ERPWare — B9 (part 1/3): the scheduler
-- Spec 3.8 (Scheduler and jobs), 5.11 ("scheduled job management with evidence")
--
--   "Scheduled and triggered execution with timeout, retry policy, overlap
--    protection and concurrency limits per tenant. Planned-outage calendar
--    suppresses jobs and their alerts during known windows. Every run logged
--    with outcome and summary counts; a job that stops running raises an alert."
--
-- The last clause is the one that earns its place, and the one most schedulers
-- get wrong. A job that fails is loud: there is a failure, someone sees it. A
-- job that stops being scheduled at all is silent — no runs, no failures, no
-- alerts, and a quiet dashboard that looks exactly like success. Month-end
-- accruals that stopped running in March are discovered in October.
--
-- So "did anything fail" is not the health question. "Has each job run as
-- recently as its own schedule says it should have" is, and erp.silent_jobs()
-- asks it. It is the difference between monitoring failures and monitoring
-- absence, and only the second one catches a scheduler that has quietly
-- stopped.
--
-- Where the boundary sits, as in B8: the database owns the schedule, the
-- decision to run, overlap, concurrency and evidence. A worker outside owns
-- doing the work. The worker's only input is a claimed erp.job_run row, so
-- nothing runs that the schedule did not authorise, and everything that ran
-- left a record whether it succeeded or not.
--
-- Four refusals:
--
--   1. A schedule the engine cannot compute. There is deliberately no 'cron'
--      kind: every kind in the enum has an implementation in
--      erp.compute_next_run(), because a schedule that silently never fires is
--      the failure this whole migration exists to prevent.
--
--   2. A handler nobody implements. erp_ref.job_handler is product content and
--      a job must name one, so a tenant cannot schedule work that no worker
--      knows how to do — it would look scheduled and never run.
--
--   3. A skipped tick with no record. Overlap protection does not drop a tick
--      silently; it writes a run with outcome 'skipped' and the reason. An
--      invisible skip is indistinguishable from a job that is not scheduled.
--
--   4. Editing a finished run. Evidence that can be revised is not evidence.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- What the product knows how to run (product content)
-- -----------------------------------------------------------------------------

create table erp_ref.job_handler (
  code            text primary key
                    check (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  name_key        text not null,
  description     text,
  module_code     text references erp_ref.module(code),
  -- JSON Schema for erp.job.parameters, validated on write so a misconfigured
  -- job is refused when it is defined rather than when it first fires at 3am.
  parameter_schema jsonb not null default '{"type":"object"}'::jsonb,
  default_timeout_seconds integer not null default 3600
                    check (default_timeout_seconds between 1 and 86400),
  -- A handler that must never run twice concurrently regardless of what a
  -- tenant configures — a ledger revaluation, say.
  forbids_overlap boolean not null default false,
  is_current      boolean not null default true
);

comment on table erp_ref.job_handler is
  'Product content: the work the product knows how to perform on a schedule. A '
  'tenant schedules a handler; a tenant never invents one, because a job naming '
  'a handler no worker implements would look scheduled and never run.';

-- -----------------------------------------------------------------------------
-- Schedules
-- -----------------------------------------------------------------------------

-- No 'cron'. Every kind here is implemented by erp.compute_next_run(); an
-- unimplemented kind would be a schedule that silently never fires.
create type erp.job_schedule_kind as enum (
  'manual',    -- triggered only, never on a clock
  'interval',  -- every N seconds from the last scheduled time
  'daily',     -- at a local time of day
  'weekly',    -- at a local time on given weekdays
  'monthly'    -- at a local time on a given day of month
);

create type erp.job_overlap_policy as enum (
  'skip',   -- the tick is recorded as skipped and the schedule moves on
  'queue',  -- the tick waits; the next claim picks it up when the run finishes
  'allow'   -- concurrent runs are legitimate for this job
);

create type erp.job_run_outcome as enum (
  'running', 'succeeded', 'failed', 'timed_out', 'cancelled', 'skipped'
);

create table erp.job (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name            text not null,
  handler_code    text not null references erp_ref.job_handler(code),
  parameters      jsonb not null default '{}'::jsonb,

  schedule_kind   erp.job_schedule_kind not null,
  interval_seconds integer check (interval_seconds is null or interval_seconds >= 30),
  at_time         time,
  -- ISO weekday numbers, 1 = Monday.
  days_of_week    smallint[],
  day_of_month    smallint check (day_of_month is null or day_of_month between 1 and 31),
  -- Spec 4.10: storage is absolute, display is local. A daily job at 06:00
  -- means 06:00 where the business is, which is not a fixed offset from UTC
  -- once daylight saving moves.
  timezone        text not null default 'UTC',

  next_run_at     timestamptz,
  timeout_seconds integer not null check (timeout_seconds between 1 and 86400),
  max_attempts    integer not null default 3 check (max_attempts between 1 and 20),
  retry_backoff_seconds integer not null default 60 check (retry_backoff_seconds >= 1),
  overlap_policy  erp.job_overlap_policy not null default 'skip',
  max_concurrent_runs integer not null default 1 check (max_concurrent_runs between 1 and 64),

  -- The dead-man's switch. How long this job may go without a successful run
  -- before its silence is itself a finding. Null means "derive it from the
  -- schedule", which is the right default: a job that should run hourly and
  -- has not run for a day is overdue without anyone having to say so.
  max_silence_seconds integer check (max_silence_seconds is null or max_silence_seconds >= 60),

  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  is_enabled      boolean not null default true,
  -- Set when consecutive failures exhaust max_attempts: the job stops being
  -- retried on its retry cadence and returns to its ordinary schedule, but the
  -- flag stays up so the condition is visible rather than merely historical.
  is_failing      boolean not null default false,

  entity_id       uuid,
  site_id         uuid,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,

  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade,

  -- Refusal 1, at the table level: a schedule must carry what its kind needs.
  -- A daily job with no time of day is not a daily job, it is a job that never
  -- runs, and it should be impossible to write down.
  constraint job_schedule_is_complete check (
    case schedule_kind
      when 'manual'   then interval_seconds is null and at_time is null
      when 'interval' then interval_seconds is not null
      when 'daily'    then at_time is not null
      when 'weekly'   then at_time is not null
                          and days_of_week is not null
                          and cardinality(days_of_week) > 0
      when 'monthly'  then at_time is not null and day_of_month is not null
    end),
  -- Containment rather than an aggregate over unnest(): a CHECK constraint may
  -- not contain a subquery, and <@ says the same thing without one.
  constraint job_days_of_week_valid check (
    days_of_week is null
    or days_of_week <@ array[1,2,3,4,5,6,7]::smallint[]),
  -- A scheduled job must know when it next runs; a manual one must not pretend
  -- to.
  constraint job_next_run_matches_kind check (
    (schedule_kind = 'manual') = (next_run_at is null) or not is_enabled)
);

comment on table erp.job is
  'Spec 3.8. A tenant''s scheduled work. The database decides what is due; a '
  'worker outside does the work and can do nothing that is not a claimed run.';

comment on column erp.job.max_silence_seconds is
  'The dead-man''s switch. A job that fails is loud; a job that stops being '
  'scheduled is silent, and silence is what erp.silent_jobs() reports.';

create index on erp.job (tenant_id, next_run_at) where is_enabled;
create index on erp.job (tenant_id, handler_code);

-- -----------------------------------------------------------------------------
-- Planned outages
-- -----------------------------------------------------------------------------

create table erp.outage_window (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null,
  -- Mandatory and length-checked: an outage nobody explained is
  -- indistinguishable from an outage nobody intended.
  reason          text not null check (length(trim(reason)) >= 10),
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  -- Null means every job. A named subset lets a database upgrade suppress the
  -- jobs that touch it without silencing everything else.
  job_codes       text[],
  suppress_jobs   boolean not null default true,
  -- Spec 3.8 says the calendar suppresses jobs AND their alerts. Suppressing
  -- the job while leaving the alerts on would page somebody at 02:00 about a
  -- job that was deliberately stopped.
  suppress_alerts boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint outage_window_ordered check (ends_at > starts_at)
);

comment on table erp.outage_window is
  'Spec 3.8: the planned-outage calendar. Suppresses jobs and, deliberately, '
  'their alerts — a maintenance window that pages someone is not a window.';

create index on erp.outage_window (tenant_id, starts_at, ends_at);

create or replace function erp.in_outage_window(
  p_job_code text,
  p_at       timestamptz default now(),
  p_for_alerts boolean default false
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from erp.outage_window w
     where w.tenant_id = erp.current_tenant_id()
       and p_at >= w.starts_at and p_at < w.ends_at
       and (w.job_codes is null or p_job_code = any (w.job_codes))
       and case when p_for_alerts then w.suppress_alerts else w.suppress_jobs end)
$$;

-- -----------------------------------------------------------------------------
-- When does this run next?
--
-- Refusal 1: every erp.job_schedule_kind has a branch here. Adding a kind
-- without adding its branch would be a schedule that never fires, so the
-- function raises on an unhandled kind rather than returning null.
-- -----------------------------------------------------------------------------

create or replace function erp.compute_next_run(
  p_kind             erp.job_schedule_kind,
  p_interval_seconds integer,
  p_at_time          time,
  p_days_of_week     smallint[],
  p_day_of_month     smallint,
  p_timezone         text,
  p_after            timestamptz default now()
) returns timestamptz
language plpgsql
-- STABLE rather than IMMUTABLE: the body is a pure function of its arguments,
-- but the p_after default is now(), and claiming immutability for something
-- whose default reads the clock invites the planner to fold a call that should
-- not be folded.
stable
set search_path = ''
as $$
declare
  v_tz     text := coalesce(p_timezone, 'UTC');
  v_local  timestamp;
  v_cand   timestamp;
  v_month  timestamp;
  v_dom    integer;
  i        integer;
begin
  if p_kind = 'manual' then
    return null;
  end if;

  if p_kind = 'interval' then
    return p_after + make_interval(secs => p_interval_seconds);
  end if;

  -- The rest are wall-clock schedules, so the arithmetic happens in local time
  -- and converts back. Doing it in UTC would drift by an hour twice a year.
  v_local := p_after at time zone v_tz;

  if p_kind = 'daily' then
    v_cand := date_trunc('day', v_local) + p_at_time;
    if v_cand <= v_local then
      v_cand := v_cand + interval '1 day';
    end if;
    return v_cand at time zone v_tz;
  end if;

  if p_kind = 'weekly' then
    -- At most eight candidates: today, then each of the next seven days.
    for i in 0..7 loop
      v_cand := date_trunc('day', v_local) + make_interval(days => i) + p_at_time;
      if v_cand > v_local
         and extract(isodow from v_cand)::smallint = any (p_days_of_week)
      then
        return v_cand at time zone v_tz;
      end if;
    end loop;
    raise exception 'ERPWARE_UNSCHEDULABLE: no weekday in % matches', p_days_of_week
      using errcode = '22023';
  end if;

  if p_kind = 'monthly' then
    v_month := date_trunc('month', v_local);
    -- Two candidates is always enough: this month, then next.
    for i in 0..1 loop
      -- A job set for the 31st must still run in February. Clamping to the
      -- last day is the only reading that does not silently skip months.
      v_dom := least(
        p_day_of_month,
        extract(day from (v_month + interval '1 month' - interval '1 day'))::integer);
      v_cand := v_month + make_interval(days => v_dom - 1) + p_at_time;
      if v_cand > v_local then
        return v_cand at time zone v_tz;
      end if;
      v_month := v_month + interval '1 month';
    end loop;
  end if;

  raise exception 'ERPWARE_UNHANDLED_SCHEDULE_KIND: % has no implementation', p_kind
    using errcode = '22023',
    detail = 'Every erp.job_schedule_kind must have a branch in erp.compute_next_run().';
end;
$$;

comment on function erp.compute_next_run is
  'The whole schedule vocabulary, in local time. Raises on a kind it cannot '
  'compute rather than returning null, because a null next run is a job that '
  'never fires and looks scheduled.';

-- Keeps erp.job.next_run_at true to the schedule without every caller having to
-- remember. Also validates the parameters against the handler's schema.
create or replace function erp.maintain_job_schedule()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_schema jsonb;
begin
  select h.parameter_schema into v_schema
    from erp_ref.job_handler h where h.code = new.handler_code;

  if v_schema is not null
     and not extensions.jsonb_matches_schema(v_schema::json, new.parameters)
  then
    raise exception
      'ERPWARE_INVALID_JOB_PARAMETERS: % does not satisfy the schema for handler %',
      new.code, new.handler_code
      using errcode = '22023', detail = new.parameters::text;
  end if;

  -- Recompute whenever the schedule itself moved, or when a disabled job is
  -- switched back on and its next_run_at is stale or in the past.
  if tg_op = 'INSERT'
     or new.schedule_kind is distinct from old.schedule_kind
     or new.interval_seconds is distinct from old.interval_seconds
     or new.at_time is distinct from old.at_time
     or new.days_of_week is distinct from old.days_of_week
     or new.day_of_month is distinct from old.day_of_month
     or new.timezone is distinct from old.timezone
     or (new.is_enabled and not old.is_enabled)
  then
    if new.schedule_kind = 'manual' or not new.is_enabled then
      new.next_run_at := null;
    else
      new.next_run_at := erp.compute_next_run(
        new.schedule_kind, new.interval_seconds, new.at_time,
        new.days_of_week, new.day_of_month, new.timezone, now());
    end if;
  end if;

  return new;
end;
$$;

create trigger t_job_schedule
  before insert or update on erp.job
  for each row execute function erp.maintain_job_schedule();

-- -----------------------------------------------------------------------------
-- Runs
-- -----------------------------------------------------------------------------

create table erp.job_run (
  id              bigint generated always as identity,
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  job_id          uuid not null,
  -- The tick this run is for, which is not the same as when it started. A run
  -- that began late still belongs to the schedule slot it was claimed for, and
  -- keeping both is how lateness becomes measurable.
  scheduled_for   timestamptz not null,
  started_at      timestamptz,
  finished_at     timestamptz,
  outcome         erp.job_run_outcome not null default 'running',
  attempt         integer not null default 1 check (attempt >= 1),
  worker          text,
  lease_expires_at timestamptz,
  -- Spec 3.8: "every run logged with outcome and summary counts". The counts
  -- are what make a run reviewable at a glance: 0 processed on a job that
  -- normally does 4000 is a finding even though it succeeded.
  summary         jsonb not null default '{}'::jsonb,
  error           text,
  skip_reason     text,
  correlation_id  uuid,
  triggered_by    uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, job_id) references erp.job (tenant_id, id) on delete cascade,
  constraint job_run_terminal_has_finish
    check ((outcome = 'running') = (finished_at is null)),
  constraint job_run_lease_matches_state
    check ((outcome = 'running') = (lease_expires_at is not null)),
  constraint job_run_skip_has_reason
    check (outcome <> 'skipped' or skip_reason is not null)
);

comment on table erp.job_run is
  'Spec 3.8: every run logged with outcome and summary counts — including the '
  'ticks that were skipped, because an invisible skip is indistinguishable '
  'from a job that was never scheduled.';

create index on erp.job_run (tenant_id, job_id, scheduled_for desc);
create index on erp.job_run (tenant_id, outcome) where outcome = 'running';

-- Refusal 4. Not append-only — a run legitimately moves from running to its
-- outcome — but frozen the moment it is terminal. Evidence that can be revised
-- after the fact is not evidence.
create or replace function erp.guard_finished_job_run()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.outcome <> 'running' then
    raise exception
      'ERPWARE_JOB_RUN_FINISHED: run % is %; a finished run is evidence and '
      'cannot be edited', old.id, old.outcome
      using errcode = '42501';
  end if;

  if new.job_id is distinct from old.job_id
     or new.scheduled_for is distinct from old.scheduled_for
     or new.attempt is distinct from old.attempt
  then
    raise exception
      'ERPWARE_JOB_RUN_IMMUTABLE: which job, which tick and which attempt are '
      'fixed when the run is created'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger t_job_run_guard
  before update on erp.job_run
  for each row execute function erp.guard_finished_job_run();

select erp_meta.register_table('erp_ref', 'job_handler', 'product_content',
  'The work the product knows how to run on a schedule.');
select erp_meta.register_table('erp', 'job', 'tenant_scoped',
  'Spec 3.8: a tenant''s scheduled work.');
select erp_meta.register_table('erp', 'outage_window', 'tenant_scoped',
  'Spec 3.8: the planned-outage calendar.');
select erp_meta.register_table('erp', 'job_run', 'tenant_scoped',
  'Run evidence. Mutable only while running; frozen once terminal.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'job_run',
   'The run row IS the audit record for the run: it carries its own outcome, '
   'timings, worker, summary counts and error, and erp.guard_finished_job_run() '
   'freezes it the moment it is terminal. Auditing it would store a second copy '
   'of evidence that already cannot be revised, at two rows per run on tables '
   'that turn over every minute.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

-- erp.job is deliberately NOT exempt. Its next_run_at churns on every claim,
-- which is noise, but a change to a schedule, a timeout or an overlap policy is
-- exactly the kind of thing an auditor asks about later, and separating the two
-- would mean deciding per column which changes count.

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
