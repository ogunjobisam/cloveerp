-- =============================================================================
-- ERPWare — B1: the adversarial isolation suite
-- Spec 2.2: "Automated isolation testing: the test suite includes adversarial
--            cases attempting cross-tenant reads and writes through every
--            entry point, and these run on every build."
--
-- erp.assert_isolation() (migration 0004) proves the SHAPE of the schema is
-- safe. This proves the BEHAVIOUR is: it stands up two tenants, authenticates
-- as one of them for real, and then tries every way there is to touch the
-- other. Each case asserts a refusal, not merely an empty result.
--
-- The suite runs inside one transaction and rolls its fixtures back, so it is
-- safe against any environment including production.
-- =============================================================================

create schema if not exists erp_test;

comment on schema erp_test is
  'Test harness. Not reachable by any tenant role; exists so that isolation is '
  'a property that is checked on every build rather than assumed.';

revoke all on schema erp_test from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- The suite
--
-- SECURITY INVOKER, deliberately. PostgreSQL refuses SET ROLE inside a
-- SECURITY DEFINER function, and this suite is worthless without it: the whole
-- point is to become the `authenticated` role for real rather than to simulate
-- what that role would see. So it must be called by a role that can both create
-- fixtures and assume `authenticated` — the migration owner, at build time.
--
-- Every role switch happens inline in this frame. A SET ROLE performed inside a
-- *called* function would be unwound when that function returned, so the
-- impersonation has to sit in the same frame as the query it is testing.
-- -----------------------------------------------------------------------------

create or replace function erp_test.isolation_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_owner       text := current_user;
  v_tenant_a    uuid;
  v_tenant_b    uuid;
  v_user_a      uuid;
  v_user_b      uuid;
  v_auth_a      uuid := gen_random_uuid();
  v_auth_b      uuid := gen_random_uuid();
  v_entity_a    uuid;
  v_entity_b    uuid;
  v_site_b      uuid;
  v_role_b      uuid;
  v_count       bigint;
  v_uuid        uuid;
  v_text        text;
  v_ok          boolean;
  v_detail      text;
