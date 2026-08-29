-- =============================================================================
-- ERPWare — the API surface the user interface is allowed to see
--
-- PostgREST exposes one set of schemas, and `erp` is deliberately not among
-- them. Adding it would put roughly a hundred and twenty tables on the REST
-- surface at once. Row-level security would still hold — that is the whole
-- point of B1 — but "protected by RLS" and "deliberately exposed" are different
-- claims, and only the second is a design.
--
-- So `public` carries a curated API instead, and it is small on purpose. Three
-- rules hold everything in it:
--
--   1. Every function is SECURITY INVOKER. A definer function here would run as
--      the owner, who holds BYPASSRLS, and hand every tenant's rows to whoever
--      called it. That is the same defect as the view-ownership leak found in
--      B1, arriving through a different door, and erp.assert_public_api_safe()
--      checks for it rather than trusting that nobody will.
--
--   2. Nothing is granted to `anon`. An unauthenticated caller has no tenant,
--      so every one of these would return nothing anyway — but relying on
--      "returns nothing" as the access control is how a later change to
--      current_tenant_id() quietly becomes a data leak.
--
--   3. Reads only. Writes go through the functions that already gate them —
--      erp.submit_command(), erp.apply_stock_movement(), erp_ai.apply_proposal()
--      — each of which authorises, validates and records. A CRUD endpoint onto
--      a table would be a way around every one of those.
--
-- The naming is erp_* so that provenance is obvious from the call site: a
-- reader of the front-end code can tell at a glance that this is the product's
-- surface and not an incidental helper someone added to public.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Who am I, and what may I see?
--
-- One round trip, because the shell needs all of it before it can render
-- anything: the principal, the tenant, the entities and sites in scope, and the
-- permissions that decide which navigation exists.
-- -----------------------------------------------------------------------------

create or replace function public.erp_session()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'principal_id', erp.current_principal_id(),
    'tenant_id',    erp.current_tenant_id(),
    'principal', (
      select jsonb_build_object(
               'display_name', u.display_name,
               'email', u.email,
               'kind', u.kind,
               'user_locale', u.user_locale,
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
    -- What the navigation may offer. Deriving it here rather than in the client
    -- means a screen cannot appear for someone who could not use it.
    'permissions', coalesce((
      select jsonb_agg(distinct ep.permission_code)
        from erp.effective_permission ep
       where ep.app_user_id = erp.current_principal_id()
         and ep.valid_from <= current_date
         and (ep.valid_to is null or ep.valid_to >= current_date)), '[]'::jsonb)
  ))
$$;

comment on function public.erp_session() is
  'Everything the shell needs before it can render: principal, tenant, scope '
  'and permissions. Permissions are derived here so a screen cannot appear for '
  'someone who could not use it.';

-- -----------------------------------------------------------------------------
-- Operational health
--
-- The screens that show whether the foundation is actually doing its job. Each
-- is a thin projection of a function built in B8 or B9, so the UI and the
-- assertions read the same source rather than two implementations that drift.
-- -----------------------------------------------------------------------------

create or replace function public.erp_job_health()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.job_code), '[]'::jsonb)
    from erp.job_health() h
$$;

create or replace function public.erp_silent_jobs()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.silent_for desc), '[]'::jsonb)
    from erp.silent_jobs() s
$$;

comment on function public.erp_silent_jobs() is
  'Spec 3.8: the jobs that have stopped running. The one health question a '
  'dashboard of failures cannot answer.';

create or replace function public.erp_integration_health()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.system_code), '[]'::jsonb)
    from erp.integration_health() h
$$;

create or replace function public.erp_integration_backlog(p_limit integer default 50)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    from erp.integration_backlog(p_limit) b
$$;

-- The platform's own conscience, surfaced. An administration screen that shows
-- these is more useful than one that shows green boxes: every entry is a thing
-- the build would refuse to ship with.
create or replace function public.erp_platform_assurance()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_check  text;
  v_error  text;
begin
  foreach v_check in array array[
    'erp.assert_isolation',
    'erp.assert_audit_coverage',
    'erp.assert_attribution_coverage',
    'erp.assert_session_context_hygiene',
    'erp.assert_gateway_integrity',
    'erp.assert_scheduler_integrity',
    'erp.assert_governed_views_are_safe',
    'erp.assert_intelligence_boundary',
    -- Defined below. Resolved at call time, so the forward reference is fine,
    -- and it belongs here rather than only in CI: this surface is the one thing
    -- on this list that a later migration could widen without touching any of
    -- the schemas the other checks watch.
    'erp.assert_public_api_safe'
  ] loop
    begin
      execute format('select %s()', v_check);
      v_error := null;
    exception when others then
      v_error := sqlerrm;
    end;

    v_result := v_result || jsonb_build_object(
      'check', v_check,
      'ok', v_error is null,
      'detail', v_error);
  end loop;

  return v_result;
end;
$$;

comment on function public.erp_platform_assurance() is
  'Runs the structural assertions and reports rather than raising, so an '
  'administration screen can show what the build checks on every push.';

-- -----------------------------------------------------------------------------
-- Grants: authenticated only, never anon
-- -----------------------------------------------------------------------------

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.erp_session()',
    'public.erp_job_health()',
    'public.erp_silent_jobs()',
    'public.erp_integration_health()',
    'public.erp_integration_backlog(integer)',
    'public.erp_platform_assurance()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- The assertion that keeps the three rules true
-- -----------------------------------------------------------------------------

create or replace function erp.public_api_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Rule 1. A definer function in public runs as the owner, who bypasses RLS.
  select 'a public API function is SECURITY DEFINER',
         p.oid::regprocedure::text,
         'it would run as the owner, who bypasses row-level security, and '
         'return every tenant''s rows'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and p.prosecdef
  union all
  -- Rule 2. Execute granted to anon.
  select 'a public API function is executable by anon',
         p.oid::regprocedure::text,
         'an unauthenticated caller should not reach the product surface at all'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  -- Rule 3, and the one that matters most: a function here that is not stable
  -- is one that can write. Writes must go through the gated paths.
  select 'a public API function is not read-only',
         p.oid::regprocedure::text,
         'it is VOLATILE, so it may write; writes belong in the functions that '
         'authorise and record them'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and p.provolatile = 'v'
$$;

create or replace function erp.assert_public_api_safe()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.public_api_report();

  if v_count > 0 then
    raise exception 'ERPWARE_PUBLIC_API_UNSAFE: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

select erp.assert_public_api_safe();
select erp.assert_isolation();
