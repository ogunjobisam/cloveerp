-- ============================================================
-- Part A: read-only lookups for record pickers
-- ============================================================

create or replace function public.erp_locations(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'location_id', l.id, 'code', l.code, 'name', l.name,
           'site', s.code, 'location_type', l.location_type,
           'is_pickable', l.is_pickable, 'is_blocked', l.is_blocked)
           order by s.code, l.code), '[]'::jsonb)
    from erp.location l
    join erp.site s on s.tenant_id = l.tenant_id and s.id = l.site_id
   where l.tenant_id = erp.current_tenant_id()
     and l.status = 'active'::erp.record_status
     and (p_site_id is null or l.site_id = p_site_id);
$$;

create or replace function public.erp_document_lines(
  p_document_id uuid default null, p_type_code text default null, p_limit integer default 200)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'document_number', (x->>'line_no')::int), '[]'::jsonb) from (
    select jsonb_build_object(
             'line_id', dl.id, 'document_id', d.id, 'document_number', d.document_number,
             'document_type', dt.code, 'line_no', dl.line_no,
             'item', i.code, 'description', dl.description,
             'quantity', dl.quantity, 'quantity_fulfilled', dl.quantity_fulfilled,
             'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency,
             'line_state', dl.line_state) as x
      from erp.document_line dl
      join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
     where dl.tenant_id = erp.current_tenant_id()
       and coalesce(dl.is_cancelled, false) = false
       and (p_document_id is null or dl.document_id = p_document_id)
       and (p_type_code is null or dt.code = p_type_code)
     order by d.document_date desc nulls last, dl.line_no
     limit greatest(p_limit, 1)) t;
$$;

create or replace function public.erp_inspections(p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'started_at' desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
             'inspection_id', ins.id, 'item', i.code, 'batch', b.batch_number,
             'status', ins.status, 'disposition', ins.disposition,
             'quantity_inspected', ins.quantity_inspected,
             'started_at', ins.started_at, 'completed_at', ins.completed_at) as x
      from erp.inspection ins
      left join erp.item i on i.tenant_id = ins.tenant_id and i.id = ins.item_id
      left join erp.batch b on b.tenant_id = ins.tenant_id and b.id = ins.batch_id
     where ins.tenant_id = erp.current_tenant_id()
     order by ins.started_at desc nulls last
     limit greatest(p_limit, 1)) t;
$$;

create or replace function public.erp_landed_costs(p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'charge_code'), '[]'::jsonb) from (
    select jsonb_build_object(
             'landed_cost_id', lc.id, 'charge_code', lc.charge_code,
             'description', lc.description, 'amount_minor', lc.amount_minor,
             'currency', lc.currency, 'basis', lc.allocation_basis,
             'receipt', d.document_number, 'allocated_at', lc.allocated_at) as x
      from erp.landed_cost lc
      left join erp.document d on d.tenant_id = lc.tenant_id and d.id = lc.receipt_document_id
     where lc.tenant_id = erp.current_tenant_id()
     order by lc.created_at desc
     limit greatest(p_limit, 1)) t;
$$;

create or replace function public.erp_payment_proposals(p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'payment_date' desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
             'proposal_id', pp.id, 'reference', pp.reference, 'payment_date', pp.payment_date,
             'currency', pp.currency, 'total_minor', pp.total_minor, 'status', pp.status) as x
      from erp.payment_proposal pp
     where pp.tenant_id = erp.current_tenant_id()
     order by pp.payment_date desc nulls last
     limit greatest(p_limit, 1)) t;
$$;

create or replace function public.erp_forecast_versions(p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'forecast', (x->>'version')::int desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'version_id', fv.id, 'forecast', f.code, 'forecast_name', f.name,
             'version', fv.version, 'method', fv.method, 'status', fv.status,
             'horizon_from', fv.horizon_from, 'horizon_to', fv.horizon_to) as x
      from erp.forecast_version fv
      join erp.forecast f on f.tenant_id = fv.tenant_id and f.id = fv.forecast_id
     where fv.tenant_id = erp.current_tenant_id()
     order by fv.created_at desc
     limit greatest(p_limit, 1)) t;
$$;

-- ============================================================
-- Part B1: warehouse tasks (putaway and replenishment)
-- ============================================================

