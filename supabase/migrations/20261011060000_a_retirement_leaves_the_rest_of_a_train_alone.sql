set lock_timeout = '30s';

-- =============================================================================
-- 20261011060000  A retirement leaves the rest of a train alone
-- -----------------------------------------------------------------------------
-- A second review of the retire door, before it reached production, found
-- that retiring one client cancelled every release request still waiting
-- that named it — including one that also named the control plane or other
-- clients, which then were never released, with nothing to say so. Since
-- 20261011050000 that cancellation buys no safety: deploy.yml reads only
-- built and live clients, and each client's release asks the register
-- first. So a waiting release is left alone; only a waiting BUILD of the
-- retired client is cancelled, since it would rebuild what is gone.
--
-- The door and the retirement suite are re-made with that one change; the
-- suite's sixth case now asks that a train naming the retired client and the
-- control plane is still waiting afterwards.
-- =============================================================================

create or replace function public.erp_platform_retire_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  d       erp_meta.deployment;
  -- The register's own word, a text column's value. Named rather than
  -- written inline: erp.record_status_literal_report() looks for that word
  -- written into a record_status column, which has no such value, and a
  -- register column is not one (20261011040000).
  c_retired constant text := 'retired';
  v_last  erp_meta.deployment_event;
  v_busy  text;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: retiring a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say why the deployment is retired and what becomes of its project. At least twenty characters.';
  end if;

  -- The row's lock, held to the end: a release asking whether it may start
  -- (erp_meta.begin_deployment_release) waits for this, and then sees the
  -- row retired (20261011050000).
  select * into d from erp_meta.deployment x where x.code = d.code for update;

  -- The newest step of a release or a build dispatch, if any.
  select * into v_last
    from erp_meta.deployment_event e
   where e.code = d.code and e.phase in ('release', 'dispatch', 'create', 'build')
   order by e.at desc, e.id desc
   limit 1;

  v_busy := case
    when d.status in ('creating', 'building') then 'its build is running'
    when d.status = c_retired then 'it is retired already'
    when v_last.phase = 'release' and v_last.status = 'started' and v_last.at > now() - interval '90 minutes'
      then 'a release to it has started and not finished'
    when d.status = 'requested' and v_last.phase = 'dispatch' and v_last.at > now() - interval '90 minutes'
      then 'its build has been started and has not yet begun'
  end;

  if v_busy is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE: % is not retired: %', d.code, v_busy
      using errcode = '55000',
            hint = 'Wait until the Fleet view shows no build or release running for it, then retire it. If it is '
                   'retired already, there is nothing left to do but delete its project in the Supabase dashboard.';
  end if;

  update erp_meta.deployment x
     set status = c_retired, owner_email = null, updated_at = now()
   where x.code = d.code;

  -- A build still waiting for the sweep would rebuild a deployment that is
  -- gone. A release waiting for it is left alone: it may name the control
  -- plane and other clients too, and the train itself releases nothing to a
  -- retired client (deploy.yml reads only built and live ones, and each
  -- client's release asks the register first) (20261011060000).
  update erp_meta.fleet_request r
     set status = 'cancelled', outcome = 'the deployment was retired', settled_at = now()
   where r.status = 'requested'
     and r.kind = 'build'
     and r.payload ->> 'code' = d.code;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('retired by %s (was %s): %s. Nothing runs for it now: delete project %s in the Supabase dashboard, and remove its Lovable domain and DNS records.',
           v.email, d.status, btrim(p_reason), coalesce(d.project_ref, 'that was never made')));

  perform erp_meta.platform_log(v, 'platform.deployment_retired', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'project_ref', d.project_ref));

  return jsonb_build_object('code', d.code, 'status', c_retired, 'was', d.status, 'project_ref', d.project_ref);
end;
$$;

create or replace function erp_test.deployment_retirement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  v_uid    uuid := gen_random_uuid();
  v_owner  text;
  v_role   text := current_user;
  v_apex   text;
  v_step   text := 'standing up an owner';
  v_state  text;
  v_got    text;
  v_got2   text;
  v_json   jsonb;
  v_req    uuid;
