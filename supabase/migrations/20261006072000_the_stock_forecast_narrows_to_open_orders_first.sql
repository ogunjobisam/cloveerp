set lock_timeout = '30s';

-- =============================================================================
-- 20261006072000  The stock forecast narrows to open orders first
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-43). The stock
-- forecast (public.erp_stock_forecast, reading erp.stock_forecast_lines)
-- timed out under load.
--
-- Its demand is what customers are still owed: lines of sales orders that
-- are confirmed, being picked or part despatched, less any line the sales
-- policy reads delivered (erp.sales_line_is_delivered, a three-table lookup
-- and the sales policy, per line). That last test names only the line, so the
-- planner is free to put it on the scan of erp.document_line, before the join
-- narrows to open sales orders. A plain EXPLAIN without statistics does just
-- that: the test is asked of every line of every document the organisation
-- has ever raised. Whether it does on live depends on the plan of the day;
-- nothing in the query stopped it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_test.stock_forecast_lines_reference(site, days): today's body,
--      word for word, kept as the answer the new one must give.
--   B. erp.stock_forecast_lines(site, days), edited in place: the open sales
--      order lines are gathered first, materialised, and the delivered test
--      is asked of those lines alone. The same lines, the same test, the same
--      sums; only where the test is asked moves. Everything else in the
--      forecast is unchanged.
--   C. erp_test.stock_forecast_narrows_first_suite: the forecast is the same
--      as the reference for every organisation in the database, for a
--      demonstration with three weeks of trading and an order still owed,
--      read by its administrator (every site, one site, a shorter window),
--      and when the sales policy reads every line delivered; and the plan
--      asks the delivered test of the open lines only.
--
-- On production: one function is edited in place. No table is altered and no
-- row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Today's body, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_forecast_lines_reference(p_site_id uuid default null, p_days integer default 90)
returns table(item_id uuid, item_code text, item_name text, site_id uuid, site_code text, on_hand numeric, on_order numeric, demand numeric, usage_days integer, usage_quantity numeric, usage_per_day numeric, lead_time_days integer, lead_time_demand numeric, planned_lead_time_days integer, measured_lead_time_days numeric, measured_deliveries integer, lead_time_source text, safety_stock numeric, reorder_point numeric, order_up_to numeric, min_order_quantity numeric, order_multiple numeric, supplier text, supplier_party_id uuid, days_cover numeric, reorder_by date, suggest_quantity numeric, state text)
language sql
stable
set search_path = ''
as $reference$
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
       -- Demand is what customers are still owed: orders confirmed, being
       -- picked or part despatched (20260914076000, 20260923800000). A despatched, invoiced or closed order is
       -- not demand, whatever its lines count as fulfilled.
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = d.tenant_id and os.object_type = 'document'
                      and os.object_id = d.id and s.code in ('confirmed', 'picking', 'partially_despatched'))
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
       -- Nor a line the sales policy reads delivered (20260924000000).
       and not erp.sales_line_is_delivered(dl.id)
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
$reference$;

revoke all on function erp_test.stock_forecast_lines_reference(uuid, integer) from public, anon;

comment on function erp_test.stock_forecast_lines_reference(uuid, integer) is
  'erp.stock_forecast_lines() as it was before 20261006072000, word for word: the forecast the new body must still '
  'give (J-43). Read only by erp_test.stock_forecast_narrows_first_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Open sales order lines first, then the delivered test
-- ─────────────────────────────────────────────────────────────────────────────

do $forecast$
declare
  v_sig  constant text := 'erp.stock_forecast_lines(uuid,integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  demanded as (
    select dl.item_id, d.site_id,
           sum(greatest(dl.quantity - coalesce(dl.quantity_fulfilled, 0), 0)) as qty
      from erp.document_line dl
      join erp.document d
        on d.id = dl.document_id and d.tenant_id = dl.tenant_id
      join erp.document_type dt on dt.id = d.document_type_id
         , t
     where dl.tenant_id = t.tenant_id
       and dt.code = 'sales_order'
       -- Demand is what customers are still owed: orders confirmed, being
       -- picked or part despatched (20260914076000, 20260923800000). A despatched, invoiced or closed order is
       -- not demand, whatever its lines count as fulfilled.
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = d.tenant_id and os.object_type = 'document'
                      and os.object_id = d.id and s.code in ('confirmed', 'picking', 'partially_despatched'))
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
       -- Nor a line the sales policy reads delivered (20260924000000).
       and not erp.sales_line_is_delivered(dl.id)
     group by dl.item_id, d.site_id
  ),