create table if not exists erp.warehouse_task (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  site_id uuid not null references erp.site(id),
  kind text not null check (kind in ('putaway', 'replenishment')),
  item_id uuid not null references erp.item(id),
  batch_id uuid references erp.batch(id),
  from_location_id uuid not null references erp.location(id),
  to_location_id uuid not null references erp.location(id),
  stock_status erp.stock_status not null default 'available',
  quantity numeric not null check (quantity > 0),
  quantity_done numeric not null default 0 check (quantity_done >= 0),
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  note text,
  completed_at timestamptz,
  completed_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists warehouse_task_tenant_status_idx
  on erp.warehouse_task (tenant_id, status, kind);

alter table erp.warehouse_task enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'erp'
                   and tablename = 'warehouse_task' and policyname = 'tenant_isolation') then
    create policy tenant_isolation on erp.warehouse_task
      using (tenant_id = erp.current_tenant_id())
      with check (tenant_id = erp.current_tenant_id());
  end if;
end $$;

create or replace function erp.raise_putaway_tasks(p_site_id uuid)
returns integer language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_created integer := 0;
  r record;
  v_target uuid;
begin
  perform erp.authorise('inventory.adjust', null, p_site_id, null, 'site', p_site_id);

  -- Stock standing in a receiving location has arrived but has not been put
  -- away; that is the whole definition of a putaway task.
  for r in
    select sb.item_id, sb.batch_id, sb.location_id, sb.stock_status, sum(sb.quantity) as qty
      from erp.stock_balance sb
      join erp.location l on l.tenant_id = sb.tenant_id and l.id = sb.location_id
     where sb.tenant_id = v_tenant
       and sb.site_id = p_site_id
       and sb.quantity > 0
       and l.location_type = 'receiving'::erp.location_type
     group by 1, 2, 3, 4
  loop
    select l.id into v_target
      from erp.location l
     where l.tenant_id = v_tenant and l.site_id = p_site_id
       and l.status = 'active'::erp.record_status
       and coalesce(l.is_blocked, false) = false
       and l.location_type in ('bulk'::erp.location_type, 'pick'::erp.location_type)
     order by case when l.location_type = 'bulk'::erp.location_type then 0 else 1 end, l.code
     limit 1;

    if v_target is null then
      continue;
    end if;

    if exists (select 1 from erp.warehouse_task t
                where t.tenant_id = v_tenant and t.status = 'open' and t.kind = 'putaway'
                  and t.item_id = r.item_id and t.from_location_id = r.location_id
                  and coalesce(t.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                      = coalesce(r.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)) then
      continue;
    end if;

    insert into erp.warehouse_task (tenant_id, site_id, kind, item_id, batch_id,
      from_location_id, to_location_id, stock_status, quantity, created_by, updated_by)
    values (v_tenant, p_site_id, 'putaway', r.item_id, r.batch_id,
      r.location_id, v_target, r.stock_status, r.qty, v_actor, v_actor);
    v_created := v_created + 1;
  end loop;

  return v_created;
end $$;

create or replace function erp.raise_replenishment_tasks(p_site_id uuid)
returns integer language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_created integer := 0;
  r record;
begin
  perform erp.authorise('inventory.adjust', null, p_site_id, null, 'site', p_site_id);

  -- A pick face is short when what is committed against it exceeds what is
  -- available in it. The shortfall is fetched from reserve stock.
  for r in
    with pick as (
      select a.item_id,
             sum(a.available) as available,
             sum(a.committed) as committed,
             min(a.location_id) as location_id
        from erp.stock_availability a
        join erp.location l on l.tenant_id = a.tenant_id and l.id = a.location_id
       where a.tenant_id = v_tenant and a.site_id = p_site_id
         and coalesce(l.is_pickable, false) = true
       group by a.item_id
    ), reserve as (
      select sb.item_id, sb.location_id, sb.batch_id, sb.stock_status, sum(sb.quantity) as qty
        from erp.stock_balance sb
        join erp.location l on l.tenant_id = sb.tenant_id and l.id = sb.location_id
       where sb.tenant_id = v_tenant and sb.site_id = p_site_id and sb.quantity > 0
         and coalesce(l.is_pickable, false) = false
         and l.location_type = 'bulk'::erp.location_type
       group by 1, 2, 3, 4
    )
    select p.item_id, p.location_id as to_location_id, rs.location_id as from_location_id,
           rs.batch_id, rs.stock_status,
           least(p.committed - p.available, rs.qty) as qty
      from pick p
      join reserve rs on rs.item_id = p.item_id
     where p.committed > p.available
       and p.location_id is not null
  loop
    if r.qty is null or r.qty <= 0 then
      continue;
    end if;

    if exists (select 1 from erp.warehouse_task t
                where t.tenant_id = v_tenant and t.status = 'open' and t.kind = 'replenishment'
                  and t.item_id = r.item_id and t.to_location_id = r.to_location_id) then
      continue;
    end if;

    insert into erp.warehouse_task (tenant_id, site_id, kind, item_id, batch_id,
      from_location_id, to_location_id, stock_status, quantity, created_by, updated_by)
    values (v_tenant, p_site_id, 'replenishment', r.item_id, r.batch_id,
      r.from_location_id, r.to_location_id, r.stock_status, r.qty, v_actor, v_actor);
    v_created := v_created + 1;
  end loop;

  return v_created;
end $$;

create or replace function erp.complete_warehouse_task(p_task_id uuid, p_quantity numeric default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  t erp.warehouse_task%rowtype;
  v_qty numeric;
  v_uom uuid;
  v_entity uuid;
begin
  select * into t from erp.warehouse_task where tenant_id = v_tenant and id = p_task_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_TASK: that warehouse task does not exist here';
  end if;

  perform erp.authorise('inventory.adjust', null, t.site_id, null, 'warehouse_task', t.id);

  if t.status <> 'open' then
    raise exception 'ERPWARE_TASK_NOT_OPEN: that task has already been %', t.status;
  end if;

  v_qty := coalesce(p_quantity, t.quantity);
  if v_qty <= 0 or v_qty > t.quantity then
    raise exception 'ERPWARE_TASK_QUANTITY: the quantity must be above zero and no more than %', t.quantity;
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id;
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = t.site_id;

  insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, to_location_id, to_status, quantity, uom_id, reason_code, actor_id)
  values (v_tenant, v_entity, t.site_id, 'transfer', t.item_id, t.batch_id,
    t.from_location_id, t.stock_status, t.to_location_id, t.stock_status, v_qty, v_uom, t.kind, v_actor);

  update erp.warehouse_task
     set quantity_done = quantity_done + v_qty,
         status = case when quantity_done + v_qty >= quantity then 'done' else 'open' end,
         completed_at = case when quantity_done + v_qty >= quantity then now() else null end,
         completed_by = case when quantity_done + v_qty >= quantity then v_actor else null end,
         updated_at = now(), updated_by = v_actor
   where id = t.id;

  return jsonb_build_object('task_id', t.id, 'moved', v_qty);
end $$;

create or replace function public.erp_warehouse_tasks(
  p_site_id uuid default null, p_kind text default null, p_limit integer default 200)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'task_id', t.id, 'kind', t.kind, 'status', t.status,
             'item', i.code, 'item_name', i.name, 'site', s.code,
             'batch', b.batch_number,
             'from_location', fl.code, 'to_location', tl.code,
             'quantity', t.quantity, 'quantity_done', t.quantity_done,
             'created_at', t.created_at, 'completed_at', t.completed_at) as x
      from erp.warehouse_task t
      join erp.item i on i.tenant_id = t.tenant_id and i.id = t.item_id
      join erp.site s on s.tenant_id = t.tenant_id and s.id = t.site_id
      left join erp.batch b on b.tenant_id = t.tenant_id and b.id = t.batch_id
      join erp.location fl on fl.tenant_id = t.tenant_id and fl.id = t.from_location_id
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or t.site_id = p_site_id)
       and (p_kind is null or t.kind = p_kind)
     order by t.created_at desc
     limit greatest(p_limit, 1)) q;
