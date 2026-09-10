-- ---------------------------------------------------------------------------
-- The stock audit: what the book says, what the last count found, and the
-- distance between the two — per place, and per product within a place.
--
-- Everything needed already existed and was scattered: erp.stock_balance holds
-- the book, erp.count_task holds what somebody found, erp.stock_valuation_report
-- holds what it is worth. Nothing put them side by side, so a variance could
-- only be seen one count task at a time — which is the wrong unit. An auditor
-- asks about a location, not a task, and the answer has to include the
-- locations no count task was ever raised for. Those are the interesting ones.
-- ---------------------------------------------------------------------------

create or replace function erp.stock_audit_lines(
  p_site_id uuid default null,
  p_location_id uuid default null)
returns table (
  location_id uuid, location_code text, location_name text,
  location_type text, is_blocked boolean,
  site_id uuid, site_code text,
  item_id uuid, item_code text, item_name text,
  quantity numeric, unit_cost_minor bigint, value_minor bigint, currency character(3),
  last_counted_at timestamptz, expected_quantity numeric,
  counted_quantity numeric, variance numeric, variance_value_minor bigint,
  count_status text, count_class text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.current_tenant_id() as tenant_id),
  book as (
    select b.location_id, b.site_id, b.item_id, sum(b.quantity) as quantity
      from erp.stock_balance b, t
     where b.tenant_id = t.tenant_id
       and b.location_id is not null
       and (p_site_id is null or b.site_id = p_site_id)
       and (p_location_id is null or b.location_id = p_location_id)
     group by b.location_id, b.site_id, b.item_id
    having sum(b.quantity) <> 0
  ),
  -- The last count for each place and product, whatever came of it. A task
  -- raised and never counted still belongs here: "asked, not answered" is a
  -- finding, and it is invisible if only posted counts are read.
  last_count as (
    select distinct on (c.location_id, c.item_id)
           c.location_id, c.item_id, c.expected_quantity, c.counted_quantity,
           c.variance, c.status::text as status,
           coalesce(c.counted_at, c.created_at) as at
      from erp.count_task c, t
     where c.tenant_id = t.tenant_id
       and c.location_id is not null
       and (p_site_id is null or c.site_id = p_site_id)
       and (p_location_id is null or c.location_id = p_location_id)
     order by c.location_id, c.item_id, coalesce(c.counted_at, c.created_at) desc
  ),
  -- Valuation is held per product and site, not per bin. A bin's share of the
  -- value is its share of the quantity, at the same unit cost: an apportionment,
  -- and honest about being one.
  cost as (
    select v.item_id, v.site_id, v.unit_cost_minor, v.currency
      from erp.stock_valuation_report() v
  ),
  -- Places with a count but no stock left in them: counted to nil, or emptied
  -- since. Dropping them would hide exactly the variance worth seeing.
  keys as (
    select location_id, site_id, item_id from book
    union
    select lc.location_id, l.site_id, lc.item_id
      from last_count lc
      join erp.location l on l.id = lc.location_id
  )
  select l.id, l.code, l.name, l.location_type::text, coalesce(l.is_blocked, false),
         s.id, s.code,
         i.id, i.code, i.name,
         coalesce(b.quantity, 0),
         coalesce(c.unit_cost_minor, 0),
         round(coalesce(b.quantity, 0) * coalesce(c.unit_cost_minor, 0))::bigint,
         coalesce(c.currency, 'GBP'::character(3)),
         lc.at,
         lc.expected_quantity,
         lc.counted_quantity,
         lc.variance,
         round(coalesce(lc.variance, 0) * coalesce(c.unit_cost_minor, 0))::bigint,
         lc.status,
         l.count_class
    from keys k
    join erp.location l on l.id = k.location_id
    join erp.site s on s.id = k.site_id
    join erp.item i on i.id = k.item_id
    left join book b on b.location_id = k.location_id and b.item_id = k.item_id
    left join last_count lc on lc.location_id = k.location_id and lc.item_id = k.item_id
    left join cost c on c.item_id = k.item_id and c.site_id is not distinct from k.site_id
   order by s.code, l.code, i.code
$$;

comment on function erp.stock_audit_lines is
  'Product by product within a place: the book quantity, its apportioned value, '
  'and the last count raised against it whether or not it was ever answered.';

create or replace function public.erp_stock_audit_lines(
  p_site_id uuid default null,
  p_location_id uuid default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.site_code, a.location_code, a.item_code),
                  '[]'::jsonb)
    from erp.stock_audit_lines(p_site_id, p_location_id) a
$$;

comment on function public.erp_stock_audit_lines is
  'Stock audit, product by product within a location.';

create or replace function public.erp_stock_audit(p_site_id uuid default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with lines as (select * from erp.stock_audit_lines(p_site_id, null)),
  -- Every active place, not only the ones holding something. An empty bin the
  -- book says is empty is a fact; an empty bin nobody has counted in a year is
  -- a question, and it can only be asked if the bin appears.
  places as (
    select l.id, l.code, l.name, l.location_type::text as location_type,
           coalesce(l.is_blocked, false) as is_blocked, l.count_class,
           s.code as site_code, s.id as site_id
      from erp.location l
      join erp.site s on s.tenant_id = l.tenant_id and s.id = l.site_id
     where l.tenant_id = erp.current_tenant_id()
       and l.status = 'active'::erp.record_status
       and (p_site_id is null or l.site_id = p_site_id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'location_id', p.id, 'location', p.code, 'location_name', p.name,
           'location_type', p.location_type, 'is_blocked', p.is_blocked,
           'count_class', p.count_class,
           'site', p.site_code, 'site_id', p.site_id,
           'products', coalesce(g.products, 0),
           'quantity', coalesce(g.quantity, 0),
           'value_minor', coalesce(g.value_minor, 0),
           'currency', coalesce(g.currency, 'GBP'),
           'last_counted_at', g.last_counted_at,
           'counted_quantity', g.counted_quantity,
           'variance', g.variance,
           'variance_value_minor', coalesce(g.variance_value_minor, 0),
           'counts_open', coalesce(g.counts_open, 0),
           'state', case
                      when coalesce(g.counts_open, 0) > 0 then 'counting'
                      when g.last_counted_at is null then 'never counted'
                      when coalesce(g.variance, 0) <> 0 then 'variance'
                      else 'agreed'
                    end)
           order by p.site_code, p.code), '[]'::jsonb)
    from places p
    left join (
      select l.location_id,
             count(*) filter (where l.quantity <> 0) as products,
             sum(l.quantity) as quantity,
             sum(l.value_minor) as value_minor,
             min(l.currency) as currency,
             max(l.last_counted_at) as last_counted_at,
             sum(l.counted_quantity) as counted_quantity,
             sum(l.variance) as variance,
             sum(l.variance_value_minor) as variance_value_minor,
             count(*) filter (where l.count_status in ('open', 'counted')) as counts_open
        from lines l
       group by l.location_id
    ) g on g.location_id = p.id
$$;

comment on function public.erp_stock_audit is
  'Stock audit by location: what stands there, what it is worth, when it was '
  'last counted and by how much the count differed.';

revoke all on function public.erp_stock_audit(uuid) from public, anon;
grant execute on function public.erp_stock_audit(uuid) to authenticated, service_role;
revoke all on function public.erp_stock_audit_lines(uuid, uuid) from public, anon;
grant execute on function public.erp_stock_audit_lines(uuid, uuid) to authenticated, service_role;

select erp.apply_execute_grants();
select erp.assert_public_api_safe();