$o$;
  v_new  constant text := $n$  -- The open sales order lines first, and only then the sales policy's
  -- test of whether each is delivered (20261006072000, J-43). Asked inside
  -- one query the test went down to every line of every document the
  -- organisation had ever raised, before the join narrowed to open sales
  -- orders; materialised here, it is asked of those lines alone.
  open_sales_lines as materialized (
    select dl.id, dl.item_id, d.site_id,
           greatest(dl.quantity - coalesce(dl.quantity_fulfilled, 0), 0) as qty
      from erp.document_line dl
      join erp.document d
        on d.id = dl.document_id and d.tenant_id = dl.tenant_id
      join erp.document_type dt on dt.id = d.document_type_id
         , t
     where dl.tenant_id = t.tenant_id
       and dt.code = 'sales_order'
       -- Demand is what customers are still owed: orders confirmed, being
       -- picked or part despatched (20260914076000, 20260923800000). A despatched, invoiced or closed order is
       -- not demand, whatever its lines count as fulfilled.
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = d.tenant_id and os.object_type = 'document'
                      and os.object_id = d.id and s.code in ('confirmed', 'picking', 'partially_despatched'))
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
  ),
  demanded as (
    select o.item_id, o.site_id, sum(o.qty) as qty
      from open_sales_lines o
     -- Nor a line the sales policy reads delivered (20260924000000).
     where not erp.sales_line_is_delivered(o.id)
     group by o.item_id, o.site_id
  ),
$n$;
begin
  if strpos(v_src, '20261006072000') > 0 then
    raise notice '% already narrows to open orders first; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '64989c579fce55b14eab5469b127a14d' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006072000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % demand anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$forecast$;

comment on function erp.stock_forecast_lines(uuid, integer) is
  'Usage measured over a window against the lead time the supplier has actually taken — purchase order date to goods '
  'receipt date — falling back to the planned lead time where there is no delivery history, with days of cover, the '
  'reorder-by date, a suggested quantity and the supplier to buy from. Demand asks the sales policy only of open '
  'sales order lines (20261006072000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_forecast_narrows_first_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  v_owner  text := current_user;
  rb       record;
  tn       record;
  v_step   text := 'every organisation in the database';
  v_state  text;
  v_orgs   integer := 0;
  v_rows   integer := 0;
  v_differ text := '';
  v_n      integer;
  v_new    jsonb;
  v_ref    jsonb;
  v_site   uuid;
  v_cust   uuid;
  v_item   uuid;
  v_so     uuid;
  v_entity uuid;
  v_site_n jsonb;
  v_site_r jsonb;
  v_win_n  jsonb;
  v_win_r  jsonb;
  v_demand numeric;
  v_used   numeric;
  v_after  numeric;
  v_src    text;
  v_line   text;
  v_prev   text := '';
  v_tests  integer := 0;
  v_on_open integer := 0;
