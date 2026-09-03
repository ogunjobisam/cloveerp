create or replace function public.erp_platform_enter_tenant(
  p_tenant_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  v_t     erp.tenant;
  v_user  uuid;
  v_owner uuid;
  v_role  uuid;
begin
  v := erp_meta.require_platform('support');

  if coalesce(trim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: entering a customer tenant needs a reason'
      using errcode = '22023';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    select u.id, u.auth_user_id into v_user, v_owner
      from erp.app_user u
     where u.tenant_id = p_tenant_id
       and lower(u.email) = lower(v.email)
     limit 1;

    if v_user is not null and v_owner is not null then
      raise exception
        'ERPWARE_EMAIL_TAKEN: a different account already holds % in this organisation', v.email
        using errcode = '22023';
    end if;

    if v_user is not null then
      update erp.app_user
         set auth_user_id = v.auth_user_id,
             status       = 'active'
       where id = v_user;
    else
      insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                                email, user_locale)
      values (p_tenant_id, v.auth_user_id, 'person', 'active',
              v.display_name || ' (Clove ERP ' || v.staff_role || ')',
              v.email, 'en')
      returning id into v_user;
    end if;
  else
    update erp.app_user set status = 'active' where id = v_user;
  end if;

  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'administrator' and r.status = 'active';

  if v_role is not null and not exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id and ur.app_user_id = v_user and ur.role_id = v_role)
  then
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (p_tenant_id, v_user, v_role,
            'Platform ' || v.staff_role || ' support access: ' || p_reason);
  end if;

  insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
  values (v.auth_user_id, p_tenant_id)
  on conflict (auth_user_id)
    do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason);

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user);
end;
$$;

select erp.assert_public_api_safe();
select erp.assert_session_context_hygiene();