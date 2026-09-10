-- A planned lead time is what the supplier said. What matters for a reorder
-- point is what they have actually done: the days between the purchase order
-- and the goods receipt that fulfilled it. Where that history exists it is
-- used; where it does not, the planned figure still answers.

drop function if exists erp.stock_forecast_lines(uuid, integer);

create or replace function erp.stock_forecast_lines(
  p_site_id uuid default null,
  p_days integer default 90)
returns table (
  item_id uuid, item_code text, item_name text,
  site_id uuid, site_code text,
  on_hand numeric, on_order numeric, demand numeric,
  usage_days integer, usage_quantity numeric, usage_per_day numeric,
  lead_time_days integer, lead_time_demand numeric,
  planned_lead_time_days integer,
  measured_lead_time_days numeric, measured_deliveries integer,
  lead_time_source text,
  safety_stock numeric, reorder_point numeric, order_up_to numeric,
  min_order_quantity numeric, order_multiple numeric,
  supplier text, supplier_party_id uuid,
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
  -- Every delivery that answered a purchase order: the supplier it came from,
  -- the products on it, and the days it took. A receipt dated before its own
  -- order is a data error rather than a negative lead time, so it is dropped.
  deliveries as (
    select po.party_id as supplier_party_id,
           poline.item_id,
           po.site_id,
           (grn.document_date - po.document_date) as days
      from erp.document_relation r
      join erp.document grn on grn.id = r.from_document_id
      join erp.document_type grt on grt.id = grn.document_type_id
      join erp.document po on po.id = r.to_document_id
      join erp.document_type pot on pot.id = po.document_type_id
      join erp.document_line poline
        on poline.document_id = po.id and poline.tenant_id = po.tenant_id
         , t
     where r.tenant_id = t.tenant_id
       and r.relation_kind = 'fulfils'
       and grt.code = 'goods_receipt'
       and pot.code = 'purchase_order'
       and coalesce(grn.is_cancelled, false) = false
       and coalesce(po.is_cancelled, false) = false
       and coalesce(poline.is_cancelled, false) = false
       and po.party_id is not null
       and grn.document_date >= po.document_date
       and grn.document_date >= current_date - 730
  ),
  -- Measured for this supplier and this product first; the supplier's own
  -- overall record stands behind it when a product is new to them.
  by_item as (
    select supplier_party_id, item_id,
           round(avg(days)::numeric, 1) as days,
           count(*)::integer as n
      from deliveries group by 1, 2
  ),
  by_supplier as (
    select supplier_party_id,
           round(avg(days)::numeric, 1) as days,
           count(*)::integer as n
      from deliveries group by 1
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
           coalesce(p.lead_time_days, sup.lead_time_days, 0) as planned_lead_time_days,
           coalesce(mi.days, ms.days) as measured_lead_time_days,
           coalesce(mi.n, ms.n, 0) as measured_deliveries,
           p.safety_stock, p.reorder_point, p.order_up_to,
           coalesce(p.min_order_quantity, sup.min_order_quantity) as min_order_quantity,
           coalesce(p.order_multiple, sup.order_multiple) as order_multiple,
           sup.supplier, sup.supplier_party_id
      from t
      cross join keys k
      join erp.item i on i.id = k.item_id
      join sites s on s.id = k.site_id
      left join bal b on b.item_id = k.item_id and b.site_id = k.site_id
      left join used u on u.item_id = k.item_id and u.site_id = k.site_id
      left join ordered o on o.item_id = k.item_id and o.site_id = k.site_id
      left join demanded dm on dm.item_id = k.item_id and dm.site_id = k.site_id
      left join pol p on p.item_id = k.item_id and p.site_id = k.site_id
      left join lateral (
        select pt.name as supplier, pt.id as supplier_party_id, isup.lead_time_days,
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
      left join by_item mi
        on mi.supplier_party_id = sup.supplier_party_id and mi.item_id = k.item_id
      left join by_supplier ms
        on ms.supplier_party_id = sup.supplier_party_id
     where i.status = 'active'::erp.record_status
  ),
  calc as (
    select b.*,
           -- What the supplier has actually done wins over what was planned.
           coalesce(ceil(b.measured_lead_time_days)::integer,
                    b.planned_lead_time_days, 0) as lt,
           case
             when b.measured_lead_time_days is not null then 'measured'
             when b.planned_lead_time_days > 0 then 'planned'
             else 'none'
           end as lead_time_source
      from base b
  ),
  calc2 as (
    select c.*,
           round(c.usage_per_day * c.lt, 4) as lead_time_demand,
           coalesce(nullif(c.reorder_point, 0),
                    round(c.usage_per_day * c.lt
                          + coalesce(c.safety_stock, 0), 4)) as rp
      from calc c
  )
  select c.item_id, c.item_code, c.item_name, c.site_id, c.site_code,
         c.on_hand, c.on_order, c.demand,
         c.usage_days, c.usage_quantity, c.usage_per_day,
         c.lt, c.lead_time_demand,
         c.planned_lead_time_days, c.measured_lead_time_days,
         c.measured_deliveries, c.lead_time_source,
         c.safety_stock, c.rp, c.order_up_to,
         c.min_order_quantity, c.order_multiple, c.supplier, c.supplier_party_id,
         case when c.usage_per_day > 0
              then round(c.on_hand / c.usage_per_day, 1) end as days_cover,
         case when c.usage_per_day > 0 and c.on_hand > c.rp
              then (current_date
                    + ((c.on_hand - c.rp) / c.usage_per_day)::integer)
              when c.usage_per_day > 0 then current_date end as reorder_by,
         case
           when c.on_hand + c.on_order >= greatest(c.rp, 0) then 0
           else greatest(
                  coalesce(nullif(c.order_up_to, 0),
                           c.rp + round(c.usage_per_day * c.lt, 4))
                  - (c.on_hand + c.on_order), 0)
         end as suggest_quantity,
         case
           when c.usage_per_day = 0 and c.on_hand = 0 and c.on_order = 0 then 'dormant'
           when c.on_hand <= 0 and (c.usage_per_day > 0 or c.demand > 0) then 'out of stock'
           when c.rp > 0 and c.on_hand + c.on_order <= c.rp then 'order now'
           when c.usage_per_day > 0 and c.lt > 0
                and c.on_hand / c.usage_per_day < c.lt then 'order now'
           when c.safety_stock is not null and c.on_hand < c.safety_stock then 'below safety'
           when c.usage_per_day = 0 then 'no usage'
           else 'covered'
         end as state
    from calc2 c
   order by c.site_code, c.item_code
$$;

comment on function erp.stock_forecast_lines is
  'Usage measured over a window against the lead time the supplier has actually '
  'taken — purchase order date to goods receipt date — falling back to the '
  'planned lead time where there is no delivery history, with days of cover, '
  'the reorder-by date, a suggested quantity and the supplier to buy from.';

select erp.apply_execute_grants();
select erp.assert_public_api_safe();