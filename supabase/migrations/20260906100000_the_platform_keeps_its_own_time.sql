-- The platform keeps its own time.
--
-- Nothing scheduled anything. Twenty-three job handlers existed, a job table
-- with next-run times existed, a worker that drains queues existed, and every
-- one of them waited for a process somebody else would start. erp.run_due_jobs()
-- ran one organisation's due jobs when called; nothing called it. The dispatch
-- function accepted an unauthenticated request whenever its secret happened to
-- be unset. A transition could declare effects and the engine declared a
-- variable for them and never read it; the dead-configuration report knew, and
-- refused any declaration, so the executor and the first declaration had to
-- land together. Four policy decisions had been open since they were written.
-- Part 23's register ran D1 to D18 and D34 onward, so fifteen decisions the
-- specification names were bound to nothing.
--
-- This file makes the platform run itself, and says where it cannot.
--
-- Time. erp.run_due_jobs_all_tenants() visits every organisation from a
-- trusted session and runs what is due. erp.ensure_platform_schedule()
-- schedules it every minute where the host has pg_cron, and the dispatch
-- function every minute where the host has pg_net and a vault secret to sign
-- with; where the host lacks them it records that, and the register
-- (erp_meta.platform_schedule, seq 98) says exactly what is and is not
-- scheduled and why, so a console never reads "healthy" over a scheduler that
-- does not exist. The migration schedules the job runner itself where it can.
--
-- Evidence. The worker records every pass (erp_meta.drain_pass) and
-- erp.dispatch_evidence() shows an organisation the last time each of its
-- queues was claimed and settled, by whom, and when the platform last drained
-- at all. The silent-jobs report becomes an event (job.silenced) a notification
-- route can carry to a person. The dispatch function refuses without its
-- secret, always; the worker's outbound calls carry the command's idempotency
-- key as a header, so a receiver can tell a retry from a repeat.
--
-- Effects. erp.perform_transition() executes a transition's effects and a
-- state's entry and exit actions from a vocabulary of five: emit_event, notify,
-- require_approval, set_attribute, run_handler. An effect kind the executor
-- does not know is refused at promotion and at execution, and the
-- dead-configuration report now flags that rather than every declaration. The
-- approval request the document lifecycle raised by a hard-coded rule becomes a
-- declared require_approval effect on the installers' submit transitions; the
-- hard-coded path stands down when the transition declares it, so organisations
-- configured before this file keep their behaviour.
--
-- Decisions. The four open policy decisions are closed with evidence: count
-- schedule generation ships as a handler with an open-task guard; the
-- intelligence boundary's text-derived call graph is accepted as the
-- conservative direction; print routes join notification routes as promotable
-- configuration; a posting-rule line may say `determined` and be resolved
-- through account determination at posting, so the two mechanisms meet. D19 to
-- D33 are registered and bound; the completeness clause reads the register's
-- own bound.
--
-- Found on the way, and closed here because the proofs could not be written
-- around them: the worker and erp.run_due_jobs() each claimed every due job and
-- failed the other's (every handler now has a SQL body, so the worker failed all
-- of them); the email queue could never reach `queued`, because the constraint
-- 20260904750000 replaced was a second constraint of the same shape under an
-- older name and the suite that guarded the path read the function's source
-- rather than running it; five doors wrote a record_status the enum does not
-- have and had never once succeeded; the worker read a connection key the
-- adapter schema forbids. Each has its assertion or its rehearsal below.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Time: every organisation's due jobs, from one trusted call
-- ═════════════════════════════════════════════════════════════════════════════

-- One claimed run, executed. erp.run_due_jobs() did this inline, and the worker
-- could not reach it: the worker claimed a run, found no TypeScript handler for
-- a code whose handler is SQL, and failed it — while run_due_jobs() failed the
-- runs whose handler is TypeScript. Two engines each marking the other's work
-- failed. Now there is one executor for a SQL handler, the database calls it
-- from run_due_jobs() and the worker calls it for any run it has no handler of
-- its own for, and a handler nobody implements is the only thing that fails.
create or replace function erp.run_claimed_job(p_run_id bigint)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.job_run%rowtype;
  j        erp.job%rowtype;
  h        erp_ref.job_handler%rowtype;
  v_result jsonb;
begin
  select * into r from erp.job_run where tenant_id = v_tenant and id = p_run_id and outcome = 'running';
  if r.id is null then
    raise exception 'CLOVEERP_JOB_RUN_NOT_CLAIMED: run % is not a running run of this organisation; claim it with erp.claim_job_runs() first', p_run_id
      using errcode = '23503';
  end if;
  select * into j from erp.job where tenant_id = v_tenant and id = r.job_id;
  select * into h from erp_ref.job_handler where code = j.handler_code;

  if h.sql_function is null then
    -- Named, implemented elsewhere, and not implementable here. Failing it
    -- without a retry is the honest answer: retrying will not make SQL able to
    -- make an HTTP request, and counting it as done would be a lie.
    perform erp.fail_job_run(r.id,
      format('%s needs the worker: it makes an outbound call, which SQL cannot', j.handler_code),
      '{}'::jsonb, false);
    return jsonb_build_object('job', j.code, 'outcome', 'needs the worker');
  end if;

  begin
    -- One argument by convention: a handler that wants its job's parameters
    -- takes a single jsonb and is given them; one that does not is called bare.
    -- erp.scheduler_integrity_report() refuses a handler that declares
    -- properties and cannot accept them.
    if exists (
      select 1 from pg_catalog.pg_proc pp
        join pg_catalog.pg_namespace pn on pn.oid = pp.pronamespace
       where pn.nspname = 'erp' and pp.proname = h.sql_function
         and pp.pronargs = 1 and pp.proargtypes[0] = 'jsonb'::regtype)
    then
      execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from erp.%I($1) t', h.sql_function)
        into v_result using coalesce(j.parameters, '{}'::jsonb);
    else
      execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from erp.%I() t', h.sql_function)
        into v_result;
    end if;
    perform erp.complete_job_run(r.id, jsonb_build_object('result', v_result));
    return jsonb_build_object('job', j.code, 'outcome', 'ok', 'result', v_result);
  exception when others then
    perform erp.fail_job_run(r.id, sqlerrm);
    return jsonb_build_object('job', j.code, 'outcome', 'failed', 'error', left(sqlerrm, 200));
  end;
end;
$$;
revoke all on function erp.run_claimed_job(bigint) from public, anon, authenticated;

-- run_due_jobs() re-emitted over the shared executor. The deployed body is
-- asserted first: it is the one 20260904 left, with the inline execution.
do $rdj$
declare v_def text := pg_get_functiondef('erp.run_due_jobs(integer)'::regprocedure);
begin
  if position('for r in select * from erp.claim_job_runs(''database'', greatest(p_batch_size, 1)) loop' in v_def) = 0
     or position('needs the worker: it makes an outbound call, which SQL cannot' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.run_due_jobs is not the body this migration re-emits';
  end if;
end
$rdj$;

create or replace function erp.run_due_jobs(p_batch_size integer default 25)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r          erp.job_run%rowtype;
  v_res      jsonb;
  v_claimed  integer := 0;
  v_ok       integer := 0;
  v_failed   integer := 0;
  v_worker   integer := 0;
  v_detail   jsonb := '[]'::jsonb;
begin
  for r in select * from erp.claim_job_runs('database', greatest(p_batch_size, 1)) loop
    v_claimed := v_claimed + 1;
    v_res := erp.run_claimed_job(r.id);
    case v_res ->> 'outcome'
      when 'ok'               then v_ok := v_ok + 1;
      when 'needs the worker' then v_worker := v_worker + 1;
      else                         v_failed := v_failed + 1;
    end case;
    v_detail := v_detail || jsonb_build_array(v_res);
  end loop;

  return jsonb_build_object(
    'claimed', v_claimed, 'succeeded', v_ok, 'failed', v_failed,
    'needs_worker', v_worker, 'runs', v_detail);
end;
$$;

create or replace function erp.run_due_jobs_all_tenants(p_batch_size integer default 25)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  t         record;
  v_res     jsonb;
  v_out     jsonb := '[]'::jsonb;
  v_tenants integer := 0;
  v_claimed integer := 0;
  v_ok      integer := 0;
  v_failed  integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not run every organisation''s jobs', current_user
      using errcode = '42501',
            hint = 'The scheduler runs this as the database owner; an organisation runs its own with erp.run_due_jobs().';
  end if;

  for t in select tn.id, tn.code from erp.tenant tn where tn.status = 'active' order by tn.code loop
    v_tenants := v_tenants + 1;
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    begin
      v_res := erp.run_due_jobs(p_batch_size);
      v_claimed := v_claimed + coalesce((v_res ->> 'claimed')::integer, 0);
      v_ok      := v_ok      + coalesce((v_res ->> 'succeeded')::integer, 0);
      v_failed  := v_failed  + coalesce((v_res ->> 'failed')::integer, 0);
      v_out := v_out || jsonb_build_array(jsonb_build_object('organisation', t.code, 'claimed', v_res -> 'claimed',
                                                             'succeeded', v_res -> 'succeeded', 'failed', v_res -> 'failed'));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object('organisation', t.code, 'error', left(sqlerrm, 200)));
    end;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);

  return jsonb_build_object('organisations', v_tenants, 'claimed', v_claimed, 'succeeded', v_ok,
                            'failed', v_failed, 'detail', v_out);
end;
$$;
revoke all on function erp.run_due_jobs_all_tenants(integer) from public, anon, authenticated;

comment on function erp.run_due_jobs_all_tenants is
  'One pass over every organisation''s due SQL jobs, from a trusted session. '
  'What pg_cron calls every minute where the host has it.';

create table if not exists erp_meta.platform_schedule (
  code            text primary key,
  cron_expression text not null,
  command         text not null,
  is_scheduled    boolean not null default false,
  cron_jobid      bigint,
  reason          text not null,
  checked_at      timestamptz not null default now()
);
comment on table erp_meta.platform_schedule is
  'What the platform asked its host to run on a clock, whether the host took it, and why not when it did not.';

