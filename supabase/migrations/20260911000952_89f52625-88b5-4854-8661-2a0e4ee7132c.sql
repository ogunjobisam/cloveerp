-- Goods in: what is standing in a receiving area, waiting to be put away.
--
-- A receipt posts stock into the site's receiving bay, and put-away moves it to
-- where the product belongs. Between those two facts there was nothing to look
-- at: the interface could raise put-away tasks for a site and could list the
-- tasks once raised, but could not show the pallets standing in goods-in that
-- have no task yet. This is that step, read from the balances.

create or replace function erp.goods_in_lines(p_site_id uuid default null)
returns table(
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
  select s.id, s.code, l.id, l.code, i.id, i.code, i.name,
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

create or replace function public.erp_goods_in(p_site_id uuid default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(g) order by g.site, g.location, g.item_code), '[]'::jsonb)
    from erp.goods_in_lines(p_site_id) g
$$;

comment on function public.erp_goods_in(uuid) is
  'What is standing in goods-in, waiting to be put away.';

revoke all on function public.erp_goods_in(uuid) from public, anon;
grant execute on function public.erp_goods_in(uuid) to authenticated, service_role;

select erp.apply_execute_grants();
select erp.assert_public_api_safe();