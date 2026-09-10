-- The owner override reached into erp_meta from invoker-security functions, so
-- an ordinary signed-in caller hit "permission denied for schema erp_meta"
-- before erp_session() could return anything. The check moves behind a
-- definer-security wrapper in a schema the caller may already use.
create or replace function erp.is_platform_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select erp_meta.is_platform_owner()
$$;

comment on function erp.is_platform_owner is
  'True when the caller is an unrevoked platform owner. A definer-security '
  'reader of erp_meta.is_platform_owner(), so invoker-security callers such as '
  'erp.authorise() and public.erp_session() need no rights on erp_meta.';

revoke all on function erp.is_platform_owner() from public, anon;
grant execute on function erp.is_platform_owner() to authenticated, service_role;

create or replace function erp.has_permission(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_app_user_id     uuid default null
) returns boolean
language sql
stable
set search_path = ''
as $$
  select (p_app_user_id is null and erp.is_platform_owner())
      or exists (
    select 1
      from erp.effective_permission ep
     where ep.app_user_id = coalesce(p_app_user_id, erp.current_principal_id())
       and ep.permission_code = p_permission_code
       and ep.valid_from <= current_date
       and (ep.valid_to is null or ep.valid_to >= current_date)
       and (p_entity_id is null or ep.entity_id is null or ep.entity_id = p_entity_id)
       and (p_site_id   is null or ep.site_id   is null or ep.site_id   = p_site_id)
       and (p_data_class is null
            or cardinality(ep.data_classes) = 0
            or p_data_class = any (ep.data_classes))
  )
$$;

create or replace function erp.authorise(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_object_type     text default null,
  p_object_id       uuid default null,
  p_correlation_id  uuid default null
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_granted boolean;
  v_status  text;
  v_mutates boolean;
begin
  if erp.is_platform_owner() then
    perform erp.log_access_decision(
      p_permission_code, true, p_entity_id, p_site_id, p_data_class,
      p_object_type, p_object_id, 'platform owner override', p_correlation_id);
    return;
  end if;

  select t.status::text into v_status
    from erp.tenant t
   where t.id = erp.current_tenant_id();

  if v_status is not null and v_status in ('restricted', 'suspended') then
    select p.is_mutating into v_mutates
      from erp_ref.permission p where p.code = p_permission_code;

    if v_status = 'suspended' or coalesce(v_mutates, true) then
      perform erp.log_access_decision(
        p_permission_code, false, p_entity_id, p_site_id, p_data_class,
        p_object_type, p_object_id,
        format('organisation is %s', v_status), p_correlation_id);

      raise exception
        'CLOVEERP_ORGANISATION_%: this organisation is %, so % is refused',
        upper(v_status), v_status, p_permission_code
        using errcode = '42501',
              detail = case v_status
                         when 'restricted' then
                           'Reads and export remain available. Writes resume on '
                           'resolution, with no data lost in between.'
                         else
                           'Access is withdrawn and the data is intact. '
                           'Restoration is immediate on resolution.'
                       end;
    end if;
  end if;

  v_granted := erp.has_permission(p_permission_code, p_entity_id, p_site_id, p_data_class);
  perform erp.log_access_decision(
    p_permission_code, v_granted, p_entity_id, p_site_id, p_data_class,
    p_object_type, p_object_id,
    case when v_granted then null else 'no matching grant' end,
    p_correlation_id);

  if not v_granted then
    raise exception 'CLOVEERP_PERMISSION_DENIED: %', p_permission_code
      using errcode = '42501';
  end if;
end;
$$;

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
      ) s), '[]'::jsonb)
  ))
$$;

select erp.assert_public_api_safe();