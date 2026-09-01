-- =============================================================================
-- The superadmin console — the suite
--
-- Four pieces of work, and the thing worth proving about each is the same: that
-- the guard is load-bearing rather than decorative. So every case here is
-- written as a falsification — break the thing, watch the check catch it, put
-- it back — rather than as a demonstration that the happy path works.
-- =============================================================================

create or replace function erp_test.superadmin_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  ow uuid := gen_random_uuid();   -- platform owner
  nb uuid := gen_random_uuid();   -- nobody
  r  record;
  v_ok boolean; v_msg text; res jsonb; n integer; v_grants integer;
begin
  insert into auth.users (id, email) values
    (ow, 'owner@zzsa.test'), (nb, 'nobody@zzsa.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzsa.test', ow, 'Superadmin Suite Owner', 'owner');

  -- ── A: the register is the allow-list ───────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', nb)::text, true);
  begin
    perform public.erp_platform_run_check('isolation');
    v_ok := false; v_msg := 'an account off the staff list ran a check';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_PLATFORM_STAFF%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'a caller who is not platform staff cannot run a check',
    v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  begin
    perform public.erp_platform_run_check('drop_everything');
    v_ok := false; v_msg := 'an unregistered name was executed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_DIAGNOSTIC%'; v_msg := left(sqlerrm, 58);
  end;
  -- The register is the allow-list, which is the whole safety argument for
  -- dispatching a function by name at all.
  return query select 'and a name that is not in the register is refused',
    v_ok, v_msg;

  return query select 'the register runs every assertion CI does, not nine of them',
    (select count(*) from erp_meta.diagnostic_check where kind = 'assertion') >= 24,
    format('%s registered', (select count(*) from erp_meta.diagnostic_check));

  -- An assertion nobody registered is the failure this exists to prevent.
  create function erp.assert_zz_unregistered() returns text
    language sql stable as $f$ select 'x' $f$;
  begin
    perform erp.assert_diagnostics_registered();
    v_ok := false; v_msg := 'an unregistered assertion passed unnoticed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DIAGNOSTICS_UNREGISTERED%'; v_msg := left(sqlerrm, 58);
  end;
  drop function erp.assert_zz_unregistered();
  return query select 'a new assertion that nobody registered is caught', v_ok, v_msg;

  -- And a register row naming something that is not there.
  insert into erp_meta.diagnostic_check
    (code, title, kind, scope, function_name, blurb)
  values ('zz_phantom', 'Phantom', 'assertion', 'platform',
          'assert_no_such_thing', 'Names a function that does not exist.');
  begin
    perform erp.assert_diagnostics_registered();
    v_ok := false; v_msg := 'a register naming a missing function passed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DIAGNOSTICS_UNREGISTERED%'; v_msg := left(sqlerrm, 58);
  end;
  delete from erp_meta.diagnostic_check where code = 'zz_phantom';
  -- A register that reports green over nothing is worse than no register.
  return query select 'and a register row naming a function that is gone',
    v_ok, v_msg;

  -- The half that was missing: a failure that names what failed.
  begin
    alter table erp.department disable row level security;
    res := erp.run_diagnostic('isolation');
    alter table erp.department enable row level security;
  exception when others then
    alter table erp.department enable row level security;
    raise;
  end;
  return query select 'a failing check returns the findings, not just false',
    (res ->> 'ok')::boolean is false
      and jsonb_array_length(res -> 'findings') > 0
      and res -> 'findings' -> 0 ->> 'table_name' = 'department',
    format('%s finding(s), first names %s', jsonb_array_length(res -> 'findings'),
           res -> 'findings' -> 0 ->> 'table_name');

  return query select 'and isolation is intact again afterwards',
    (erp.run_diagnostic('isolation') ->> 'ok')::boolean,
    'a suite that leaves row security off would fail every assertion after it';

  -- ── B: a job surface that can hold a job ────────────────────────────────

  select * into r from erp.provision_tenant('zzsa','Superadmin Suite','a@zzsa.test','Suite Admin');
  perform set_config('erp.job_tenant_id', r.tenant_id::text, true);

  return query select 'every handler the database claims to run exists',
    erp.assert_job_handlers_resolvable() like 'job handlers:%',
    erp.assert_job_handlers_resolvable();

  perform erp.upsert_job('zzreclaim', 'Reclaim timed-out runs',
                         'platform.reclaim_timed_out_runs', 'interval', 60);
  return query select 'a job can be created at all — nothing could before',
    (select count(*) from erp.job j where j.tenant_id = r.tenant_id) = 1,
    'erp.job had no insert anywhere in the product, so /operations/jobs was '
    'empty by construction and its Trigger action could only fail';

  return query select 'and the schedule trigger set its next run',
    (select j.next_run_at is not null from erp.job j
      where j.tenant_id = r.tenant_id and j.code = 'zzreclaim'),
    'computed by erp.maintain_job_schedule(), not duplicated by the door';

  begin
    perform erp.upsert_job('zzbad', 'Bad', 'platform.no_such_handler', 'interval', 60);
    v_ok := false; v_msg := 'a job named a handler nothing implements';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_JOB_HANDLER%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'a job naming a handler nothing implements is refused',
    v_ok, v_msg;

  update erp.job set next_run_at = now() - interval '1 minute'
   where tenant_id = r.tenant_id and code = 'zzreclaim';
  res := erp.run_due_jobs();
  return query select 'a due job runs and its run is recorded',
    (res ->> 'claimed')::integer = 1 and (res ->> 'succeeded')::integer = 1
      and (select count(*) from erp.job_run jr where jr.tenant_id = r.tenant_id) = 1,
    format('claimed %s, succeeded %s', res ->> 'claimed', res ->> 'succeeded');

  -- The honesty case. A handler that needs an outbound call must be refused by
  -- name; counting it as done would make the report a lie.
  update erp_ref.job_handler set sql_function = null
   where code = 'platform.reclaim_timed_out_runs';
  perform erp.upsert_job('zzworker', 'Needs the worker',
                         'platform.reclaim_timed_out_runs', 'interval', 60);
  update erp.job set next_run_at = now() - interval '1 minute'
   where tenant_id = r.tenant_id and code = 'zzworker';
  res := erp.run_due_jobs();
  update erp_ref.job_handler set sql_function = 'reclaim_timed_out_runs'
   where code = 'platform.reclaim_timed_out_runs';
  return query select 'a handler the database cannot run is refused by name',
    (res ->> 'needs_worker')::integer >= 1 and (res ->> 'succeeded')::integer = 0,
    'skipping it silently would report a clean pass over work nobody did';

  -- ── C: leaving actually leaves ──────────────────────────────────────────

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform public.erp_platform_enter_tenant(r.tenant_id, 'suite: investigating');

  select count(*) into v_grants
    from erp.user_role ur
    join erp.role ro on ro.id = ur.role_id
    join erp.app_user u on u.id = ur.app_user_id
   where ur.tenant_id = r.tenant_id and u.auth_user_id = ow
     and ro.code = 'administrator';
  return query select 'entering an organisation grants the administrator role',
    v_grants = 1, 'a real grant on a real principal, not an impersonation';

  res := public.erp_platform_leave_tenant(r.tenant_id);
  select count(*) into n
    from erp.user_role ur
    join erp.role ro on ro.id = ur.role_id
    join erp.app_user u on u.id = ur.app_user_id
   where ur.tenant_id = r.tenant_id and u.auth_user_id = ow
     and ro.code = 'administrator';
  return query select 'and leaving revokes it',
    n = 0 and (res ->> 'grants_revoked')::integer = 1,
    'it used to leave the grant in place for ever, dormant, for the next entry '
    'to find already there — and nothing in the product could call leave at all';

  perform public.erp_platform_enter_tenant(r.tenant_id, 'suite: second visit');
  select count(*) into n
    from erp.user_role ur
    join erp.role ro on ro.id = ur.role_id
    join erp.app_user u on u.id = ur.app_user_id
   where ur.tenant_id = r.tenant_id and u.auth_user_id = ow
     and ro.code = 'administrator';
  return query select 'so re-entering has to grant it again, and is recorded again',
    n = 1
      and (select count(*) from erp_meta.platform_audit
            where action = 'platform.tenant_entered' and tenant_id = r.tenant_id) = 2,
    'one audit line per period of access rather than one for the first ever';

  return query select 'and the console can say which organisations you are in',
    exists (select 1 from jsonb_array_elements(public.erp_platform_my_tenancies()) t
             where t.value ->> 'code' = 'zzsa'
               and (t.value ->> 'holds_administrator')::boolean),
    'nothing showed this, which is why nobody ever left';

  return query select 'and what each one is missing, without entering it',
    (select (t.value ->> 'accounts')::integer = 0
       from jsonb_array_elements(public.erp_platform_tenant_configuration()) t
      where t.value ->> 'code' = 'zzsa'),
    'this is the read that answers "has this organisation got master data?"';

  -- ── D: deployment state ─────────────────────────────────────────────────

  return query select 'deployment state reports the registers it is built on',
    (public.erp_platform_deployment_state() -> 'registers' ->> 'diagnostic_check')::integer > 0
      and (public.erp_platform_deployment_state() -> 'counts' ->> 'public_doors')::integer > 250,
    format('%s public doors, %s registered checks',
           public.erp_platform_deployment_state() -> 'counts' ->> 'public_doors',
           public.erp_platform_deployment_state() -> 'registers' ->> 'diagnostic_check');

  perform set_config('request.jwt.claims', json_build_object('sub', nb)::text, true);
  begin
    perform public.erp_platform_deployment_state();
    v_ok := false; v_msg := 'anybody signed in could read the deployment state';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_PLATFORM_STAFF%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'and is not readable by an account off the staff list',
    v_ok, v_msg;

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email = 'owner@zzsa.test';
  delete from auth.users where id in (ow, nb);

  return query select 'and the suite removes the organisation and the staff row',
    not exists (select 1 from erp_meta.platform_staff where email = 'owner@zzsa.test')
      and not exists (select 1 from erp.job j where j.tenant_id = r.tenant_id),
    'a staff row left behind changes what erp_platform_claim_ownership() does next';
end $$;

create or replace function erp_test.assert_superadmin_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Seven on the register and its guards, six on the job surface, five on
  -- entering and leaving, two on deployment state, and the cleanup.
  c_expected constant integer := 21;
begin
  create temporary table if not exists zz_superadmin_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_superadmin_result;
  insert into zz_superadmin_result select * from erp_test.superadmin_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_superadmin_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_SUPERADMIN_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_SUPERADMIN_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('superadmin: %s/%s', v_pass, v_total);
end $$;

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_diagnostics_registered();
