set lock_timeout = '30s';

-- =============================================================================
-- 20261006170000  The session says which modules are installed
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-05, J-89). The
-- demonstration has not installed Manufacturing, Planning or Quality, and will
-- not; yet the rail, the home page, the palette, the first steps, the guides
-- and the scanner all offered them, and every verb on those screens was
-- refused. The owner decided (decision 6) that a module an organisation has
-- not installed is hidden from navigation and the home page.
--
-- The desk cannot hide what it is not told. It reads public.erp_session()
-- before any screen draws, and the session said nothing about modules. Asking
-- erp_module_installations() instead would cost a second read on every
-- navigation, and that door works out an upgrade plan for every installer.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_session() gains 'modules': the modules installed and in
--      force in the caller's organisation, each once, sorted. An installation
--      is in force when the change set that installed it is promoted, or when
--      it predates change sets (no change set). One waiting for a second
--      administrator's approval is not in force, and its verbs still refuse,
--      so it stays hidden until it is promoted (the owner accepted this).
--      Everything else in the answer is unchanged, and who is signed in is
--      still asked once.
--   B. erp_test.session_roles_suite compares each session it reads with the
--      body 20261006070000 replaced, which named no modules; it now sets the
--      new key aside before comparing, and counts seven parts filtered by the
--      organisation instead of six.
--   C. erp_test.session_modules_suite, five cases.
--
-- Hiding is a courtesy. The database refuses an uninstalled module's verbs
-- exactly as before; nothing here grants or removes anything.
--
-- On production: one door is replaced; no row is changed and no table
-- altered.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The session names the modules in force
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'public.erp_session()'::regprocedure);
begin
  if strpos(v_src, '20261006170000') = 0 and md5(v_src) <> '0e739d58da0eebed4a0e4b65aece276a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_session() is not the body 20261006170000 expects (md5 %)', md5(v_src);
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
               group by r.code, r.name, r.name_key) g), '[]'::jsonb),
    -- The modules installed and in force, each once (20261006170000, J-05,
    -- J-89): the change set that installed it is promoted, or it predates
    -- change sets. One awaiting a second administrator is not listed until
    -- it is promoted, because until then its verbs refuse. The desk hides
    -- what is not listed; the database refuses regardless.
    'modules', coalesce((
      select jsonb_agg(distinct i.module_code order by i.module_code)
        from erp.module_installation i
        left join erp.change_set cs
               on cs.tenant_id = i.tenant_id and cs.id = i.change_set_id
       where i.tenant_id = v_tenant
         and i.module_code is not null
         and (i.change_set_id is null or cs.status = 'promoted')), '[]'::jsonb)
  ));
end;
$$;

comment on function public.erp_session() is
  'The signed-in session: principal, organisation, companies, sites, permissions, and the roles held, each saying '
  'whether support access granted it (20261003400000). Who is signed in is asked once (20261006070000). And the '
  'modules installed and in force, so the desk offers only those (20261006170000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The session roles suite sets the new key aside
-- ─────────────────────────────────────────────────────────────────────────────
-- Its reference is the body 20261006070000 replaced, word for word, which
-- named no modules. Each session it reads is compared without them; the
-- modules are proved by C. The body now filters seven parts by the
-- organisation, not six.

do $edit$
declare
  v_sig  constant regprocedure := 'erp_test.session_roles_suite()'::regprocedure;
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'erp_test.session_roles_suite()'::regprocedure);
  v_def  text;
  v_new  text;
  v_from text;
  v_to   text;