begin
  begin
    -- ── 1. Every organisation already in the database ───────────────────────
    perform set_config('request.jwt.claims', '', true);
    for tn in select t.id, t.code from erp.tenant t where t.deleted_at is null order by t.code loop
      perform erp.set_job_tenant(tn.id);
      select count(*) into v_n
        from ((select * from erp.stock_forecast_lines(null, 90)
               except all select * from erp_test.stock_forecast_lines_reference(null, 90))
              union all
              (select * from erp_test.stock_forecast_lines_reference(null, 90)
               except all select * from erp.stock_forecast_lines(null, 90))) z;
      v_orgs := v_orgs + 1;
      v_rows := v_rows + (select count(*) from erp.stock_forecast_lines(null, 90))::integer;
      if v_n > 0 then
        v_differ := v_differ || tn.code || ' (' || v_n || '); ';
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'every organisation in the database has the same stock forecast as before';
    passed := v_orgs >= 1 and v_differ = '';
    detail := format('%s organisation(s), %s forecast line(s); differing: %s',
                     v_orgs, v_rows, coalesce(nullif(v_differ, ''), 'none'));
    return next;

    -- ── 2. A demonstration that has traded, read by its administrator ──────
    v_step := 'a demonstration with three weeks of trading';
    select * into rb from erp.provision_tenant(
      'demo-zzsf' || v_tag, 'Stock Forecast Suite', 'admin@demo-zzsf' || v_tag || '.test', 'Forecast Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzsf' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    perform erp_test.build_demo_days(current_date - 26, current_date - 5);
    -- And one order of its own still owed, so there is demand whatever the
    -- seeded weeks left open.
    v_step := 'an order still owed to a customer';
    select s.id, s.entity_id into v_site, v_entity
      from erp.site s where s.tenant_id = rb.tenant_id and s.status = 'active' order by s.code limit 1;
    select pr.party_id into v_cust
      from erp.party_role pr where pr.tenant_id = rb.tenant_id and pr.role_kind = 'customer' and pr.status = 'active'
     order by pr.party_id limit 1;
    select b.item_id into v_item
      from erp.stock_balance b where b.tenant_id = rb.tenant_id and b.site_id = v_site and b.quantity > 0
     order by b.item_id limit 1;
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    perform erp.add_document_line(v_so, v_item, 7, 100, 'the stock forecast suite');
    perform erp.transition_document(v_so, 'submit', 'the stock forecast suite');
    perform erp_test.approve_document(v_so, 'the stock forecast suite');

    v_step := 'the demonstration''s forecast read both ways';
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_new from erp.stock_forecast_lines(null, 90) f;
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_site_n from erp.stock_forecast_lines(v_site, 90) f;
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_win_n from erp.stock_forecast_lines(null, 14) f;
    execute format('set local role %I', v_owner);
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_ref from erp_test.stock_forecast_lines_reference(null, 90) f;
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_site_r from erp_test.stock_forecast_lines_reference(v_site, 90) f;
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_win_r from erp_test.stock_forecast_lines_reference(null, 14) f;
    select coalesce(sum((x ->> 'demand')::numeric), 0), coalesce(sum((x ->> 'usage_quantity')::numeric), 0)
      into v_demand, v_used from jsonb_array_elements(v_new) x;
    v_cases := v_cases + 1;
    case_name := 'a demonstration that has traded has the same forecast as before, for every site, one site and a shorter window';
    passed := v_new = v_ref and v_site_n is not distinct from v_site_r and v_win_n is not distinct from v_win_r
          and v_demand >= 7 and v_used > 0 and erp.object_current_state('document', v_so) = 'confirmed';
    detail := format('%s line(s), demand %s, usage %s, the order %s%s', jsonb_array_length(v_new), v_demand, v_used,
                     erp.object_current_state('document', v_so),
                     case when v_new = v_ref and v_site_n is not distinct from v_site_r
                               and v_win_n is not distinct from v_win_r then '' else '; differs from before' end);
    return next;

    -- ── 3. The sales policy reads every open line delivered ────────────────
    v_step := 'a sales policy that short-closes everything';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.set_config_value('sales.policy', jsonb_build_object('over_ship_pct', 0, 'short_close_pct', 100),
      null, null, v_entity, null, 'the stock forecast suite');
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_new from erp.stock_forecast_lines(null, 90) f;
    select jsonb_agg(to_jsonb(f) order by f.site_code, f.item_code) into v_ref from erp_test.stock_forecast_lines_reference(null, 90) f;
    select coalesce(sum((x ->> 'demand')::numeric), 0) into v_after from jsonb_array_elements(v_new) x;
    v_cases := v_cases + 1;
    case_name := 'when the sales policy reads every open line delivered there is no demand, as before';
    passed := v_new = v_ref and v_after = 0 and v_demand > 0;
    detail := format('demand %s before the policy, %s after%s', v_demand, v_after,
                     case when v_new = v_ref then '' else '; differs from before' end);
    return next;

    -- ── 4. The plan, as the administrator ───────────────────────────────────
    v_step := 'planning the forecast as the administrator';
    select p.prosrc into v_src from pg_catalog.pg_proc p where p.oid = 'erp.stock_forecast_lines(uuid,integer)'::regprocedure;
    v_src := replace(replace(v_src, 'p_site_id', 'null::uuid'), 'p_days', '90');
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    for v_line in execute 'explain ' || v_src loop
      if v_line like '%erp.sales_line_is_delivered(%' then
        v_tests := v_tests + 1;
        if v_prev like '%CTE Scan on open_sales_lines%' then
          v_on_open := v_on_open + 1;
        end if;
      end if;
      v_prev := v_line;
    end loop;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'the delivered test is asked of the open sales order lines only';
    passed := v_tests = 1 and v_on_open = 1;
    detail := format('%s place(s) in the plan ask the test, %s of them over the open lines', v_tests, v_on_open);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_STOCK_FORECAST_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.stock_forecast_narrows_first_suite() from public, anon;

comment on function erp_test.stock_forecast_narrows_first_suite() is
  'The stock forecast narrows to open orders first (20261006072000, J-43): the same forecast as the body it replaced '
  'for every organisation and for a demonstration that has traded, and the delivered test asked of open lines only.';

create or replace function erp_test.assert_stock_forecast_narrows_first_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.stock_forecast_narrows_first_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_STOCK_FORECAST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The stock forecast would say otherwise than before, or ask the sales policy of every line again. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_STOCK_FORECAST_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('stock forecast narrows first: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_stock_forecast_narrows_first_suite() from public, anon;

comment on function erp_test.assert_stock_forecast_narrows_first_suite() is
  'The stock forecast is what it was, and asks the sales policy of open lines only (20261006072000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
