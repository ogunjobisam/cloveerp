-- ─────────────────────────────────────────────────────────────────────────────
-- The chain suite needed a real backlog, not a threshold the schema refuses.
--
-- CI caught a case that only passed on the development rig.
-- erp.maintain_job_schedule() validates a job's parameters against its
-- handler's parameter_schema on insert, and integration.backlog_alert declares
-- threshold with a minimum of 1 — so {"threshold": 0} can never be stored. The
-- case used nought as the discriminator between "the parameter arrived" and
-- "the handler used its own default", and it worked locally only because
-- pg_jsonschema 0.3.3 on that build validates nothing at all. Against a
-- correct validator the job cannot be created and the suite dies before the
-- case runs.
--
-- The honest discriminator is a real backlog: an external system with
-- max_attempts of one, a command failed once so it dies, and a threshold of
-- one. One command behind crosses one and not the handler's default of ten,
-- and the event carries the threshold it used — so the case reads the number
-- that arrived rather than inferring it from a count that is the same either
-- way. Its neighbour moves with it: with something in the queue, "an empty
-- queue raises nothing" becomes "a backlog under its threshold raises
-- nothing", asked at fifty.
--
-- Written as a new migration rather than an edit to 20260904920000. That file
-- has been pushed, and supabase/ci/migrations_immutable.sh says what an edit
-- to a pushed migration costs: it is invisible to a build that starts from an
-- empty database and reaches no environment that has already run it. A
-- definition is repaired forward.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.notification_chain_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  r        record;
  v_tenant uuid;
  v_admin  uuid := gen_random_uuid();
  v_admin2 uuid := gen_random_uuid();
  v_user2  uuid;
  v_cs     uuid;
  v_job    uuid;
  v_run    bigint;
  v_cmd    uuid;
  v_n      int;
  v_cases  int := 0;
  it       record;