$$;

create or replace function public.erp_raise_putaway_tasks(p_site_id uuid)
returns integer language sql volatile security invoker set search_path to ''
as $$ select erp.raise_putaway_tasks(p_site_id); $$;

create or replace function public.erp_raise_replenishment_tasks(p_site_id uuid)
returns integer language sql volatile security invoker set search_path to ''
as $$ select erp.raise_replenishment_tasks(p_site_id); $$;

create or replace function public.erp_complete_warehouse_task(p_task_id uuid, p_quantity numeric default null)
returns jsonb language sql volatile security invoker set search_path to ''
as $$ select erp.complete_warehouse_task(p_task_id, p_quantity); $$;

-- ============================================================
-- Part B2: batch merge
-- ============================================================

create or replace function erp.merge_batches(
  p_target_batch_id uuid, p_source_batch_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  tgt erp.batch%rowtype;
  src erp.batch%rowtype;
  v_uom uuid;
  v_moved numeric := 0;
  r record;
begin
  if p_target_batch_id = p_source_batch_id then
    raise exception 'ERPWARE_MERGE_SAME_BATCH: a batch cannot be merged into itself';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_MERGE_NEEDS_REASON: a merge must say why it happened';
  end if;

  select * into tgt from erp.batch where tenant_id = v_tenant and id = p_target_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_BATCH: the surviving batch does not exist here';
  end if;
  select * into src from erp.batch where tenant_id = v_tenant and id = p_source_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_BATCH: the batch being merged does not exist here';
  end if;

  perform erp.authorise('inventory.adjust', null, null, null, 'batch', p_target_batch_id);

  if tgt.item_id <> src.item_id then
    raise exception 'ERPWARE_MERGE_DIFFERENT_ITEMS: batches of different items cannot be merged';
  end if;
  if tgt.status <> src.status then
    raise exception 'ERPWARE_MERGE_DIFFERENT_STATUS: both batches must be in the same condition';
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.tenant_id = v_tenant and i.id = tgt.item_id;

  for r in
    select sb.site_id, sb.location_id, sb.stock_status, sum(sb.quantity) as qty, s.entity_id
      from erp.stock_balance sb
      join erp.site s on s.tenant_id = sb.tenant_id and s.id = sb.site_id
     where sb.tenant_id = v_tenant and sb.batch_id = p_source_batch_id and sb.quantity > 0
     group by 1, 2, 3, s.entity_id
  loop
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, quantity, uom_id, reason_code, actor_id)
    values (v_tenant, r.entity_id, r.site_id, 'batch_merge_out', src.item_id, p_source_batch_id,
      r.location_id, r.stock_status, r.qty, v_uom, 'batch_merge', v_actor);

    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      to_location_id, to_status, quantity, uom_id, reason_code, actor_id)
    values (v_tenant, r.entity_id, r.site_id, 'batch_merge_in', tgt.item_id, p_target_batch_id,
      r.location_id, r.stock_status, r.qty, v_uom, 'batch_merge', v_actor);

    v_moved := v_moved + r.qty;
  end loop;

  -- A merged batch may not outlive either parent, so the earliest date wins.
  update erp.batch
     set expires_on = least(expires_on, src.expires_on),
         retest_on = least(retest_on, src.retest_on),
         best_before_on = least(best_before_on, src.best_before_on),
         manufactured_on = least(manufactured_on, src.manufactured_on),
         updated_at = now(), updated_by = v_actor
   where id = p_target_batch_id;

  update erp.batch
     set attributes = coalesce(attributes, '{}'::jsonb)
                    || jsonb_build_object('merged_into', p_target_batch_id,
                                          'merged_at', now(), 'merge_reason', p_reason),
         updated_at = now(), updated_by = v_actor
   where id = p_source_batch_id;

  return jsonb_build_object(
    'target_batch_id', p_target_batch_id, 'source_batch_id', p_source_batch_id,
    'quantity_moved', v_moved,
    'expires_on', (select expires_on from erp.batch where id = p_target_batch_id));