create or replace function erp.ensure_platform_schedule(
  p_dispatch_url text default null, p_secret_name text default 'cloveerp_dispatch_secret')
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_has_cron  boolean;
  v_can_cron  boolean;
  v_has_net   boolean;
  v_has_vault boolean;
  v_jobid     bigint;
  v_cmd       text;
  v_out       jsonb := '{}'::jsonb;
  v_no_cron   text := 'not scheduled: host lacks pg_cron';
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not schedule the platform', current_user
      using errcode = '42501';
  end if;

  select exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') into v_has_cron;
  select exists (select 1 from pg_catalog.pg_available_extensions where name = 'pg_cron') into v_can_cron;
  if not v_has_cron and v_can_cron then
    -- pg_cron lives in one database per cluster (cron.database_name), so a
    -- host that ships it can still refuse it here; the refusal is the reason.
    begin
      execute 'create extension if not exists pg_cron';
      v_has_cron := true;
    exception when others then
      v_has_cron := false;
      v_no_cron := 'not scheduled: pg_cron is available and could not be installed in this database: ' || left(sqlerrm, 160);
    end;
  end if;
  select exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') into v_has_net;
  select exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') into v_has_vault;

  -- The job runner.
  v_cmd := 'select erp.run_due_jobs_all_tenants()';
  if v_has_cron then
    execute 'select j.jobid from cron.job j where j.jobname = $1' into v_jobid using 'clove-jobs';
    if v_jobid is not null then
      execute 'select cron.unschedule($1)' using v_jobid;
    end if;
    execute 'select cron.schedule($1, $2, $3)' into v_jobid using 'clove-jobs', '* * * * *', v_cmd;
    insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
    values ('clove-jobs', '* * * * *', v_cmd, true, v_jobid, 'scheduled with pg_cron', now())
    on conflict (code) do update set is_scheduled = true, cron_jobid = excluded.cron_jobid, reason = excluded.reason, checked_at = now();
  else
    insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
    values ('clove-jobs', '* * * * *', v_cmd, false, null, v_no_cron, now())
    on conflict (code) do update set is_scheduled = false, cron_jobid = null, reason = excluded.reason, checked_at = now();
  end if;
  v_out := v_out || jsonb_build_object('clove-jobs', (select reason from erp_meta.platform_schedule where code = 'clove-jobs'));

  -- The dispatch function, signed with a secret the database never sees in
  -- clear: the command reads it from the vault at fire time.
  if p_dispatch_url is not null then
    v_cmd := format(
      'select net.http_post(url := %L, headers := jsonb_build_object(''content-type'', ''application/json'', ''x-dispatch-secret'', (select s.decrypted_secret from vault.decrypted_secrets s where s.name = %L)), body := ''{}''::jsonb)',
      p_dispatch_url, p_secret_name);
    if v_has_cron and v_has_net and v_has_vault then
      execute 'select j.jobid from cron.job j where j.jobname = $1' into v_jobid using 'clove-dispatch';
      if v_jobid is not null then
        execute 'select cron.unschedule($1)' using v_jobid;
      end if;
      execute 'select cron.schedule($1, $2, $3)' into v_jobid using 'clove-dispatch', '* * * * *', v_cmd;
      insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
      values ('clove-dispatch', '* * * * *', v_cmd, true, v_jobid, 'scheduled with pg_cron and pg_net; the secret is read from the vault at fire time', now())
      on conflict (code) do update set command = excluded.command, is_scheduled = true, cron_jobid = excluded.cron_jobid, reason = excluded.reason, checked_at = now();
    else
      insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
      values ('clove-dispatch', '* * * * *', v_cmd, false, null,
              'not scheduled: host lacks ' || concat_ws(', ', case when not v_has_cron then 'pg_cron' end,
                                                             case when not v_has_net then 'pg_net' end,
                                                             case when not v_has_vault then 'vault' end), now())
      on conflict (code) do update set command = excluded.command, is_scheduled = false, cron_jobid = null, reason = excluded.reason, checked_at = now();
    end if;
  elsif not exists (select 1 from erp_meta.platform_schedule where code = 'clove-dispatch') then
    insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
    values ('clove-dispatch', '* * * * *', 'select net.http_post(...)', false, null,
            'not scheduled: no dispatch URL has been given; an operator runs erp.ensure_platform_schedule(url) once', now());
  end if;
  v_out := v_out || jsonb_build_object('clove-dispatch', (select reason from erp_meta.platform_schedule where code = 'clove-dispatch'));

  return v_out;
end;
$$;
revoke all on function erp.ensure_platform_schedule(text, text) from public, anon, authenticated;

