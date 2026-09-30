-- ═════════════════════════════════════════════════════════════════════════════
-- The session says its roles
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The account button in the desk's header names the person and nothing else,
-- so nobody could see at a glance what they may do here — or whether they are
-- in an organisation as its administrator or as support visiting it. There is
-- no access level in this product: roles are the organisation's own data. So
-- the session now carries the roles the signed-in principal holds, and the
-- header shows them under the name.
--
-- Each role says whether support access granted it, so a visit reads as one.
-- Same door, same volatility, same row security: erp.user_role and erp.role
-- are tenant-scoped, and the rows read are the caller's own.

set lock_timeout = '30s';

create or replace function public.erp_session()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'principal_id', erp.current_principal_id(),
    'tenant_id',    erp.current_tenant_id(),
    'principal', (
      select jsonb_build_object(
               'display_name', u.display_name,
               'given_name', u.given_name,
               'family_name', u.family_name,
               'email', u.email,
               'kind', u.kind,
               'user_locale', u.user_locale,
               'document_locale', u.document_locale,
               'reporting_locale', u.reporting_locale,
               'timezone', u.timezone)
        from erp.app_user u where u.id = erp.current_principal_id()),
    'tenant', (
      select jsonb_build_object('code', t.code, 'name', t.name, 'status', t.status)
        from erp.tenant t where t.id = erp.current_tenant_id()),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'code', e.code, 'name', e.name)
                       order by e.code)
        from erp.entity e where e.tenant_id = erp.current_tenant_id()), '[]'::jsonb),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name,
                                          'entity_id', s.entity_id) order by s.code)
        from erp.site s where s.tenant_id = erp.current_tenant_id()), '[]'::jsonb),
    'permissions', coalesce((
      select jsonb_agg(distinct code) from (
        select ep.permission_code as code
          from erp.effective_permission ep
         where ep.app_user_id = erp.current_principal_id()
           and ep.valid_from <= current_date
           and (ep.valid_to is null or ep.valid_to >= current_date)
        union
        select p.code from erp_ref.permission p
         where erp.is_platform_owner()
      ) s), '[]'::jsonb),
    -- The roles held, administrator first, each once however many scopes it
    -- is granted over; support says a support window granted it.
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name,
                                          'name_key', g.name_key, 'support', g.support)
                       order by (g.code = 'administrator') desc, g.name)
        from (select r.code, r.name, r.name_key,
                     bool_and(coalesce(ur.grant_reason, '') like 'Platform % support access:%') as support
                from erp.user_role ur
                join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
               where ur.tenant_id = erp.current_tenant_id()
                 and ur.app_user_id = erp.current_principal_id()
                 and (ur.valid_to is null or ur.valid_to > now())
               group by r.code, r.name, r.name_key) g), '[]'::jsonb)
  ))
$$;

comment on function public.erp_session() is
  'The signed-in session: principal, organisation, companies, sites, permissions, '
  'and the roles held, each saying whether support access granted it (20261003400000).';

-- The header's one new word, with the row it is renamed by.
insert into erp_ref.resource (key, locale, value, description)
values (erp_ref.ui_key('as support'), 'en', 'as support',
        'A screen string declared at its call site and rendered through ui(). Said after the roles under the name in the header when a support window granted every one of them.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ─────────────────────────────────────────────────────────────────────────────
-- The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.session_roles_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r record;
  v_session jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzsr-' || v_tag, 'Session Roles Suite', 'admin@zzsr-' || v_tag || '.test', 'Roles Admin');
    insert into auth.users (id, email) values (a1, 'admin@zzsr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);

    v_step := 'reading the session as the data API does';
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_session := public.erp_session();
    execute format('set local role %I', v_owner);

    v_cases := v_cases + 1;
    case_name := 'the session names the roles its principal holds, administrator first';
    passed := jsonb_typeof(v_session -> 'roles') = 'array'
          and (v_session -> 'roles' -> 0 ->> 'code') = 'administrator';
    detail := coalesce((v_session -> 'roles')::text, 'no roles');
    return next;

    v_cases := v_cases + 1;
    case_name := 'a role the organisation granted does not read as support';
    passed := not (v_session -> 'roles' -> 0 ->> 'support')::boolean;
    detail := coalesce((v_session -> 'roles' -> 0)::text, 'no role');
    return next;

    v_cases := v_cases + 1;
    case_name := 'each role appears once, and nothing else in the session moved';
    passed := (select count(*) from jsonb_array_elements(v_session -> 'roles') x)
              = (select count(distinct x ->> 'code') from jsonb_array_elements(v_session -> 'roles') x)
          and v_session ? 'permissions' and v_session ? 'principal' and v_session ? 'tenant'
          and (v_session ->> 'tenant_id')::uuid = r.tenant_id;
    detail := format('%s role(s)', jsonb_array_length(v_session -> 'roles'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_SESSION_ROLES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzsr-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_SESSION_ROLES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.session_roles_suite() from public, anon, authenticated;

create or replace function erp_test.assert_session_roles_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.session_roles_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SESSION_ROLES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The header would name the wrong roles, or none. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_SESSION_ROLES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('session roles: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_session_roles_suite() from public, anon;

comment on function erp_test.assert_session_roles_suite() is
  'The session names the roles its principal holds (20261003400000).';

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