end $$;

create or replace function public.erp_merge_batches(
  p_target_batch_id uuid, p_source_batch_id uuid, p_reason text)
returns jsonb language sql volatile security invoker set search_path to ''
as $$ select erp.merge_batches(p_target_batch_id, p_source_batch_id, p_reason); $$;

-- ============================================================
-- Part B3: supplier purchase price resolution
-- ============================================================

create or replace function public.erp_resolve_purchase_price(
  p_item_id uuid, p_party_id uuid, p_quantity numeric default 1,
  p_site_id uuid default null, p_on date default null)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(
    (select jsonb_build_object(
              'amount_minor', p.amount_minor, 'currency', p.currency,
              'price_kind', p.price_kind, 'price_list_code', p.price_list_code,
              'source', case p.price_kind
                          when 'contract' then 'a contract with this supplier'
                          when 'purchase_list' then 'the supplier purchase list'
                          else 'the last cost paid'
                        end)
       from erp.item_price p
       left join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.id = p.party_role_id
      where p.tenant_id = erp.current_tenant_id()
        and p.item_id = p_item_id
        and p.price_kind in ('contract'::erp.price_kind, 'purchase_list'::erp.price_kind,
                             'last_cost'::erp.price_kind)
        and (p.party_role_id is null or pr.party_id = p_party_id)
        and (p.site_id is null or p_site_id is null or p.site_id = p_site_id)
        and coalesce(p.min_quantity, 0) <= coalesce(p_quantity, 1)
        and p.valid_from <= coalesce(p_on, current_date)
        and (p.valid_to is null or p.valid_to > coalesce(p_on, current_date))
      order by case p.price_kind when 'contract' then 0 when 'purchase_list' then 1 else 2 end,
               (p.party_role_id is not null) desc,
               (p.site_id is not null) desc,
               coalesce(p.min_quantity, 0) desc
      limit 1),
    jsonb_build_object('amount_minor', null, 'source', 'no price is on record for this supplier and item'));
