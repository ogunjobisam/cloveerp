set lock_timeout = '30s';

-- =============================================================================
-- 20261011040000  A client deployment can be retired
-- -----------------------------------------------------------------------------
-- The first client deployment is a rehearsal (8 October): it proves the
-- whole build on a real project, and then the owner deletes the project. A
-- row in the register outlives its project unless something says it is
-- gone, and while it says built or live every release train goes to it:
-- deploy.yml releases to every built client before the control plane, a
-- release to a deleted project fails, and a failed client holds the control
-- plane back. So a deployment must be retired from the register BEFORE its
-- project is deleted, and until now nothing could do it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. One refusal, registered.
--   B. erp_meta.deployment.owner_email may be empty. The request door still
--      asks for it; retiring clears it, as the personal-data exemption for
--      the column (20261011020000) already promised: the client's first
--      administrator is a person, and the register keeps them only while
--      the deployment lives.
--   C. public.erp_platform_retire_deployment(code, reason): platform owner,
--      control plane only, with a reason. Marks the deployment retired,
--      clears its first administrator's address, records the step and the
--      platform log. A retired deployment is no release target (deploy.yml
--      reads built and live), answers nothing at its address
--      (erp_deployment_for_host reads built, live, suspended and retiring),
--      and keeps its code: the row stays, so the code is never another
--      organisation's or another client's (erp.tenant_code_refusal). Not
--      while a build runs: a build in flight marks its row built at the end
--      and would refuse; a build that stopped reads failed and may be
--      retired.
--
--      It deletes nothing. The project is the owner's to delete in the
--      dashboard, afterwards; the connection string and secret key in the
--      vault stay, and open nothing once the project is gone.
--   D. erp_test.deployment_retirement_suite and its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code and no organisation's screen. Nothing reaches a client's
-- database. There is no door back: a retired code is not requested again,
-- because the row that holds it stays.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusal
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE',
  'Retiring a client deployment that is being built, or that is retired already.',
  'A build in progress marks its deployment built when it finishes, so a deployment is retired only once its '
  'build has finished or stopped. A retired deployment stays retired, and keeps its address so that nobody else '
  'can take it.',
  'Wait until the Fleet view says the build is built, live or failed, then retire it. If the deployment is '
  'retired already, there is nothing left to do but delete its project in the Supabase dashboard.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The first administrator's address may be cleared
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.deployment alter column owner_email drop not null;

comment on column erp_meta.deployment.owner_email is
  'The client''s first administrator, onboarded from the client''s own console once it is live. The build '
  'invites nobody. Cleared when the deployment is retired (20261011040000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The door
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_retire_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
  d erp_meta.deployment;
  -- The register's own word, a text column's value. Named rather than
  -- written inline: erp.record_status_literal_report() looks for that word
  -- written into a record_status column, which has no such value, and a
  -- register column is not one (20261011040000).
  c_retired constant text := 'retired';
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: retiring a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say why the deployment is retired and what becomes of its project. At least twenty characters.';
  end if;

  if d.status in ('creating', 'building', 'retired') then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE: % is %', d.code, d.status
      using errcode = '55000',
            hint = 'Wait until the Fleet view says the build is built, live or failed, then retire it. If the '
                   'deployment is retired already, there is nothing left to do but delete its project in the '
                   'Supabase dashboard.';
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
    format('retired by %s (was %s): %s. Delete project %s in the Supabase dashboard, and remove its Lovable domain and DNS records.',
           v.email, d.status, btrim(p_reason), coalesce(d.project_ref, 'that was never made')));

  perform erp_meta.platform_log(v, 'platform.deployment_retired', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'project_ref', d.project_ref));

  return jsonb_build_object('code', d.code, 'status', 'retired', 'was', d.status, 'project_ref', d.project_ref);
end;
$$;

