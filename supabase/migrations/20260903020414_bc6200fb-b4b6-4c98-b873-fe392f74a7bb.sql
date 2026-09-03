create or replace function erp.create_location(
  p_site_id uuid,
  p_code text,
  p_name text default null,
  p_location_type text default 'bulk'
) returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('administration.configure', null, p_site_id, null, 'location', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_LOCATION_CODE_REQUIRED: a location needs a code'
      using errcode = '23514';
  end if;

  if not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id) then
    raise exception 'ERPWARE_UNKNOWN_SITE: %', p_site_id using errcode = '23503';
  end if;

  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (v_tenant, p_site_id, trim(p_code),
          coalesce(nullif(trim(coalesce(p_name, '')), ''), trim(p_code)),
          p_location_type::erp.location_type, 'active')
  returning id into v_id;

  return v_id;
end $$;

create or replace function erp.create_site(
  p_code text,
  p_name text,
  p_site_type text default 'warehouse',
  p_entity_id uuid default null,
  p_country_code char default null,
  p_timezone text default null
) returns uuid
language plpgsql
set search_path to ''
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

  -- A site with nowhere to put anything cannot take a receipt: posting an
  -- inbound movement looks for an active receiving location and fails. So a
  -- new site is given the places every warehouse has, rather than leaving a
  -- first goods receipt to discover the gap.
  if p_site_type in ('warehouse', 'production', 'distribution', 'retail', 'third_party') then
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (v_tenant, v_id, 'GOODS-IN',   'Goods in',    'receiving',  'active'),
           (v_tenant, v_id, 'MAIN',       'Main storage','bulk',       'active'),
           (v_tenant, v_id, 'QUARANTINE', 'Quarantine',  'quarantine', 'active'),
           (v_tenant, v_id, 'DESPATCH',   'Despatch',    'despatch',   'active');
  else
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (v_tenant, v_id, 'HOLD', 'Holding', 'virtual', 'active');
  end if;

  return v_id;
end $$;

create or replace function public.erp_create_location(
  p_site_id uuid,
  p_code text,
  p_name text default null,
  p_location_type text default 'bulk'
) returns uuid
language sql
set search_path to ''
as $$ select erp.create_location(p_site_id, p_code, p_name, p_location_type) $$;

revoke all on function public.erp_create_location(uuid, text, text, text) from public, anon;
grant execute on function public.erp_create_location(uuid, text, text, text) to authenticated;
