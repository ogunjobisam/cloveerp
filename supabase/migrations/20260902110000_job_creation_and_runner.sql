-- =============================================================================
-- The superadmin console, part B — a job surface that can hold a job
--
-- /operations/jobs has a trigger action, two kill-switch actions and two panels,
-- all correctly wired to doors that work. It has never shown a row and never
-- could: nothing anywhere inserts into erp.job, erp_ref.job_handler has no seed
-- row in any migration, and there is no creation door on the public API. The
-- screen's own empty state offers Seed demo, which does not create jobs either.
--
-- So "Trigger a job" could only ever fail, "Jobs that have stopped running" was
-- empty because no job had ever started, and erp.assert_scheduler_integrity()
-- passed because it had nothing to judge — the same vacuous green this codebase
-- already documents about itself.
--
-- Three things close it: handlers to name, a door to create a job with, and
-- something to run one.
--
-- WHAT THE DATABASE CAN RUN, AND WHAT IT CANNOT
--
-- All three handlers the worker implements are pure SQL: it calls
-- erp.reclaim_timed_out_runs(), erp.silent_jobs() and
-- erp.reclaim_expired_commands() with select, and the whole claim/complete/fail
-- runtime is SQL too. For these the worker contributes a loop and a transaction
-- boundary and nothing else, so the database can run them itself.
--
-- Outbox and command DELIVERY are different: they POST to somebody else's
-- endpoint, which SQL cannot do. erp_ref.job_handler.sql_function is null for
-- any such handler, erp.run_due_jobs() refuses it by name, and the report says
-- so. A drain that silently skipped them would report a clean pass over work it
-- had not done.
-- =============================================================================

alter table erp_ref.job_handler
  add column if not exists sql_function text;

comment on column erp_ref.job_handler.sql_function is
  'The erp function that implements this handler, where the database can run it '
  'itself. Null means the handler needs something SQL cannot do — an outbound '
  'HTTP call — and only the worker can run it.';

-- ── The handlers the worker actually implements ──────────────────────────────

insert into erp_ref.job_handler
  (code, name_key, description, parameter_schema, default_timeout_seconds,
   forbids_overlap, sql_function) values
  ('platform.reclaim_timed_out_runs',
   'job_handler.reclaim_timed_out_runs.name',
   'Returns runs whose lease expired to the queue, so a worker that died does '
   'not strand them for ever.',
   '{"type":"object","additionalProperties":false}'::jsonb, 300, true,
   'reclaim_timed_out_runs'),
  ('platform.report_silent_jobs',
   'job_handler.report_silent_jobs.name',
   'Finds jobs that have stopped running. A job that silently stops looks '
   'exactly like one that has nothing to do.',
   '{"type":"object","additionalProperties":false}'::jsonb, 300, false,
   'silent_jobs'),
  ('platform.reclaim_expired_commands',
   'job_handler.reclaim_expired_commands.name',
   'Returns commands whose lease expired to the queue.',
   '{"type":"object","additionalProperties":false}'::jsonb, 300, true,
   'reclaim_expired_commands')
on conflict (code) do update set
  name_key = excluded.name_key, description = excluded.description,
  parameter_schema = excluded.parameter_schema,
  default_timeout_seconds = excluded.default_timeout_seconds,
  forbids_overlap = excluded.forbids_overlap,
  sql_function = excluded.sql_function;

-- erp.resource_coverage_report() does not scan job_handler.name_key today, so
-- these would not have been missed. Seeded anyway: a key with nothing behind it
-- is a blank label the first time somebody renders it.
insert into erp_ref.resource (key, locale, value) values
  ('job_handler.reclaim_timed_out_runs.name', 'en', 'Reclaim timed-out runs'),
  ('job_handler.report_silent_jobs.name', 'en', 'Report silent jobs'),
  ('job_handler.reclaim_expired_commands.name', 'en', 'Reclaim expired commands')
on conflict (key, locale) do update set value = excluded.value;

-- ── Creating one ─────────────────────────────────────────────────────────────

