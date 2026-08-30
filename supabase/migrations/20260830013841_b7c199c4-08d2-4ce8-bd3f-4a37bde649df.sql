
-- A tenant cannot have items without a unit of measure, and erp.item requires
-- one. Nothing in the product created the first one, so this does.
create or replace function erp.ensure_base_uom(p_tenant_id uuid, p_principal uuid default null)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_id uuid;
begin
  select u.id into v_id from erp.uom u
   where u.tenant_id = p_tenant_id and u.is_base and u.status = 'active'::erp.record_status
   order by u.code limit 1;
  if v_id is not null then return v_id; end if;

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status, created_by)
  values (p_tenant_id, 'EA', 'Each', 'quantity'::erp.uom_class, 0, true,
          'active'::erp.record_status, p_principal)
  on conflict (tenant_id, code) do update set is_base = true
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.erp_create_party(p_code text, p_name text,
                                                   p_role_kind text default 'customer',
                                                   p_country_code text default null)
returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid;
  v_id uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'party', null);
  v_tenant := erp.current_tenant_id();

  if p_code is null or btrim(p_code) = '' then
    raise exception 'ERPWARE_VALIDATION: a party code is required' using errcode = '23514';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'ERPWARE_VALIDATION: a party name is required' using errcode = '23514';
  end if;

  insert into erp.party (tenant_id, code, name, country_code, status, created_by)
  values (v_tenant, btrim(p_code), btrim(p_name), nullif(btrim(coalesce(p_country_code, '')), ''),
          'active'::erp.record_status, erp.current_principal_id())
  returning id into v_id;

  if p_role_kind is not null then
    insert into erp.party_role (tenant_id, party_id, role_kind, status, created_by)
    values (v_tenant, v_id, p_role_kind::erp.party_role_kind,
            'active'::erp.record_status, erp.current_principal_id())
    on conflict (tenant_id, party_id, role_kind) do nothing;
  end if;

  return jsonb_build_object('party_id', v_id);
end;
$$;

create or replace function public.erp_add_party_role(p_party_id uuid, p_role_kind text)
returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'party', p_party_id);
  v_tenant := erp.current_tenant_id();

  insert into erp.party_role (tenant_id, party_id, role_kind, status, created_by)
  select v_tenant, p.id, p_role_kind::erp.party_role_kind,
         'active'::erp.record_status, erp.current_principal_id()
    from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id
  on conflict (tenant_id, party_id, role_kind) do nothing;

  return jsonb_build_object('party_id', p_party_id, 'role_kind', p_role_kind);
end;
$$;

create or replace function public.erp_create_item(p_code text, p_name text,
                                                  p_item_class text default null,
                                                  p_is_batch_controlled boolean default false)
returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid;
  v_uom uuid;
  v_id uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'item', null);
  v_tenant := erp.current_tenant_id();

  if p_code is null or btrim(p_code) = '' then
    raise exception 'ERPWARE_VALIDATION: an item code is required' using errcode = '23514';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'ERPWARE_VALIDATION: an item name is required' using errcode = '23514';
  end if;

  v_uom := erp.ensure_base_uom(v_tenant, erp.current_principal_id());

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id,
                        is_batch_controlled, lifecycle, status, created_by)
  values (v_tenant, btrim(p_code), btrim(p_name),
          nullif(btrim(coalesce(p_item_class, '')), ''), v_uom,
          coalesce(p_is_batch_controlled, false),
          'active'::erp.item_lifecycle, 'active'::erp.record_status,
          erp.current_principal_id())
  returning id into v_id;

  return jsonb_build_object('item_id', v_id);
end;
$$;