$$;

-- ============================================================
-- Part B4: slow-moving stock provision
-- ============================================================

create or replace function public.erp_stock_provision()
returns jsonb language sql stable security invoker set search_path to '' as $$
  -- One published policy, applied the same way every time: nothing is provided
  -- against in the first quarter of life, a quarter after six months, half
  -- after a year, and the whole value beyond that.
  select coalesce(jsonb_agg(x order by (x->>'provision_minor')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'item_id', l.item_id, 'item_code', i.code, 'item_name', i.name,
             'bucket', b.bucket, 'quantity', sum(l.remaining),
             'value_minor', round(sum(l.remaining * l.unit_cost_minor))::bigint,
             'provision_pct', b.pct,
             'provision_minor', round(sum(l.remaining * l.unit_cost_minor) * b.pct / 100.0)::bigint) as x
      from erp.stock_valuation_layer l
      join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
      cross join lateral (
        select case
                 when l.received_at > now() - interval '90 days'  then '0-90'
                 when l.received_at > now() - interval '180 days' then '91-180'
                 when l.received_at > now() - interval '365 days' then '181-365'
                 else '365+' end as bucket,
               case
                 when l.received_at > now() - interval '90 days'  then 0
                 when l.received_at > now() - interval '180 days' then 25
                 when l.received_at > now() - interval '365 days' then 50
                 else 100 end as pct) b
     where l.tenant_id = erp.current_tenant_id()
       and l.remaining > 0
     group by l.item_id, i.code, i.name, b.bucket, b.pct) t;
$$;

-- ============================================================
-- Part B5: sales release sequencing
-- ============================================================

create or replace function public.erp_release_sequence(p_site_id uuid default null, p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(x order by (x->>'rank')::int), '[]'::jsonb) from (
    select jsonb_build_object(
             'rank', row_number() over (
               order by dl.required_date nulls last,
                        case when coalesce(t.credit_status, 'ok') = 'ok' then 0 else 1 end,
                        (dl.quantity * dl.unit_price_minor) desc),
             'line_id', dl.id, 'document_number', d.document_number,
             'customer', p.name, 'item', i.code, 'item_name', i.name,
             'quantity', dl.quantity, 'quantity_fulfilled', dl.quantity_fulfilled,
             'required_date', dl.required_date,
             'credit_status', coalesce(t.credit_status, 'ok'),
             'available', coalesce(av.available, 0),
             'can_ship_in_full', coalesce(av.available, 0) >= (dl.quantity - coalesce(dl.quantity_fulfilled, 0))) as x
      from erp.document_line dl
      join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
      left join erp.party_role_terms t on t.tenant_id = d.tenant_id and t.party_role_id = d.party_role_id
      left join lateral (
        select sum(a.available) as available
          from erp.stock_availability a
         where a.tenant_id = dl.tenant_id and a.item_id = dl.item_id
           and (d.site_id is null or a.site_id = d.site_id)) av on true
     where dl.tenant_id = erp.current_tenant_id()
       and dt.code = 'sales_order'
       and coalesce(dl.is_cancelled, false) = false
       and coalesce(d.is_cancelled, false) = false
       and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
       and (p_site_id is null or d.site_id = p_site_id)
     limit greatest(p_limit, 1)) q;