begin
  select * into r from erp.provision_tenant(
    'zzchain', 'Chain Suite', 'admin@zzchain.test', 'Chain Suite Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email)
  values (v_admin, 'admin@zzchain.test'), (v_admin2, 'second@zzchain.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- Whoever raises a change set may not wave it through, so the suite needs
  -- somebody else to be.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                            email, user_locale)
  values (v_tenant, v_admin2, 'person', 'active', 'Chain Suite Second',
          'second@zzchain.test', 'en')
  returning id into v_user2;

  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  select v_tenant, v_user2, ro.id, 'the suite needs a second approver'
    from erp.role ro
   where ro.tenant_id = v_tenant and ro.code = 'administrator' and ro.status = 'active';

  -- ── The pack can carry a route at all ─────────────────────────────────────
  -- Planned rather than promoted: the base pack asks an organisation nine
  -- policy questions before it will install, and none of them is what this
  -- suite is about. What matters here is that routes appear in the plan, which
  -- they could not before notification_route was a kind.

  v_cases := v_cases + 1;
  select count(*) into v_n from erp.plan_content_pack('base') p
   where p.object_kind = 'notification_route';
  return query select 'the base pack can carry a notification route'::text,
    v_n >= 3,
    format('%s route(s) in the plan — it was structurally zero until the '
           'promoter learned the kind', v_n);

  -- ── And the promoter installs one ─────────────────────────────────────────
  -- Just the job_failed pair, promoted on its own: the template it renders
  -- through and the route that carries it.

  v_cs := erp.create_change_set('zzchain-routes', 'Chain suite routes',
                                'The job_failed template and the route that carries it', null);
  for it in
    select p.object_kind, p.object_key, p.payload
      from erp.plan_content_pack('base') p
     where (p.object_kind = 'notification_route' and p.object_key = 'job_failed')
        or (p.object_kind = 'notification_template' and p.object_key = 'job_failed')
     order by case p.object_kind when 'notification_template' then 1 else 2 end
  loop
    perform erp.add_change_set_item(v_cs, it.object_kind, it.object_key, it.payload,
                                    'upsert'::erp.change_operation, current_date,
                                    'the chain suite, walking §9.2 end to end');
  end loop;

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin2, 'role', 'authenticated')::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  v_cases := v_cases + 1;
  return query select 'promoting one installs it'::text,
    exists (select 1 from erp.notification_route nr
             where nr.tenant_id = v_tenant and nr.code = 'job_failed'
               and nr.status = 'active'),
    'the promoter branch this migration adds, doing the thing it was added for';

  v_cases := v_cases + 1;
  return query select 'and it names the template that renders it'::text,
    exists (select 1 from erp.notification_route nr
              join erp.notification_template nt
                on nt.tenant_id = nr.tenant_id and nt.code = nr.template_code
             where nr.tenant_id = v_tenant and nr.code = 'job_failed'),
    'a route naming a template nobody ships renders nothing';

  -- ── A job that runs out of attempts ───────────────────────────────────────

  perform erp.upsert_job('zzfail', 'Failing job', 'platform.report_silent_jobs',
                         'interval', 3600, null, null, null, 'UTC', '{}'::jsonb,
                         null, null, true);
  select j.id into v_job from erp.job j where j.tenant_id = v_tenant and j.code = 'zzfail';
  update erp.job set max_attempts = 1, next_run_at = now() where id = v_job;

  v_cases := v_cases + 1;
  begin
    select cr.id into v_run
      from erp.claim_job_runs('chain-suite', 1, interval '5 minutes') cr limit 1;
    perform erp.fail_job_run(v_run, 'the dependency this job needs is not answering',
                             '{}'::jsonb, true);
    return query select 'a job that runs out of attempts raises an event'::text,
      exists (select 1 from erp.event e
               where e.tenant_id = v_tenant and e.event_type = 'job.failed'),
      'the base pack has shipped a job_failed template all along and nothing '
      'ever raised the event it renders';
  exception when others then
    return query select 'a job that runs out of attempts raises an event'::text,
      false, left(sqlerrm, 90);
  end;

  v_cases := v_cases + 1;
  perform erp.route_notifications();
  select count(*) into v_n from erp.notification n where n.tenant_id = v_tenant;
  return query select 'and somebody is actually told'::text,
    v_n > 0,
    format('%s notification(s) — this is the number that was zero on every '
           'organisation ever built from this pack', v_n);

  v_cases := v_cases + 1;
  return query select 'the notification reaches an administrator, not nobody'::text,
    exists (select 1 from erp.notification n
              join erp.app_user u on u.tenant_id = n.tenant_id and u.id = n.app_user_id
             where n.tenant_id = v_tenant and u.email like '%@zzchain.test'),
    'the route says role administrator and this organisation has two';

  -- ── The backlog half ──────────────────────────────────────────────────────

  -- Through the scheduler, not by calling the handler directly: what was broken
  -- was the delivery of a job's parameters, and a direct call is exactly the
  -- test that cannot see it.
  --
  -- It needs a real backlog. With an empty queue the handler answers nought
  -- whether it was given a threshold of one or fell back to its own ten, so the
  -- two are indistinguishable — which is how the first draft of this case
  -- passed against plumbing that was demonstrably broken. One dead command and
  -- a threshold of one, and only the number that actually arrived raises an
  -- event; the payload then carries it, so the case reads the value rather than
  -- inferring it.
  insert into erp.external_system
    (tenant_id, code, name, adapter_code, adapter_version, connection,
     credential_ref, status, max_in_flight, max_attempts, retry_backoff_seconds)
  values (v_tenant, 'zzwms', 'Suite system', 'example_http', 1,
          jsonb_build_object('base_url', 'https://zzwms.test'),
          'vault://zzchain/suite-key', 'active', 5, 1, 60);

  insert into erp.external_system_operation
    (tenant_id, external_system_id, operation_code, is_enabled)
  select v_tenant, es.id, 'order.create', true
    from erp.external_system es
   where es.tenant_id = v_tenant and es.code = 'zzwms';

  perform erp.submit_command(
    'zzwms', 'order.create',
    jsonb_build_object('order_ref', 'ZZ-1',
                       'lines', jsonb_build_array(jsonb_build_object('sku', 'A'))),
    false, 'zzchain-command-0001');

  -- max_attempts is one, so the first failure is the last: the command dies and
  -- the backlog has exactly one thing in it needing a person.
  select cc.id into v_cmd
    from erp.claim_command_batch('zzwms', 1, 'chain-suite', interval '5 minutes') cc
   limit 1;
  perform erp.fail_command(v_cmd, 'the suite needs one command in the backlog', true);

  v_cases := v_cases + 1;
  perform erp.upsert_job('zzbacklog', 'Backlog alert', 'integration.backlog_alert',
                         'interval', 900, null, null, null, 'UTC',
                         '{"threshold": 1}'::jsonb, null, null, true);
  update erp.job set next_run_at = now()
   where tenant_id = v_tenant and code = 'zzbacklog';
  perform erp.run_due_jobs(10);
  return query select 'a job''s parameters reach the handler that declared them'::text,
    exists (select 1 from erp.event e
             where e.tenant_id = v_tenant
               and e.event_type = 'integration.backlog_exceeded'
               and (e.payload ->> 'threshold') = '1'),
    'the job says one and the handler''s default is ten; one dead command '
    'crosses the first and not the second, and the event carries the number '
    'that arrived';

  v_cases := v_cases + 1;
  return query select 'a backlog under its threshold raises nothing'::text,
    erp.alert_integration_backlog('{"threshold": 50}'::jsonb) = 0,
    'one command behind and a threshold of fifty: an alert here would be this '
    'fault inverted';

  v_cases := v_cases + 1;
  begin
    perform erp.alert_integration_backlog('{"threshold": 0}'::jsonb);
    return query select 'a threshold of zero is refused'::text, false,
      'an alert that always fires is not a threshold';
  exception when others then
    return query select 'a threshold of zero is refused'::text,
      sqlerrm like 'ERPWARE_THRESHOLD_INVALID%', left(sqlerrm, 70);
  end;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp_meta.platform_audit where tenant_id = v_tenant;
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (v_admin, v_admin2);

  v_cases := v_cases + 1;
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp.tenant t where t.code = 'zzchain'),
    'and the notifications went with the organisation, being tenant-scoped';

  if v_cases <> 10 then
    raise exception 'ERPWARE_SUITE_SHRANK: notification_chain_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.notification_chain_suite() from public, anon;