begin
  if strpos(v_src, '20261006170000') > 0 then
    return;
  end if;
  if md5(v_src) <> '752e3c8adec149c820f4a80ace0e3e6c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp_test.session_roles_suite() is not the body 20261006170000 expects (md5 %)', md5(v_src);
  end if;

  v_def := pg_get_functiondef(v_sig);

  -- Every read of the session, six of them, sets the modules aside.
  v_from := 'public.erp_session();';
  v_to   := 'public.erp_session() - ''modules'';';
  if (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from) <> 6 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp_test.session_roles_suite() does not read the session six times';
  end if;
  v_new := replace(v_def, v_from, v_to);

  v_from := '/ length(''= v_tenant'') = 6;';
  v_to   := '/ length(''= v_tenant'') = 7;';
  if strpos(v_new, v_from) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp_test.session_roles_suite() no longer counts six organisation filters';
  end if;
  v_new := replace(v_new, v_from, v_to);

  v_from := '    v_step := ''the administrator''''s session, read both ways'';';
  v_to   := '    -- The session also names the modules in force (20261006170000), which the' || chr(10)
         || '    -- body it replaced did not: each read above and below sets them aside,' || chr(10)
         || '    -- and erp_test.session_modules_suite proves them.' || chr(10)
         || v_from;
  if strpos(v_new, v_from) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp_test.session_roles_suite() no longer reads the administrator''s session both ways';
  end if;
  v_new := replace(v_new, v_from, v_to);

  execute v_new;
end
$edit$;

comment on function erp_test.session_roles_suite() is
  'The session names the roles held, administrator first, none as support unless a support window granted it; '
  'and, read once (20261006070000, J-40), it answers what the body it replaced did for every kind of reader, '
  'the modules it now names set aside (20261006170000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.session_modules_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  r        record;
  r2       record;
  v_second uuid;
  v_token  text;
  v_cs     uuid;
  v_status text;
  v_sess   jsonb;
  v_other  jsonb;
  v_ref    jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzsm-' || v_tag, 'Session Modules Suite', 'admin@zzsm-' || v_tag || '.test', 'Modules Admin');
    insert into auth.users (id, email) values (a1, 'admin@zzsm-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    select pr.app_user_id, pr.token into v_second, v_token
      from erp.invite_principal('second@zzsm-' || v_tag || '.test', 'Second Admin') pr;
    perform erp.grant_role(v_second, 'administrator', null, null, 'the session modules suite');

    -- ── 1. A new organisation has installed nothing ─────────────────────────
    v_step := 'reading a new organisation''s session as the data API does';
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_sess := public.erp_session();
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a new organisation''s session names its modules as an array, and it is empty';
    passed := jsonb_typeof(v_sess -> 'modules') = 'array'
          and v_sess -> 'modules' = '[]'::jsonb
          and not exists (select 1 from erp.module_installation i where i.tenant_id = r.tenant_id);
    detail := coalesce((v_sess -> 'modules')::text, 'no modules key');
    return next;

    -- ── 2. An install awaiting a second administrator is not in force ───────
    v_step := 'installing Quality, which waits for a second administrator';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cs := erp.configure_quality();
    select cs.status::text into v_status from erp.change_set cs where cs.id = v_cs;
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_sess := public.erp_session();
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'a module whose install awaits approval is not named, although its installation is recorded';
    passed := v_status in ('ready', 'approved')
          and exists (select 1 from erp.module_installation i
                       where i.tenant_id = r.tenant_id and i.module_code = 'quality' and i.change_set_id = v_cs)
          and v_sess -> 'modules' = '[]'::jsonb;
    detail := format('change set %s; modules %s', v_status, v_sess -> 'modules');
    return next;

    -- ── 3. Promoted, it is named, and nothing else is ───────────────────────
    v_step := 'the second administrator approves and promotes the install';
    insert into auth.users (id, email) values (a2, 'second@zzsm-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_sess := public.erp_session();
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'once its install is promoted the session names quality, and neither production nor planning';
    passed := v_sess -> 'modules' = '["quality"]'::jsonb
          and not (v_sess -> 'modules') ? 'production'
          and not (v_sess -> 'modules') ? 'planning';
    detail := coalesce((v_sess -> 'modules')::text, 'no modules key');
    return next;

    -- ── 4. Another organisation's modules are its own ───────────────────────
    v_step := 'a second organisation, with Planning installed before change sets';
    perform set_config('request.jwt.claims', '', true);
    select * into r2 from erp.provision_tenant(
      'zzsm2-' || v_tag, 'Session Modules Other', 'admin@zzsm2-' || v_tag || '.test', 'Other Admin');
    insert into auth.users (id, email) values (a3, 'admin@zzsm2-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    insert into erp.module_installation (tenant_id, install_code, module_code, installer_version, change_set_id)
    values (r2.tenant_id, 'planning', 'planning', 1, null);
    perform set_config('request.jwt.claims',
      json_build_object('sub', a3, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_other := public.erp_session();
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_sess := public.erp_session();
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'an installation with no change set is in force, and only in its own organisation''s session';
    passed := v_other -> 'modules' = '["planning"]'::jsonb
          and (v_other ->> 'tenant_id')::uuid = r2.tenant_id
          and v_sess -> 'modules' = '["quality"]'::jsonb
          and (v_sess ->> 'tenant_id')::uuid = r.tenant_id;
    detail := format('other %s; first %s', v_other -> 'modules', v_sess -> 'modules');
    return next;

    -- ── 5. Each module once, and nothing else in the session moved ──────────
    v_step := 'comparing with the body the session replaced';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_ref := erp_test.erp_session_reference();
    v_cases := v_cases + 1;
    case_name := 'each module is named once, and the rest of the session is what it was before';
    passed := (select count(*) from jsonb_array_elements_text(v_sess -> 'modules') x)
              = (select count(distinct x) from jsonb_array_elements_text(v_sess -> 'modules') x)
          and (v_sess - 'modules') = v_ref
          and jsonb_array_length(v_ref -> 'permissions') > 0
          and (v_ref -> 'roles' -> 0 ->> 'code') = 'administrator';
    detail := case when (v_sess - 'modules') = v_ref
                   then format('%s module(s), %s permission(s)', jsonb_array_length(v_sess -> 'modules'),
                               jsonb_array_length(v_ref -> 'permissions'))
                   else format('new %s | before %s', left((v_sess - 'modules')::text, 300), left(v_ref::text, 300)) end;
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
    raise exception 'CLOVEERP_SESSION_MODULES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('zzsm-' || v_tag, 'zzsm2-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (a1, a2, a3)) then
    raise exception 'CLOVEERP_SESSION_MODULES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.session_modules_suite() from public, anon;

comment on function erp_test.session_modules_suite() is
  'The session names the modules installed and in force (20261006170000, J-05, J-89): none for a new '
  'organisation; not one awaiting approval; one once promoted; one installed before change sets; never another '
  'organisation''s; each once, and the rest of the session as it was.';

create or replace function erp_test.assert_session_modules_suite()
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
    from erp_test.session_modules_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SESSION_MODULES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The desk would offer a module that is not in force, or hide one that is, or show another organisation''s. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_SESSION_MODULES_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('session modules: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_session_modules_suite() from public, anon;

comment on function erp_test.assert_session_modules_suite() is
  'The session names the modules installed and in force, and only those (20261006170000).';

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
select erp.assert_personal_data_register_sound();
