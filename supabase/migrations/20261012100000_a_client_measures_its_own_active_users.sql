-- A client measures its own active users.
--
-- erp.measure_active_users() writes the active_users meter for every
-- organisation a database holds, and since 20261012080000 it runs daily from a
-- job in the platform's own organisation. A client's deployment has no
-- platform organisation, so nothing there ever ran it: the fleet poll reads
-- each client's erp_meta.usage_meter, found no active_users row, and the
-- Fleet view said "not measured" for every client.
--
-- On a client, the organisation the deployment holds is given the same job,
-- at the same time: daily at 05:30 UTC, handler
-- commercial.measure_active_users. erp.schedule_usage_measurement(tenant)
-- does it, and does nothing on the control plane or the demonstration (the
-- platform's job measures every organisation there). A trigger on erp.tenant
-- calls it as an organisation is made, as t_tenant_standard_roles gives each
-- organisation its roles; an organisation already held on a client is given
-- it below. A job already there keeps whether it is switched on.

create or replace function erp.schedule_usage_measurement(p_tenant_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_prior_tenant    text := current_setting('erp.job_tenant_id', true);
  v_prior_principal text := current_setting('erp.job_principal_id', true);
  v_enabled         boolean;
begin
  if erp.deployment_kind() <> 'client' or p_tenant_id is null then
    return;
  end if;

  select j.is_enabled into v_enabled
    from erp.job j where j.tenant_id = p_tenant_id and j.code = 'measure_active_users';

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);
  perform set_config('erp.job_principal_id', '', true);
  perform erp.upsert_job('measure_active_users', 'Measure active users', 'commercial.measure_active_users',
                         'daily', null, '05:30'::time, null, null, 'UTC', '{}'::jsonb, null, 172800,
                         coalesce(v_enabled, true));
  perform set_config('erp.job_tenant_id', coalesce(v_prior_tenant, ''), true);
  perform set_config('erp.job_principal_id', coalesce(v_prior_principal, ''), true);
end;
$$;
revoke all on function erp.schedule_usage_measurement(uuid) from public, anon, authenticated;
comment on function erp.schedule_usage_measurement(uuid) is
  'On a client''s own deployment, gives the organisation a daily job measuring active users (commercial.measure_active_users, '
  '05:30 UTC), keeping whether one already there is switched on. Does nothing anywhere else: the platform''s own job '
  'measures every organisation on the control plane (20261012080000). Called by the trigger on erp.tenant (20261012100000).';

create or replace function erp.schedule_usage_measurement_on_tenant()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform erp.schedule_usage_measurement(new.id);
  return new;
end;
$$;
revoke all on function erp.schedule_usage_measurement_on_tenant() from public, anon, authenticated;

drop trigger if exists t_tenant_usage_measurement on erp.tenant;
create trigger t_tenant_usage_measurement
  after insert on erp.tenant
  for each row execute function erp.schedule_usage_measurement_on_tenant();

-- An organisation a client already holds.
do $held$
declare t record;
begin
  for t in select tn.id from erp.tenant tn where tn.status not in ('deleting', 'deleted') loop
    perform erp.schedule_usage_measurement(t.id);
  end loop;
end
$held$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Not run from this migration: its fixture marks the database a client, a
-- live setting. The catalogue runs it on the build.

create or replace function erp_test.client_measures_its_own_active_users_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tag      text := substr(md5(clock_timestamp()::text), 1, 6);
  v_ccode    text;
  v_pcode    text;
  v_client   uuid;
  v_plain    uuid;
  v_jobs     integer;
  v_job      erp.job%rowtype;
  v_plain_n  integer;
  v_twice    integer;
  v_off      boolean;
  v_run      jsonb;
  v_outcome  text;
  v_msg      text;
  v_step     text;
begin
  v_ccode := 'zzcmu-c-' || v_tag;
  v_pcode := 'zzcmu-p-' || v_tag;

  -- Under a subtransaction that is always undone: the build is no client.
  begin
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);

    v_step := 'an organisation on a deployment that is not a client';
    select r.tenant_id into v_plain
      from erp.provision_tenant(v_pcode, 'Not A Client Ltd', 'admin@' || v_pcode || '.test', 'Plain Admin') r;
    select count(*) into v_plain_n from erp.job j where j.tenant_id = v_plain and j.code = 'measure_active_users';

    v_step := 'an organisation on a client';
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"client"'::jsonb, 'client_measures_its_own_active_users_suite');
    select r.tenant_id into v_client
      from erp.provision_tenant(v_ccode, 'Client Measures Ltd', 'admin@' || v_ccode || '.test', 'Client Admin') r;
    select count(*) into v_jobs from erp.job j where j.tenant_id = v_client and j.code = 'measure_active_users';
    select * into v_job from erp.job j where j.tenant_id = v_client and j.code = 'measure_active_users';

    v_step := 'scheduling again, with the job switched off';
    update erp.job set is_enabled = false where id = v_job.id;
    perform erp.schedule_usage_measurement(v_client);
    select count(*), bool_or(j.is_enabled) into v_twice, v_off
      from erp.job j where j.tenant_id = v_client and j.code = 'measure_active_users';
    update erp.job set is_enabled = true where id = v_job.id;

    v_step := 'running the job when it is due';
    update erp.job set next_run_at = now() - interval '1 minute' where id = v_job.id;
    perform set_config('erp.job_tenant_id', v_client::text, true);
    v_run := erp.run_due_jobs(10);
    perform set_config('erp.job_tenant_id', '', true);
    select r.outcome into v_outcome
      from erp.job_run r where r.job_id = v_job.id order by r.scheduled_for desc limit 1;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_msg := v_step || ': ' || left(sqlerrm, 160);
    end if;
  end;

  case_name := 'an organisation made on a client is given a job measuring its active users';
  passed := coalesce(v_msg is null and v_jobs = 1 and v_job.handler_code = 'commercial.measure_active_users', false);
  detail := coalesce(v_msg, format('%s job(s); handler %s', v_jobs, coalesce(v_job.handler_code, 'none')));
  return next;

  case_name := 'daily at 05:30 UTC, switched on';
  passed := coalesce(v_msg is null and v_job.schedule_kind = 'daily' and v_job.at_time = '05:30'::time
        and v_job.timezone = 'UTC' and v_job.is_enabled, false);
  detail := coalesce(v_msg, format('%s at %s %s, enabled %s', v_job.schedule_kind, v_job.at_time, v_job.timezone, v_job.is_enabled));
  return next;

  case_name := 'and it runs: the runner claims it when due and it succeeds';
  passed := coalesce(v_msg is null and v_outcome = 'succeeded', false);
  detail := coalesce(v_msg, format('last run %s; runner said %s', coalesce(v_outcome, 'none'), coalesce(v_run::text, 'nothing')));
  return next;

  case_name := 'scheduling it again leaves one job, and one switched off stays off';
  passed := coalesce(v_msg is null and v_twice = 1 and v_off = false, false);
  detail := coalesce(v_msg, format('%s job(s), enabled %s', v_twice, v_off));
  return next;

  case_name := 'an organisation made where the deployment is not a client is given none';
  passed := coalesce(v_msg is null and v_plain_n = 0, false);
  detail := coalesce(v_msg, format('%s job(s)', v_plain_n));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code like 'zzcmu-%')
        and erp.deployment_kind() <> 'client';
  detail := format('deployment kind %s', erp.deployment_kind());
  return next;
end;
$$;
revoke all on function erp_test.client_measures_its_own_active_users_suite() from public, anon, authenticated;

create or replace function erp_test.assert_client_measures_its_own_active_users_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _client_measures_its_own_active_users on commit drop as
    select * from erp_test.client_measures_its_own_active_users_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _client_measures_its_own_active_users;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CLIENT_MEASURES_ITS_OWN_ACTIVE_USERS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CLIENT_MEASURES_ITS_OWN_ACTIVE_USERS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('client measures its own active users: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_client_measures_its_own_active_users_suite() from public, anon, authenticated;

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
select erp.assert_scheduler_integrity();
select erp.assert_job_handlers_resolvable();
