-- A place to say what a product is made of.
--
-- erp.raise_works_order() refuses with CLOVEERP_NO_BILL_OF_MATERIALS when the
-- product has no active bill — and until now no public routine could create
-- one. This migration adds the governed create and withdraw routines, the
-- read that lists bills with their components, and the refusal wording that
-- tells the person where to go.

create or replace function erp.create_bom(
  p_item_id uuid,
  p_site_id uuid default null,
  p_name text default null,
  p_output_quantity numeric default 1,
  p_effective_from date default null,
  p_lines jsonb default '[]'::jsonb
) returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
  v_version integer;
  v_code text;
  v_item_code text;
  v_line jsonb;
  v_seq integer := 0;
  v_component uuid;
  v_qty numeric;
  v_scrap numeric;
  v_uom uuid;
  v_seen uuid[] := '{}';
begin
  perform erp.authorise('production.order', null, p_site_id, null, 'bom', null);

  select i.code into v_item_code
    from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id and i.status = 'active'::erp.record_status;
  if v_item_code is null then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: % is not a product here', p_item_id
      using errcode = '23503';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'CLOVEERP_BOM_NEEDS_LINES: a bill of materials needs at least one component'
      using errcode = '23514',
            hint = 'Add each thing the product is made of, with the quantity one run uses.';
  end if;

  if coalesce(p_output_quantity, 0) <= 0 then
    raise exception 'CLOVEERP_BOM_OUTPUT: the quantity one run makes must be more than zero'
      using errcode = '23514';
  end if;

  -- A new bill supersedes the one in force for the same product and site
  -- scope. The old version stays on record — the change guard already stops
  -- a used bill being edited, and withdrawing history would break it.
  update erp.bom b
     set status = 'superseded'::erp.config_version_status, updated_at = now()
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.status = 'active'::erp.config_version_status
     and ((b.site_id is null and p_site_id is null) or b.site_id = p_site_id);

  select coalesce(max(b.version), 0) + 1 into v_version
    from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id
     and ((b.site_id is null and p_site_id is null) or b.site_id = p_site_id);

  v_code := 'BOM-' || v_item_code || '-V' || v_version;

  insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                       output_quantity, status, effective_from)
  values (v_tenant, v_code, p_item_id, p_site_id, v_version,
          nullif(trim(coalesce(p_name, '')), ''),
          p_output_quantity, 'active'::erp.config_version_status,
          coalesce(p_effective_from, current_date))
  returning id into v_id;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_seq := v_seq + 10;
    v_component := nullif(trim(coalesce(v_line ->> 'component_item_id', '')), '')::uuid;
    v_qty := nullif(trim(coalesce(v_line ->> 'quantity', '')), '')::numeric;
    v_scrap := coalesce(nullif(trim(coalesce(v_line ->> 'scrap_factor', '')), '')::numeric, 0);

    if v_component is null or v_qty is null or v_qty <= 0 then
      raise exception 'CLOVEERP_BOM_LINE: every component needs a product and a quantity more than zero'
        using errcode = '23514';
    end if;
    if v_component = p_item_id then
      raise exception 'CLOVEERP_BOM_CYCLE: a product cannot be made of itself'
        using errcode = '23514';
    end if;
    if v_component = any(v_seen) then
      raise exception 'CLOVEERP_BOM_LINE: the same component is listed twice — add the quantities together'
        using errcode = '23514';
    end if;
    v_seen := v_seen || v_component;

    select i.stock_uom_id into v_uom
      from erp.item i
     where i.tenant_id = v_tenant and i.id = v_component and i.status = 'active'::erp.record_status;
    if v_uom is null then
      raise exception 'CLOVEERP_UNKNOWN_ITEM: % is not a product here', v_component
        using errcode = '23503';
    end if;

    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor)
    values (v_tenant, v_id, v_seq, v_component, v_qty, v_uom, v_scrap);
  end loop;

  return v_id;
end $$;

comment on function erp.create_bom is
  'Defines what a product is made of, header and components in one call. '
  'Supersedes the bill in force for the same product and site scope.';

