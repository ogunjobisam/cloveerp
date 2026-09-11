-- Lists the forms need so a field that expects a specific term can offer it.

create or replace function public.erp_roles()
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'role_id', r.id, 'code', r.code,
           'name', coalesce(r.name, r.name_key, r.code))
           order by r.code), '[]'::jsonb)
    from erp.role r
   where r.tenant_id = erp.current_tenant_id()
     and r.status = 'active';
$$;

comment on function public.erp_roles is
  'The active roles of the current tenant, so a role code can be chosen rather than typed.';

revoke all on function public.erp_roles() from public, anon;
grant execute on function public.erp_roles() to authenticated, service_role;

create or replace function public.erp_item_classes()
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('item_class', c.item_class)
           order by c.item_class), '[]'::jsonb)
    from (select distinct i.item_class
            from erp.item i
           where i.tenant_id = erp.current_tenant_id()
             and i.merged_into_id is null
             and i.item_class is not null) c;
$$;

comment on function public.erp_item_classes is
  'The product classes in use by the current tenant, so a class can be chosen.';

revoke all on function public.erp_item_classes() from public, anon;
grant execute on function public.erp_item_classes() to authenticated, service_role;

create or replace function public.erp_countries()
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', c.code, 'name', c.name, 'default_currency', c.default_currency)
           order by c.name)
           filter (where erp.current_tenant_id() is not null), '[]'::jsonb)
    from erp_ref.country c
   where c.is_active;
$$;

comment on function public.erp_countries is
  'Active ISO 3166-1 alpha-2 countries, so a country code can be chosen rather than typed.';

revoke all on function public.erp_countries() from public, anon;
grant execute on function public.erp_countries() to authenticated, service_role;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();