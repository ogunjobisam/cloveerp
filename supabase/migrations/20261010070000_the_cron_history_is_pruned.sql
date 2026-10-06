set lock_timeout = '30s';

-- =============================================================================
-- 20261010070000  The cron history is pruned
-- -----------------------------------------------------------------------------
-- Found reading production's storage, 6 October. pg_cron writes a row to
-- cron.job_run_details for every run of every job, and nothing ever deletes
-- one. Two jobs run every minute: clove-jobs (erp.run_due_jobs_all_tenants())
-- and clove-dispatch (the net.http_post to the dispatch function), which is
-- 2,880 rows a day. The table was about 24.5 MB and grows without bound.
--
-- The platform already schedules its own jobs one way, and this follows it:
-- erp.ensure_platform_schedule() (20260906100000) schedules with pg_cron where
-- the host has it, records in erp_meta.platform_schedule what it scheduled or
-- why it could not, and erp.platform_schedule_report() / the platform_scheduled
-- check (seq 98, which the deploy's "Prove the live database" step runs) treat
-- a register that disagrees with the host's cron as a finding.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.ensure_cron_history_pruned(), trusted sessions only. Where the host
--      has pg_cron it schedules one named job, clove-cron-history, at 03:17
--      UTC every day:
--
--        delete from cron.job_run_details where end_time < now() - interval '7 days'
--
--      Idempotent without churn: when exactly one job of that name exists,
--      active, on that clock and with that command, it is left alone under its
--      id; otherwise every job of that name is unscheduled and one is
--      scheduled. Re-running this migration or the function never adds a
--      second job. Where the host has no pg_cron (the local cluster, and the
--      build's database, where pg_cron is available but only installable in
--      the database named by cron.database_name) it schedules nothing and
--      records why. Either way the register has a row for it.
--   B. erp.ensure_platform_schedule() calls it, so the operator's door
--      (erp_platform_ensure_schedule) and the deploy's dispatch step, which
--      re-run the platform's schedule, keep the pruning with it.
--   C. erp.platform_schedule_report(): where the host has pg_cron, history
--      that is never pruned is a finding, and so is anything but exactly one
--      job of that name, active, on the recorded clock with the recorded
--      command. A job with no active run at all is already found by the loop
--      above it. erp.assert_platform_scheduled() says each job's clock rather
--      than "every minute" for all of them.
--   D. erp_test.cron_history_pruned_suite, seven cases, and its assertion.
--      The case that runs the delete runs the recorded command against a
--      stand-in for cron.job_run_details, so it proves the predicate on every
--      host and touches no real history.
--   E. The migration schedules it, then proves from the report that where
--      the host has pg_cron the job is there exactly once as recorded. It
--      asks the report about this job only: the deploy pauses the minute jobs
--      for the length of the replay, so the whole report disagrees until
--      "Start the scheduler again" has run.
--
-- ── SIZE ──────────────────────────────────────────────────────────────────────
--
-- One DELETE in one statement is enough at this size. A week at two jobs a
-- minute is about 20,000 rows; each night removes about 2,900. The first night
-- removes everything older than a week, at most the whole 24.5 MB, which is a
-- sequential scan of a table that small and finishes in seconds on a Small
-- instance. No index is added to the cron schema: it is pg_cron's, and a scan
-- of a week's history once a night does not need one. The space is not handed
-- back to the operating system (that would take a VACUUM FULL, which locks the
-- table cron writes to every minute); autovacuum makes it reusable, so the
-- table stops growing at about a week of history.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- clove-jobs and clove-dispatch are not touched or renumbered. No door,
-- permission, refusal, screen string or table changes. The pruning job runs
-- as the role that applies the migration (postgres on production), which owns
-- both minute jobs and so sees their history.
--
-- On production: one cron job is added, one register row is written, three
-- functions are replaced and two added. No row of any organisation is touched.
-- The first run deletes run history older than seven days.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The pruning job
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.ensure_cron_history_pruned()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_code     constant text := 'clove-cron-history';
  c_expr     constant text := '17 3 * * *';
  c_cmd      constant text := $c$delete from cron.job_run_details where end_time < now() - interval '7 days'$c$;
  v_has_cron boolean;
  v_jobs     integer;
  v_same     integer;
  v_jobid    bigint;
  v_old      bigint;
  v_reason   text;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not schedule the platform', current_user
      using errcode = '42501',
            hint = 'Run it from a trusted session: the migration, the deploy, or erp_platform_ensure_schedule as a platform operator.';
  end if;

  select exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') into v_has_cron;

  if v_has_cron then
    execute 'select count(*)::integer,
                    (count(*) filter (where j.active and j.schedule = $2 and j.command = $3))::integer,
                    min(j.jobid)
               from cron.job j where j.jobname = $1'
       into v_jobs, v_same, v_jobid using c_code, c_expr, c_cmd;
    if not (v_jobs = 1 and v_same = 1) then
      for v_old in execute 'select j.jobid from cron.job j where j.jobname = $1' using c_code loop
        execute 'select cron.unschedule($1)' using v_old;
      end loop;
      execute 'select cron.schedule($1, $2, $3)' into v_jobid using c_code, c_expr, c_cmd;
    end if;
    v_reason := 'scheduled with pg_cron: run history older than 7 days is deleted at 03:17 UTC';
    insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
    values (c_code, c_expr, c_cmd, true, v_jobid, v_reason, now())
    on conflict (code) do update
      set cron_expression = excluded.cron_expression, command = excluded.command, is_scheduled = true,
          cron_jobid = excluded.cron_jobid, reason = excluded.reason, checked_at = now();
  else
    v_reason := 'not scheduled: pg_cron is not installed in this database, so there is no run history to prune';
    insert into erp_meta.platform_schedule (code, cron_expression, command, is_scheduled, cron_jobid, reason, checked_at)
    values (c_code, c_expr, c_cmd, false, null, v_reason, now())
    on conflict (code) do update
      set cron_expression = excluded.cron_expression, command = excluded.command, is_scheduled = false,
          cron_jobid = null, reason = excluded.reason, checked_at = now();
  end if;

  return v_reason;
end;
$$;

revoke all on function erp.ensure_cron_history_pruned() from public, anon, authenticated;

comment on function erp.ensure_cron_history_pruned() is
  'Schedules clove-cron-history with pg_cron where the host has it: at 03:17 UTC every day, delete from '
  'cron.job_run_details the run history that ended more than 7 days ago (20261010070000). Exactly one job of that '
  'name: one already scheduled as recorded is left under its id, anything else is replaced. Where the host has no '
  'pg_cron it records why in erp_meta.platform_schedule. Trusted sessions only; erp.ensure_platform_schedule() calls it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The platform's schedule keeps the pruning with it
-- ─────────────────────────────────────────────────────────────────────────────

do $ensure$
declare
  v_sig  constant text := 'erp.ensure_platform_schedule(text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$
  return v_out;
end;
$o$;
  v_new  constant text := $n$
  -- The run history pg_cron keeps of every job, pruned nightly (20261010070000).
  v_out := v_out || jsonb_build_object('clove-cron-history', erp.ensure_cron_history_pruned());

  return v_out;
end;
$n$;
begin
  if strpos(v_src, '20261010070000') > 0 then
    raise notice '% already schedules the history pruning; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '64ce165422b509bea81b075f89ed53d7' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010070000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$ensure$;

revoke all on function erp.ensure_platform_schedule(text, text) from public, anon, authenticated;

comment on function erp.ensure_platform_schedule(text, text) is
  'Schedules what the host can run and records what it cannot in erp_meta.platform_schedule: clove-jobs '
  '(erp.run_due_jobs_all_tenants(), every minute), clove-dispatch (the signed post to the dispatch function, every '
  'minute, once given its URL) and clove-cron-history (the nightly pruning of pg_cron''s run history, 20261010070000). '
  'Trusted sessions only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The report finds history that is never pruned
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig  constant text := 'erp.platform_schedule_report()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$
  end loop;
end;
$o$;
  v_new  constant text := $n$
  end loop;

  -- The run history is pruned (20261010070000): where the host has pg_cron,
  -- exactly one job of that name, active, on the recorded clock and command.
  -- No active job at all is found by the loop above, so it is not said twice.
  if v_has_cron then
    declare
      v_row    erp_meta.platform_schedule;
      v_jobs   integer;
      v_active integer;
      v_same   integer;
    begin
      select * into v_row from erp_meta.platform_schedule s where s.code = 'clove-cron-history';
      if v_row.code is null or not v_row.is_scheduled then
        finding := 'the host has pg_cron and its run history is never pruned';
        reference := 'clove-cron-history';
        detail := coalesce(v_row.reason, 'the register has no row for it: erp.ensure_cron_history_pruned() has not run');
        return next;
      else
        execute 'select count(*)::integer,
                        (count(*) filter (where j.active))::integer,
                        (count(*) filter (where j.active and j.schedule = $2 and j.command = $3))::integer
                   from cron.job j where j.jobname = $1'
           into v_jobs, v_active, v_same using v_row.code, v_row.cron_expression, v_row.command;
        if v_active > 0 and not (v_jobs = 1 and v_same = 1) then
          finding := 'the run history pruning is not scheduled exactly once as recorded';
          reference := v_row.code;
          detail := format('%s job(s) named %s, %s active, %s on %s with the recorded command',
                           v_jobs, v_row.code, v_active, v_same, v_row.cron_expression);
          return next;
        end if;
      end if;
    end;
  end if;
end;
$n$;
begin
  if strpos(v_src, '20261010070000') > 0 then
    raise notice '% already reads the history pruning; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '573b8f76966088dfb834e79169355eea' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010070000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$report$;

revoke all on function erp.platform_schedule_report() from public, anon, authenticated;

comment on function erp.platform_schedule_report() is
  'Read by erp.assert_platform_scheduled(). Findings: the platform was never asked to schedule itself; the register '
  'says a job is scheduled and the host''s cron has no active job of that name, or no pg_cron; the host has pg_cron '
  'and the job runner is not scheduled; the host has pg_cron and its run history is never pruned, or the pruning is '
  'not exactly one job on the recorded clock with the recorded command (20261010070000).';

do $assert$
declare
  v_sig  constant text := 'erp.assert_platform_scheduled()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$case when s.is_scheduled then 'every minute' else s.reason end$o$;
  v_new  constant text := $n$case when not s.is_scheduled then s.reason
                                                                   when s.cron_expression = '* * * * *' then 'every minute'
                                                                   else 'on ' || s.cron_expression || ' (UTC)' end$n$;
begin
  if strpos(v_src, $k$'on ' || s.cron_expression$k$) > 0 then
    raise notice '% already says each job''s clock; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ba1c18a2458aeddf7705a4bbc1119a89' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010070000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert$;

revoke all on function erp.assert_platform_scheduled() from public, anon, authenticated;

comment on function erp.assert_platform_scheduled() is
  'The platform runs on a clock, or says why it cannot: raises CLOVEERP_PLATFORM_NOT_SCHEDULED over any finding of '
  'erp.platform_schedule_report(), and otherwise names each job with its clock or the reason it is not scheduled.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.cron_history_pruned_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  c_code     constant text := 'clove-cron-history';
  c_expr     constant text := '17 3 * * *';
  c_cmd      constant text := $c$delete from cron.job_run_details where end_time < now() - interval '7 days'$c$;
  c_table    constant text := 'cron.job_run_details';
  v_cases    integer := 0;
  v_step     text := 'reading the host';
  v_state    text;
  v_owner    text := current_user;
  v_has_cron boolean;
  v_reg      erp_meta.platform_schedule;
  v_jobs     integer;
  v_same     integer;
  v_jobid    bigint;
  v_jobid2   bigint;
  v_out      jsonb;
  v_n        integer;
  v_found    text;
  v_tmp      text := 'zz_cron_history_' || substr(md5(gen_random_uuid()::text), 1, 6);
  v_left     text;
begin
  begin
    select exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') into v_has_cron;

    -- ── 1. The register names it ────────────────────────────────────────────
    v_step := 'the register';
    select * into v_reg from erp_meta.platform_schedule s where s.code = c_code;
    v_cases := v_cases + 1;
    case_name := 'the platform schedule register names the history pruning at 03:17 UTC with the plain delete of run history older than 7 days';
    passed := v_state is null and v_reg.code is not null and v_reg.cron_expression = c_expr and v_reg.command = c_cmd;
    detail := coalesce(v_state, format('%s | %s', v_reg.cron_expression, v_reg.command), 'no row for ' || c_code);
    return next;

    -- ── 2. The host has it once, or the register says why not ───────────────
    v_step := 'the host''s cron';
    if v_has_cron then
      execute 'select count(*)::integer,
                      (count(*) filter (where j.active and j.schedule = $2 and j.command = $3))::integer,
                      min(j.jobid)
                 from cron.job j where j.jobname = $1'
         into v_jobs, v_same, v_jobid using c_code, c_expr, c_cmd;
      passed := v_jobs = 1 and v_same = 1 and coalesce(v_reg.is_scheduled, false) and v_reg.cron_jobid = v_jobid;
      detail := format('pg_cron: %s job(s) named %s, %s active as recorded; the register says job %s',
                       v_jobs, c_code, v_same, coalesce(v_reg.cron_jobid::text, 'none'));
    else
      passed := not coalesce(v_reg.is_scheduled, true) and v_reg.cron_jobid is null
            and v_reg.reason like 'not scheduled:%pg_cron%';
      detail := 'no pg_cron: ' || coalesce(v_reg.reason, 'no reason recorded');
    end if;
    v_cases := v_cases + 1;
    case_name := 'where the host has pg_cron the pruning is one active job on the recorded clock and command; where it has none the register says so and why';
    passed := v_state is null and coalesce(passed, false);
    return next;

    -- ── 3. Scheduling again adds nothing ────────────────────────────────────
    v_step := 'scheduling again, twice';
    v_out := erp.ensure_platform_schedule();
    perform erp.ensure_cron_history_pruned();
    select count(*)::integer into v_n from erp_meta.platform_schedule s where s.code = c_code;
    if v_has_cron then
      execute 'select count(*)::integer, min(j.jobid) from cron.job j where j.jobname = $1'
         into v_jobs, v_jobid2 using c_code;
    else
      v_jobs := 0;
      v_jobid2 := null;
    end if;
    v_cases := v_cases + 1;
    case_name := 'scheduling again, through erp.ensure_platform_schedule() and directly, leaves one register row and at most one job, under the same id';
    passed := v_state is null and v_n = 1 and v_out ? c_code
          and case when v_has_cron then v_jobs = 1 and v_jobid2 = v_jobid else v_jobs = 0 end;
    detail := format('%s register row(s), %s job(s), job %s then %s; erp.ensure_platform_schedule() said %s',
                     v_n, v_jobs, coalesce(v_jobid::text, 'none'), coalesce(v_jobid2::text, 'none'),
                     coalesce(v_out ->> c_code, 'nothing about it'));
    return next;

    -- ── 4. A disagreement is a finding ──────────────────────────────────────
    v_step := 'a pruning job that disagrees with the register';
    if v_has_cron then
      execute 'select cron.alter_job($1, command := $2)' using v_jobid2, 'select 1';
    else
      update erp_meta.platform_schedule set is_scheduled = true, cron_jobid = 0 where code = c_code;
    end if;
    select count(*)::integer, string_agg(r.finding, '; ') into v_n, v_found
      from erp.platform_schedule_report() r where r.reference = c_code;
    v_cases := v_cases + 1;
    case_name := 'a pruning job that disagrees with the register is a finding of the platform schedule report';
    passed := v_state is null and v_n = 1
          and v_found = case when v_has_cron then 'the run history pruning is not scheduled exactly once as recorded'
                             else 'the register says scheduled and the host has no pg_cron' end;
    detail := coalesce(v_found, 'no finding');
    return next;

    -- ── 5. Scheduling again repairs it ──────────────────────────────────────
    v_step := 'scheduling repairs the disagreement';
    perform erp.ensure_cron_history_pruned();
    select count(*)::integer, string_agg(r.finding, '; ') into v_n, v_found
      from erp.platform_schedule_report() r where r.reference = c_code;
    if v_has_cron then
      execute 'select count(*)::integer from cron.job j where j.jobname = $1' into v_jobs using c_code;
    else
      v_jobs := 0;
    end if;
    v_cases := v_cases + 1;
    case_name := 'scheduling again puts a disagreeing pruning job back as recorded, once, and the report has nothing to say about it';
    passed := v_state is null and v_n = 0 and v_jobs = case when v_has_cron then 1 else 0 end;
    detail := format('%s job(s); %s', v_jobs, coalesce(v_found, 'no finding'));
    return next;

    -- ── 6. The recorded command deletes only what is older than a week ──────
    -- Against a stand-in shaped like cron.job_run_details, so the predicate is
    -- proved on every host and no real history is touched.
    v_step := 'the recorded command over a stand-in for the run history';
    select * into v_reg from erp_meta.platform_schedule s where s.code = c_code;
    if (length(v_reg.command) - length(replace(v_reg.command, c_table, ''))) / length(c_table) <> 1 then
      raise exception 'the recorded command does not name % exactly once: %', c_table, v_reg.command;
    end if;
    if v_has_cron then
      execute format('create temporary table %I (like cron.job_run_details)', v_tmp);
    else
      execute format('create temporary table %I (runid bigint not null, end_time timestamptz)', v_tmp);
    end if;
    execute format('insert into pg_temp.%I (runid, end_time) values '
                   '(1, now() - interval ''8 days''), (2, now() - interval ''6 days''), (3, null)', v_tmp);
    execute replace(v_reg.command, c_table, format('pg_temp.%I', v_tmp));
    execute format('select string_agg(runid::text, '','' order by runid) from pg_temp.%I', v_tmp) into v_left;
    v_cases := v_cases + 1;
    case_name := 'the recorded command deletes run history that ended more than 7 days ago and keeps the last week and any run still going';
    passed := v_state is null and v_left = '2,3';
    detail := 'left: ' || coalesce(v_left, 'nothing');
    return next;

    -- ── 7. Only a trusted session schedules it ──────────────────────────────
    v_step := 'an untrusted session';
    begin
      execute 'set local role authenticated';
      perform erp.ensure_cron_history_pruned();
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception
      when insufficient_privilege then
        v_found := sqlerrm;
      when others then
        v_found := case when sqlerrm = 'CLOVEERP_SUITE_UNDO' then 'it was accepted' else 'refused otherwise: ' || sqlerrm end;
    end;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a session that is not trusted cannot schedule the pruning';
    passed := v_state is null and v_found <> 'it was accepted' and v_found not like 'refused otherwise:%';
    detail := v_found;
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CRON_HISTORY_PRUNED_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read the step the fixture stopped at, or re-pin the count if a case was added on purpose.';
  end if;
end;
$$;

revoke all on function erp_test.cron_history_pruned_suite() from public, anon;

comment on function erp_test.cron_history_pruned_suite() is
  'pg_cron''s run history is pruned nightly (20261010070000): the register names clove-cron-history with its clock and '
  'command; where the host has pg_cron it is one active job as recorded, and where it has none the register says why; '
  'scheduling again adds nothing; a disagreement is a finding and scheduling again repairs it; the command deletes only '
  'history older than seven days; an untrusted session cannot schedule it.';

create or replace function erp_test.assert_cron_history_pruned_suite()
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
    from erp_test.cron_history_pruned_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CRON_HISTORY_PRUNED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'pg_cron''s run history is not pruned as recorded, or the report misses a pruning job that disagrees with the register. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_CRON_HISTORY_PRUNED_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('cron history pruned: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_cron_history_pruned_suite() from public, anon;

comment on function erp_test.assert_cron_history_pruned_suite() is
  'The nightly pruning of pg_cron''s run history is scheduled once as recorded where the host has pg_cron, says why '
  'not where it has none, and deletes only history older than seven days (20261010070000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Schedule it here, and prove it
-- ─────────────────────────────────────────────────────────────────────────────

select erp.ensure_cron_history_pruned();

-- This job only: the deploy pauses the minute jobs for the length of the
-- replay, so the rest of the report disagrees until they are started again.
do $proved$
declare
  v_n      integer;
  v_detail text;
begin
  select count(*), string_agg(format('%s [%s] %s', r.finding, r.reference, r.detail), E'\n')
    into v_n, v_detail
    from erp.platform_schedule_report() r
   where r.reference = 'clove-cron-history';
  if v_n > 0 then
    raise exception E'CLOVEERP_PLATFORM_NOT_SCHEDULED: % finding(s)\n%', v_n, v_detail
      using errcode = '23514',
            hint = 'Run erp.ensure_cron_history_pruned() from a trusted session and read cron.job for jobs named clove-cron-history.';
  end if;
end
$proved$;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