create or replace function erp.withdraw_bom(p_bom_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site uuid;
begin
  select b.site_id into v_site from erp.bom b
   where b.tenant_id = v_tenant and b.id = p_bom_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_BOM: % is not a bill of materials here', p_bom_id
      using errcode = '23503';
  end if;

  perform erp.authorise('production.order', null, v_site, null, 'bom', p_bom_id);

  update erp.bom b
     set status = 'withdrawn'::erp.config_version_status, updated_at = now()
   where b.tenant_id = v_tenant and b.id = p_bom_id
     and b.status in ('draft'::erp.config_version_status, 'active'::erp.config_version_status);

  return p_bom_id;
end $$;

comment on function erp.withdraw_bom is
  'Retires a bill of materials so nothing new is made against it. The record stays.';

-- The public doors.

create or replace function public.erp_create_bom(
  p_item_id uuid,
  p_site_id uuid default null,
  p_name text default null,
  p_output_quantity numeric default 1,
  p_effective_from date default null,
  p_lines jsonb default '[]'::jsonb
) returns uuid
language sql
set search_path to ''
as $$ select erp.create_bom(p_item_id, p_site_id, p_name, p_output_quantity,
                            p_effective_from, p_lines) $$;

create or replace function public.erp_withdraw_bom(p_bom_id uuid)
returns uuid
language sql
set search_path to ''
as $$ select erp.withdraw_bom(p_bom_id) $$;

create or replace function public.erp_boms(
  p_item_id uuid default null,
  p_site_id uuid default null
) returns jsonb
language sql
stable
security invoker
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'bom_id', b.id,
           'code', b.code,
           'item', i.code, 'item_name', i.name, 'item_id', b.item_id,
           'site', s.code, 'site_id', b.site_id,
           'version', b.version,
           'status', b.status,
           'output_quantity', b.output_quantity,
           'effective_from', b.effective_from,
           'effective_to', b.effective_to,
           'components', (select string_agg(
                            ci.code || ' × ' || trim(to_char(bl.quantity, 'FM9999999990.########')),
                            ', ' order by bl.seq)
                            from erp.bom_line bl
                            join erp.item ci on ci.tenant_id = bl.tenant_id
                                            and ci.id = bl.component_item_id
                           where bl.tenant_id = b.tenant_id and bl.bom_id = b.id
                             and not bl.is_alternate))
           order by i.code, b.version desc), '[]'::jsonb)
    from erp.bom b
    join erp.item i on i.tenant_id = b.tenant_id and i.id = b.item_id
    left join erp.site s on s.tenant_id = b.tenant_id and s.id = b.site_id
   where b.tenant_id = erp.current_tenant_id()
     and (p_item_id is null or b.item_id = p_item_id)
     and (p_site_id is null or b.site_id = p_site_id);
$$;

revoke all on function public.erp_create_bom(uuid, uuid, text, numeric, date, jsonb) from public, anon;
grant execute on function public.erp_create_bom(uuid, uuid, text, numeric, date, jsonb) to authenticated, service_role;
revoke all on function public.erp_withdraw_bom(uuid) from public, anon;
grant execute on function public.erp_withdraw_bom(uuid) to authenticated, service_role;
revoke all on function public.erp_boms(uuid, uuid) from public, anon;
grant execute on function public.erp_boms(uuid, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_bom', 'erp.create_bom',
   'Defines what a product is made of, under production.order. A new version '
   'supersedes the one in force; used versions stay immutable.'),
  ('erp_withdraw_bom', 'erp.withdraw_bom',
   'Retires a bill of materials, under production.order. The record stays.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- The refusal, in words, so the screen can say where the setup lives.
insert into erp_ref.refusal (code, refused, why, next_action, spec_reference)
values (
  'CLOVEERP_NO_BILL_OF_MATERIALS',
  'This product has no bill of materials.',
  'Nothing says what it is made of, so a works order cannot be raised for it.',
  'Open Manufacturing and use "Define a bill of materials" to list its components, then raise the order again.',
  '5.5')
on conflict (code) do update set
  refused = excluded.refused,
  why = excluded.why,
  next_action = excluded.next_action,
  spec_reference = excluded.spec_reference;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();