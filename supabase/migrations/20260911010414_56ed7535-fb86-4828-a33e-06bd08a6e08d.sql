create or replace function public.erp_platform_my_support_accesses()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(x order by x->>'granted_at' desc)
      from (
        select jsonb_build_object(
                 'id', a.id,
                 'tenant_id', a.tenant_id,
                 'tenant_code', t.code,
                 'tenant_name', t.name,
                 'reason', a.reason,
                 'request_reference', a.request_reference,
                 'is_write_access', a.is_write_access,
                 'granted_at', a.granted_at,
                 'expires_at', a.expires_at,
                 'is_live', a.expires_at > now(),
                 'actions_recorded',
                   (select count(*) from erp.support_action sa
                     where sa.support_access_id = a.id)) as x
          from erp.support_access a
          left join erp.tenant t on t.id = a.tenant_id
         where a.staff_email = v.email
         order by a.granted_at desc
         limit 50) s), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_my_support_accesses() is
  'The support access grants held by the calling platform staff member, so the '
  'console can offer them as a choice rather than asking for an id. Read only; '
  'it never shows another person''s grant, because an action recorded against '
  'somebody else''s grant is refused anyway.';

revoke all on function public.erp_platform_my_support_accesses() from public, anon;
grant execute on function public.erp_platform_my_support_accesses() to authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('public', 'erp_platform_my_support_accesses',
        'Platform-level read. It exists precisely to act above tenants, so no '
        'tenant context can scope it; it is gated on erp_meta.require_platform() '
        'and returns only the calling staff member''s own grants.')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_platform_my_support_accesses', 'erp_meta.require_platform',
        'Platform staff read, gated on the platform staff list rather than on '
        'erp.authorise(), because it is performed above every tenant.')
on conflict do nothing;

select erp.assert_public_api_safe();