create or replace function erp.upsert_job(
  p_code                text,
  p_name                text,
  p_handler_code        text,
  p_schedule_kind       text,
  p_interval_seconds    integer default null,
  p_at_time             time    default null,
  p_days_of_week        text    default null,
  p_day_of_month        integer default null,
  p_timezone            text    default 'UTC',
  p_parameters          jsonb   default '{}'::jsonb,
  p_timeout_seconds     integer default null,
  p_max_silence_seconds integer default null,
  p_is_enabled          boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  h        erp_ref.job_handler%rowtype;
  v_days   smallint[];
  v_id     uuid;
begin
  select * into h from erp_ref.job_handler where code = p_handler_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_JOB_HANDLER: % is not a handler this product implements',
      p_handler_code using errcode = '23503',
      hint = 'erp_ref.job_handler lists them. A job naming a handler nothing implements '
             'is the failure erp.assert_scheduler_integrity() exists to refuse.';
  end if;

  if jsonb_typeof(coalesce(p_parameters, '{}'::jsonb)) <> 'object' then
    raise exception 'ERPWARE_JOB_PARAMETERS: parameters must be an object'
      using errcode = '22023';
  end if;

  -- Comma-separated rather than an array, because that is what every other door
  -- taking a list does and what a form field can produce.
  v_days := case
    when p_days_of_week is null or btrim(p_days_of_week) = '' then null
    else (select array_agg(btrim(s)::smallint)
            from unnest(string_to_array(p_days_of_week, ',')) s
           where btrim(s) <> '')
  end;

  insert into erp.job (
    tenant_id, code, name, handler_code, parameters, schedule_kind,
    interval_seconds, at_time, days_of_week, day_of_month, timezone,
    timeout_seconds, max_silence_seconds, is_enabled)
  values (
    v_tenant, lower(btrim(p_code)), p_name, p_handler_code,
    coalesce(p_parameters, '{}'::jsonb),
    p_schedule_kind::erp.job_schedule_kind,
    p_interval_seconds, p_at_time, v_days, p_day_of_month::smallint,
    coalesce(nullif(btrim(p_timezone), ''), 'UTC'),
    coalesce(p_timeout_seconds, h.default_timeout_seconds),
    p_max_silence_seconds, coalesce(p_is_enabled, true))
  on conflict (tenant_id, code) do update set
    name = excluded.name, handler_code = excluded.handler_code,
    parameters = excluded.parameters, schedule_kind = excluded.schedule_kind,
    interval_seconds = excluded.interval_seconds, at_time = excluded.at_time,
    days_of_week = excluded.days_of_week, day_of_month = excluded.day_of_month,
    timezone = excluded.timezone, timeout_seconds = excluded.timeout_seconds,
    max_silence_seconds = excluded.max_silence_seconds,
    is_enabled = excluded.is_enabled, updated_at = now()
  returning id into v_id;

  -- next_run_at is not set here: erp.maintain_job_schedule() computes it from
  -- the schedule on write, and duplicating that arithmetic is how the two
  -- disagree later.
  return jsonb_build_object('job_id', v_id, 'code', lower(btrim(p_code)));
end;
$$;

create or replace function public.erp_upsert_job(
  p_code text, p_name text, p_handler_code text, p_schedule_kind text,
  p_interval_seconds integer default null, p_at_time time default null,
  p_days_of_week text default null, p_day_of_month integer default null,
  p_timezone text default 'UTC', p_parameters jsonb default '{}'::jsonb,
  p_timeout_seconds integer default null, p_max_silence_seconds integer default null,
  p_is_enabled boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.jobs');
  return erp.upsert_job(p_code, p_name, p_handler_code, p_schedule_kind,
    p_interval_seconds, p_at_time, p_days_of_week, p_day_of_month, p_timezone,
    p_parameters, p_timeout_seconds, p_max_silence_seconds, p_is_enabled);
end;
$$;

create or replace function public.erp_job_handlers()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', h.code, 'description', h.description,
           'runs_in_database', h.sql_function is not null,
           'default_timeout_seconds', h.default_timeout_seconds)
         order by h.code), '[]'::jsonb)
    from erp_ref.job_handler h
$$;

-- ── Running the due ones ─────────────────────────────────────────────────────
--
-- erp.claim_job_runs() already does the hard part: it finds due jobs, respects
-- kill switches and outage windows, creates the run and takes a lease. All that
-- was missing was something to call the handler and say how it went.

create or replace function erp.run_due_jobs(p_batch_size integer default 25)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  r          erp.job_run%rowtype;
  j          erp.job%rowtype;
  h          erp_ref.job_handler%rowtype;
  v_result   jsonb;
  v_claimed  integer := 0;
  v_ok       integer := 0;
  v_failed   integer := 0;
  v_worker   integer := 0;
  v_detail   jsonb := '[]'::jsonb;
