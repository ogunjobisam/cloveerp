create or replace function erp.create_site(
  p_code text,
  p_name text default null,
  p_site_type text default 'warehouse',
  p_entity_id uuid default null,
  p_country_code character(2) default null,
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

  -- A site with nowhere to put anything cannot take a receipt. The picking
  -- flags matter as much as the bays: a quarantine bay that reads as pickable
  -- is a recall waiting to happen.
  if p_site_type in ('warehouse', 'production', 'distribution', 'retail', 'third_party') then
    insert into erp.location (tenant_id, site_id, code, name, location_type, status, is_pickable)
    values (v_tenant, v_id, 'GOODS-IN',   'Goods in',    'receiving',  'active', false),
           (v_tenant, v_id, 'MAIN',       'Main storage','bulk',       'active', true),
           (v_tenant, v_id, 'QUARANTINE', 'Quarantine',  'quarantine', 'active', false),
           (v_tenant, v_id, 'DESPATCH',   'Despatch',    'despatch',   'active', false);
  else
    insert into erp.location (tenant_id, site_id, code, name, location_type, status, is_pickable)
    values (v_tenant, v_id, 'HOLD', 'Holding', 'virtual', 'active', false);
  end if;

  return v_id;
end;
$$;
