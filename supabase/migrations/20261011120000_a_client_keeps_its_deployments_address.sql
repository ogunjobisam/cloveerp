set lock_timeout = '30s';

-- =============================================================================
-- 20261011120000  A client keeps its deployment's address
-- -----------------------------------------------------------------------------
-- 20261011100000 made a client's own deployment hold one organisation, under
-- the address the deployment is served at (erp.deployment_code()), because the
-- control plane's subscription for that client names that code. Changing the
-- organisation's address afterwards was still open: the console's Change
-- address and the organisation's own Address card both pass through
-- erp.refuse_unchosen_address, which knew nothing about the deployment. A
-- client's organisation now keeps the deployment's address there; renaming a
-- client is a fleet operation done from the control plane. Making the
-- organisation is left to erp.require_client_organisation (20261011100000).
--
-- Also: 20261011110000 recorded erp_platform_restart_deployment as a door with
-- no screen yet. The Fleet view's Start again names it in the same pull
-- request, so the record is removed here, before anything reads it.
-- =============================================================================

do $$
declare
  v_sig  constant regprocedure := 'erp.refuse_unchosen_address(text,uuid)'::regprocedure;
  v_src  text := (select p.prosrc from pg_proc p where p.oid = v_sig);
  v_def  text := pg_get_functiondef(v_sig);
  v_old  constant text := E'begin\n  if v_code like ''demo-%'' then';
  v_new  constant text := E'begin\n'
    '  -- On a client''s own deployment an organisation that exists keeps the\n'
    '  -- address the deployment is served at (20261011120000). Making one is\n'
    '  -- asked by erp.require_client_organisation, which says more.\n'
    '  if p_tenant is not null and erp.deployment_kind() = ''client''\n'
    '     and v_code is distinct from erp.deployment_code() then\n'
    '    raise exception ''CLOVEERP_CLIENT_ORGANISATION_CODE: this deployment is served as %, so its organisation keeps that address, not %'',\n'
    '      coalesce(erp.deployment_code(), ''an address it has not been told yet''), coalesce(nullif(v_code, ''''), ''nothing'')\n'
    '      using errcode = ''22023'',\n'
    '            hint = ''An organisation on a client''''s own deployment keeps the address the deployment is served at. To change it, rename the deployment from the platform console at cloveerp.com.'';\n'
    '  end if;\n'
    '  if v_code like ''demo-%'' then';
begin
  if strpos(v_src, '20261011120000') > 0 then
    raise notice 'erp.refuse_unchosen_address already keeps a client''s address';
    return;
  end if;
  if md5(v_src) <> '573a14e132b6b69ac5dca60b530660bf' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.refuse_unchosen_address is not the body this migration was written against';
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.refuse_unchosen_address does not hold its anchor exactly once';
  end if;
  execute replace(v_def, v_old, v_new);
end
$$;

delete from erp_meta.api_only_door where function_name = 'erp_platform_restart_deployment';

create or replace function erp_test.client_address_is_its_deployments_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  v_uid    uuid := gen_random_uuid();
  v_owner  text;
  v_tenant uuid;
  v_json   jsonb;
  v_step   text := 'standing up an owner on a client';
  v_state  text;
  v_got    text;
  v_got2   text;
begin
  begin
    v_code := 'zzadr-' || v_tag;
    v_owner := 'owner@' || v_code || '.test';
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Client Address Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason) values
      ('deployment.kind', '"client"'::jsonb, 'client_address_is_its_deployments_suite'),
      ('deployment.app_origin', to_jsonb('https://' || v_code || '.cloveerp.com'), 'client_address_is_its_deployments_suite');

    -- ── 1. The console cannot move a client's organisation to another address
    v_step := 'changing a client organisation''s address from the console';
    -- Whatever organisations this database holds are put out of the way for
    -- the length of the suite: a client starts empty.
    update erp.tenant t set status = 'deleted' where t.status not in ('deleting', 'deleted');
    v_json := public.erp_platform_onboard_company(v_code, 'Client Address Ltd', 'admin@' || v_code || '.test', 'Client Admin');
    v_tenant := (v_json ->> 'tenant_id')::uuid;
    begin
      perform public.erp_platform_set_tenant_address(v_tenant, v_code || '-elsewhere',
        'The client address suite moves the organisation, which must refuse.');
      v_got := 'it was moved';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the console cannot give a client''s organisation an address other than its deployment''s';
    passed := v_got like 'CLOVEERP_CLIENT_ORGANISATION_CODE%'
          and (select t.code from erp.tenant t where t.id = v_tenant) = v_code;
    detail := left(v_got, 160);
    return next;

    -- ── 2. The shared check: its own address passes, any other refuses ───────
    v_step := 'asking the shared address check on a client';
    begin
      perform erp.refuse_unchosen_address(v_code, v_tenant);
      v_got := 'its own address passes';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.refuse_unchosen_address('zzoth-' || v_tag, v_tenant);
      v_got2 := 'another address passes';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'on a client the address check passes the deployment''s own address and refuses any other';
    passed := v_got = 'its own address passes' and v_got2 like 'CLOVEERP_CLIENT_ORGANISATION_CODE%';
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80);
    return next;

    -- ── 3. Elsewhere the check is as it was ─────────────────────────────────
    v_step := 'asking the shared address check on the demonstration';
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"demonstration"'::jsonb, 'client_address_is_its_deployments_suite');
    begin
      perform erp.refuse_unchosen_address('zzdem-' || v_tag, null);
      v_got := 'another address passes';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'off a client the address check does not ask about a deployment';
    passed := v_got = 'another address passes';
    detail := left(v_got, 160);
    return next;

    -- ── 4. Start again has its screen ───────────────────────────────────────
    v_step := 'reading the register of doors with no screen';
    v_cases := v_cases + 1;
    case_name := 'the restart door is not recorded as a door with no screen, because the Fleet view names it';
    passed := not exists (select 1 from erp_meta.api_only_door d where d.function_name = 'erp_platform_restart_deployment');
    detail := case when passed then 'not recorded' else 'still recorded' end;
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
    raise exception 'CLOVEERP_CLIENT_ADDRESS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_client_address_is_its_deployments_suite()
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
    from erp_test.client_address_is_its_deployments_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CLIENT_ADDRESS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A client''s organisation can leave its deployment''s address: read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_CLIENT_ADDRESS_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('client address: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.client_address_is_its_deployments_suite() from public, anon;
revoke all on function erp_test.assert_client_address_is_its_deployments_suite() from public, anon;

comment on function erp_test.assert_client_address_is_its_deployments_suite() is
  'A client''s own deployment keeps its one organisation at the deployment''s address, from the console and from '
  'the organisation''s own Address card; elsewhere the address check is unchanged (20261011120000).';

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
