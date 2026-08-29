-- 1. Tenant administrator role + grant for the test admin in the Finance smoke
-- tenant.
--
-- Guarded, because it names two rows by literal UUID and neither exists in an
-- empty database. Unguarded it raised a foreign-key violation, and since every
-- migration is applied with --single-transaction the whole file rolled back —
-- taking erp.provision_tenant_admin(), public.erp_onboard_tenant() and
-- public.erp_seed_demo() with it. That is why the schema build went red on
-- "Added perms mgmt & demo seed": not the seed data, but everything defined
-- after it.
--
-- A seed for one specific tenant is environment data, not schema, so it should
-- never have been able to fail a build. Skipping it where the tenant is absent
-- is a no-op on the database it was written for.
do $seed$
declare
  v_tenant constant uuid := 'c59e86ce-5d50-4aa2-b6e2-456d97459828';
  v_user   constant uuid := '5dff2d8a-487a-458c-8cbc-ab0c62148a03';
  v_role   uuid;
begin
  if not exists (select 1 from erp.tenant where id = v_tenant)
     or not exists (select 1 from erp.app_user where id = v_user) then
    raise notice 'skipping the Finance smoke seed: tenant or principal absent';
    return;
  end if;

  insert into erp.role (tenant_id, code, name_key, name, description, status)
  values (v_tenant, 'tenant-admin', 'role.tenant_admin.name', 'Tenant administrator',
          'Full access to every module and action in this tenant.',
          'active'::erp.record_status)
  on conflict (tenant_id, code) do update set name = excluded.name
  returning id into v_role;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
  select v_tenant, v_role, p.code, '{}' from erp_ref.permission p
  on conflict do nothing;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from,
                             granted_by, grant_reason)
  values (v_tenant, v_user, v_role, current_date, v_user,
          'Initial administrator grant')
  on conflict do nothing;
end;
$seed$;

-- 2. Shared helper: create admin role (all permissions) + grant for a principal
create or replace function erp.provision_tenant_admin(p_tenant_id uuid, p_app_user_id uuid, p_granted_by uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role_id uuid;
begin
  insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
  values (p_tenant_id, 'tenant-admin', 'role.tenant_admin.name', 'Tenant administrator',
          'Full access to every module and action in this tenant.', 'active'::erp.record_status, p_granted_by)
  on conflict (tenant_id, code) do update set name = excluded.name
  returning id into v_role_id;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select p_tenant_id, v_role_id, p.code, '{}', p_granted_by
  from erp_ref.permission p
  on conflict do nothing;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason, created_by)
  values (p_tenant_id, p_app_user_id, v_role_id, current_date, p_granted_by,
          'Tenant administrator grant', p_granted_by)
  on conflict do nothing;

  return v_role_id;
end;
$$;

-- 3. Onboarding: create a tenant with the caller as its first principal + admin grants
create or replace function public.erp_onboard_tenant(p_name text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_id uuid := auth.uid();
  v_email text;
  v_display text;
  v_tenant_id uuid;
  v_principal_id uuid;
begin
  if v_auth_id is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' or p_code is null or btrim(p_code) = '' then
    raise exception 'ERPWARE_VALIDATION: tenant name and code are required';
  end if;

  select email, coalesce(raw_user_meta_data->>'full_name', email)
    into v_email, v_display
  from auth.users where id = v_auth_id;

  insert into erp.tenant (code, name, status, provisioned_at)
  values (p_code, p_name, 'active'::erp.tenant_status, now())
  returning id into v_tenant_id;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, v_auth_id, 'person'::erp.principal_kind, 'active'::erp.principal_status,
          coalesce(v_display, 'Tenant administrator'), v_email)
  returning id into v_principal_id;

  perform erp.provision_tenant_admin(v_tenant_id, v_principal_id, v_principal_id);

  return jsonb_build_object('tenant_id', v_tenant_id, 'principal_id', v_principal_id);
end;
$$;

