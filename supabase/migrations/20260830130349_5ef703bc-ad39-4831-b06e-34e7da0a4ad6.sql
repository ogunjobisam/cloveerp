create or replace function public.erp_principals()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'display_name', coalesce(u.display_name, u.email),
           'email', u.email, 'kind', u.kind, 'status', u.status)
           order by coalesce(u.display_name, u.email)), '[]'::jsonb)
    into v_out
    from erp.app_user u
   where u.tenant_id = erp.current_tenant_id()
     and u.status = 'active';
  return v_out;
end;
$$;

revoke all on function public.erp_principals() from public, anon;
grant execute on function public.erp_principals() to authenticated, service_role;