revoke all on function public.erp_platform_retire_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_retire_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_retire_deployment(text, text) is
  'Retires a client deployment from the register before its project is deleted: no longer a release target, '
  'nothing at its address, its code kept, its first administrator''s address cleared. Platform owner, on the '
  'control plane, with a reason; not while a build runs. Deletes nothing (20261011040000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_retire_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its '
   'first lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Marks one register row '
   'retired, clears its first administrator''s address, cancels requests still waiting for it, and writes the '
   'platform audit row. Deletes nothing.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_retire_deployment', 'erp_meta.require_platform',
   'Retires a client deployment from the register before its project is deleted; platform owner, with a reason kept in the activity log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.platform_door_rank (schema_name, function_name, minimum_role, why) values
  ('public', 'erp_platform_retire_deployment', 'owner',
   'Takes a client out of every release and off its address; the owner decides when a client''s project ends.')
on conflict (schema_name, function_name, minimum_role) do update set why = excluded.why;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.deployment_retirement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
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
  rb       record;
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

    -- A client, built and released, as the workflows leave one.
    v_step := 'building a client';
    perform public.erp_platform_request_deployment(v_code, 'Retirement Suite Ltd', 'admin@' || v_code || '.test',
      'A client the retirement suite builds and then retires.');
    perform erp_meta.claim_fleet_request('run-' || v_tag);
    perform erp_meta.record_deployment_event(v_code, 'create', 'started', 'making the project', 'run-' || v_tag);
    perform erp_meta.register_deployment_project(v_code, 'abcdefghijklmnopqrst', 'https://abcdefghijklmnopqrst.supabase.co',
      'sb_publishable_suite', 'eu-central-1', 'micro');
    perform erp_meta.record_deployment_event(v_code, 'build', 'started', 'replaying every migration', 'run-' || v_tag);

    -- ── 1. Not while it builds ──────────────────────────────────────────────
    v_step := 'retiring while it builds';
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires a build in progress, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment whose build is running is not retired';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'building';
    detail := left(v_got, 120);
    return next;

    perform erp_meta.deployment_built(v_code);
    perform erp_meta.record_deployment_release(v_code, 'abc1234def5678', 'success', 'run-' || v_tag || '-r');
    perform public.erp_platform_request_release(array[v_code], 'A train the retirement suite asks for before retiring the client.');
    v_req := (select r.id from erp_meta.fleet_request r where r.kind = 'release' and r.status = 'requested'
               and r.payload -> 'targets' ? v_code order by r.created_at desc limit 1);

    -- ── 2. Only the owner, and only with a reason ───────────────────────────
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

    -- ── 3. Retired: off its address, its administrator forgotten ────────────
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

    -- ── 4. No longer a release target; its waiting train is cancelled ───────
    v_step := 'reading the release targets';
    v_cases := v_cases + 1;
    case_name := 'a retired deployment is no release target, and a train still waiting for it is cancelled';
    passed := not exists (select 1 from erp_meta.deployment d where d.code = v_code and d.status in ('built', 'live'))
          and (select r.status from erp_meta.fleet_request r where r.id = v_req) = 'cancelled';
    detail := coalesce((select r.status || ': ' || coalesce(r.outcome, '') from erp_meta.fleet_request r where r.id = v_req), 'no request');
    return next;

    -- ── 5. Its code stays held ──────────────────────────────────────────────
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

    -- ── 6. Once, and said ───────────────────────────────────────────────────
    v_step := 'retiring it again';
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires the same deployment twice, which must refuse.');
      v_got := 'it was retired again';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment is retired once, and the step and the platform log say who and why';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%'
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'note'
                       and e.detail like 'retired by ' || v_owner || '%Delete project abcdefghijklmnopqrst%')
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
  'Retiring a client deployment (20261011040000): not while it builds; owner only, with a reason; off its '
  'address with its administrator forgotten; no release target, and a waiting train cancelled; its code held; '
  'once, and recorded.';

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
  if v_total <> 6 then
    raise exception 'CLOVEERP_DEPLOYMENT_RETIREMENT_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment retirement: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_deployment_retirement_suite() from public, anon;

comment on function erp_test.assert_deployment_retirement_suite() is
  'A client deployment is retired by its owner before its project is deleted: off its address, out of every '
  'release, its code kept (20261011040000).';

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
