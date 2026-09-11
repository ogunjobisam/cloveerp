-- Product class, category and lifecycle as choices.
--
-- erp_create_item accepted only a free-text class. This adds the product
-- group and lifecycle, and a small read that lists the categories already
-- in use so the form can offer them.

drop function if exists public.erp_create_item(text, text, text, boolean);

create or replace function public.erp_create_item(
  p_code text,
  p_name text,
  p_item_class text default null,
  p_is_batch_controlled boolean default false,
  p_item_group text default null,
  p_lifecycle text default null
) returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid;
  v_uom uuid;
  v_id uuid;
  v_lifecycle erp.item_lifecycle;
begin
  perform erp.authorise('master_data.write', null, null, null, 'item', null);
  v_tenant := erp.current_tenant_id();

  if p_code is null or btrim(p_code) = '' then
    raise exception 'CLOVEERP_VALIDATION: an item code is required' using errcode = '23514';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'CLOVEERP_VALIDATION: an item name is required' using errcode = '23514';
  end if;

  v_lifecycle := coalesce(nullif(btrim(coalesce(p_lifecycle, '')), ''), 'active')::erp.item_lifecycle;

  v_uom := erp.ensure_base_uom(v_tenant, erp.current_principal_id());

  insert into erp.item (tenant_id, code, name, item_class, item_group, stock_uom_id,
                        is_batch_controlled, lifecycle, status, created_by)
  values (v_tenant, btrim(p_code), btrim(p_name),
          nullif(btrim(coalesce(p_item_class, '')), ''),
          nullif(btrim(coalesce(p_item_group, '')), ''),
          v_uom,
          coalesce(p_is_batch_controlled, false),
          v_lifecycle, 'active'::erp.record_status,
          erp.current_principal_id())
  returning id into v_id;

  return jsonb_build_object('item_id', v_id);
end $$;

comment on function public.erp_create_item is
  'Creates a product with class, category and lifecycle. Blank lifecycle starts active.';

revoke all on function public.erp_create_item(text, text, text, boolean, text, text) from public, anon;
grant execute on function public.erp_create_item(text, text, text, boolean, text, text) to authenticated, service_role;

-- The categories already in use, so the form can offer them as a dropdown.
create or replace function public.erp_item_categories()
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('group', g.item_group) order by g.item_group), '[]'::jsonb)
    from (select distinct i.item_group
            from erp.item i
           where i.tenant_id = erp.current_tenant_id()
             and i.merged_into_id is null
             and i.item_group is not null) g;
$$;

revoke all on function public.erp_item_categories() from public, anon;
grant execute on function public.erp_item_categories() to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_item', 'erp.authorise',
   'Creates a product under master_data.write, with class, category and lifecycle.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();