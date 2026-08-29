-- Deterministic principal context: newest active principal wins, so a freshly
-- onboarded or seeded tenant becomes the caller's working context.
create or replace function erp.principal_context()
returns table(principal_id uuid, tenant_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.tenant_id
    from erp.app_user u
   where u.auth_user_id = (select auth.uid())
     and u.status = 'active'::erp.principal_status
   order by u.created_at desc
   limit 1
$$;

-- Permissions directory for the caller's tenant.
create or replace function public.erp_permissions_directory()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  return jsonb_build_object(
    'principals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'display_name', u.display_name, 'email', u.email,
               'kind', u.kind, 'status', u.status, 'created_at', u.created_at)
               order by u.display_name)
        from erp.app_user u where u.tenant_id = v_tenant), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'code', r.code, 'name', r.name,
               'description', r.description, 'status', r.status,
               'permissions', coalesce((
                 select jsonb_agg(rp.permission_code order by rp.permission_code)
                   from erp.role_permission rp
                  where rp.tenant_id = r.tenant_id and rp.role_id = r.id), '[]'::jsonb))
               order by r.code)
        from erp.role r where r.tenant_id = v_tenant), '[]'::jsonb),
    'grants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ur.id, 'app_user_id', ur.app_user_id, 'role_id', ur.role_id,
               'entity_id', ur.entity_id, 'site_id', ur.site_id,
               'valid_from', ur.valid_from, 'valid_to', ur.valid_to,
               'grant_reason', ur.grant_reason, 'created_at', ur.created_at)
               order by ur.created_at desc)
        from erp.user_role ur where ur.tenant_id = v_tenant), '[]'::jsonb),
    'permission_catalog', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', p.code, 'module_code', p.module_code,
               'action', p.action, 'is_mutating', p.is_mutating)
               order by p.code)
        from erp_ref.permission p), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.erp_permissions_directory() from public, anon;
grant execute on function public.erp_permissions_directory() to authenticated;

-- Assign a role to a principal within the caller's tenant.
create or replace function public.erp_grant_role(
  p_app_user_id uuid,
  p_role_id uuid,
  p_valid_from date default current_date,
  p_valid_to date default null,
  p_grant_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_id uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  if not exists (select 1 from erp.app_user u
                  where u.id = p_app_user_id and u.tenant_id = v_tenant) then
    raise exception 'ERPWARE_VALIDATION: principal not found in this tenant';
  end if;
  if not exists (select 1 from erp.role r
                  where r.id = p_role_id and r.tenant_id = v_tenant
                    and r.status = 'active'::erp.record_status) then
    raise exception 'ERPWARE_VALIDATION: active role not found in this tenant';
  end if;
  if p_valid_to is not null and p_valid_to < p_valid_from then
    raise exception 'ERPWARE_VALIDATION: valid_to precedes valid_from';
  end if;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, valid_to,
                             granted_by, grant_reason)
  values (v_tenant, p_app_user_id, p_role_id, p_valid_from, p_valid_to,
          erp.current_principal_id(), p_grant_reason)
  returning id into v_id;

  return jsonb_build_object('grant_id', v_id);
end;
$$;

revoke all on function public.erp_grant_role(uuid, uuid, date, date, text) from public, anon;
grant execute on function public.erp_grant_role(uuid, uuid, date, date, text) to authenticated;

-- Remove a grant within the caller's tenant.
create or replace function public.erp_revoke_role(p_user_role_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  delete from erp.user_role ur
   where ur.id = p_user_role_id and ur.tenant_id = v_tenant;
  if not found then
    raise exception 'ERPWARE_VALIDATION: grant not found in this tenant';
  end if;

  return jsonb_build_object('revoked', p_user_role_id);
end;
$$;

revoke all on function public.erp_revoke_role(uuid) from public, anon;
grant execute on function public.erp_revoke_role(uuid) to authenticated;

-- Create a role, or replace a role's permission set, within the caller's tenant.
create or replace function public.erp_save_role(
  p_role_id uuid,
  p_code text,
  p_name text,
  p_description text,
  p_permissions text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_id uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'ERPWARE_VALIDATION: role name is required';
  end if;
  if exists (select 1
               from unnest(coalesce(p_permissions, '{}')) perm
              where not exists (select 1 from erp_ref.permission p where p.code = perm)) then
    raise exception 'ERPWARE_VALIDATION: unknown permission code';
  end if;

  if p_role_id is null then
    if p_code is null or btrim(p_code) = '' then
      raise exception 'ERPWARE_VALIDATION: role code is required';
    end if;
    insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
    values (v_tenant, p_code, 'role.' || replace(p_code, '-', '_') || '.name', p_name,
            p_description, 'active'::erp.record_status, erp.current_principal_id())
    returning id into v_id;
  else
    update erp.role r
       set name = p_name, description = p_description, updated_at = now(),
           updated_by = erp.current_principal_id()
     where r.id = p_role_id and r.tenant_id = v_tenant
    returning id into v_id;
    if not found then
      raise exception 'ERPWARE_VALIDATION: role not found in this tenant';
    end if;
    delete from erp.role_permission rp where rp.tenant_id = v_tenant and rp.role_id = v_id;
  end if;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select v_tenant, v_id, perm, '{}', erp.current_principal_id()
  from unnest(coalesce(p_permissions, '{}')) perm;

  return jsonb_build_object('role_id', v_id);
end;
$$;

revoke all on function public.erp_save_role(uuid, text, text, text, text[]) from public, anon;
grant execute on function public.erp_save_role(uuid, text, text, text, text[]) to authenticated;