set lock_timeout = '30s';

-- =============================================================================
-- 20261006070000  The session is read once
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-40). Every page load
-- reads public.erp_session(), and under load it took 8 to 14 seconds and was
-- cancelled at the signed-in limit.
--
-- Its body asked who was signed in, and for which organisation, nine times:
-- four calls of erp.current_principal_id() and five of erp.current_tenant_id(),
-- each of them a call of erp.principal_context() (a lookup of the sign-in in
-- erp.app_user, then whether a support window has closed). Neither call can be
-- folded into the query, so where a table was scanned row by row, and where a
-- join rescanned an index, the question was asked again for every row. On the
-- fixtures one session read asked it 106 times; the more roles, permissions,
-- companies and sites an organisation has, the more times it asks.
-- erp.principal_context() itself found the sign-in through an index that leads
-- on the organisation, which it does not know yet, so it read app_user whole.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. An index on erp.app_user (auth_user_id) for the people and services who
--      are active, so finding who is signed in is one probe.
--   B. erp_test.erp_session_reference(): today's body, word for word, kept as
--      the answer the new one must give.
--   C. public.erp_session() asks erp.principal_context() once, keeps the
--      principal and the organisation in two variables, and every part of the
--      answer is filtered by them. Where nobody is signed in (a trusted job,
--      a worker) it falls back to erp.current_principal_id() and
--      erp.current_tenant_id() exactly as before. Each table's row policy is
--      then answered once per part of the answer, not once per row. The
--      answer is the same: same keys, same order, same values.
--   D. erp_test.session_roles_suite gains six cases (3 to 9): the new body
--      answers what the old one did for the suite's administrator, for a
--      person holding a narrower role, for every person already signed up in
--      the database, for a trusted job acting for the organisation and for
--      nobody at all; and the body asks who is signed in once.
--
-- On production: one index is built on erp.app_user (a small table; the build
-- holds off writes to it for as long as it takes, and no reader waits). One
-- door is replaced; no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Who is signed in, found by one probe
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists app_user_auth_user_id_active_idx
  on erp.app_user (auth_user_id)
  where status = 'active'::erp.principal_status;

comment on index erp.app_user_auth_user_id_active_idx is
  'Who is signed in, found by one probe (20261006070000, J-40): erp.principal_context() looks the sign-in up '
  'by auth_user_id among the active principals before it knows the organisation.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Today's body, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.erp_session_reference()
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

revoke all on function erp_test.erp_session_reference() from public, anon;

comment on function erp_test.erp_session_reference() is
  'public.erp_session() as it was before 20261006070000, word for word: the answer the session read must still '
  'give (J-40). Read only by erp_test.session_roles_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The session asks who is signed in once
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'public.erp_session()'::regprocedure);
begin
  if strpos(v_src, '20261006070000') = 0 and md5(v_src) <> '3fe7cc62dd47228035b9dd900e537116' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_session() is not the body 20261006070000 expects (md5 %)', md5(v_src);
  end if;
end
$guard$;

create or replace function public.erp_session()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_principal uuid;
  v_tenant    uuid;
begin
  -- Who is signed in, and for which organisation, asked once (20261006070000,
  -- J-40). Every part of the answer below is filtered by these two, so each
  -- table's row policy is answered once per part, not once per row.
  select pc.principal_id, pc.tenant_id
    into v_principal, v_tenant
    from erp.principal_context() pc;

  -- Nobody signed in: a trusted job or worker may still act for an
  -- organisation, and for a service principal of its own. Answered as before.
  if v_principal is null then
    v_principal := erp.current_principal_id();
    v_tenant    := erp.current_tenant_id();
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'principal_id', v_principal,
    'tenant_id',    v_tenant,
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
        from erp.app_user u where u.tenant_id = v_tenant and u.id = v_principal),
    'tenant', (
      select jsonb_build_object('code', t.code, 'name', t.name, 'status', t.status)
        from erp.tenant t where t.id = v_tenant),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'code', e.code, 'name', e.name)
                       order by e.code)
        from erp.entity e where e.tenant_id = v_tenant), '[]'::jsonb),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name,
                                          'entity_id', s.entity_id) order by s.code)
        from erp.site s where s.tenant_id = v_tenant), '[]'::jsonb),
    'permissions', coalesce((
      select jsonb_agg(distinct code) from (
        select ep.permission_code as code
          from erp.effective_permission ep
         where ep.tenant_id = v_tenant
           and ep.app_user_id = v_principal
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
               where ur.tenant_id = v_tenant
                 and ur.app_user_id = v_principal
                 and (ur.valid_to is null or ur.valid_to > now())
               group by r.code, r.name, r.name_key) g), '[]'::jsonb)
  ));
end;
$$;