$$;

-- ============================================================
-- Part C: guarded demo operational history
-- ============================================================

create or replace function erp.seed_demo_operations()
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_site uuid;
  v_entity uuid;
  v_notes jsonb := '[]'::jsonb;
  v_supplier uuid;
  v_customer uuid;
  v_rm uuid;
  v_fg uuid;
  v_po uuid;
  v_receipt uuid;
  v_so uuid;
  v_line uuid;
  v_wo uuid;
  v_recv uuid;
  v_bulk uuid;
  v_pick uuid;
  v_n integer;
begin
  perform erp.authorise('master_data.write', null, null, null, 'tenant', v_tenant);

  select s.id, s.entity_id into v_site, v_entity
    from erp.site s where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
   order by s.code limit 1;
  if v_site is null then
    return jsonb_build_object('ok', false, 'notes',
      jsonb_build_array('There is no active site yet, so no operational history could be built.'));
  end if;

  -- Locations. A warehouse without places to put things cannot be operated.
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, created_by, updated_by)
  select v_tenant, v_site, x.code, x.name, x.lt::erp.location_type, x.pickable, v_actor, v_actor
    from (values ('RECV', 'Goods in', 'receiving', false),
                 ('BULK', 'Bulk store', 'bulk', false),
                 ('PICK', 'Pick face', 'pick', true),
                 ('QC', 'Quarantine', 'quarantine', false),
                 ('DESP', 'Despatch bay', 'despatch', false)) as x(code, name, lt, pickable)
   where not exists (select 1 from erp.location l
                      where l.tenant_id = v_tenant and l.site_id = v_site and l.code = x.code);

  select id into v_recv from erp.location where tenant_id = v_tenant and site_id = v_site and code = 'RECV';
  select id into v_bulk from erp.location where tenant_id = v_tenant and site_id = v_site and code = 'BULK';
  select id into v_pick from erp.location where tenant_id = v_tenant and site_id = v_site and code = 'PICK';

  select p.id into v_supplier from erp.party p
    join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
   where p.tenant_id = v_tenant and r.role_kind = 'supplier' order by p.code limit 1;
  select p.id into v_customer from erp.party p
    join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
   where p.tenant_id = v_tenant and r.role_kind = 'customer' order by p.code limit 1;
  select id into v_rm from erp.item where tenant_id = v_tenant and code like 'RM-%' order by code limit 1;
  select id into v_fg from erp.item where tenant_id = v_tenant and code like 'FG-%' order by code limit 1;

  if v_supplier is null or v_customer is null or v_rm is null or v_fg is null then
    return jsonb_build_object('ok', false, 'notes',
      jsonb_build_array('Seed the demo master data first: suppliers, customers and items are needed.'));
  end if;

  -- Purchase: order, approve, send, receive, post the stock.
  begin
    v_po := erp.create_document('purchase_order', v_entity, v_site, v_supplier, current_date - 21);
    perform erp.add_document_line(v_po, v_rm, 500, 1250, 'Demo raw material order');
    perform erp.transition_document(v_po, 'submit');
    perform erp.transition_document(v_po, 'approve');
    perform erp.transition_document(v_po, 'send');
    v_receipt := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date - 14);
    select dl.id into v_line from erp.document_line dl where dl.document_id = v_po order by dl.line_no limit 1;
    perform erp.receive_against(v_receipt, v_line, 500);
    perform erp.transition_document(v_receipt, 'post');
    perform erp.post_document_stock(v_receipt);
    v_notes := v_notes || to_jsonb('Purchased and received 500 units of raw material.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Purchasing history was skipped: ' || sqlerrm)::text);
  end;

  -- Warehouse: put the receipt away.
  begin
    v_n := erp.raise_putaway_tasks(v_site);
    v_notes := v_notes || to_jsonb((v_n || ' putaway task(s) raised.')::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Putaway was skipped: ' || sqlerrm)::text);
  end;

  -- Production: raise, release, issue, receive output.
  begin
    v_wo := erp.raise_works_order(v_fg, v_site, 50, 'assembly'::erp.works_order_kind, current_date + 7);
    perform erp.release_works_order(v_wo, true);
    perform erp.issue_to_works_order(v_wo, v_rm, 100, null, v_bulk);
    perform erp.receive_works_order_output(v_wo, 40, null, v_bulk);
    v_notes := v_notes || to_jsonb('Ran a works order for 50, received 40 so far.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Production history was skipped: ' || sqlerrm)::text);
  end;

  -- Sales: order, approve, so the pipeline and release sequence have content.
  begin
    v_so := erp.create_document('sales_order', v_entity, v_site, v_customer, current_date - 5);
    perform erp.add_document_line(v_so, v_fg, 20, 9900, 'Demo customer order', current_date + 5);
    perform erp.transition_document(v_so, 'submit');
    perform erp.transition_document(v_so, 'approve');
    v_notes := v_notes || to_jsonb('Confirmed a customer order for 20 units.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Sales history was skipped: ' || sqlerrm)::text);
  end;

  -- Counting: one cycle count so accuracy has something to report.
  begin
    v_n := erp.raise_count_tasks('CYCLE');
    v_notes := v_notes || to_jsonb((v_n || ' count task(s) raised.')::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Counting was skipped: ' || sqlerrm)::text);
  end;

  -- Planning: run the engine so planned orders exist.
  begin
    perform erp.run_planning(v_site, 90);
    v_notes := v_notes || to_jsonb('Planning run completed for the next 90 days.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Planning was skipped: ' || sqlerrm)::text);
  end;

  return jsonb_build_object('ok', true, 'site', v_site, 'notes', v_notes);