revoke all on function public.erp_onboard_tenant(text, text) from public, anon;
grant execute on function public.erp_onboard_tenant(text, text) to authenticated;

-- 4. One-click demo seed: tenant + entities + sites + admin grant + sample viewer principal
create or replace function public.erp_seed_demo()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_id uuid := auth.uid();
  v_email text;
  v_display text;
  v_tenant_id uuid;
  v_principal_id uuid;
  v_viewer_id uuid;
  v_role_id uuid;
  v_e1 uuid;
  v_e2 uuid;
begin
  if v_auth_id is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED' using errcode = '42501';
  end if;

  -- Idempotent: reuse the caller's existing demo tenant.
  select t.id into v_tenant_id
  from erp.tenant t
  join erp.app_user u on u.tenant_id = t.id and u.auth_user_id = v_auth_id
  where t.code like 'demo-%' and t.status = 'active'::erp.tenant_status
  order by t.created_at
  limit 1;
  if v_tenant_id is not null then
    select u.id into v_principal_id from erp.app_user u
     where u.tenant_id = v_tenant_id and u.auth_user_id = v_auth_id;
    return jsonb_build_object('tenant_id', v_tenant_id, 'principal_id', v_principal_id, 'already_existed', true);
  end if;

  select email, coalesce(raw_user_meta_data->>'full_name', email)
    into v_email, v_display
  from auth.users where id = v_auth_id;

  insert into erp.tenant (code, name, status, provisioned_at)
  values ('demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
          'Demo — Acme Manufacturing', 'active'::erp.tenant_status, now())
  returning id into v_tenant_id;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, v_auth_id, 'person'::erp.principal_kind, 'active'::erp.principal_status,
          coalesce(v_display, 'Demo administrator'), v_email)
  returning id into v_principal_id;

  perform erp.provision_tenant_admin(v_tenant_id, v_principal_id, v_principal_id);

  insert into erp.entity (tenant_id, code, name, legal_name, base_currency, country_code, created_by)
  values (v_tenant_id, 'ACME-UK', 'Acme United Kingdom', 'Acme Manufacturing Ltd', 'GBP', 'GB', v_principal_id)
  returning id into v_e1;

  insert into erp.entity (tenant_id, code, name, legal_name, base_currency, country_code, created_by)
  values (v_tenant_id, 'ACME-EU', 'Acme Europe', 'Acme Manufacturing BV', 'EUR', 'NL', v_principal_id)
  returning id into v_e2;

  insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, created_by)
  values
    (v_tenant_id, v_e1, 'LON-HQ', 'London head office', 'office'::erp.site_type, 'GB', v_principal_id),
    (v_tenant_id, v_e1, 'BHM-WH', 'Birmingham warehouse', 'warehouse'::erp.site_type, 'GB', v_principal_id),
    (v_tenant_id, v_e2, 'RTM-DC', 'Rotterdam distribution centre', 'distribution'::erp.site_type, 'NL', v_principal_id);

  -- Sample read-only principal so the permissions page has something to manage.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, null, 'person'::erp.principal_kind, 'invited'::erp.principal_status,
          'Dana Viewer', 'dana.viewer@example.invalid')
  returning id into v_viewer_id;

  insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
  values (v_tenant_id, 'viewer', 'role.viewer.name', 'Viewer',
          'Read-only access to every module.', 'active'::erp.record_status, v_principal_id)
  returning id into v_role_id;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select v_tenant_id, v_role_id, p.code, '{}', v_principal_id
  from erp_ref.permission p
  where not p.is_mutating
  on conflict do nothing;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason, created_by)
  values (v_tenant_id, v_viewer_id, v_role_id, current_date, v_principal_id,
          'Seeded demo viewer', v_principal_id);

  return jsonb_build_object('tenant_id', v_tenant_id, 'principal_id', v_principal_id, 'already_existed', false);
end;
$$;

revoke all on function public.erp_seed_demo() from public, anon;
grant execute on function public.erp_seed_demo() to authenticated;