drop function if exists erp.goods_in_lines(uuid);

create or replace function erp.goods_in_lines(p_site_id uuid default null)
returns table(
  line_key text,
  site_id uuid,
  site text,
  location_id uuid,
  location text,
  item_id uuid,
  item_code text,
  item text,
  batch text,
  stock_status text,
  quantity numeric,
  suggested_location text,
  putaway_task text)
language sql
stable
security invoker
set search_path = ''
as $$
  select md5(sb.location_id::text || sb.item_id::text
              || coalesce(sb.batch_id::text, '') || sb.stock_status::text),
         s.id, s.code, l.id, l.code, i.id, i.code, i.name,
         b.batch_number,
         sb.stock_status::text,
         sum(sb.quantity),
         (select tl.code
            from erp.resolve_storage_locations(i.id, s.id, 'putaway') r
            join erp.location tl on tl.tenant_id = l.tenant_id and tl.id = r.location_id
           limit 1),
         case when exists (
                select 1 from erp.warehouse_task t
                 where t.tenant_id = sb.tenant_id
                   and t.kind = 'putaway'
                   and t.status = 'open'
                   and t.item_id = sb.item_id
                   and t.from_location_id = sb.location_id
                   and coalesce(t.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                       = coalesce(sb.batch_id, '00000000-0000-0000-0000-000000000000'::uuid))
              then 'task raised' else 'waiting' end
    from erp.stock_balance sb
    join erp.location l on l.tenant_id = sb.tenant_id and l.id = sb.location_id
    join erp.site s on s.tenant_id = sb.tenant_id and s.id = sb.site_id
    join erp.item i on i.tenant_id = sb.tenant_id and i.id = sb.item_id
    left join erp.batch b on b.tenant_id = sb.tenant_id and b.id = sb.batch_id
   where sb.tenant_id = erp.current_tenant_id()
     and sb.quantity > 0
     and l.location_type = 'receiving'::erp.location_type
     and (p_site_id is null or sb.site_id = p_site_id)
   group by s.id, s.code, l.id, l.code, i.id, i.code, i.name, b.batch_number,
            sb.stock_status, sb.tenant_id, sb.item_id, sb.location_id, sb.batch_id
$$;

comment on function erp.goods_in_lines(uuid) is
  'Stock standing in a receiving area, with where it belongs and whether a put-away task exists.';

select erp.apply_execute_grants();
select erp.assert_public_api_safe();