end $$;

create or replace function public.erp_seed_demo_operations()
returns jsonb language sql volatile security invoker set search_path to ''
as $$ select erp.seed_demo_operations(); $$;

-- ============================================================
-- Registration, grants and coverage
-- ============================================================

insert into erp_meta.transaction_path_function (schema_name, function_name, rationale)
select 'erp', v.fn, v.why
  from (values
    ('raise_putaway_tasks', 'Reads balances and writes tasks under the tenant guard; authorises first.'),
    ('raise_replenishment_tasks', 'Reads availability and writes tasks under the tenant guard; authorises first.'),
    ('complete_warehouse_task', 'Writes a stock movement, so it travels the deterministic stock path.'),
    ('merge_batches', 'Batch genealogy and stock movements: an inventory adjustment by another name.'),
    ('seed_demo_operations', 'Demonstration data only; authorises as a master data write before doing anything.')
  ) as v(fn, why)
 where not exists (select 1 from erp_meta.transaction_path_function f
                    where f.schema_name = 'erp' and f.function_name = v.fn);

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('erp_locations', 'erp_document_lines', 'erp_inspections',
         'erp_landed_costs', 'erp_payment_proposals', 'erp_forecast_versions',
         'erp_warehouse_tasks', 'erp_raise_putaway_tasks', 'erp_raise_replenishment_tasks',
         'erp_complete_warehouse_task', 'erp_merge_batches', 'erp_resolve_purchase_price',
         'erp_stock_provision', 'erp_release_sequence', 'erp_seed_demo_operations')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end $$;

select erp.apply_audit_coverage();

update erp_ref.part5_capability
   set status = 'built', gap = null,
       artefacts = coalesce(artefacts, array[]::text[]) || array['erp.merge_batches', 'public.erp_merge_batches']
 where status <> 'built' and (requirement ilike '%merge%batch%' or requirement ilike '%batch%merge%');

update erp_ref.part5_capability
   set status = 'built', gap = null,
       artefacts = coalesce(artefacts, array[]::text[])
                 || array['erp.warehouse_task', 'erp.raise_putaway_tasks', 'erp.raise_replenishment_tasks', 'erp.complete_warehouse_task']
 where status <> 'built' and (requirement ilike '%putaway%' or requirement ilike '%replenish%');

update erp_ref.part5_capability
   set status = 'built', gap = null,
       artefacts = coalesce(artefacts, array[]::text[]) || array['public.erp_resolve_purchase_price']
 where status <> 'built' and requirement ilike '%purchase price%';

update erp_ref.part5_capability
   set status = 'built', gap = null,
       artefacts = coalesce(artefacts, array[]::text[]) || array['public.erp_stock_provision']
 where status <> 'built' and requirement ilike '%provision%';

update erp_ref.part5_capability
   set status = 'built', gap = null,
       artefacts = coalesce(artefacts, array[]::text[]) || array['public.erp_release_sequence']
 where status <> 'built' and requirement ilike '%release%sequenc%';