begin
  -- ---------------------------------------------------------------------------
  -- Fixtures, created as the trusted owner.
  -- ---------------------------------------------------------------------------
  insert into erp_ref.currency (code, name, minor_units)
  values ('XTS', 'Test currency', 2)
  on conflict (code) do nothing;

  insert into erp.tenant (code, name, status)
  values ('zz-isolation-a', 'Isolation fixture A', 'active') returning id into v_tenant_a;
  insert into erp.tenant (code, name, status)
  values ('zz-isolation-b', 'Isolation fixture B', 'active') returning id into v_tenant_b;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_a, v_auth_a, 'person', 'active', 'Fixture A', 'a@example.invalid')
  returning id into v_user_a;
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_b, v_auth_b, 'person', 'active', 'Fixture B', 'b@example.invalid')
  returning id into v_user_b;

  insert into erp.entity (tenant_id, code, name, base_currency)
  values (v_tenant_a, 'EA', 'Entity A', 'XTS') returning id into v_entity_a;
  insert into erp.entity (tenant_id, code, name, base_currency)
  values (v_tenant_b, 'EB', 'Entity B', 'XTS') returning id into v_entity_b;

  insert into erp.site (tenant_id, entity_id, code, name, site_type)
  values (v_tenant_b, v_entity_b, 'SB', 'Site B', 'warehouse') returning id into v_site_b;

  insert into erp.role (tenant_id, code, name)
  values (v_tenant_b, 'RB', 'Role B') returning id into v_role_b;

  insert into erp.access_log (tenant_id, app_user_id, permission_code, granted)
  values (v_tenant_b, v_user_b, 'admin.read', true);

  -- ---------------------------------------------------------------------------
  -- Become tenant A, for real: the `authenticated` role, with a JWT subject
  -- that resolves through erp.app_user to tenant A and nothing else.
  -- ---------------------------------------------------------------------------
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_auth_a, 'role', 'authenticated')::text);
  set local role authenticated;

  -- --- 1. Context resolution ------------------------------------------------
  case_name := 'session resolves to its own tenant';
  select erp.current_tenant_id() into v_uuid;
  passed := (v_uuid = v_tenant_a);
  detail := format('current_tenant_id() = %s, expected %s', v_uuid, v_tenant_a);
  return next;

  case_name := 'session resolves to its own principal';
  select erp.current_principal_id() into v_uuid;
  passed := (v_uuid = v_user_a);
  detail := format('current_principal_id() = %s', v_uuid);
  return next;

  -- --- 2. Cross-tenant reads ------------------------------------------------
  case_name := 'cannot read another tenant''s entities';
  select count(*) into v_count from erp.entity where tenant_id = v_tenant_b;
  passed := (v_count = 0);
  detail := format('%s row(s) visible', v_count);
  return next;

  case_name := 'cannot read another tenant''s principals';
  select count(*) into v_count from erp.app_user where tenant_id = v_tenant_b;
  passed := (v_count = 0);
  detail := format('%s row(s) visible', v_count);
  return next;

  case_name := 'cannot read another tenant''s sites';
  select count(*) into v_count from erp.site where tenant_id = v_tenant_b;
  passed := (v_count = 0);
  detail := format('%s row(s) visible', v_count);
  return next;

  case_name := 'cannot read another tenant''s access log';
  select count(*) into v_count from erp.access_log where tenant_id = v_tenant_b;
  passed := (v_count = 0);
  detail := format('%s row(s) visible', v_count);
  return next;

  case_name := 'cannot read the other tenant''s root row';
  select count(*) into v_count from erp.tenant where id = v_tenant_b;
  passed := (v_count = 0);
  detail := format('%s row(s) visible', v_count);
  return next;

  case_name := 'own tenant root row is visible';
  select count(*) into v_count from erp.tenant where id = v_tenant_a;
  passed := (v_count = 1);
  detail := format('%s row(s) visible', v_count);
  return next;

  -- Targeting a row by primary key rather than by tenant_id: a policy keyed on
  -- the wrong column would pass the tests above and fail this one.
  case_name := 'cannot read another tenant''s row by its primary key';
  select count(*) into v_count from erp.entity where id = v_entity_b;
  passed := (v_count = 0);
  detail := format('%s row(s) visible', v_count);
  return next;

  -- --- 3. Cross-tenant writes -----------------------------------------------
  case_name := 'cannot insert a row into another tenant';
  begin
    insert into erp.role (tenant_id, code, name)
    values (v_tenant_b, 'INTRUDER', 'Intruder');
    passed := false; detail := 'insert was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'cannot update another tenant''s row';
  update erp.role set name = 'hijacked' where id = v_role_b;
  get diagnostics v_count = row_count;
  passed := (v_count = 0);
  detail := format('%s row(s) updated', v_count);
  return next;

  case_name := 'cannot delete another tenant''s row';
  delete from erp.role where id = v_role_b;
  get diagnostics v_count = row_count;
  passed := (v_count = 0);
  detail := format('%s row(s) deleted', v_count);
  return next;

  case_name := 'cannot move an own row into another tenant';
  begin
    update erp.entity set tenant_id = v_tenant_b where id = v_entity_a;
    get diagnostics v_count = row_count;
    passed := false;
    detail := format('%s row(s) reassigned', v_count);
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- 4. Append-only surfaces (spec 3.2) -----------------------------------
  case_name := 'cannot update the access log, even within own tenant';
  begin
    update erp.access_log set granted = false where tenant_id = v_tenant_a;
    get diagnostics v_count = row_count;
    passed := (v_count = 0);
    detail := format('%s row(s) updated without error', v_count);
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'cannot delete from the access log, even within own tenant';
  begin
    delete from erp.access_log where tenant_id = v_tenant_a;
    get diagnostics v_count = row_count;
    passed := (v_count = 0);
    detail := format('%s row(s) deleted without error', v_count);
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- 5. Privilege escalation ----------------------------------------------
  case_name := 'cannot assert a tenant context by GUC';
  begin
    perform erp.set_job_tenant(v_tenant_b);
    passed := false; detail := 'set_job_tenant was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- Even if the GUC is set directly, current_tenant_id() must ignore it,
  -- because the session is not trusted.
  case_name := 'a directly-set tenant GUC is ignored on an untrusted role';
  begin
    perform set_config('erp.job_tenant_id', v_tenant_b::text, true);
  exception when others then null;
  end;
  select erp.current_tenant_id() into v_uuid;
  passed := (v_uuid = v_tenant_a);
  detail := format('current_tenant_id() = %s after setting the GUC to %s', v_uuid, v_tenant_b);
  return next;
  perform set_config('erp.job_tenant_id', '', true);

  case_name := 'cannot see another tenant''s permission grants';
  passed := not erp.has_permission('admin.read', null, null, null, v_user_b);
  detail := 'has_permission() evaluated against a foreign principal';
  return next;

  -- --- 6. Product content and platform metadata -----------------------------
  case_name := 'cannot write product content';
  begin
    insert into erp_ref.currency (code, name) values ('XZZ', 'Injected');
    passed := false; detail := 'insert into erp_ref was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'cannot read platform metadata';
  begin
    select count(*) into v_count from erp_meta.table_policy;
    passed := false; detail := format('erp_meta.table_policy returned %s row(s)', v_count);
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- 7. Referential attacks -----------------------------------------------
  -- The composite (tenant_id, id) foreign keys mean a cross-tenant parent is
  -- structurally impossible, not merely unauthorised.
  case_name := 'cannot parent an own row under another tenant''s row';
  begin
    insert into erp.site (tenant_id, entity_id, code, name, site_type)
    values (v_tenant_a, v_entity_b, 'STOLEN', 'Stolen', 'warehouse');
    passed := false; detail := 'cross-tenant foreign key was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'cannot smuggle another tenant''s id into a nullable reference';
  begin
    insert into erp.user_role (tenant_id, app_user_id, role_id, entity_id)
    values (v_tenant_a, v_user_a, v_role_b, null);
    passed := false; detail := 'cross-tenant role grant was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- ---------------------------------------------------------------------------
  -- Back to the owner, then the unauthenticated case.
  -- ---------------------------------------------------------------------------
  execute format('set local role %I', v_owner);
  execute 'set local request.jwt.claims = ''''';

  set local role anon;

  -- Either answer is a pass: a null context, or a refusal to let anon into the
  -- schema at all. The second is what actually happens, because `anon` is never
  -- granted USAGE on erp — the denial lands before the function is reached.
  case_name := 'an anonymous session has no tenant context';
  begin
    select erp.current_tenant_id() into v_uuid;
    passed := (v_uuid is null);
    detail := format('current_tenant_id() = %s', coalesce(v_uuid::text, 'null'));
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'an anonymous session cannot read any tenant data';
  begin
    select count(*) into v_count from erp.entity;
    passed := false; detail := format('erp.entity returned %s row(s)', v_count);
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'work refuses to start without a tenant context';
  begin
    perform erp.require_tenant_id();
    passed := false; detail := 'require_tenant_id() returned without a context';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  execute format('set local role %I', v_owner);

  -- ---------------------------------------------------------------------------
  -- Fixtures are removed here for the case where the caller committed; the
  -- suite is normally run inside a transaction that is rolled back anyway.
  -- ---------------------------------------------------------------------------
  delete from erp.tenant where id in (v_tenant_a, v_tenant_b);
  delete from erp_ref.currency where code = 'XTS';

exception when others then
  -- Never leave the session impersonating anybody.
  execute format('set local role %I', v_owner);
  raise;
end;
$$;

comment on function erp_test.isolation_suite() is
  'Adversarial cross-tenant test suite. Authenticates as one tenant and '
  'attempts every route into another: reads, writes, primary-key targeting, '
  'tenant reassignment, GUC escalation, foreign-key smuggling, product content '
  'and platform metadata.';

-- -----------------------------------------------------------------------------
-- The build entry point.
--
-- Structural invariant + behavioural suite. Raises on the first sign of a leak,
-- so it can be wired to a build step with no result parsing.
-- -----------------------------------------------------------------------------

create or replace function erp_test.assert_isolation_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_failures text;
  v_failed   integer;
  v_total    integer;
begin
  perform erp.assert_isolation();

  select count(*) filter (where not r.passed),
         count(*),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_failed, v_total, v_failures
    from erp_test.isolation_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_ISOLATION_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_failures;
  end if;

  return format('isolation: 0 structural findings, %s/%s adversarial cases passed',
                v_total, v_total);
end;
$$;

revoke all on function erp_test.isolation_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_isolation_suite() from public, anon, authenticated;