begin
  for r in select * from erp.claim_job_runs('database', greatest(p_batch_size, 1)) loop
    v_claimed := v_claimed + 1;

    select * into j from erp.job where tenant_id = v_tenant and id = r.job_id;
    select * into h from erp_ref.job_handler where code = j.handler_code;

    if h.sql_function is null then
      -- Named, implemented, and not implementable here. Failing it without a
      -- retry is the honest answer: retrying will not make SQL able to make an
      -- HTTP request, and counting it as done would be a lie in the report.
      perform erp.fail_job_run(
        r.id,
        format('%s needs the worker: it makes an outbound call, which SQL cannot',
               j.handler_code),
        '{}'::jsonb, false);
      v_worker := v_worker + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'job', j.code, 'outcome', 'needs the worker'));
      continue;
    end if;

    begin
      -- Uniform whatever the handler returns: a scalar comes back as a
      -- one-element array, a set as an array of rows.
      execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from erp.%I() t',
                     h.sql_function)
        into v_result;
      perform erp.complete_job_run(r.id, jsonb_build_object('result', v_result));
      v_ok := v_ok + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'job', j.code, 'outcome', 'ok', 'result', v_result));
    exception when others then
      perform erp.fail_job_run(r.id, sqlerrm);
      v_failed := v_failed + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'job', j.code, 'outcome', 'failed', 'error', left(sqlerrm, 200)));
    end;
  end loop;

  return jsonb_build_object(
    'claimed', v_claimed, 'succeeded', v_ok, 'failed', v_failed,
    'needs_worker', v_worker, 'runs', v_detail);
end;
$$;

comment on function erp.run_due_jobs is
  'Runs every due job whose handler the database can execute, for the current '
  'organisation. Handlers that make outbound calls are failed by name rather '
  'than skipped, so the report cannot claim work it did not do.';

create or replace function public.erp_platform_run_due_jobs(p_batch_size integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
  t record;
  v_one jsonb;
  v_out jsonb := '[]'::jsonb;
  v_claimed integer := 0; v_ok integer := 0; v_failed integer := 0; v_worker integer := 0;
begin
  v := erp_meta.require_platform('operator');

  for t in select id, code from erp.tenant where status = 'active' order by code loop
    -- The same transaction-local mechanism erp_platform_enter_tenant() uses:
    -- this runs as the owner, which erp.session_is_trusted() accepts, so the
    -- context is honoured and closes with the transaction whatever happens.
    perform set_config('erp.job_tenant_id', t.id::text, true);
    v_one := erp.run_due_jobs(p_batch_size);

    v_claimed := v_claimed + (v_one ->> 'claimed')::integer;
    v_ok      := v_ok      + (v_one ->> 'succeeded')::integer;
    v_failed  := v_failed  + (v_one ->> 'failed')::integer;
    v_worker  := v_worker  + (v_one ->> 'needs_worker')::integer;

    if (v_one ->> 'claimed')::integer > 0 then
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('organisation', t.code) || v_one);
    end if;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);

  perform erp_meta.platform_log(v, 'platform.jobs_run', null, null, null,
    jsonb_build_object('claimed', v_claimed, 'succeeded', v_ok,
                       'failed', v_failed, 'needs_worker', v_worker));

  return jsonb_build_object(
    'claimed', v_claimed, 'succeeded', v_ok, 'failed', v_failed,
    'needs_worker', v_worker, 'organisations', v_out);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_upsert_job(text, text, text, text, integer, time, text, integer, text, jsonb, integer, integer, boolean)',
    'public.erp_job_handlers()',
    'public.erp_platform_run_due_jobs(integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upsert_job', 'erp.authorise',
   'Defines a scheduled job. The only door that can create one — until it, '
   'erp.job could not hold a row and /operations/jobs was empty by construction.'),
  ('erp_platform_run_due_jobs', 'erp_meta.require_platform',
   'Runs due jobs across every organisation, so it is gated on platform staff '
   'rather than on any one tenant''s permissions.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('public', 'erp_platform_run_due_jobs',
        'Sets tenant context per organisation to drain each one in turn, which '
        'requires the owner role that erp.session_is_trusted() recognises.')
on conflict do nothing;

-- ── The assertion ────────────────────────────────────────────────────────────

create or replace function erp.assert_job_handlers_resolvable()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s names erp.%s, which does not exist',
                                     h.code, h.sql_function), E'\n')
    into v_count, v_detail
    from erp_ref.job_handler h
   where h.sql_function is not null
     and not exists (
       select 1 from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'erp' and p.proname = h.sql_function);

  if v_count > 0 then
    raise exception E'ERPWARE_JOB_HANDLER_UNRESOLVABLE: % finding(s)\n%',
      v_count, v_detail using errcode = '23514';
  end if;

  return format('job handlers: %s registered, %s runnable in the database',
                (select count(*) from erp_ref.job_handler),
                (select count(*) from erp_ref.job_handler where sql_function is not null));
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('job_handlers_resolvable', 'Job handlers', 'assertion', 'platform',
        'assert_job_handlers_resolvable', '', null, '',
        'Every handler the database claims to run names a function that exists.', true, 19)
on conflict (code) do update set title = excluded.title, blurb = excluded.blurb;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_job_handlers_resolvable();
select erp.assert_scheduler_integrity();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();