-- The demo used to seed a shell: entities, sites, principals and nothing to
-- transact with. This is the part that makes it a demonstration.
create or replace function erp.seed_demo_master_data(p_tenant_id uuid, p_principal uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_uom uuid;
  v_site uuid;
  v_entity uuid;
  v_cust uuid;
  v_supp uuid;
  v_doc uuid;
  v_item uuid;
  v_items integer;
  v_parties integer;
  v_docs jsonb := '[]'::jsonb;
  v_note text := null;
  r record;
begin
  v_uom := erp.ensure_base_uom(p_tenant_id, p_principal);

  select e.id into v_entity from erp.entity e
   where e.tenant_id = p_tenant_id order by e.code limit 1;
  select s.id into v_site from erp.site s
   where s.tenant_id = p_tenant_id and s.entity_id = v_entity
     and s.site_type <> 'office'::erp.site_type
   order by s.code limit 1;
  if v_site is null then
    select s.id into v_site from erp.site s
     where s.tenant_id = p_tenant_id order by s.code limit 1;
  end if;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id,
                        lifecycle, status, created_by)
  values
    (p_tenant_id, 'FG-1000', 'Acme widget, 100mm', 'finished_good', v_uom, 'active'::erp.item_lifecycle, 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'FG-1001', 'Acme widget, 150mm', 'finished_good', v_uom, 'active'::erp.item_lifecycle, 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'FG-2000', 'Acme gearbox assembly', 'finished_good', v_uom, 'active'::erp.item_lifecycle, 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'RM-100', 'Steel bar, 20mm', 'raw_material', v_uom, 'active'::erp.item_lifecycle, 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'RM-200', 'Bearing, 30mm bore', 'raw_material', v_uom, 'active'::erp.item_lifecycle, 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'PK-010', 'Carton, 400x300x200', 'packaging', v_uom, 'active'::erp.item_lifecycle, 'active'::erp.record_status, p_principal)
  on conflict (tenant_id, code) do nothing;

  insert into erp.party (tenant_id, code, name, legal_name, country_code, status, created_by)
  values
    (p_tenant_id, 'C-NORTH', 'Northgate Retail', 'Northgate Retail Ltd', 'GB', 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'C-HARBOUR', 'Harbour Engineering', 'Harbour Engineering BV', 'NL', 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'C-VELA', 'Vela Industrial', 'Vela Industrial SA', 'FR', 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'S-STEEL', 'Midland Steel', 'Midland Steel Ltd', 'GB', 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'S-BEAR', 'Rheinbearing', 'Rheinbearing GmbH', 'DE', 'active'::erp.record_status, p_principal),
    (p_tenant_id, 'S-PACK', 'Packwell', 'Packwell Ltd', 'GB', 'active'::erp.record_status, p_principal)
  on conflict (tenant_id, code) do nothing;

  for r in select p.id, p.code from erp.party p
            where p.tenant_id = p_tenant_id and p.code like 'C-%'
  loop
    insert into erp.party_role (tenant_id, party_id, role_kind, status, created_by)
    values (p_tenant_id, r.id, 'customer'::erp.party_role_kind, 'active'::erp.record_status, p_principal)
    on conflict (tenant_id, party_id, role_kind) do nothing;
  end loop;

  for r in select p.id, p.code from erp.party p
            where p.tenant_id = p_tenant_id and p.code like 'S-%'
  loop
    insert into erp.party_role (tenant_id, party_id, role_kind, status, created_by)
    values (p_tenant_id, r.id, 'supplier'::erp.party_role_kind, 'active'::erp.record_status, p_principal)
    on conflict (tenant_id, party_id, role_kind) do nothing;
  end loop;

  select count(*) into v_items from erp.item where tenant_id = p_tenant_id;
  select count(*) into v_parties from erp.party where tenant_id = p_tenant_id;

  -- Two live documents, so the demo has something with a lifecycle on it.
  -- A tenant whose document types are not numbered cannot have these, and
  -- that is worth saying rather than failing the whole seed.
  if not exists (select 1 from erp.document where tenant_id = p_tenant_id) then
    begin
      select p.id into v_cust from erp.party p
       where p.tenant_id = p_tenant_id and p.code = 'C-NORTH';
      select p.id into v_supp from erp.party p
       where p.tenant_id = p_tenant_id and p.code = 'S-STEEL';

      if exists (select 1 from erp.document_type dt
                  where dt.tenant_id = p_tenant_id and dt.code = 'quotation'
                    and dt.status = 'active'::erp.record_status) then
        v_doc := erp.create_document('quotation', v_entity, v_site, v_cust,
                                     current_date, null, 'Demo enquiry');
        select i.id into v_item from erp.item
          i where i.tenant_id = p_tenant_id and i.code = 'FG-1000';
        perform erp.add_document_line(v_doc, v_item, 25, 4950, 'Acme widget, 100mm');
        v_docs := v_docs || jsonb_build_object('quotation', v_doc);
      end if;

      if exists (select 1 from erp.document_type dt
                  where dt.tenant_id = p_tenant_id and dt.code = 'purchase_order'
                    and dt.status = 'active'::erp.record_status) then
        v_doc := erp.create_document('purchase_order', v_entity, v_site, v_supp,
                                     current_date, null, 'Demo replenishment');
        select i.id into v_item from erp.item i
         where i.tenant_id = p_tenant_id and i.code = 'RM-100';
        perform erp.add_document_line(v_doc, v_item, 500, 1275, 'Steel bar, 20mm');
        v_docs := v_docs || jsonb_build_object('purchase_order', v_doc);
      end if;
    exception when others then
      v_note := sqlerrm;
    end;
  end if;

  return jsonb_build_object('items', v_items, 'parties', v_parties,
                            'documents', v_docs, 'document_note', v_note);
end;
$$;

-- One click still means one call: seed the tenant, adopt it, fill it.
create or replace function public.erp_seed_demo()
returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_base jsonb;
  v_tenant uuid;
  v_principal uuid;
begin
  v_base := erp.seed_demo();
  v_tenant := (v_base ->> 'tenant_id')::uuid;
  v_principal := (v_base ->> 'principal_id')::uuid;

  -- Adopting it first means erp.create_document() below sees the right tenant.
  perform erp.set_active_tenant(v_tenant);

  return v_base || jsonb_build_object(
    'seeded', erp.seed_demo_master_data(v_tenant, v_principal));
end;
$$;

grant execute on function public.erp_create_party(text, text, text, text) to authenticated;
grant execute on function public.erp_add_party_role(uuid, text) to authenticated;
grant execute on function public.erp_create_item(text, text, text, boolean) to authenticated;
grant execute on function public.erp_seed_demo() to authenticated;
