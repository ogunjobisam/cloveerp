set lock_timeout = '30s';

-- =============================================================================
-- 20261011080000  A retirement forgets the deployment's credentials
-- -----------------------------------------------------------------------------
-- A client deployment's build keeps three things in the control plane's
-- vault: its connection string and its service key, named by its project's
-- ref, and, while the ref is not yet known, its database password, named by
-- its code (deployment_from_empty.yml, supabase/ci/fleet_register.sh). The
-- retire door left all three behind. Once the owner deletes the project they
-- are dead credentials; until then they are live ones to a deployment that
-- nothing should reach any more.
--
-- The door now deletes them as it retires, says how many in the step the
-- Fleet view shows, and returns the count. A database with no vault (every
-- test build) has nothing to delete and still retires. Deployments retired
-- before this are cleared once, below, and each is given a step saying so.
-- The retirement suite proves it against a stand-in vault, gains a case, and
-- is re-pinned at ten.
--
-- The reason the owner gives is also no longer followed by a second full stop
-- when it ends with one.
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
  v_names text[];
  v_forgotten integer := 0;
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

  -- Its stored credentials: nothing connects to it again, and its project is
  -- deleted next. Named as deployment_from_empty.yml keeps them: by ref, its
  -- connection and its service key; by code, the database password a build
  -- holds while the ref is not yet known. Through the catalogue rather than
  -- by name, because a database with no vault (a test build) has nothing to
  -- delete and must still be able to retire (20261011080000).
  v_names := array_remove(array[
    case when d.project_ref is not null then format('cloveerp:deployment:%s:db_url', d.project_ref) end,
    case when d.project_ref is not null then format('cloveerp:deployment:%s:service_key', d.project_ref) end,
    format('cloveerp:provision:%s:db_pass', d.code)], null);
  if exists (select 1 from pg_catalog.pg_namespace n where n.nspname = 'vault') then
    execute 'delete from vault.secrets s where s.name = any($1)' using v_names;
    get diagnostics v_forgotten = row_count;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('retired by %s (was %s): %s. Nothing runs for it now: %s; delete project %s in the Supabase dashboard. Its address needs nothing removed: it answers nothing once retired.',
           v.email, d.status, rtrim(btrim(p_reason), '.'),
           case v_forgotten
             when 0 then 'the vault held no credentials of it'
             when 1 then 'its one stored credential is deleted from the vault'
             else format('its %s stored credentials are deleted from the vault', v_forgotten)
           end,
           coalesce(d.project_ref, 'that was never made')));

  perform erp_meta.platform_log(v, 'platform.deployment_retired', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'project_ref', d.project_ref, 'credentials_deleted', v_forgotten));

  return jsonb_build_object('code', d.code, 'status', c_retired, 'was', d.status, 'project_ref', d.project_ref,
                            'credentials_deleted', v_forgotten);
end;
$$;


revoke all on function public.erp_platform_retire_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_retire_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_retire_deployment(text, text) is
  'Retires a client deployment from the register before its project is deleted: no longer a release target, '
  'nothing at its address, its code kept, its first administrator''s address cleared, and its stored credentials '
  'deleted from the vault. Platform owner, on the control plane, with a reason; not while a build or a release '
  'runs. Deletes nothing else: its project is the owner''s to delete (20261011040000, 20261011080000).';

revoke all on function erp_test.deployment_retirement_suite() from public, anon;
revoke all on function erp_test.assert_deployment_retirement_suite() from public, anon;

comment on function erp_test.assert_deployment_retirement_suite() is
  'A client deployment is retired by its owner, only when nothing runs for it, and stays retired: off its address, '
  'out of every release, its code kept, its stored credentials deleted (20261011040000, 20261011050000, 20261011080000).';