begin
  begin
    v_code := 'zzret-' || v_tag;
    v_owner := 'owner@zzret-' || v_tag || '.test';
    insert into auth.users (id, email) values (v_uid, v_owner);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Deployment Retirement Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.ref', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_retirement_suite');
    v_apex := regexp_replace(erp.app_origin(), '^https://', '');

    -- A client, dispatched and building, as the workflows leave one.
    v_step := 'building a client';
    perform public.erp_platform_request_deployment(v_code, 'Retirement Suite Ltd', 'admin@' || v_code || '.test',
      'A client the retirement suite builds and then retires.');
    perform erp_meta.claim_fleet_request('run-' || v_tag);

    -- ── 1. Not while its build has been dispatched and not yet begun ────────
    v_step := 'retiring a dispatched build';
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires a dispatched build, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment whose build has been dispatched and not yet begun is not retired';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%has been started%'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'requested';
    detail := left(v_got, 140);
    return next;

    -- ── 2. Not while it builds ──────────────────────────────────────────────
    v_step := 'retiring while it builds';
    perform erp_meta.record_deployment_event(v_code, 'create', 'started', 'making the project', 'run-' || v_tag);
    perform erp_meta.register_deployment_project(v_code, 'abcdefghijklmnopqrst', 'https://abcdefghijklmnopqrst.supabase.co',
      'sb_publishable_suite', 'eu-central-1', 'micro');
    perform erp_meta.record_deployment_event(v_code, 'build', 'started', 'replaying every migration', 'run-' || v_tag);
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires a build in progress, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment whose build is running is not retired';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%build is running%'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'building';
    detail := left(v_got, 140);
    return next;

    -- ── 3. Not while a release runs; a release starts only for a target ─────
    v_step := 'retiring during its first release';
    perform erp_meta.deployment_built(v_code);
    v_got2 := erp_meta.begin_deployment_release(v_code, 'run-' || v_tag || '-r');
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires during a release, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a release asks first and is recorded as started, and the deployment is not retired while it runs';
    passed := v_got2 = 'built'
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'release' and e.status = 'started')
          and v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%release to it has started%'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'built';
    detail := v_got2 || ' / ' || left(v_got, 120);
    return next;

    perform erp_meta.record_deployment_release(v_code, 'abc1234def5678', 'success', 'run-' || v_tag || '-r');
    perform public.erp_platform_request_release(array[v_code, 'control'], 'A train the retirement suite asks for before retiring the client.');
    v_req := (select r.id from erp_meta.fleet_request r where r.kind = 'release' and r.status = 'requested'
               and r.payload -> 'targets' ? v_code order by r.created_at desc limit 1);
    -- The sweep would claim it; the suite leaves it waiting.

    -- ── 4. Only the owner, and only with a reason ───────────────────────────
    v_step := 'retiring as an operator, then without a reason';
    update erp_meta.platform_staff set staff_role = 'operator' where auth_user_id = v_uid;
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires as an operator, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    update erp_meta.platform_staff set staff_role = 'owner' where auth_user_id = v_uid;
    begin
      perform public.erp_platform_retire_deployment(v_code, 'done');
      v_got2 := 'it was retired';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'only an owner retires a deployment, and only with a reason';
    passed := v_got like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%' and v_got2 like 'CLOVEERP_REASON_REQUIRED%'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'live';
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80);
    return next;

    -- ── 5. Retired: off its address, its administrator forgotten ────────────
    v_step := 'retiring a live client';
    v_json := public.erp_platform_retire_deployment(v_code, 'The rehearsal is proved, and its project is to be deleted.');
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_got := coalesce(public.erp_deployment_for_host(v_code || '.' || v_apex)::text, 'nothing');
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a retired deployment answers nothing at its address and keeps no administrator''s address';
    passed := v_json ->> 'status' = 'retired' and v_json ->> 'was' = 'live'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'retired'
          and (select d.owner_email from erp_meta.deployment d where d.code = v_code) is null
          and v_got = 'nothing';
    detail := coalesce(v_json::text, 'no answer') || ' / directory: ' || v_got;
    return next;

    -- ── 6. No release starts for it; a waiting train is left for the rest ──
    -- The train may name the control plane and other clients; it carries
    -- on, and releases nothing to the retired one (20261011060000).
    v_step := 'asking to release a retired client';
    v_got := erp_meta.begin_deployment_release(v_code, 'run-' || v_tag || '-late');
    v_cases := v_cases + 1;
    case_name := 'a retired deployment is no release target: a release that asks is told so and records nothing, and a train still waiting is left to release the rest';
    passed := v_got = 'retired'
          and not exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.run_id = 'run-' || v_tag || '-late')
          and not exists (select 1 from erp_meta.deployment d where d.code = v_code and d.status in ('built', 'live'))
          and (select r.status from erp_meta.fleet_request r where r.id = v_req) = 'requested';
    detail := v_got || ' / ' || coalesce((select r.status from erp_meta.fleet_request r where r.id = v_req), 'no request');
    return next;

    -- ── 7. Once retired, nothing writes it back ─────────────────────────────
    v_step := 'writing a retired row back';
    begin
      perform erp_meta.record_deployment_event(v_code, 'create', 'started', 'a late build step', 'run-' || v_tag || '-late');
      update erp_meta.deployment set status = 'requested' where code = v_code;
      v_got := 'it was written back';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'once retired, no writer gives the deployment another status';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%does not change again%'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'retired';
    detail := left(v_got, 140);
    return next;

    -- ── 8. Its code stays held ──────────────────────────────────────────────
    v_step := 'taking the retired code';
    begin
      perform public.erp_platform_request_deployment(v_code, 'Retirement Suite Again Ltd', 'admin@' || v_code || '.test',
        'The retirement suite asks for a retired code again, which must refuse.');
      v_got := 'it was requested';
    exception when others then
      v_got := sqlerrm;
    end;
    v_got2 := coalesce(erp.tenant_code_refusal(v_code, null), 'no refusal');
    v_cases := v_cases + 1;
    case_name := 'a retired deployment''s code is held: neither another client''s nor an organisation''s address';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_EXISTS%' and v_got2 like 'CLOVEERP_ADDRESS_TAKEN%';
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80);
    return next;

    -- ── 9. Once, and said ───────────────────────────────────────────────────
    v_step := 'retiring it again';
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires the same deployment twice, which must refuse.');
      v_got := 'it was retired again';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment is retired once, and the step and the platform log say who, why, and that nothing runs for it';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%retired already%'
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'note'
                       and e.detail like 'retired by ' || v_owner || '%Nothing runs for it now%abcdefghijklmnopqrst%')
          and exists (select 1 from erp_meta.platform_audit a where a.action = 'platform.deployment_retired'
                       and a.target = v_code);
    detail := left(v_got, 120);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEPLOYMENT_RETIREMENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function public.erp_platform_retire_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_retire_deployment(text, text) to authenticated, service_role;

revoke all on function erp_test.deployment_retirement_suite() from public, anon;

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
