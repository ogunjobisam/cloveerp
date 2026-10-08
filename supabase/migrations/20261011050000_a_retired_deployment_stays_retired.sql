set lock_timeout = '30s';

-- =============================================================================
-- 20261011050000  A retired deployment stays retired
-- -----------------------------------------------------------------------------
-- 20261011040000 lets the owner retire a client deployment before deleting
-- its project. A review of it before it reached production found that
-- retiring took no account of work already in flight:
--
--   - A release train reads the register once, at its start, and releases
--     to each client much later, after the demonstration. A client retired
--     in between was still released to; with its project deleted, that
--     release failed and held the control plane back, which is exactly what
--     retiring was for.
--   - A build's first release runs after the build marks the row built, so
--     "built" did not mean nothing was running.
--   - The door read the row without a lock and wrote it unconditionally, as
--     do Retry and the steps a build records; whichever came second won, so
--     a retirement could be written over.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_meta.begin_deployment_release(code, run): the first thing a
--      client's release does (release.yml). Under the row's lock it says
--      whether the deployment is still a release target and, if it is,
--      records that a release has started. A release to a client the
--      register no longer holds as built or live does nothing and ends
--      green, so a train never fails on, or touches, a retired client.
--   B. The door takes the row's lock, and refuses while a release has
--      started and not finished (younger than ninety minutes; a release job
--      times out at sixty) or a build has been dispatched and not yet
--      begun. Between A and B, under the one lock, either the release sees
--      the row retired and stops, or the door sees the release and refuses.
--   C. A trigger: once retired, a deployment's status does not change again,
--      whoever writes it — Retry, a build's late step, anything later.
--   D. The refusal and the retirement note say when the project may be
--      deleted: once the row says retired, which no run in flight allows.
--   E. The retirement suite grows from six cases to nine.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The refusal, said again
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE',
  'Retiring a client deployment while something is still running for it, or once it is retired.',
  'A build or a release still running for a deployment would carry on into a project about to be deleted, and '
  'a release that fails holds every later release back. So a deployment is retired only when nothing is running '
  'for it. A retired deployment stays retired, and keeps its address so that nobody else can take it.',
  'Wait until the Fleet view shows no build or release running for it, then retire it. If it is retired '
  'already, there is nothing left to do but delete its project in the Supabase dashboard.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A release asks first
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.begin_deployment_release(p_code text, p_run_id text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d erp_meta.deployment;
begin
  select * into d from erp_meta.deployment x
   where x.code = lower(btrim(coalesce(p_code, '')))
   for update;
  if d.code is null then
    return 'unknown';
  end if;
  if d.status not in ('built', 'live') then
    return d.status;
  end if;
  insert into erp_meta.deployment_event (code, phase, status, detail, run_id)
  values (d.code, 'release', 'started', 'a release has started',
          nullif(btrim(coalesce(p_run_id, '')), ''));
  return d.status;
end;
$$;

revoke all on function erp_meta.begin_deployment_release(text, text) from public, anon, authenticated, service_role;

comment on function erp_meta.begin_deployment_release(text, text) is
  'The first thing a client''s release does: under the row''s lock, answers the deployment''s status and, when it '
  'is built or live, records that a release has started. Anything else, retired included, means nothing is '
  'released. Trusted build role only (20261011050000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The door: under the lock, and not while anything runs
-- ─────────────────────────────────────────────────────────────────────────────

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

  -- Any request still waiting for the sweep would build or release a
  -- deployment that is gone.
  update erp_meta.fleet_request r
     set status = 'cancelled', outcome = 'the deployment was retired', settled_at = now()
   where r.status = 'requested'
     and (r.payload ->> 'code' = d.code or r.payload -> 'targets' ? d.code);

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('retired by %s (was %s): %s. Nothing runs for it now: delete project %s in the Supabase dashboard, and remove its Lovable domain and DNS records.',
           v.email, d.status, btrim(p_reason), coalesce(d.project_ref, 'that was never made')));

  perform erp_meta.platform_log(v, 'platform.deployment_retired', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'project_ref', d.project_ref));

  return jsonb_build_object('code', d.code, 'status', c_retired, 'was', d.status, 'project_ref', d.project_ref);
end;
$$;

revoke all on function public.erp_platform_retire_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_retire_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_retire_deployment(text, text) is
  'Retires a client deployment from the register before its project is deleted: no longer a release target, '
  'nothing at its address, its code kept, its first administrator''s address cleared. Platform owner, on the '
  'control plane, with a reason; refused while a build or a release is running for it, under the row''s lock. '
  'Deletes nothing (20261011040000, 20261011050000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Once retired, always retired
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.deployment_stays_retired()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Reached only through the trigger's WHEN clause: the row was retired and
  -- something tried to give it another status (20261011050000).
  raise exception 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE: % is retired, and its status does not change again', old.code
    using errcode = '55000',
          hint = 'Wait until the Fleet view shows no build or release running for it, then retire it. If it is '
                 'retired already, there is nothing left to do but delete its project in the Supabase dashboard.';
end;
$$;

revoke all on function erp_meta.deployment_stays_retired() from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_stays_retired() is
  'The trigger that keeps a retired client deployment retired, whoever writes its status: Retry, a build''s late '
  'step, anything later (20261011050000).';

drop trigger if exists t_deployment_stays_retired on erp_meta.deployment;
create trigger t_deployment_stays_retired
  before update of status on erp_meta.deployment
  for each row
  when (old.status = 'retired' and new.status is distinct from old.status)
  execute function erp_meta.deployment_stays_retired();

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof, nine cases
-- ─────────────────────────────────────────────────────────────────────────────

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
    perform public.erp_platform_request_release(array[v_code], 'A train the retirement suite asks for before retiring the client.');
    v_req := (select r.id from erp_meta.fleet_request r where r.kind = 'release' and r.status = 'requested'
               and r.payload -> 'targets' ? v_code order by r.created_at desc limit 1);

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

    -- ── 6. No release starts for it; its waiting train is cancelled ─────────
    v_step := 'asking to release a retired client';
    v_got := erp_meta.begin_deployment_release(v_code, 'run-' || v_tag || '-late');
    v_cases := v_cases + 1;
    case_name := 'a retired deployment is no release target: a release that asks is told so and records nothing, and a train still waiting for it is cancelled';
    passed := v_got = 'retired'
          and not exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.run_id = 'run-' || v_tag || '-late')
          and not exists (select 1 from erp_meta.deployment d where d.code = v_code and d.status in ('built', 'live'))
          and (select r.status from erp_meta.fleet_request r where r.id = v_req) = 'cancelled';
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

revoke all on function erp_test.deployment_retirement_suite() from public, anon;

comment on function erp_test.deployment_retirement_suite() is
  'Retiring a client deployment (20261011040000, 20261011050000): not while its build is dispatched or running, '
  'nor while a release runs; owner only, with a reason; off its address with its administrator forgotten; no '
  'release starts for it and a waiting train is cancelled; nothing writes it back; its code held; once, and '
  'recorded.';

create or replace function erp_test.assert_deployment_retirement_suite()
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
    from erp_test.deployment_retirement_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_RETIREMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Retiring a client deployment misbehaves: read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_DEPLOYMENT_RETIREMENT_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment retirement: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_deployment_retirement_suite() from public, anon;

comment on function erp_test.assert_deployment_retirement_suite() is
  'A client deployment is retired by its owner, only when nothing runs for it, and stays retired: off its address, '
  'out of every release, its code kept (20261011040000, 20261011050000).';

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
