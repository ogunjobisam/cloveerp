-- ---------------------------------------------------------------------------
-- The stock forecast: usage, lead time, reorder point — per product, per site.
--
-- The pieces were all on file and none of them were beside each other.
-- erp.stock_balance says what is standing there. erp.stock_movement says what
-- has been going out. erp.item_site holds the policy figures, and
-- erp.item_supplier holds the lead time when the site does not. A buyer had to
-- hold four screens in their head to answer one question — "what will run out,
-- and when do I have to order it?" — so it is answered here in one row.
--
-- Usage is measured, not forecast: what actually left over the window asked
-- for. A demand plan is a different instrument and lives in Planning.
-- ---------------------------------------------------------------------------

create or replace function erp.stock_forecast_lines(
  p_site_id uuid default null,
  p_days integer default 90)
returns table (
  item_id uuid, item_code text, item_name text,
  site_id uuid, site_code text,
  on_hand numeric, on_order numeric, demand numeric,
  usage_days integer, usage_quantity numeric, usage_per_day numeric,
  lead_time_days integer, lead_time_demand numeric,
  safety_stock numeric, reorder_point numeric, order_up_to numeric,
  min_order_quantity numeric, order_multiple numeric,
  supplier text,
  days_cover numeric, reorder_by date, suggest_quantity numeric, state text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.current_tenant_id() as tenant_id, greatest(coalesce(p_days, 90), 1) as win),
  sites as (
    select s.id, s.code
      from erp.site s, t
     where s.tenant_id = t.tenant_id
       and s.status = 'active'::erp.record_status
       and (p_site_id is null or s.id = p_site_id)
  ),
  bal as (
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b, t
     where b.tenant_id = t.tenant_id
     group by b.item_id, b.site_id
  ),
  -- What has actually left. Reversals excluded: a movement and its undoing are
  -- not two units of demand.
  used as (
    select m.item_id, m.site_id, sum(m.quantity) as qty
      from erp.stock_movement m, t
     where m.tenant_id = t.tenant_id
       and coalesce(m.is_reversal, false) = false
       and m.movement_type in ('despatch', 'issue', 'consumption',
                               'production_issue', 'write_off', 'scrap')
       and m.occurred_at >= now() - make_interval(days => t.win)
     group by m.item_id, m.site_id
  ),
  -- Already bought and not yet arrived. Counting it is the difference between
  -- ordering once and ordering twice.
  ordered as (
    select dl.item_id, d.site_id,
           sum(greatest(dl.quantity - coalesce(dl.quantity_fulfilled, 0), 0)) as qty
      from erp.document_line dl
      join erp.document d
        on d.id = dl.document_id and d.tenant_id = dl.tenant_id
      join erp.document_type dt on dt.id = d.document_type_id
         , t
     where dl.tenant_id = t.tenant_id
       and dt.code = 'purchase_order'
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
     group by dl.item_id, d.site_id
  ),
  -- Already sold and not yet gone out.
  demanded as (
    select dl.item_id, d.site_id,
           sum(greatest(dl.quantity - coalesce(dl.quantity_fulfilled, 0), 0)) as qty
      from erp.document_line dl
      join erp.document d
        on d.id = dl.document_id and d.tenant_id = dl.tenant_id
      join erp.document_type dt on dt.id = d.document_type_id
         , t
     where dl.tenant_id = t.tenant_id
       and dt.code = 'sales_order'
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
     group by dl.item_id, d.site_id
  ),
  pol as (
    select i.item_id, i.site_id, i.safety_stock, i.reorder_point, i.order_up_to,
           i.min_order_quantity, i.order_multiple, i.lead_time_days
      from erp.item_site i, t
     where i.tenant_id = t.tenant_id
       and coalesce(i.is_stocked, true)
  ),
  keys as (
    select item_id, site_id from bal where qty <> 0
    union select item_id, site_id from used
    union select item_id, site_id from ordered
    union select item_id, site_id from demanded
    union select item_id, site_id from pol
  ),
  base as (
    select i.id as item_id, i.code as item_code, i.name as item_name,
           s.id as site_id, s.code as site_code,
           coalesce(b.qty, 0) as on_hand,
           coalesce(o.qty, 0) as on_order,
           coalesce(dm.qty, 0) as demand,
           t.win as usage_days,
           coalesce(u.qty, 0) as usage_quantity,
           round(coalesce(u.qty, 0) / t.win, 4) as usage_per_day,
           coalesce(p.lead_time_days, sup.lead_time_days, 0) as lead_time_days,
           p.safety_stock, p.reorder_point, p.order_up_to,
           coalesce(p.min_order_quantity, sup.min_order_quantity) as min_order_quantity,
           coalesce(p.order_multiple, sup.order_multiple) as order_multiple,
           sup.supplier
      from t
      cross join keys k
      join erp.item i on i.id = k.item_id
      join sites s on s.id = k.site_id
      left join bal b on b.item_id = k.item_id and b.site_id = k.site_id
      left join used u on u.item_id = k.item_id and u.site_id = k.site_id
      left join ordered o on o.item_id = k.item_id and o.site_id = k.site_id
      left join demanded dm on dm.item_id = k.item_id and dm.site_id = k.site_id
      left join pol p on p.item_id = k.item_id and p.site_id = k.site_id
      -- The lead time the buyer would actually get: the site's own figure if it
      -- has one, otherwise the default supplier's.
      left join lateral (
        select pt.name as supplier, isup.lead_time_days,
               isup.min_order_quantity, isup.order_multiple
          from erp.item_supplier isup
          join erp.party pt on pt.id = isup.party_id
         where isup.tenant_id = t.tenant_id
           and isup.item_id = k.item_id
           and (isup.site_id is null or isup.site_id = k.site_id)
           and isup.status = 'active'
           and coalesce(isup.is_approved_for_use, true)
           and isup.valid_from <= current_date
           and (isup.valid_to is null or isup.valid_to >= current_date)
         order by (isup.site_id is not null) desc,
                  isup.is_default desc, isup.preference_rank
         limit 1
      ) sup on true
     where i.status = 'active'::erp.record_status
  ),
  calc as (
    select b.*,
           round(b.usage_per_day * b.lead_time_days, 4) as lead_time_demand,
           -- The reorder point the organisation set, or — where it set none —
           -- the one its own history implies. Shown either way, so a product
           -- nobody has policied is still answerable.
           coalesce(nullif(b.reorder_point, 0),
                    round(b.usage_per_day * b.lead_time_days
                          + coalesce(b.safety_stock, 0), 4)) as rp
      from base b
  )
  select c.item_id, c.item_code, c.item_name, c.site_id, c.site_code,
         c.on_hand, c.on_order, c.demand,
         c.usage_days, c.usage_quantity, c.usage_per_day,
         c.lead_time_days, c.lead_time_demand,
         c.safety_stock, c.rp, c.order_up_to,
         c.min_order_quantity, c.order_multiple, c.supplier,
         case when c.usage_per_day > 0
              then round(c.on_hand / c.usage_per_day, 1) end as days_cover,
         -- The date the balance falls to the reorder point. Ordering after it
         -- is ordering late by definition.
         case when c.usage_per_day > 0 and c.on_hand > c.rp
              then (current_date
                    + ((c.on_hand - c.rp) / c.usage_per_day)::integer)
              when c.usage_per_day > 0 then current_date end as reorder_by,
         case
           when c.on_hand + c.on_order >= greatest(c.rp, 0) then 0
           else greatest(
                  coalesce(nullif(c.order_up_to, 0),
                           c.rp + round(c.usage_per_day * c.lead_time_days, 4))
                  - (c.on_hand + c.on_order), 0)
         end as suggest_quantity,
         case
           when c.usage_per_day = 0 and c.on_hand = 0 and c.on_order = 0 then 'dormant'
           when c.on_hand <= 0 and (c.usage_per_day > 0 or c.demand > 0) then 'out of stock'
           when c.rp > 0 and c.on_hand + c.on_order <= c.rp then 'order now'
           when c.usage_per_day > 0 and c.lead_time_days > 0
                and c.on_hand / c.usage_per_day < c.lead_time_days then 'order now'
           when c.safety_stock is not null and c.on_hand < c.safety_stock then 'below safety'
           when c.usage_per_day = 0 then 'no usage'
           else 'covered'
         end as state
    from calc c
   order by c.site_code, c.item_code
$$;

comment on function erp.stock_forecast_lines is
  'Usage measured over a window, the lead time to replace it, the reorder point '
  'and what is on order — with days of cover, the reorder-by date and a '
  'suggested quantity, per product per site.';

create or replace function public.erp_stock_forecast(
  p_site_id uuid default null,
  p_days integer default 90)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(f) order by
           case f.state when 'out of stock' then 0 when 'order now' then 1
                        when 'below safety' then 2 when 'covered' then 3
                        when 'no usage' then 4 else 5 end,
           f.reorder_by nulls last, f.site_code, f.item_code), '[]'::jsonb)
    from erp.stock_forecast_lines(p_site_id, p_days) f
$$;

comment on function public.erp_stock_forecast is
  'Stock forecast: usage per day, lead time, reorder point, days of cover and a '
  'suggested purchase quantity for every stocked product.';

revoke all on function public.erp_stock_forecast(uuid, integer) from public, anon;
grant execute on function public.erp_stock_forecast(uuid, integer) to authenticated, service_role;

select erp.apply_execute_grants();
select erp.assert_public_api_safe();