create or replace function erp_test.deployment_retirement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
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
  v_names  text[];
  v_n      integer;
  v_n2     integer;
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

    -- What the workflows keep for it in the vault, and an entry of another
    -- deployment's that must outlive its retirement. A test build has no
    -- vault: a stand-in with the one column the door reads is made for the
    -- suite, and undone with everything else it did.
    v_step := 'keeping its credentials';
    v_names := array['cloveerp:deployment:abcdefghijklmnopqrst:db_url',
                     'cloveerp:deployment:abcdefghijklmnopqrst:service_key',
                     'cloveerp:provision:' || v_code || ':db_pass',
                     'cloveerp:deployment:zyxwvutsrqponmlkjihg:db_url'];
    if not exists (select 1 from pg_catalog.pg_namespace n where n.nspname = 'vault') then
      execute 'create schema vault';
      execute 'create table vault.secrets (id uuid primary key default gen_random_uuid(), name text, secret text)';
      execute 'insert into vault.secrets (name, secret) select x, ''suite'' from unnest($1::text[]) x' using v_names;
    else
      for i in 1 .. array_length(v_names, 1) loop
        execute 'select vault.create_secret($1, $2, $3)' using 'suite', v_names[i], 'deployment retirement suite';
      end loop;
    end if;

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

    -- ── 6. Its credentials go with it, and nobody else's ────────────────────
    v_step := 'reading the vault after retiring';
    execute 'select count(*) from vault.secrets s where s.name = any($1)' into v_n using v_names[1:3];
    execute 'select count(*) from vault.secrets s where s.name = $1' into v_n2 using v_names[4];
    v_cases := v_cases + 1;
    case_name := 'a retired deployment''s stored credentials are deleted from the vault, and no other deployment''s';
    passed := (v_json ->> 'credentials_deleted')::integer = 3 and v_n = 0 and v_n2 = 1;
    detail := format('%s deleted, %s of its left, %s of another''s left', coalesce(v_json ->> 'credentials_deleted', 'none'), v_n, v_n2);
    return next;

    -- ── 7. No release starts for it; a waiting train is left for the rest ──
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

    -- ── 8. Once retired, nothing writes it back ─────────────────────────────
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

    -- ── 9. Its code stays held ──────────────────────────────────────────────
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

    -- ── 10. Once, and said ───────────────────────────────────────────────────
    v_step := 'retiring it again';
    begin
      perform public.erp_platform_retire_deployment(v_code, 'The retirement suite retires the same deployment twice, which must refuse.');
      v_got := 'it was retired again';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment is retired once, and the step and the platform log say who, why, what was deleted, and that nothing runs for it';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE%retired already%'
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'note'
                       and e.detail like 'retired by ' || v_owner || '%deleted. Nothing runs for it now: its 3 stored credentials are deleted from the vault; delete project abcdefghijklmnopqrst%')
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
  if v_total <> 10 then
    raise exception 'CLOVEERP_DEPLOYMENT_RETIREMENT_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment retirement: %s/%s cases passed', v_total, v_total);
end;
$$;


-- Deployments retired before the door deleted their credentials. Only the
-- control plane keeps a register, and only a real project has a vault, so
-- everywhere else this does nothing.
do $$
declare
  c_retired constant text := 'retired';
  r      record;
  v_n    integer;
begin
  if not exists (select 1 from pg_catalog.pg_namespace n where n.nspname = 'vault') then
    return;
  end if;
  for r in
    select d.code, d.project_ref from erp_meta.deployment d where d.status = c_retired order by d.code
  loop
    execute 'delete from vault.secrets s where s.name = any($1)'
      using array_remove(array[
        case when r.project_ref is not null then format('cloveerp:deployment:%s:db_url', r.project_ref) end,
        case when r.project_ref is not null then format('cloveerp:deployment:%s:service_key', r.project_ref) end,
        format('cloveerp:provision:%s:db_pass', r.code)], null);
    get diagnostics v_n = row_count;
    if v_n > 0 then
      perform erp_meta.record_deployment_event(r.code, 'note', 'done',
        format('%s stored credential(s) of this retired deployment deleted from the vault (20261011080000): retiring now deletes them, and these were kept from before.', v_n));
    end if;
  end loop;
end
$$;

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
