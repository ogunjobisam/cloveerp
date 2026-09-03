create or replace function erp.create_site(
  p_code text,
  p_name text,
  p_site_type text default 'warehouse',
  p_entity_id uuid default null,
  p_country_code char(2) default null,
  p_timezone text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid := p_entity_id;
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'site', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_SITE_CODE_REQUIRED: a site needs a code'
      using errcode = '23514';
  end if;

  if v_entity is null then
    select e.id into v_entity
      from erp.entity e
     where e.tenant_id = v_tenant
     order by e.created_at
     limit 1;
  end if;

  if v_entity is null then
    raise exception 'ERPWARE_ENTITY_REQUIRED: this organisation has no legal entity to hold a site'
      using errcode = '23514';
  end if;

  insert into erp.site (tenant_id, entity_id, code, name, site_type,
                        country_code, timezone, status)
  values (v_tenant, v_entity, trim(p_code),
          coalesce(nullif(trim(p_name), ''), trim(p_code)),
          p_site_type::erp.site_type, p_country_code,
          coalesce(nullif(trim(coalesce(p_timezone, '')), ''), 'UTC'), 'active')
  returning id into v_id;

  return v_id;
end $$;

comment on function erp.create_site(text, text, text, uuid, char, text) is
  'Creates a site under administration.configure, defaulting the legal entity '
  'to the organisation''s first. The single-record door that makes a newly '
  'provisioned organisation able to raise a document that needs a site.';

create or replace function public.erp_create_site(
  p_code text, p_name text, p_site_type text default 'warehouse',
  p_entity_id uuid default null, p_country_code text default null,
  p_timezone text default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('site_id',
  erp.create_site(p_code, p_name, p_site_type, p_entity_id,
                  p_country_code::char(2), p_timezone)) $$;

create or replace function public.erp_entities()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'entity_id', e.id, 'code', e.code, 'name', e.name,
           'base_currency', e.base_currency, 'country_code', e.country_code,
           'status', e.status) order by e.code), '[]'::jsonb)
    from erp.entity e
$$;

create or replace function public.erp_sites()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'site_id', s.id, 'code', s.code, 'name', s.name,
           'site_type', s.site_type, 'entity_id', s.entity_id,
           'entity_code', (select e.code from erp.entity e
                            where e.tenant_id = s.tenant_id and e.id = s.entity_id),
           'country_code', s.country_code, 'status', s.status)
           order by s.code), '[]'::jsonb)
    from erp.site s
$$;

revoke all on function public.erp_create_site(text, text, text, uuid, text, text) from public, anon;
revoke all on function public.erp_entities() from public, anon;
revoke all on function public.erp_sites() from public, anon;
grant execute on function public.erp_create_site(text, text, text, uuid, text, text) to authenticated;
grant execute on function public.erp_entities() to authenticated;
grant execute on function public.erp_sites() to authenticated;

do $$
declare v_ok boolean;
begin
  select count(*) = 3 into v_ok from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('erp_create_site', 'erp_entities', 'erp_sites');
  if not v_ok then raise exception 'wrappers missing'; end if;
end $$;