comment on function public.erp_session() is
  'The signed-in session: principal, organisation, companies, sites, permissions, and the roles held, each saying '
  'whether support access granted it (20261003400000). Who is signed in is asked once (20261006070000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.session_roles_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r record;
  p record;
  v_session jsonb;
  v_new   jsonb;
  v_ref   jsonb;
  v_new_owner jsonb;
  v_person uuid;
  v_token  text;
  v_seen   integer := 0;
  v_differ text := '';
  v_src    text;
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

    -- ── The session read once answers what it answered before ───────────────
    -- (20261006070000). The reference is today's body, read under the same
    -- sign-in by the suite's owner: every part of it names its organisation
    -- or its principal, so the row policies do not change what it answers.
    v_step := 'the administrator''s session, read both ways';
    v_ref := erp_test.erp_session_reference();
    v_new_owner := public.erp_session();
    v_cases := v_cases + 1;
    case_name := 'the administrator''s session is the same as the body it replaced gave';
    passed := v_session = v_ref and v_new_owner = v_ref
          and jsonb_array_length(v_ref -> 'permissions') > 0
          and jsonb_array_length(v_ref -> 'entities') > 0;
    detail := case when v_session = v_ref and v_new_owner = v_ref
                   then format('%s permission(s), %s compan(ies), %s site(s)',
                               jsonb_array_length(v_ref -> 'permissions'),
                               jsonb_array_length(v_ref -> 'entities'),
                               jsonb_array_length(v_ref -> 'sites'))
                   else format('new %s | before %s', left(v_session::text, 300), left(v_ref::text, 300)) end;
    return next;

    v_step := 'a second person, holding a narrower role';
    select pr.app_user_id, pr.token into v_person, v_token
      from erp.invite_principal('observer@zzsr-' || v_tag || '.test', 'Session Observer') pr;
    perform erp.grant_role(v_person, 'observer', null, null, 'the session suite');
    insert into auth.users (id, email) values (a2, 'observer@zzsr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_token);
    perform set_config('request.jwt.claims',
      json_build_object('sub', a2, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_new := public.erp_session();
    execute format('set local role %I', v_owner);
    v_ref := erp_test.erp_session_reference();
    v_cases := v_cases + 1;
    case_name := 'a person holding a narrower role reads the same session as before';
    passed := v_new = v_ref
          and (v_new -> 'roles' -> 0 ->> 'code') = 'observer'
          and (v_new ->> 'principal_id')::uuid = v_person
          and jsonb_array_length(v_new -> 'permissions') < jsonb_array_length(v_session -> 'permissions');
    detail := case when v_new = v_ref then format('%s permission(s)', jsonb_array_length(v_new -> 'permissions'))
                   else format('new %s | before %s', left(v_new::text, 300), left(v_ref::text, 300)) end;
    return next;

    v_step := 'every person already signed up';
    for p in select u.auth_user_id
               from erp.app_user u
              where u.kind = 'person' and u.status = 'active' and u.auth_user_id is not null
              order by u.created_at, u.id loop
      perform set_config('request.jwt.claims',
        json_build_object('sub', p.auth_user_id, 'role', 'authenticated')::text, true);
      begin
        execute 'set local role authenticated';
        v_new := public.erp_session();
        execute format('set local role %I', v_owner);
      exception when others then
        execute format('set local role %I', v_owner);
        v_new := jsonb_build_object('refused', sqlerrm);
      end;
      begin
        v_ref := erp_test.erp_session_reference();
      exception when others then
        v_ref := jsonb_build_object('refused', sqlerrm);
      end;
      v_seen := v_seen + 1;
      if v_new is distinct from v_ref then
        v_differ := v_differ || p.auth_user_id::text || '; ';
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'every person signed up in the database reads the same session as before';
    passed := v_seen >= 2 and v_differ = '';
    detail := format('%s person(s) read; differing: %s', v_seen, coalesce(nullif(v_differ, ''), 'none'));
    return next;

    v_step := 'a trusted job acting for the organisation';
    perform set_config('request.jwt.claims', '', true);
    perform erp.set_job_tenant(r.tenant_id);
    v_new := public.erp_session();
    v_ref := erp_test.erp_session_reference();
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'a trusted job with no sign-in reads the same session as before';
    passed := v_new = v_ref and (v_new ->> 'tenant_id')::uuid = r.tenant_id and not v_new ? 'principal_id';
    detail := format('new %s | before %s', left(v_new::text, 160), left(v_ref::text, 160));
    return next;

    v_step := 'nobody at all';
    v_new := public.erp_session();
    v_ref := erp_test.erp_session_reference();
    v_cases := v_cases + 1;
    case_name := 'with nobody signed in and no organisation the session is as empty as before';
    passed := v_new = v_ref and not v_new ? 'tenant_id' and not v_new ? 'principal_id';
    detail := format('new %s | before %s', v_new, v_ref);
    return next;

    v_step := 'reading the body';
    select pp.prosrc into v_src from pg_catalog.pg_proc pp where pp.oid = 'public.erp_session()'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'the session asks who is signed in once, and every part is filtered by the answer';
    passed := (length(v_src) - length(replace(v_src, 'erp.principal_context()', ''))) / length('erp.principal_context()') = 1
          and (length(v_src) - length(replace(v_src, 'erp.current_tenant_id()', ''))) / length('erp.current_tenant_id()') = 1
          and (length(v_src) - length(replace(v_src, 'erp.current_principal_id()', ''))) / length('erp.current_principal_id()') = 1
          and (length(v_src) - length(replace(v_src, '= v_tenant', ''))) / length('= v_tenant') = 6;
    detail := format('%s characters', length(v_src));
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
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_SESSION_ROLES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.session_roles_suite() from public, anon;

comment on function erp_test.session_roles_suite() is
  'The session names the roles held, administrator first, none as support unless a support window granted it; '
  'and, read once (20261006070000, J-40), it answers what the body it replaced did for every kind of reader.';

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
      using hint = 'The header would name the wrong roles, or none, or the session read once answers otherwise than before. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_SESSION_ROLES_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('session roles: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_session_roles_suite() from public, anon;

comment on function erp_test.assert_session_roles_suite() is
  'The session names the roles held, and read once it answers as before (20261006070000).';

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