create or replace function erp.platform_schedule_report()
returns table(finding text, reference text, detail text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_has_cron boolean;
  r          record;
  v_live     boolean;
begin
  select exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') into v_has_cron;

  if not exists (select 1 from erp_meta.platform_schedule) then
    finding := 'the platform has never been asked to schedule itself';
    reference := 'erp_meta.platform_schedule';
    detail := 'erp.ensure_platform_schedule() has not run; nothing runs on a clock and nothing records why';
    return next;
    return;
  end if;

  for r in select * from erp_meta.platform_schedule order by code loop
    if r.is_scheduled then
      if v_has_cron then
        execute 'select exists (select 1 from cron.job j where j.jobname = $1 and j.active)' into v_live using r.code;
        if not v_live then
          finding := 'the register says scheduled and the host''s cron does not';
          reference := r.code;
          detail := format('recorded as job %s on %s; cron.job has no active job of that name', r.cron_jobid, r.checked_at);
          return next;
        end if;
      else
        finding := 'the register says scheduled and the host has no pg_cron';
        reference := r.code;
        detail := format('recorded on %s; the extension is gone', r.checked_at);
        return next;
      end if;
    elsif v_has_cron and r.code = 'clove-jobs' then
      finding := 'the host has pg_cron and the job runner is not scheduled';
      reference := r.code;
      detail := r.reason;
      return next;
    end if;
  end loop;
end;
$$;
revoke all on function erp.platform_schedule_report() from public, anon, authenticated;

create or replace function erp.assert_platform_scheduled()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', r.finding, r.reference, r.detail), E'\n')
    into v_count, v_detail
    from erp.platform_schedule_report() r;
  if v_count > 0 then
    raise exception E'CLOVEERP_PLATFORM_NOT_SCHEDULED: % finding(s)\n%', v_count, v_detail
      using errcode = '23514',
            hint = 'Run erp.ensure_platform_schedule(dispatch_url) from a trusted session; it schedules what the host can run and records what it cannot.';
  end if;
  return format('platform schedule: %s',
                (select string_agg(format('%s %s', s.code, case when s.is_scheduled then 'every minute' else s.reason end), '; ' order by s.code)
                   from erp_meta.platform_schedule s));
end;
$$;
revoke all on function erp.assert_platform_scheduled() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('platform_scheduled', 'The platform runs on a clock, or says why it cannot', 'assertion', 'platform',
   'assert_platform_scheduled', '', 'platform_schedule_report', '',
   'The job runner and the dispatch function are scheduled with pg_cron where the host has it; where it does not, the register says so, and a register that disagrees with the host''s cron is a finding.', true, 98)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- The operator's door: schedule, or re-schedule with a dispatch URL.
drop function if exists public.erp_platform_ensure_schedule(text);
create function public.erp_platform_ensure_schedule(p_dispatch_url text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v   erp_meta.platform_staff;
  res jsonb;
begin
  v := erp_meta.require_platform('operator');
  res := erp.ensure_platform_schedule(p_dispatch_url);
  perform erp_meta.platform_log(v, 'platform.schedule_ensured', null, null, p_dispatch_url, res);
  return res;
end;
$$;
revoke all on function public.erp_platform_ensure_schedule(text) from public, anon;
grant execute on function public.erp_platform_ensure_schedule(text) to authenticated, service_role;
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_ensure_schedule',
   'Platform-level operation above every tenant, gated on erp_meta.require_platform() and audited in erp_meta.platform_audit; schedules the job runner and the dispatch function with the host''s cron.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_ensure_schedule', 'erp_meta.require_platform',
   'Writes the platform schedule register and the host''s cron table; platform operators only, every call logged in erp_meta.platform_audit.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Evidence that anything drained
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.drain_pass (
  id          bigint generated always as identity primary key,
  worker      text not null,
  started_at  timestamptz not null,
  finished_at timestamptz not null default now(),
  report      jsonb not null default '{}'::jsonb
);
create index if not exists drain_pass_finished_idx on erp_meta.drain_pass (finished_at desc);
comment on table erp_meta.drain_pass is
  'One row per pass of the dispatch worker: who drained, when, and what it claimed and settled. The evidence the console reads.';

create or replace function erp.record_drain_pass(p_worker text, p_started_at timestamptz, p_report jsonb)
returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare v_id bigint;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record a drain pass', current_user
      using errcode = '42501';
  end if;
  insert into erp_meta.drain_pass (worker, started_at, finished_at, report)
  values (coalesce(p_worker, 'unknown'), coalesce(p_started_at, now()), now(), coalesce(p_report, '{}'::jsonb))
  returning id into v_id;
  -- Keep a month; the point is the last one.
  delete from erp_meta.drain_pass where finished_at < now() - interval '30 days';
  return v_id;
end;
$$;
revoke all on function erp.record_drain_pass(text, timestamptz, jsonb) from public, anon, authenticated;

-- The email queue could not be queued. 20260904750000 taught
-- erp.dispatch_notifications() to leave an email at `queued` for the worker and
-- widened notification_status_check to say so — but 20260904570000 had put a
-- second constraint of the same shape on the table under another name, and
-- that one still listed the old statuses. Every dispatch pass with one email in
-- it has raised on the first email since, and the suite that guarded the path
-- (erp_test.email_delivery_suite) read the function's source for the word
-- `queued` rather than queueing one. One constraint now; the rehearsal in the
-- build (supabase/ci/drain_rehearsal.sh) queues an email and reads its
-- provider id back.
alter table erp.notification drop constraint if exists notification_status_known;

-- And behind the constraint, the claim: erp.claim_email_batch() asked the kill
-- switch about the kind `notifications`, which erp.kill_target_kind does not
-- have, so the claim raised before it read a row — the worker could never have
-- picked an email up even had one reached the queue. The switch that stops an
-- outbound channel is `integration`, keyed by what it names (a system's code
-- for a system); for email the key is the channel: an operator stops it with
-- erp.set_kill_switch('integration', 'email', reason), and the claim reads that.
-- One more behind it: the claim returns severity as text and selected the enum,
-- which PL/pgSQL refuses at the first row. Three faults deep, none reachable
-- until the one in front was fixed; the rehearsal found each in turn.
do $claim$
declare v_def text := pg_get_functiondef('erp.claim_email_batch(integer)'::regprocedure);
begin
  if position('erp.is_killed(''notifications'', ''email'')' in v_def) = 0
     or position(E'         m.severity\n    from marked m' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.claim_email_batch is not the body this migration patches';
  end if;
  v_def := replace(v_def, 'erp.is_killed(''notifications'', ''email'')', 'erp.is_killed(''integration'', ''email'')');
  v_def := replace(v_def, E'         m.severity\n    from marked m', E'         m.severity::text\n    from marked m');
  execute v_def;
end
$claim$;

create or replace function erp.dispatch_evidence()
returns table(queue text, last_claimed_at timestamptz, last_settled_at timestamptz, worker text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select 'jobs',
         (select max(r.started_at) from erp.job_run r where r.tenant_id = t.tenant_id),
         (select max(r.finished_at) from erp.job_run r where r.tenant_id = t.tenant_id),
         (select r.worker from erp.job_run r where r.tenant_id = t.tenant_id and r.finished_at is not null order by r.finished_at desc limit 1),
         format('%s run(s) in the last day, %s failed',
                (select count(*) from erp.job_run r where r.tenant_id = t.tenant_id and r.started_at > now() - interval '1 day'),
                (select count(*) from erp.job_run r where r.tenant_id = t.tenant_id and r.started_at > now() - interval '1 day' and r.outcome = 'failed'))
    from t
  union all
  select 'commands',
         -- Settling a command clears claimed_by and claimed_at, so who claimed
         -- it last is read from the command's own event log, where the
         -- in-flight transition names the worker.
         (select max(ce.occurred_at) from erp.command_event ce where ce.tenant_id = t.tenant_id and ce.to_status = 'in_flight'),
         (select max(c.response_at) from erp.command c where c.tenant_id = t.tenant_id),
         (select ce.actor_label from erp.command_event ce where ce.tenant_id = t.tenant_id and ce.to_status = 'in_flight' order by ce.occurred_at desc, ce.id desc limit 1),
         (select string_agg(format('%s %s', n, s), ', ' order by s)
            from (select c.status::text as s, count(*) as n from erp.command c where c.tenant_id = t.tenant_id group by c.status) x)
    from t
  union all
  select 'messages',
         (select max(m.claimed_at) from erp.integration_message m where m.tenant_id = t.tenant_id),
         (select max(m.processed_at) from erp.integration_message m where m.tenant_id = t.tenant_id),
         null,
         (select string_agg(format('%s %s', n, s), ', ' order by s)
            from (select m.status::text as s, count(*) as n from erp.integration_message m where m.tenant_id = t.tenant_id group by m.status) x)
    from t
  union all
  select 'email',
         (select max(n.created_at) from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = 'email' and n.status in ('sending', 'sent', 'failed')),
         (select max(n.sent_at) from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = 'email'),
         null,
         (select string_agg(format('%s %s', x.n, x.s), ', ' order by x.s)
            from (select n.status::text as s, count(*) as n from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = 'email' group by n.status) x)
    from t
  union all
  select 'platform',
         (select max(p.started_at) from erp_meta.drain_pass p),
         (select max(p.finished_at) from erp_meta.drain_pass p),
         (select p.worker from erp_meta.drain_pass p order by p.finished_at desc limit 1),
         coalesce((select format('last pass %s ago: %s', date_trunc('second', now() - p.finished_at), p.report::text)
                     from erp_meta.drain_pass p order by p.finished_at desc limit 1),
                  'no worker has ever recorded a pass on this platform')
    from t
$$;
revoke all on function erp.dispatch_evidence() from public, anon, authenticated;

-- The platform row reads erp_meta.drain_pass, which is platform-internal, so
-- the door runs as definer behind the jobs permission: what it exposes is a
-- worker's name, two timestamps and a count report — nothing tenant-shaped.
drop function if exists public.erp_dispatch_evidence();
create function public.erp_dispatch_evidence()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp.authorise('administration.jobs');
  return coalesce((select jsonb_agg(to_jsonb(e) order by e.queue) from erp.dispatch_evidence() e), '[]'::jsonb);
end;
$$;
revoke all on function public.erp_dispatch_evidence() from public, anon;
grant execute on function public.erp_dispatch_evidence() to authenticated, service_role;
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_dispatch_evidence',
   'Reads erp_meta.drain_pass, which is platform-internal and unreachable by a tenant session; gated on erp.authorise(administration.jobs), returns only the last pass''s worker, timestamps and counts, and every tenant row it reads is filtered on the caller''s tenant.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_dispatch_evidence', 'erp.authorise',
   'Volatile only because erp.authorise() records the check; the door reads queue evidence and writes nothing of its own.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- Silence is an event a route can carry to a person.
insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('job.silenced', 1, 'job', 'administration', 'event.job.silenced',
        'A scheduled job has not completed within its own tolerance; the dead-man''s switch raised it so a route can tell somebody.',
        '{"type":"object","required":["job_code","finding"],"properties":{"job_code":{"type":"string"},"handler_code":{"type":"string"},"silent_for":{"type":"string"},"finding":{"type":"string"}}}',
        true)
on conflict (code, version) do update set description = excluded.description, payload_schema = excluded.payload_schema;

create or replace function erp.report_silent_jobs()
returns table(job_code text, handler_code text, silent_for text, finding text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        record;
  v_job    uuid;
begin
  for s in select * from erp.silent_jobs() loop
    select j.id into v_job from erp.job j where j.tenant_id = v_tenant and j.code = s.job_code;
    -- Once a day per job, not once a minute: the route carries it, and a
    -- person who has been told is not told again until tomorrow.
    if not exists (select 1 from erp.event ev
                    where ev.tenant_id = v_tenant and ev.event_type = 'job.silenced'
                      and ev.aggregate_id = v_job and ev.occurred_at > now() - interval '1 day') then
      perform erp.append_event('job.silenced', 'job', v_job,
        jsonb_build_object('job_code', s.job_code, 'handler_code', s.handler_code,
                           'silent_for', s.silent_for::text, 'finding', s.finding));
    end if;
    job_code := s.job_code; handler_code := s.handler_code; silent_for := s.silent_for::text; finding := s.finding;
    return next;
  end loop;
end;
$$;
revoke all on function erp.report_silent_jobs() from public, anon, authenticated;

update erp_ref.job_handler set sql_function = 'report_silent_jobs',
       description = 'Jobs that have stopped running, each raised once a day as job.silenced so a notification route can carry it to a person.'
 where code = 'platform.report_silent_jobs';

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.job.silenced', 'en', 'Scheduled job has gone silent', 'administration'),
  ('event.job.silenced', 'de', 'Geplanter Job ist verstummt', 'administration')
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Effects: a transition does what it declares
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
  ('workflow.transitioned', 1, 'workflow', 'administration', 'event.workflow.transitioned',
   'A lifecycle transition declared an emit_event effect with no event type of its own; this is the general one.',
   '{"type":"object","required":["object_type","transition"],"properties":{"object_type":{"type":"string"},"object_id":{"type":"string"},"transition":{"type":"string"},"from_state":{"type":"string"},"to_state":{"type":"string"}}}',
   true),
  ('workflow.notified', 1, 'workflow', 'administration', 'event.workflow.notified',
   'A lifecycle transition declared a notify effect: somebody is to be told, through whatever route subscribes.',
   '{"type":"object","required":["object_type","transition","message_key"],"properties":{"object_type":{"type":"string"},"object_id":{"type":"string"},"transition":{"type":"string"},"message_key":{"type":"string"},"severity":{"type":"string"}}}',
   true)
on conflict (code, version) do update set description = excluded.description, payload_schema = excluded.payload_schema;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.workflow.transitioned', 'en', 'Lifecycle transition', 'administration'),
  ('event.workflow.transitioned', 'de', 'Lebenszyklusübergang', 'administration'),
  ('event.workflow.notified', 'en', 'Lifecycle transition asked for somebody to be told', 'administration'),
  ('event.workflow.notified', 'de', 'Lebenszyklusübergang bittet um Benachrichtigung', 'administration')
on conflict (key, locale) do update set value = excluded.value;

create or replace function erp.known_effect_kinds()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['emit_event', 'notify', 'require_approval', 'set_attribute', 'run_handler'] $$;
revoke all on function erp.known_effect_kinds() from public, anon, authenticated;

-- Validated at promotion: the checked list comes back, or the promotion refuses.
create or replace function erp.checked_effects(p_effects jsonb, p_where text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  e jsonb;
begin
  if p_effects is null then return '[]'::jsonb; end if;
  if jsonb_typeof(p_effects) <> 'array' then
    raise exception 'CLOVEERP_EFFECT_UNKNOWN: effects on % are not a list', p_where using errcode = '23514';
  end if;
  for e in select value from jsonb_array_elements(p_effects) loop
    if not ((e ->> 'kind') = any (erp.known_effect_kinds())) then
      raise exception 'CLOVEERP_EFFECT_UNKNOWN: % declares an effect of kind %, which the executor does not know', p_where, coalesce(e ->> 'kind', '(none)')
        using errcode = '23514',
              hint = 'Known kinds: emit_event {event_type, payload}, notify {message_key, severity}, require_approval, set_attribute {path, value}, run_handler {handler_code, parameters}.';
    end if;
    if (e ->> 'kind') = 'emit_event' and not exists (select 1 from erp_ref.event_type et where et.code = coalesce(e ->> 'event_type', 'workflow.transitioned') and et.is_current) then
      raise exception 'CLOVEERP_EFFECT_UNKNOWN: % emits event type %, which is not registered', p_where, e ->> 'event_type' using errcode = '23514';
    end if;
    if (e ->> 'kind') = 'notify' and coalesce(e ->> 'message_key', '') = '' then
      raise exception 'CLOVEERP_EFFECT_UNKNOWN: % declares notify without a message_key', p_where using errcode = '23514';
    end if;
    if (e ->> 'kind') = 'set_attribute' and coalesce(e ->> 'path', '') = '' then
      raise exception 'CLOVEERP_EFFECT_UNKNOWN: % declares set_attribute without a path', p_where using errcode = '23514';
    end if;
    if (e ->> 'kind') = 'run_handler' and not exists (select 1 from erp_ref.job_handler h where h.code = e ->> 'handler_code' and h.sql_function is not null) then
      raise exception 'CLOVEERP_EFFECT_UNKNOWN: % runs handler %, which is not a SQL job handler', p_where, coalesce(e ->> 'handler_code', '(none)') using errcode = '23514';
    end if;
  end loop;
  return p_effects;
end;
$$;
revoke all on function erp.checked_effects(jsonb, text) from public, anon, authenticated;

create or replace function erp.execute_effects(
  p_object_type text, p_object_id uuid, p_effects jsonb, p_data jsonb,
  p_entity_id uuid, p_site_id uuid, p_transition text, p_from text, p_to text)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  e        jsonb;
  v_n      integer := 0;
  v_type   text;
  v_chain  text;
  v_fn     text;
  v_path   text[];
  v_attrs  jsonb;
  v_i      integer;
begin
  for e in select value from jsonb_array_elements(coalesce(p_effects, '[]'::jsonb)) loop
    v_n := v_n + 1;
    case e ->> 'kind'
      when 'emit_event' then
        v_type := coalesce(e ->> 'event_type', 'workflow.transitioned');
        perform erp.append_event(v_type,
          (select et.aggregate_type from erp_ref.event_type et where et.code = v_type and et.is_current),
          p_object_id,
          coalesce(e -> 'payload', '{}'::jsonb) || jsonb_build_object('object_type', p_object_type, 'object_id', p_object_id,
                                                                     'transition', p_transition, 'from_state', p_from, 'to_state', p_to),
          p_entity_id, p_site_id);

      when 'notify' then
        perform erp.append_event('workflow.notified', 'workflow', p_object_id,
          jsonb_build_object('object_type', p_object_type, 'object_id', p_object_id, 'transition', p_transition,
                             'message_key', e ->> 'message_key', 'severity', coalesce(e ->> 'severity', 'medium')),
          p_entity_id, p_site_id);

      when 'require_approval' then
        -- A document type says whether it has a chain; a declaration on a type
        -- with none is a declaration of intent that has nowhere to go yet.
        if p_object_type = 'document' then
          select dt.approval_chain_code into v_chain
            from erp.document d join erp.document_type dt on dt.id = d.document_type_id
           where d.tenant_id = v_tenant and d.id = p_object_id;
          if v_chain is not null then
            perform erp.request_approval('document', p_object_id, coalesce(p_data, '{}'::jsonb), 1, p_entity_id, p_site_id);
          end if;
        else
          perform erp.request_approval(p_object_type, p_object_id, coalesce(p_data, '{}'::jsonb), 1, p_entity_id, p_site_id);
        end if;

      when 'set_attribute' then
        if p_object_type <> 'document' then
          raise exception 'CLOVEERP_EFFECT_UNSUPPORTED_OBJECT: set_attribute is executed for documents; % carries no attributes the executor writes', p_object_type
            using errcode = '23514';
        end if;
        v_path := string_to_array(e ->> 'path', '.');
        select coalesce(d.attributes, '{}'::jsonb) into v_attrs from erp.document d
         where d.tenant_id = v_tenant and d.id = p_object_id;
        -- jsonb_set creates only the last key; the objects above it have to
        -- exist, so a dotted path is built down before the value is written.
        for v_i in 1 .. coalesce(array_length(v_path, 1), 1) - 1 loop
          if jsonb_typeof(v_attrs #> v_path[1:v_i]) is distinct from 'object' then
            v_attrs := jsonb_set(v_attrs, v_path[1:v_i], '{}'::jsonb, true);
          end if;
        end loop;
        v_attrs := jsonb_set(v_attrs, v_path, coalesce(e -> 'value', 'null'::jsonb), true);
        update erp.document
           set attributes = v_attrs, updated_at = now()
         where tenant_id = v_tenant and id = p_object_id;

      when 'run_handler' then
        select h.sql_function into v_fn from erp_ref.job_handler h where h.code = e ->> 'handler_code';
        if v_fn is null then
          raise exception 'CLOVEERP_UNKNOWN_JOB_HANDLER: % is not a SQL job handler', e ->> 'handler_code' using errcode = '23503';
        end if;
        if exists (select 1 from pg_catalog.pg_proc pp join pg_catalog.pg_namespace pn on pn.oid = pp.pronamespace
                    where pn.nspname = 'erp' and pp.proname = v_fn and pp.pronargs = 1 and pp.proargtypes[0] = 'jsonb'::regtype) then
          execute format('select count(*) from erp.%I($1) t', v_fn) using coalesce(e -> 'parameters', '{}'::jsonb);
        else
          execute format('select count(*) from erp.%I() t', v_fn);
        end if;

      else
        raise exception 'CLOVEERP_EFFECT_UNKNOWN: % on % declares an effect of kind %, which the executor does not know',
          p_transition, p_object_type, coalesce(e ->> 'kind', '(none)')
          using errcode = '23514';
    end case;
  end loop;
  return v_n;
end;
$$;
revoke all on function erp.execute_effects(text, uuid, jsonb, jsonb, uuid, uuid, text, text, text) from public, anon, authenticated;

-- Does the object's own lifecycle declare a given effect on a transition? The
-- document lifecycle's hard-coded approval request stands down when it does.
create or replace function erp.transition_declares_effect(p_object_type text, p_object_id uuid, p_transition_code text, p_kind text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from erp.object_state os
      join erp.transition t on t.state_machine_version_id = os.state_machine_version_id
                           and t.code = p_transition_code and t.from_state_id = os.current_state_id
     where os.tenant_id = erp.require_tenant_id() and os.object_type = p_object_type and os.object_id = p_object_id
       and exists (select 1 from jsonb_array_elements(coalesce(t.effects, '[]'::jsonb)) e where e ->> 'kind' = p_kind))
$$;
revoke all on function erp.transition_declares_effect(text, uuid, text, text) from public, anon, authenticated;

-- The engine executes: the from-state's exit actions, the transition's effects,
-- the to-state's entry actions, after the state has moved and been logged.
do $engine$
declare
  v_def text := pg_get_functiondef('erp.perform_transition(text,uuid,text,jsonb,text)'::regprocedure);
  v_n1  text := E'  return v_to;\nend;';
begin
  if (select count(*) from regexp_matches(v_def, 'return v_to;', 'g')) <> 1
     or position('v_effects  jsonb;' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.perform_transition is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'  v_effects := coalesce(v_t.effects, ''[]''::jsonb);\n'
    || E'  perform erp.execute_effects(p_object_type, p_object_id,\n'
    || E'    (select s.on_exit from erp.state s where s.id = v_t.from_state_id),\n'
    || E'    p_data, v_os.entity_id, v_os.site_id, p_transition_code, v_from, v_to);\n'
    || E'  perform erp.execute_effects(p_object_type, p_object_id, v_effects,\n'
    || E'    p_data, v_os.entity_id, v_os.site_id, p_transition_code, v_from, v_to);\n'
    || E'  perform erp.execute_effects(p_object_type, p_object_id,\n'
    || E'    (select s.on_enter from erp.state s where s.id = v_t.to_state_id),\n'
    || E'    p_data, v_os.entity_id, v_os.site_id, p_transition_code, v_from, v_to);\n\n'
    || E'  return v_to;\nend;');
  execute v_def;
end
$engine$;

-- The document lifecycle's own approval request stands down where the
-- transition declares it.
do $doc$
declare
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_n1  text := E'  if p_transition_code = ''submit'' and dt.approval_chain_code is not null then';
begin
  if (select count(*) from regexp_matches(v_def, 'if p_transition_code = ''submit'' and dt\.approval_chain_code is not null then', 'g')) <> 1 then
    raise exception 'CLOVEERP_LIFECYCLE_UNRECOGNISED: erp.transition_document is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'  if p_transition_code = ''submit'' and dt.approval_chain_code is not null\n'
    || E'     and not erp.transition_declares_effect(''document'', p_document_id, p_transition_code, ''require_approval'') then');
  execute v_def;
end
$doc$;

-- Promotion validates what it stores.
do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n1  text := 'coalesce(r.tr -> ''effects'', ''[]''::jsonb),';
  v_n2  text := 'coalesce(e.value -> ''on_enter'', ''[]''::jsonb),';
  v_n3  text := 'coalesce(e.value -> ''on_exit'', ''[]''::jsonb)';
begin
  if (select count(*) from regexp_matches(v_def, 'coalesce\(r\.tr -> ''effects'', ''\[\]''::jsonb\),', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'coalesce\(e\.value -> ''on_enter'', ''\[\]''::jsonb\),', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'coalesce\(e\.value -> ''on_exit'', ''\[\]''::jsonb\)', 'g')) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: erp.apply_change_set_item is not the body this migration patches (effects)';
  end if;
  v_def := replace(v_def, v_n1, 'erp.checked_effects(coalesce(r.tr -> ''effects'', ''[]''::jsonb), ''transition '' || (r.tr ->> ''code'')),');
  v_def := replace(v_def, v_n2, 'erp.checked_effects(coalesce(e.value -> ''on_enter'', ''[]''::jsonb), ''state '' || (e.value ->> ''code'') || '' on_enter''),');
  v_def := replace(v_def, v_n3, 'erp.checked_effects(coalesce(e.value -> ''on_exit'', ''[]''::jsonb), ''state '' || (e.value ->> ''code'') || '' on_exit'')');
  execute v_def;
end
$promoter$;

-- The installers declare the approval request instead of relying on the rule.
do $installers$
declare
  v_def text;
  v_n1  text := 'jsonb_build_object(''code'',''submit'',''name'',''Submit for approval'',''from'',''draft'',''to'',''pending_approval'',''required_permission'',''procurement.order'')';
  v_n2  text := 'jsonb_build_object(''code'',''submit'',''name'',''Submit'',''from'',''draft'',''to'',''submitted'',''required_permission'',''procurement.requisition'')';
  v_n3  text := 'jsonb_build_object(''code'',''submit'',''name'',''Submit'',''from'',''draft'',''to'',''pending_approval'',''required_permission'',''sales.order'')';
  v_eff text := ',''effects'',jsonb_build_array(jsonb_build_object(''kind'',''require_approval'')))';
begin
  v_def := pg_get_functiondef('erp.configure_procurement'::regproc);
  if position(v_n1 in v_def) = 0 or position(v_n2 in v_def) = 0 then
    raise exception 'CLOVEERP_INSTALLER_UNRECOGNISED: erp.configure_procurement is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1, left(v_n1, length(v_n1) - 1) || v_eff);
  v_def := replace(v_def, v_n2, left(v_n2, length(v_n2) - 1) || v_eff);
  execute v_def;

  v_def := pg_get_functiondef('erp.configure_sales'::regproc);
  if position(v_n3 in v_def) = 0 then
    raise exception 'CLOVEERP_INSTALLER_UNRECOGNISED: erp.configure_sales is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n3, left(v_n3, length(v_n3) - 1) || v_eff);
  execute v_def;
end
$installers$;

-- The dead-configuration report: a declaration is no longer dead; an unknown
-- kind is.
do $dead$
declare
  v_def text := pg_get_functiondef('erp.dead_configuration_report'::regproc);
  v_n1  text :=
       E'  select ''a transition declares effects that nothing executes'',\n'
    || E'         format(''%s.%s'', m.code, t.code),\n'
    || E'         ''erp.perform_transition() does not run transition effects, so this ''\n'
    || E'         ''configuration would be stored and silently ignored''\n'
    || E'    from erp.transition t\n'
    || E'    join erp.state_machine_version v on v.id = t.state_machine_version_id\n'
    || E'    join erp.state_machine m on m.id = v.state_machine_id\n'
    || E'   where jsonb_array_length(coalesce(t.effects, ''[]''::jsonb)) > 0\n'
    || E'  union all\n'
    || E'  select ''a state declares entry or exit actions that nothing executes'',\n'
    || E'         format(''%s.%s'', m.code, s.code),\n'
    || E'         ''on_enter and on_exit are stored and never read''\n'
    || E'    from erp.state s\n'
    || E'    join erp.state_machine_version v on v.id = s.state_machine_version_id\n'
    || E'    join erp.state_machine m on m.id = v.state_machine_id\n'
    || E'   where jsonb_array_length(coalesce(s.on_enter, ''[]''::jsonb)) > 0\n'
    || E'      or jsonb_array_length(coalesce(s.on_exit, ''[]''::jsonb)) > 0';
begin
  if position(v_n1 in v_def) = 0 then
    raise exception 'CLOVEERP_REPORT_UNRECOGNISED: erp.dead_configuration_report is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'  select ''a transition declares an effect kind the executor does not know'',\n'
    || E'         format(''%s.%s'', m.code, t.code),\n'
    || E'         (select string_agg(coalesce(e ->> ''kind'', ''(none)''), '', '') from jsonb_array_elements(coalesce(t.effects, ''[]''::jsonb)) e\n'
    || E'           where not (coalesce(e ->> ''kind'', '''') = any (erp.known_effect_kinds())))\n'
    || E'    from erp.transition t\n'
    || E'    join erp.state_machine_version v on v.id = t.state_machine_version_id\n'
    || E'    join erp.state_machine m on m.id = v.state_machine_id\n'
    || E'   where exists (select 1 from jsonb_array_elements(coalesce(t.effects, ''[]''::jsonb)) e\n'
    || E'                  where not (coalesce(e ->> ''kind'', '''') = any (erp.known_effect_kinds())))\n'
    || E'  union all\n'
    || E'  select ''a state declares an entry or exit action of a kind the executor does not know'',\n'
    || E'         format(''%s.%s'', m.code, s.code),\n'
    || E'         (select string_agg(coalesce(e ->> ''kind'', ''(none)''), '', '')\n'
    || E'            from jsonb_array_elements(coalesce(s.on_enter, ''[]''::jsonb) || coalesce(s.on_exit, ''[]''::jsonb)) e\n'
    || E'           where not (coalesce(e ->> ''kind'', '''') = any (erp.known_effect_kinds())))\n'
    || E'    from erp.state s\n'
    || E'    join erp.state_machine_version v on v.id = s.state_machine_version_id\n'
    || E'    join erp.state_machine m on m.id = v.state_machine_id\n'
    || E'   where exists (select 1 from jsonb_array_elements(coalesce(s.on_enter, ''[]''::jsonb) || coalesce(s.on_exit, ''[]''::jsonb)) e\n'
    || E'                  where not (coalesce(e ->> ''kind'', '''') = any (erp.known_effect_kinds())))');
  execute v_def;
end
$dead$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Four decisions closed with evidence
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.policy_decision add column if not exists superseded_by text references erp_meta.policy_decision (code);

-- 4a. Count schedule generation writes, with an open-task guard.
create or replace function erp.generate_count_tasks(p_params jsonb default '{}'::jsonb)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  p        record;
  v_total  integer := 0;
begin
  for p in
    select cp.* from erp.count_programme cp
     where cp.tenant_id = v_tenant and cp.status = 'active'
       and (p_params ->> 'programme' is null or cp.code = p_params ->> 'programme')
     order by cp.code
  loop
    -- Yesterday's count still open is a reason to wait, not to raise a second
    -- task for the same shelf.
    if exists (select 1 from erp.count_task ct
                where ct.tenant_id = v_tenant and ct.count_programme_id = p.id and ct.status = 'open') then
      continue;
    end if;
    v_total := v_total + erp.raise_count_tasks(p.code);
  end loop;
  return v_total;
end;
$$;
revoke all on function erp.generate_count_tasks(jsonb) from public, anon, authenticated;

insert into erp_ref.job_handler
  (code, name_key, description, module_code, sql_function, default_timeout_seconds, parameter_schema, forbids_overlap, is_current)
values
  ('inventory.generate_counts', 'job_handler.inventory_generate_counts.name',
   'Raises count tasks from every active count programme that has none open; a programme with open tasks waits.',
   'inventory', 'generate_count_tasks', 300,
   '{"type":"object","properties":{"programme":{"type":"string"}}}', true, true)
on conflict (code) do update
  set description = excluded.description, sql_function = excluded.sql_function,
      parameter_schema = excluded.parameter_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('job_handler.inventory_generate_counts.name', 'en', 'Generate count tasks', 'inventory'),
  ('job_handler.inventory_generate_counts.name', 'de', 'Inventuraufgaben erzeugen', 'inventory')
on conflict (key, locale) do update set value = excluded.value;

-- 4b. Print routes are promotable, like notification routes already are.
do $routes$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n1  text := E'when ''event_subscription'' then';
begin
  if (select count(*) from regexp_matches(v_def, 'when ''event_subscription'' then', 'g')) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: erp.apply_change_set_item is not the body this migration patches (print_route)';
  end if;
  v_def := replace(v_def, v_n1,
       E'when ''print_route'' then\n'
    || E'      if i.operation = ''remove'' then\n'
    || E'        update erp.print_route prr set status = ''inactive'', updated_at = now()\n'
    || E'         where prr.tenant_id = v_tenant and prr.code = (p ->> ''code'');\n'
    || E'      else\n'
    || E'        perform erp.upsert_print_route(p ->> ''code'', p ->> ''output_kind'', p ->> ''printer'',\n'
    || E'          p ->> ''template'', v_site, p ->> ''workstation'', nullif(p ->> ''app_user_id'', '''')::uuid,\n'
    || E'          coalesce((p ->> ''priority'')::integer, 100));\n'
    || E'      end if;\n\n'
    || E'    ' || v_n1);
  execute v_def;

  v_def := pg_get_functiondef('erp.configuration_manifest(text[])'::regprocedure);
  v_n1 := E'    select ''event_subscription'',';
  if (select count(*) from regexp_matches(v_def, 'select ''event_subscription'',', 'g')) <> 1 then
    raise exception 'CLOVEERP_MANIFEST_UNRECOGNISED: erp.configuration_manifest is not the body this migration patches (print_route)';
  end if;
  v_def := replace(v_def, v_n1,
       E'    select ''print_route'',\n'
    || E'           prr.code,\n'
    || E'           jsonb_build_object(''code'', prr.code, ''output_kind'', prr.output_kind,\n'
    || E'                              ''printer'', (select pr2.code from erp.printer pr2 where pr2.id = prr.printer_id),\n'
    || E'                              ''template'', prr.template_code,\n'
    || E'                              ''site'', (select s2.code from erp.site s2 where s2.id = prr.site_id),\n'
    || E'                              ''workstation'', prr.workstation, ''priority'', prr.priority)\n'
    || E'      from t\n'
    || E'      join erp.print_route prr on prr.tenant_id = t.tenant_id and prr.status = ''active''\n\n'
    || E'    union all\n\n'
    || v_n1);
  execute v_def;
end
$routes$;

insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale) values
  ('erp', 'print_route', 'print_route',
   '§15. Which printer a kind of output goes to, from where. A route that lives only in one environment is a label that prints in test and nowhere else.')
on conflict (schema_name, table_name) do update set object_kind = excluded.object_kind, rationale = excluded.rationale;

-- 4c. A posting-rule line may say `determined`, and be resolved through account
--     determination at posting: the two mechanisms meet on the line.
create or replace function erp.posting_line_account_code(p_line jsonb, p_document_id uuid, p_ledger_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  res      jsonb;
begin
  if coalesce(p_line ->> 'account', '') <> 'determined' then
    return p_line ->> 'account';
  end if;
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  res := erp.determine_account(
    coalesce(p_line ->> 'transaction_type', dt.base_type_code),
    (select dl.item_id from erp.document_line dl where dl.document_id = d.id and not dl.is_cancelled order by dl.line_no limit 1),
    d.party_id, d.site_id, d.entity_id, p_ledger_id, p_line ->> 'reason_code', d.document_date, true);
  return res ->> 'account_code';
end;
$$;
revoke all on function erp.posting_line_account_code(jsonb, uuid, uuid) from public, anon, authenticated;

do $bridge$
declare
  v_def text := pg_get_functiondef('erp.post_document_finance'::regproc);
  v_n1  text := E'       and a.code = (v_line ->> ''account'')';
begin
  if (select count(*) from regexp_matches(v_def, 'and a\.code = \(v_line ->> ''account''\)', 'g')) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: erp.post_document_finance is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'       and a.code = erp.posting_line_account_code(v_line, p_document_id, led.id)');
  execute v_def;
end
$bridge$;

-- 4d. The four decisions, closed.
update erp_meta.policy_decision
   set status = 'accepted', decided_at = now(),
       decision = 'Shipped as a scheduled handler. inventory.generate_counts raises count tasks from every active count programme that has none open; a programme whose tasks are still open waits rather than raising a second task for the same shelf.',
       evidence = 'erp_ref.job_handler inventory.generate_counts → erp.generate_count_tasks(jsonb); erp_test.policy_closure_suite() raises once and then waits.'
 where code = 'count_schedule_generation';

update erp_meta.policy_decision
   set status = 'accepted', decided_at = now(),
       evidence = coalesce(evidence, '') || ' Accepted as the conservative direction: a false edge fails the build loudly; a missed edge would pass it silently. The rule for authors stands: never write a call-shaped mention of an erp_ai function in a product function body.'
 where code = 'intelligence_boundary_reads_source_text';

update erp_meta.policy_decision
   set status = 'accepted', decided_at = now(),
       decision = 'Both routes are promotable configuration. erp.notification_route joined the register when its promoter branch and manifest arm were written; erp.print_route joins it here with a branch, an arm, a register row and the live-edit guard.',
       evidence = 'erp_meta.promotable_surface holds both; erp.assert_configuration_promotable() counts 43 surfaces; erp_test.policy_closure_suite() promotes a print route and captures it.'
 where code = 'notification_routes_outside_promotion';

update erp_meta.policy_decision
   set status = 'accepted', decided_at = now(),
       decision = 'Both mechanisms stay, and they meet on the posting line: a posting-rule line may name the account `determined`, and erp.post_document_finance() resolves it through erp.determine_account() at posting, with the document''s item, party, site, company, ledger and date as the facts. A rule that names an account still names it; one that says determined defers to the matrix.',
       evidence = 'erp.posting_line_account_code(); erp_test.policy_closure_suite() posts a determined line through a determination rule; erp.determination_coverage_report() still labels every finding with its mechanism.'
 where code = 'two_account_selection_mechanisms';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4b. Five doors that had never worked
-- ─────────────────────────────────────────────────────────────────────────────
-- The policy suite below assigns an item its posting class through the public
-- door, and the door raised `invalid input value for enum erp.record_status:
-- "retired"` — the same fault 20260904810000 repaired in erp_end_item_supplier
-- and erp_retire_account_determination, still present in five siblings. A
-- literal that the enum does not have fails when the statement is planned, so
-- each of these doors has refused every call it ever received: no item or party
-- has ever changed posting class, no posting class has been retired, no item
-- reclassified along an axis, no delegation ended. The sibling doors use
-- 'inactive'; these now do too. The assertion below keeps the literal out.
do $retired$
declare
  r record; v_def text; v_n integer := 0;
begin
  for r in
    select p.oid, n.nspname, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('erp_end_approval_delegation', 'erp_retire_posting_class',
                         'erp_set_item_posting_class', 'erp_set_party_posting_class',
                         'erp_classify_item')
  loop
    v_def := pg_get_functiondef(r.oid);
    if (select count(*) from regexp_matches(v_def, 'status = ''retired''', 'g')) <> 1 then
      raise exception 'CLOVEERP_DOOR_UNRECOGNISED: public.% is not the body this migration patches', r.proname;
    end if;
    execute replace(v_def, 'status = ''retired''', 'status = ''inactive''');
    v_n := v_n + 1;
  end loop;
  if v_n <> 5 then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: expected five doors to patch, found %', v_n;
  end if;
end
$retired$;

-- Behind the enum fault sat a second one the fault had hidden: both posting
-- class doors raise `posting.class_changed`, which is declared against the
-- aggregate `posting`, while one raises it against the item and the other
-- against the party — the event store refuses both. One event cannot belong to
-- two aggregates, so there are now two, and the old declaration is no longer
-- current. Nothing ever recorded it (the doors never got that far).
insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
  ('posting.item_class_changed', 1, 'item', 'finance', 'event.posting.item_class_changed',
   'An item moved to a different posting class; from, to, reason and the date it takes effect.',
   '{"type":"object","required":["to","valid_from"],"properties":{"from":{"type":["string","null"]},"to":{"type":"string"},"reason":{"type":["string","null"]},"valid_from":{"type":"string"}}}', true),
  ('posting.party_class_changed', 1, 'party', 'finance', 'event.posting.party_class_changed',
   'A party moved to a different posting class; from, to, reason and the date it takes effect.',
   '{"type":"object","required":["to","valid_from"],"properties":{"from":{"type":["string","null"]},"to":{"type":"string"},"reason":{"type":["string","null"]},"valid_from":{"type":"string"}}}', true)
on conflict (code, version) do update set description = excluded.description, payload_schema = excluded.payload_schema;

update erp_ref.event_type set is_current = false where code = 'posting.class_changed' and version = 1;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.posting.item_class_changed',  'en', 'Item accounting code changed',  'finance'),
  ('event.posting.item_class_changed',  'de', 'Kontierung des Artikels geändert', 'finance'),
  ('event.posting.party_class_changed', 'en', 'Party accounting code changed', 'finance'),
  ('event.posting.party_class_changed', 'de', 'Kontierung des Partners geändert', 'finance')
on conflict (key, locale) do update set value = excluded.value;

do $events$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.erp_set_item_posting_class(uuid,uuid,text,date)'::regprocedure);
  if position('append_event(''posting.class_changed'', ''item''' in v_def) = 0 then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: erp_set_item_posting_class is not the body this migration patches';
  end if;
  execute replace(v_def, 'append_event(''posting.class_changed'', ''item''', 'append_event(''posting.item_class_changed'', ''item''');

  v_def := pg_get_functiondef('public.erp_set_party_posting_class(uuid,uuid,text,date)'::regprocedure);
  if position('append_event(''posting.class_changed'', ''party''' in v_def) = 0 then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: erp_set_party_posting_class is not the body this migration patches';
  end if;
  execute replace(v_def, 'append_event(''posting.class_changed'', ''party''', 'append_event(''posting.party_class_changed'', ''party''');
end
$events$;

create or replace function erp.record_status_literal_report()
returns table(schema_name text, function_name text, literal text)
language sql
stable
set search_path = ''
as $$
  -- A routine that writes a record_status literal the enum does not have. The
  -- statement fails when it is planned, so such a door refuses every call.
  select n.nspname::text, p.proname::text, m[1]
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, 'status = ''([a-z_]+)''', 'g') as m
   where n.nspname in ('public', 'erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_ingress')
     and m[1] = 'retired'
     and not exists (select 1 from pg_enum e where e.enumtypid = 'erp.record_status'::regtype and e.enumlabel = m[1])
   order by 1, 2;
$$;

create or replace function erp.assert_record_status_literals_exist()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_bad text;
begin
  select string_agg(schema_name || '.' || function_name, ', ' order by schema_name, function_name)
    into v_bad from erp.record_status_literal_report();
  if v_bad is not null then
    raise exception 'CLOVEERP_STATUS_LITERAL_UNKNOWN: % write a record_status the enum does not have; use inactive or archived', v_bad
      using errcode = 'P0001';
  end if;
  return 'record status literals: every routine writes a value the enum has';
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('record_status_literals', 'A door writes only statuses the enum has', 'assertion', 'platform',
   'assert_record_status_literals_exist', '', 'record_status_literal_report', '',
   'A record_status literal the enum lacks fails when the statement is planned, so the door refuses every call it receives while looking like a refusal. Five doors did this until 6 September 2026.', true, 99)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. D19 to D33, registered and bound
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, supersedes, spec_reference) values
  ('D19', 19, 'All outbound writes pass through one gateway',
   'Commands carry idempotency keys, approval state, dry-run capability and per-scope flags; no module holds credentials or calls an external system directly. An outcome that is unknown enters an explicit ambiguous state rather than being retried blindly.',
   'A bad write to a live external system is the highest-consequence failure the platform can cause.',
   'Every integration is a command, never a call; the worker is the only process that touches a credential.', null, 'v1.2 Part 23 D19'),
  ('D20', 20, 'Capabilities are switchable, and cannot be switched off dishonestly',
   'Behaviour arrives as named capabilities, effective-dated and switched through change sets, gating navigation, fields and rules together. A capability with live data cannot be disabled; the attempt is refused with a named reason.',
   'Comprehensiveness is only tolerable if unused capability is genuinely absent rather than hidden.',
   'A capability registry, dependencies and guards on every switch.', null, 'v1.2 Part 23 D20'),
  ('D21', 21, 'Starter content is neutral by construction, and neutrality is a release gate',
   'Packs derive from published standards, statutory structures or generic practice. No artefact derived from a live organisation enters product content; every value carries a provenance note.',
   'It is what makes the product genuinely reusable, and a value without a source is a guess.',
   'Provenance on every row and a gate that refuses a pack without it.', null, 'v1.2 Part 23 D21'),
  ('D22', 22, 'Model names are stable; product language is data',
   'The schema keeps tenant, party, item, principal. The product surface says organisation, business partner, product, user.',
   'Renaming tables costs migrations and buys nothing, while renaming on screen costs a glossary entry.',
   'Every screen word goes through the resource layer.', null, 'v1.2 Part 23 D22'),
  ('D24', 24, 'Confirmation in the warehouse is by scan, not by tap',
   'Every operational confirmation on a device is made by scanning the thing being confirmed — the location, the product, the handling unit. A tap is an exception that carries a reason.',
   'A tap confirms what the screen shows; a scan confirms what is in the hand.',
   'Scan rules per task, and a keyed entry that must say why.', null, 'v1.2 Part 23 D24'),
  ('D25', 25, 'One output subsystem produces everything the platform emits',
   'Documents, labels, emails, notifications and machine messages share one template model, one render record, one delivery record and one archive.',
   'Separate paths produce separate template systems, and then a document exists in three versions with no authoritative copy.',
   'Every channel renders through the same model.', null, 'v1.2 Part 23 D25'),
  ('D26', 26, 'An output template is not promotable until it has been proved',
   'Every template ships with a rendered sample against representative data, and every label additionally with a decode check.',
   'A label that will not scan is not a cosmetic defect; it stops the operation.',
   'A proof per template before promotion.', null, 'v1.2 Part 23 D26'),
  ('D27', 27, 'Down migrations are not written',
   'Schema reversal is a new forward migration; a pushed migration is immutable and CI refuses an edit to one.',
   'A down migration is tested once and then relied upon at the worst possible moment.',
   'Reversing a schema change takes as much care as making it.', null, 'v1.2 Part 23 D27'),
  ('D28', 28, 'A backup that has never been restored is a hope',
   'Restore is proved by scheduled drill into an isolated environment, verified by running the invariant assertions against the restored data.',
   'Backup success logs record that a file was written, not that a business can be recovered.',
   'A drill on a schedule, and a register that reads never drilled until it has.', null, 'v1.2 Part 23 D28'),
  ('D29', 29, 'An organisation that cannot pay can still read and export',
   'The restricted state refuses writes and retains reads and export.',
   'Withholding a customer''s own records is not a collection method, and the portability obligation does not lapse with an invoice.',
   'Entitlement checks distinguish read from write.', null, 'v1.2 Part 23 D29'),
  ('D30', 30, 'Reports are scoped by the same rules as screens',
   'Row-level scoping lives in the governed view, not in the report definition.',
   'A report must never become the route to data an operational screen would refuse.',
   'Every report reads a governed view.', null, 'v1.2 Part 23 D30'),
  ('D31', 31, 'A migration is complete when it reconciles, not when it runs',
   'Every load produces a reconciliation of record counts, quantity sums and value sums against source, and every batch is reversible while untouched.',
   'The most expensive migration defects are the ones that loaded successfully and wrongly.',
   'Control totals on every load.', null, 'v1.2 Part 23 D31'),
  ('D32', 32, 'Cutover is evidence-gated, per domain',
   'A domain moves when its parallel-run reconciliation has been clean for a stated period, not when a planned date arrives, and each domain carries its own rollback.',
   'A date is a wish; a clean reconciliation is a fact.',
   'A gate per domain that reads the reconciliation history.', null, 'v1.2 Part 23 D32'),
  ('D33', 33, 'Accessibility defects are defects',
   'WCAG 2.2 AA is the standard for the desk application, and failures are triaged on the ordinary severity scale.',
   'A separate accessibility backlog is a backlog that never clears.',
   'An accessibility register the build reads.', null, 'v1.2 Part 23 D33')
on conflict (code) do update
  set title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
      cost = excluded.cost, spec_reference = excluded.spec_reference;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D19', 'erp', 'assert_gateway_integrity', 'Every outbound write is a command with an idempotency key, approval state and dry-run capability; the gateway''s invariants hold on every build.'),
  ('D19', 'erp_test', 'assert_gateway_suite', 'The gateway suite exercises claim, complete, fail, dry run and approval on the command queue.'),
  ('D20', 'erp', 'assert_capabilities_sound', 'Capabilities are effective-dated, dependency-checked, and refuse to switch off over live data.'),
  ('D21', 'erp', 'assert_packs_installable', 'Every starter pack installs from neutral inputs and carries its decisions.'),
  ('D21', 'erp', 'assert_legislation_provenance', 'Every legislation value names the statute or notice it was read from.'),
  ('D22', 'erp', 'assert_vocabulary_aligned', 'The product surface speaks the prescribed vocabulary; the schema keeps its own names.'),
  ('D24', 'erp', 'assert_device_operations_sound', 'Every device task confirms by scan, with scan rules and a reason for a keyed entry.'),
  ('D25', 'erp', 'assert_output_integrity', 'Every channel renders through one template model with one render and delivery record.'),
  ('D26', 'erp', 'assert_output_templates_sound', 'Every template has a rendered sample and every label a decode check before promotion.'),
  ('D27', 'erp', 'assert_release_integrity', 'Releases are forward-only; supabase/ci/migrations_immutable.sh refuses an edited migration in CI.'),
  ('D28', 'erp', 'assert_release_integrity', 'Recovery is recorded in the release register; the restore drill (Phase 6) writes erp_meta.restore_drill and continuity reads it.'),
  ('D29', 'erp', 'assert_entitlements_enforceable', 'A restricted organisation keeps reads and export; writes refuse by name.'),
  ('D30', 'erp', 'assert_governed_views_are_safe', 'Every report reads a governed view that scopes rows as the screens do.'),
  ('D31', 'erp', 'assert_migration_sound', 'Every load reconciles counts, quantities and values against source and is reversible while untouched.'),
  ('D32', 'erp', 'assert_migration_sound', 'Cutover per domain is gated on a clean parallel-run reconciliation, with its own rollback.'),
  ('D33', 'erp', 'assert_accessibility_register_sound', 'Accessibility findings live in the ordinary register with the ordinary severities.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- The completeness clause reads the register's own bound, not a constant.
create or replace function erp.decision_enforcement_report()
returns table(decision_code text, finding text, detail text)
language sql
stable
set search_path = ''
as $$
  select d.code, 'no check enforces this decision', d.title
    from erp_ref.product_decision d
   where not exists (select 1 from erp_ref.product_decision_check c where c.decision_code = d.code)
  union all
  select c.decision_code, 'the check named does not exist', c.schema_name || '.' || c.routine_name
    from erp_ref.product_decision_check c
   where not exists (
     select 1 from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = c.schema_name and p.proname = c.routine_name)
  union all
  select 'D' || g::text, 'the specification names this decision and the register does not',
         format('the register runs D1 to D%s; a gap means a decision was dropped rather than revisited', (select max(seq) from erp_ref.product_decision))
    from generate_series(1, (select max(seq) from erp_ref.product_decision)) g
   where not exists (select 1 from erp_ref.product_decision d where d.code = 'D' || g::text)
  order by 1, 2
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suites
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.effects_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_e1 uuid; v_site uuid; v_supplier uuid; v_item uuid;
  v_tr uuid; v_po uuid; v_po2 uuid; v_cs uuid; v_ver uuid;
  v_payload jsonb;
  v_n integer; v_m integer;
  v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-effects', 'Effects suite', 'admin@zz-effects.test', 'Effects Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e4', 'admin@zz-effects.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000e4')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_e1 from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;

  -- The purchase order machine's submit transition, as the (re-emitted) installer wrote it.
  select t.id into v_tr
    from erp.transition t
    join erp.state_machine_version v on v.id = t.state_machine_version_id and v.status = 'active'
    join erp.state_machine m on m.id = v.state_machine_id
   where m.tenant_id = v_tenant and m.code = 'purchase_order' and t.code = 'submit';

  -- 1. The installer declared the approval request, and it is requested exactly once.
  v_cases := v_cases + 1;
  v_po := erp.open_document('purchase_order', v_supplier, v_e1, v_site);
  perform erp.add_document_line(v_po, v_item, 1, 1000, 'effects suite');
  perform erp.transition_document(v_po, 'submit', 'effects suite');
  v_n := (select count(*) from erp.approval_request ar where ar.tenant_id = v_tenant and ar.object_type = 'document' and ar.object_id = v_po);
  case_name := 'the installer''s submit transition declares require_approval, and one approval request is raised, not two';
  passed := exists (select 1 from erp.transition t where t.id = v_tr
                     and exists (select 1 from jsonb_array_elements(t.effects) e where e ->> 'kind' = 'require_approval'))
        and v_n = 1;
  detail := format('declared: %s; %s approval request(s) (expected 1)',
                   exists (select 1 from erp.transition t where t.id = v_tr and exists (select 1 from jsonb_array_elements(t.effects) e where e ->> 'kind' = 'require_approval')), v_n);
  return next;

  -- A second version of the machine, promoted the way an organisation would:
  -- the active version's states and transitions, with effects declared on
  -- submit and an entry action on pending_approval.
  select jsonb_build_object(
           'code', 'purchase_order', 'object_type', 'document', 'name', 'Purchase order',
           'states', (select jsonb_agg(jsonb_build_object('code', st.code, 'name', st.name, 'is_initial', st.is_initial,
                                                          'is_terminal', st.is_terminal, 'is_committed', st.is_committed,
                                                          'sort_order', st.sort_order,
                                                          'on_enter', case when st.code = 'pending_approval'
                                                                           then '[{"kind":"run_handler","handler_code":"platform.reclaim_expired_commands"}]'::jsonb
                                                                           else '[]'::jsonb end)
                                       order by st.sort_order)
                        from erp.state st where st.state_machine_version_id = v.id),
           'transitions', (select jsonb_agg(jsonb_build_object('code', tr.code, 'name', tr.name,
                                                               'from', (select f.code from erp.state f where f.id = tr.from_state_id),
                                                               'to', (select tt.code from erp.state tt where tt.id = tr.to_state_id),
                                                               'required_permission', tr.required_permission, 'sort_order', tr.sort_order,
                                                               'effects', case when tr.code = 'submit' then '[
                                                                  {"kind":"require_approval"},
                                                                  {"kind":"emit_event","payload":{"note":"submitted"}},
                                                                  {"kind":"notify","message_key":"notify.approval_requested.subject","severity":"low"},
                                                                  {"kind":"set_attribute","path":"workflow.submitted","value":true}]'::jsonb
                                                                  else coalesce(tr.effects, '[]'::jsonb) end)
                                            order by tr.sort_order, tr.code)
                             from erp.transition tr where tr.state_machine_version_id = v.id))
    into v_payload
    from erp.state_machine_version v
    join erp.state_machine m on m.id = v.state_machine_id
   where m.tenant_id = v_tenant and m.code = 'purchase_order' and v.status = 'active';

  -- 2. Promoted, the transition emits, notifies, writes and asks once.
  v_cases := v_cases + 1;
  v_cs := erp.create_change_set('zz-effects-v2', 'Effects on the purchase order lifecycle', 'What submit does.', null);
  perform erp.add_change_set_item(v_cs, 'state_machine', 'purchase_order', v_payload, 'upsert'::erp.change_operation, null, null);
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  v_po2 := erp.open_document('purchase_order', v_supplier, v_e1, v_site);
  perform erp.add_document_line(v_po2, v_item, 2, 1000, 'effects suite two');
  perform erp.transition_document(v_po2, 'submit', 'effects suite');
  case_name := 'a promoted transition emits its event, asks for somebody to be told, writes the attribute it declared, and requests approval once';
  passed := exists (select 1 from erp.event ev where ev.tenant_id = v_tenant and ev.event_type = 'workflow.transitioned'
                       and ev.aggregate_id = v_po2 and ev.payload ->> 'transition' = 'submit' and ev.payload ->> 'note' = 'submitted')
        and exists (select 1 from erp.event ev where ev.tenant_id = v_tenant and ev.event_type = 'workflow.notified'
                       and ev.aggregate_id = v_po2 and ev.payload ->> 'message_key' = 'notify.approval_requested.subject')
        and (select d.attributes #>> '{workflow,submitted}' from erp.document d where d.id = v_po2) = 'true'
        and (select count(*) from erp.approval_request ar where ar.object_type = 'document' and ar.object_id = v_po2) = 1;
  detail := format('transitioned event: %s; notified event: %s; attribute: %s; approval requests: %s',
                   exists (select 1 from erp.event ev where ev.event_type = 'workflow.transitioned' and ev.aggregate_id = v_po2),
                   exists (select 1 from erp.event ev where ev.event_type = 'workflow.notified' and ev.aggregate_id = v_po2),
                   (select d.attributes #>> '{workflow,submitted}' from erp.document d where d.id = v_po2),
                   (select count(*) from erp.approval_request ar where ar.object_type = 'document' and ar.object_id = v_po2));
  return next;

  -- 3. The entry action ran, and the old document kept its version.
  v_cases := v_cases + 1;
  case_name := 'the to-state''s entry action ran a SQL handler; the new document follows the new version and the earlier one keeps its own';
  passed := exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
                     where os.object_type = 'document' and os.object_id = v_po2 and s.code = 'pending_approval')
        and (select v2.version from erp.object_state os join erp.state_machine_version v2 on v2.id = os.state_machine_version_id
              where os.object_type = 'document' and os.object_id = v_po2)
          > (select v1.version from erp.object_state os join erp.state_machine_version v1 on v1.id = os.state_machine_version_id
              where os.object_type = 'document' and os.object_id = v_po);
  detail := format('new document on version %s, earlier one on version %s',
                   (select v2.version from erp.object_state os join erp.state_machine_version v2 on v2.id = os.state_machine_version_id where os.object_type = 'document' and os.object_id = v_po2),
                   (select v1.version from erp.object_state os join erp.state_machine_version v1 on v1.id = os.state_machine_version_id where os.object_type = 'document' and os.object_id = v_po));
  return next;

  -- 4. An unknown kind is refused at promotion, and the change set does not land.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    v_cs := erp.create_change_set('zz-effects-bad', 'A kind nobody knows', 'teleport', null);
    perform erp.add_change_set_item(v_cs, 'state_machine', 'purchase_order',
      jsonb_set(v_payload, '{transitions,0,effects}', '[{"kind":"teleport"}]'::jsonb),
      'upsert'::erp.change_operation, null, null);
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    begin
      perform erp.promote_change_set(v_cs);
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an effect of a kind the executor does not know is refused by name when it is promoted';
  passed := coalesce(v_msg like '%CLOVEERP_EFFECT_UNKNOWN:%' and v_msg like '%teleport%', false)
        and erp.checked_effects('[{"kind":"require_approval"}]'::jsonb, 'x') = '[{"kind":"require_approval"}]'::jsonb;
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 5. And at execution, should one ever be handed to the executor.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform erp.execute_effects('document', v_po2, '[{"kind":"teleport"}]'::jsonb, '{}'::jsonb, v_e1, v_site, 'submit', 'draft', 'pending_approval');
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'the executor refuses an unknown effect kind by name';
  passed := coalesce(v_msg like 'CLOVEERP_EFFECT_UNKNOWN:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 6. The dead-configuration report: a declaration is not dead; an unknown kind is.
  v_cases := v_cases + 1;
  v_n := (select count(*) from erp.dead_configuration_report() r where r.finding like '%effect%');
  v_msg := null;
  begin
    -- A draft version may be written directly; only an active one is protected.
    insert into erp.state_machine_version (tenant_id, state_machine_id, version, status, effective_from, note)
    select v_tenant, m.id, 99, 'draft', current_date, 'effects suite'
      from erp.state_machine m where m.tenant_id = v_tenant and m.code = 'purchase_order'
    returning id into v_ver;
    insert into erp.state (tenant_id, state_machine_version_id, code, name, is_initial, sort_order)
    values (v_tenant, v_ver, 'a', 'A', true, 10), (v_tenant, v_ver, 'b', 'B', false, 20);
    insert into erp.transition (tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id, guard, effects)
    values (v_tenant, v_ver, 'go', 'Go',
            (select id from erp.state where state_machine_version_id = v_ver and code = 'a'),
            (select id from erp.state where state_machine_version_id = v_ver and code = 'b'),
            'true'::jsonb, '[{"kind":"teleport"}]'::jsonb);
    v_m := (select count(*) from erp.dead_configuration_report() r where r.finding like '%effect kind the executor does not know%');
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := sqlerrm; end if;
  end;
  case_name := 'the dead-configuration report no longer flags declared effects, and flags an unknown kind';
  passed := v_n = 0 and v_m = 1 and v_msg is null;
  detail := format('%s effect finding(s) with known kinds (expected 0); %s with an unknown kind (expected 1)%s', v_n, v_m, coalesce('; ' || left(v_msg, 100), ''));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 7. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-effects')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000e4');
  detail := 'zz-effects rolled back';
  return next;

  if v_cases <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: effects_suite ran % cases, expected 7', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_effects_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _effects on commit drop as
    select * from erp_test.effects_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _effects;
  drop table _effects;
  if v_fail > 0 then
    raise exception E'CLOVEERP_EFFECTS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: effects_suite ran % cases, expected 7', v_all;
  end if;
  return format('effects: %s/%s cases passed', v_all, v_all);
end;
$$;

create or replace function erp_test.policy_closure_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_e1 uuid; v_site uuid; v_supplier uuid; v_item uuid; v_acct uuid; v_gl uuid; v_class uuid;
  v_cs uuid; v_doc uuid; v_line uuid;
  v_n integer; v_m integer; v_k integer;
  v_code text; v_msg text;
  res jsonb;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-policy', 'Policy closure suite', 'admin@zz-policy.test', 'Policy Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e5', 'admin@zz-policy.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000e5')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_e1 from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;

  -- 1. A print route promotes and is captured.
  v_cases := v_cases + 1;
  perform public.erp_upsert_printer('ZZ-PRN', v_site, 'Dock printer', 'label', 'zpl', 203, 'Dock 1', '4x6', 'ipp://dock-1.local/labels');
  v_cs := erp.create_change_set('zz-print-routes', 'Print routes', 'Where labels go.', null);
  perform erp.add_change_set_item(v_cs, 'print_route', 'dock_labels',
    jsonb_build_object('code', 'dock_labels', 'output_kind', 'label', 'printer', 'ZZ-PRN',
                       'site', (select s.code from erp.site s where s.id = v_site), 'priority', 10),
    'upsert'::erp.change_operation, null, null);
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  case_name := 'a print route arrives by promotion and the manifest reads it back';
  passed := exists (select 1 from erp.print_route pr where pr.tenant_id = v_tenant and pr.code = 'dock_labels' and pr.status = 'active' and pr.site_id = v_site)
        and exists (select 1 from erp.configuration_manifest() m where m.object_kind = 'print_route' and m.object_key = 'dock_labels'
                     and m.content ->> 'printer' = 'ZZ-PRN');
  detail := format('route present: %s; in manifest: %s',
                   exists (select 1 from erp.print_route pr where pr.tenant_id = v_tenant and pr.code = 'dock_labels'),
                   exists (select 1 from erp.configuration_manifest() m where m.object_kind = 'print_route' and m.object_key = 'dock_labels'));
  return next;

  -- 2. Count generation raises once and then waits.
  v_cases := v_cases + 1;
  v_doc := erp.open_document('goods_receipt', v_supplier, v_e1, v_site);
  perform erp.add_document_line(v_doc, v_item, 10, 1000, 'stock to count');
  perform erp.transition_document(v_doc, 'post', 'policy suite');
  v_n := erp.generate_count_tasks('{}'::jsonb);
  v_m := erp.generate_count_tasks('{}'::jsonb);
  case_name := 'the count generation handler raises tasks from the programme and raises none while they are open';
  passed := v_n > 0 and v_m = 0;
  detail := format('first run raised %s, second run %s (expected 0)', v_n, v_m);
  return next;

  -- 3. A determined posting line resolves through account determination.
  v_cases := v_cases + 1;
  select a.id into v_acct from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_e1 and a.code = '5900';
  select l.id into v_gl from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_e1 and l.code = 'GL';
  -- Determination reads the item's posting class, so the item gets one first.
  v_class := (public.erp_upsert_posting_class('item', 'HW', 'Hardware', null, null) ->> 'posting_class_id')::uuid;
  perform public.erp_set_item_posting_class(v_item, v_class, 'policy suite', null);
  perform public.erp_upsert_account_determination('receipt', v_acct, v_class, null, null, v_e1, null, null, null, null, 'policy suite', null);
  v_code := erp.posting_line_account_code(jsonb_build_object('account', 'determined', 'transaction_type', 'receipt'), v_doc, v_gl);
  case_name := 'a posting line that says determined resolves to the account the determination matrix names';
  passed := v_code = '5900'
        and erp.posting_line_account_code(jsonb_build_object('account', '1200'), v_doc, v_gl) = '1200';
  detail := format('determined → %s (expected 5900); a named account passes through', coalesce(v_code, 'null'));
  return next;

  -- 4. The four decisions are closed, and the register reads them.
  v_cases := v_cases + 1;
  v_k := (select count(*) from erp_meta.policy_decision where status = 'open');
  case_name := 'no policy decision is left open, and the four closed here carry evidence';
  passed := v_k = 0
        and (select count(*) from erp_meta.policy_decision where code in ('count_schedule_generation', 'intelligence_boundary_reads_source_text',
                                                                            'notification_routes_outside_promotion', 'two_account_selection_mechanisms')
               and status = 'accepted' and coalesce(evidence, '') <> '') = 4;
  detail := format('%s open decision(s)', v_k);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 5. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-policy')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000e5');
  detail := 'zz-policy rolled back';
  return next;

  if v_cases <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: policy_closure_suite ran % cases, expected 5', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_policy_closure_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _policy_closure on commit drop as
    select * from erp_test.policy_closure_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _policy_closure;
  drop table _policy_closure;
  if v_fail > 0 then
    raise exception E'CLOVEERP_POLICY_CLOSURE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: policy_closure_suite ran % cases, expected 5', v_all;
  end if;
  return format('policy closure: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6b. Two suites that this file changed the ground under
-- ─────────────────────────────────────────────────────────────────────────────
-- erp_test.output_channels_suite() closes its organisation's bootstrap window
-- deliberately, to test notification routes under the live guard, and then
-- writes two print routes straight through the door. Print routes are
-- promotable from this file on, so the live guard now refuses that, as it
-- should; the suite reopens the window around those two writes, with the
-- helpers it already uses, and closes it again. erp_test.policy_register_suite()
-- pinned one named decision as the register's open example; that decision is
-- accepted here, so the suite now plants an open decision of its own and removes
-- it, and the two cases keep meaning what they meant.
do $suites$
declare
  v_def text;
  v_routes text := E'perform erp.upsert_print_route(''labels_dc1'', ''label'', ''LBL203'', null, v_site);\n'
                || E'  perform erp.upsert_print_route(''labels_bench2'', ''label'', ''LBL300'', null, v_site, ''BENCH-2'');';
begin
  v_def := pg_get_functiondef('erp_test.output_channels_suite()'::regprocedure);
  if position(v_routes in v_def) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.output_channels_suite is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_routes,
    E'perform erp_test.reopen_bootstrap_window(v_tenant);\n  ' || v_routes
    || E'\n  perform erp_test.close_bootstrap_window(v_tenant);');
  execute v_def;

  v_def := pg_get_functiondef('erp_test.policy_register_suite()'::regprocedure);
  if position('where d.value ->> ''code'' = ''two_account_selection_mechanisms'') = ''open''' in v_def) = 0
     or position(E'  res := public.erp_platform_policy_decisions();' in v_def) = 0
     or position('delete from erp_meta.platform_staff where email = ''support@zzpolicy.test'';' in v_def) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.policy_register_suite is not the body this migration patches';
  end if;
  v_def := replace(v_def, E'  res := public.erp_platform_policy_decisions();',
    E'  insert into erp_meta.policy_decision (code, title, decision, rationale, status)\n'
    || E'  values (''zz_policy_suite_open'', ''The suite''''s own open question'', ''Not yet decided.'',\n'
    || E'          ''Planted by erp_test.policy_register_suite() so the register always has one open question to order first; removed at the end.'', ''open'');\n'
    || E'  res := public.erp_platform_policy_decisions();');
  v_def := replace(v_def, 'where d.value ->> ''code'' = ''two_account_selection_mechanisms'') = ''open''',
                          'where d.value ->> ''code'' = ''zz_policy_suite_open'') = ''open''');
  v_def := replace(v_def, 'delete from erp_meta.platform_staff where email = ''support@zzpolicy.test'';',
    E'delete from erp_meta.policy_decision where code = ''zz_policy_suite_open'';\n'
    || E'  delete from erp_meta.platform_staff where email = ''support@zzpolicy.test'';');
  execute v_def;
end
$suites$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- Schedule what this host can run, and record what it cannot.
select erp.ensure_platform_schedule();

select erp.assert_platform_scheduled();
select erp.assert_record_status_literals_exist();
select erp_test.assert_effects_suite();
select erp_test.assert_policy_closure_suite();
select erp_test.assert_output_channels_suite();
select erp_test.assert_policy_register_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_notification_chain_suite();
select erp_test.assert_superadmin_suite();
select erp_test.assert_promotion_completeness_suite();
select erp_test.assert_gateway_suite();
select erp_test.assert_procurement_suite();
select erp_test.assert_sales_suite();
select erp_test.assert_second_organisation_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_scheduler_integrity();
select erp.assert_job_handlers_resolvable();
select erp.assert_determination_coverage();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
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
