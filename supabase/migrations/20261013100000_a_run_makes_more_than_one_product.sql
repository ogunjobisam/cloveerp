-- A run makes more than one product.
--
-- Manufacturing depth, part 3 of 4 (theme 3, owner, 13 October 2026). A works
-- order made one product. Pressing seed makes oil and meal; cutting a sheet
-- leaves offcuts; a dairy's cream comes with skimmed milk. The second product
-- had to be taken in by a stock adjustment, at whatever value somebody typed,
-- and the main product carried the whole of the run's cost.
--
-- ── DECISIONS (taken under the owner's standing approval) ───────────────────
--
--   * A co-product takes a fixed share of the run's joint cost, as a
--     percentage on the bill. The main product takes what the co-products
--     leave. A share is how a costing team states its apportionment, whatever
--     basis it chose (weight, sales value), and it is the figure an auditor
--     asks to see.
--   * A by-product is valued at a fixed value a unit, set on the bill, and
--     that value is credited against the joint cost before it is shared.
--   * Both are taken in against the works order, so every receipt relieves
--     its work in progress and the close settles what is left, as before: the
--     variance lines still add up to what the order holds.
--   * An order closes itself only once its co-products and by-products are in,
--     within the production policy's tolerance, as well as its main product.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.bom_output: a bill's co-products and by-products, set with
--      erp_define_bom_outputs and listed by erp_bom_outputs.
--   B. erp.works_order_output: what an order is to make besides its product,
--      written from the bill when it is raised.
--   C. Each output's unit cost from the order's frozen standard:
--      erp.works_order_output_unit_cost. The main product is taken in at its
--      share where it was taken in at the whole.
--   D. erp_receive_works_order_by_output: a co-product or by-product taken in
--      against its order; erp_works_order_outputs lists what is to come in.
--   E. The roll-up gives the main product its share, and the product
--      structure screen shows what else the run makes.
--   F. erp_test.co_product_suite proves A to E.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A bill's co-products and by-products
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.bom_output (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  bom_id           uuid not null,
  seq              integer not null,
  item_id          uuid not null,
  kind             text not null,
  quantity         numeric(20,6) not null,
  cost_share_pct   numeric(7,4),
  unit_value_minor bigint,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint bom_output_tenant_id_id_key unique (tenant_id, id),
  constraint bom_output_once unique (tenant_id, bom_id, item_id),
  constraint bom_output_bom_fk foreign key (tenant_id, bom_id) references erp.bom(tenant_id, id) on delete cascade,
  constraint bom_output_item_fk foreign key (tenant_id, item_id) references erp.item(tenant_id, id) on delete restrict,
  constraint bom_output_kind_known check (kind in ('co_product', 'by_product')),
  constraint bom_output_quantity check (quantity > 0),
  constraint bom_output_valued check (
    (kind = 'co_product' and cost_share_pct > 0 and cost_share_pct < 100 and unit_value_minor is null)
    or (kind = 'by_product' and cost_share_pct is null and unit_value_minor >= 0))
);

comment on table erp.bom_output is
  'What a bill''s run makes besides its product (20261013100000): co-products, each with its share of the run''s '
  'joint cost, and by-products, each at a value a unit credited against it. Quantities are for one run of the bill.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'bom_output', 'tenant_scoped', 'A bill''s co-products and by-products, with their share of cost or value a unit.')
on conflict (schema_name, table_name) do nothing;

create or replace function erp.define_bom_outputs(p_bom_id uuid, p_co_products jsonb default '[]'::jsonb,
                                                  p_by_products jsonb default '[]'::jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.bom%rowtype;
  r        record;
  v_item   uuid;
  v_qty    numeric;
  v_share  numeric;
  v_value  bigint;
  v_seen   uuid[] := '{}';
  v_total  numeric := 0;
  v_seq    integer := 0;
begin
  select * into b from erp.bom where tenant_id = v_tenant and id = p_bom_id;
  if b.id is null or b.status <> 'active' then
    raise exception 'CLOVEERP_BOM_NOT_IN_FORCE: % is no bill of materials in force here', coalesce(b.code, p_bom_id::text)
      using errcode = '23514', hint = 'Choose the bill in force for the product.';
  end if;
  perform erp.authorise('production.order', null, b.site_id, null, 'bom', p_bom_id, null);

  delete from erp.bom_output o where o.tenant_id = v_tenant and o.bom_id = p_bom_id;

  for r in
    select 'co_product' as kind, x.value as line from jsonb_array_elements(coalesce(p_co_products, '[]'::jsonb)) x
    union all
    select 'by_product', x.value from jsonb_array_elements(coalesce(p_by_products, '[]'::jsonb)) x
  loop
    v_item := nullif(btrim(coalesce(r.line ->> 'item_id', '')), '')::uuid;
    v_qty := nullif(btrim(coalesce(r.line ->> 'quantity', '')), '')::numeric;
    v_share := nullif(btrim(coalesce(r.line ->> 'cost_share_pct', '')), '')::numeric;
    v_value := nullif(btrim(coalesce(r.line ->> 'unit_value_minor', '')), '')::bigint;
    if v_item is null or coalesce(v_qty, 0) <= 0
       or (r.kind = 'co_product' and (v_share is null or v_share <= 0 or v_share >= 100))
       or (r.kind = 'by_product' and (v_value is null or v_value < 0)) then
      raise exception 'CLOVEERP_BOM_OUTPUT_LINE: every co-product needs a product, a quantity and a share of cost between nought and a hundred; every by-product a product, a quantity and a value a unit'
        using errcode = '23514', hint = 'Complete or remove the line.';
    end if;
    if v_item = b.item_id then
      raise exception 'CLOVEERP_BOM_OUTPUT_IS_THE_PRODUCT: the bill''s own product is what it makes already, not a co-product of itself'
        using errcode = '23514', hint = 'Name a different product.';
    end if;
    if v_item = any(v_seen) then
      raise exception 'CLOVEERP_BOM_OUTPUT_LINE: the same product is listed twice; add the quantities together'
        using errcode = '23514', hint = 'Keep one line for it.';
    end if;
    if not exists (select 1 from erp.item i where i.tenant_id = v_tenant and i.id = v_item and i.status = 'active') then
      raise exception 'CLOVEERP_UNKNOWN_ITEM: % is not a product here', v_item
        using errcode = '23503', hint = 'Choose a product from the list.';
    end if;
    v_seen := v_seen || v_item;
    v_total := v_total + coalesce(v_share, 0);
    v_seq := v_seq + 10;
    insert into erp.bom_output (tenant_id, bom_id, seq, item_id, kind, quantity, cost_share_pct, unit_value_minor)
    values (v_tenant, p_bom_id, v_seq, v_item, r.kind, v_qty,
            case when r.kind = 'co_product' then v_share end,
            case when r.kind = 'by_product' then v_value end);
  end loop;

  if v_total >= 100 then
    raise exception 'CLOVEERP_BOM_OUTPUT_SHARES: the co-products take % per cent of the cost, which leaves the product itself nothing', v_total
      using errcode = '23514', hint = 'Give the co-products less than a hundred per cent between them.';
  end if;

  return v_seq / 10;
end;
$$;
revoke all on function erp.define_bom_outputs(uuid, jsonb, jsonb) from public, anon;

create or replace function public.erp_define_bom_outputs(p_bom_id uuid, p_co_products jsonb default '[]'::jsonb,
                                                         p_by_products jsonb default '[]'::jsonb)
returns integer
language sql
set search_path = ''
as $$ select erp.define_bom_outputs(p_bom_id, p_co_products, p_by_products) $$;
revoke all on function public.erp_define_bom_outputs(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.erp_define_bom_outputs(uuid, jsonb, jsonb) to authenticated, service_role;
comment on function public.erp_define_bom_outputs(uuid, jsonb, jsonb) is
  'Sets what a bill''s run makes besides its product, replacing what it said (20261013100000). '
  'Co-products [{item_id, quantity, cost_share_pct}], by-products [{item_id, quantity, unit_value_minor}]. '
  'Authorises production.order.';

create or replace function public.erp_bom_outputs()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'bom_output_id', o.id, 'bom_id', b.id, 'bom', b.code, 'product', pi.code,
           'output', i.code, 'output_name', i.name,
           'kind', case o.kind when 'co_product' then 'co-product' else 'by-product' end,
           'quantity', o.quantity, 'per_run_of', b.output_quantity,
           'cost_share_pct', o.cost_share_pct, 'unit_value_minor', o.unit_value_minor)
           order by b.code, o.seq), '[]'::jsonb)
    from erp.bom_output o
    join erp.bom b on b.tenant_id = o.tenant_id and b.id = o.bom_id and b.status = 'active'
    join erp.item pi on pi.tenant_id = b.tenant_id and pi.id = b.item_id
    join erp.item i on i.tenant_id = o.tenant_id and i.id = o.item_id
   where o.tenant_id = erp.require_tenant_id()
$$;
revoke all on function public.erp_bom_outputs() from public, anon;
grant execute on function public.erp_bom_outputs() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What an order makes besides its product
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.works_order_output (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  works_order_id    uuid not null,
  seq               integer not null,
  item_id           uuid not null,
  kind              text not null,
  planned_quantity  numeric(20,6) not null,
  quantity_received numeric(20,6) not null default 0,
  cost_share_pct    numeric(7,4),
  unit_value_minor  bigint,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint works_order_output_tenant_id_id_key unique (tenant_id, id),
  constraint works_order_output_once unique (tenant_id, works_order_id, item_id),
  constraint works_order_output_order_fk foreign key (tenant_id, works_order_id)
    references erp.works_order(tenant_id, id) on delete cascade,
  constraint works_order_output_item_fk foreign key (tenant_id, item_id) references erp.item(tenant_id, id) on delete restrict,
  constraint works_order_output_kind_known check (kind in ('co_product', 'by_product')),
  constraint works_order_output_quantities check (planned_quantity > 0 and quantity_received >= 0)
);

comment on table erp.works_order_output is
  'What a works order makes besides its product (20261013100000), written from its bill when it is raised: '
  'the quantity for the order, what has come in, and the share of cost or value a unit it is taken in at.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'works_order_output', 'tenant_scoped', 'A works order''s co-products and by-products, as its bill said when it was raised.')
on conflict (schema_name, table_name) do nothing;

do $raise$
declare
  v_sig  constant text := 'erp.raise_works_order(uuid,uuid,numeric,erp.works_order_kind,date)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_seq = 0 then
    raise exception
      'CLOVEERP_EMPTY_BILL_OF_MATERIALS: % has a bill with no components',$o$;
  v_new  constant text := $n$  -- What the run makes besides the product, for this order's quantity
  -- (20261013100000), at the bill's share or value as it stands now.
  insert into erp.works_order_output (tenant_id, works_order_id, seq, item_id, kind, planned_quantity,
                                      cost_share_pct, unit_value_minor)
  select v_tenant, v_wo, o.seq, o.item_id, o.kind,
         round(p_quantity * o.quantity / coalesce(nullif(v_bom.output_quantity, 0), 1), 6),
         o.cost_share_pct, o.unit_value_minor
    from erp.bom_output o
   where o.tenant_id = v_tenant and o.bom_id = v_bom.id;

  if v_seq = 0 then
    raise exception
      'CLOVEERP_EMPTY_BILL_OF_MATERIALS: % has a bill with no components',$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('20261013100000' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % output anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$raise$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Each output's unit cost
-- ─────────────────────────────────────────────────────────────────────────────

-- One unit of p_item_id off the order, from p_total, the order's whole cost
-- (its frozen standard). By-products at their value a unit; the rest of the
-- cost shared, the co-products at their share and the product at what is
-- left. An order with neither is its total over its quantity, as before.
create or replace function erp.works_order_output_unit_cost(p_works_order_id uuid, p_item_id uuid, p_total bigint)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
  o        erp.works_order_output%rowtype;
  v_credit numeric;
  v_shares numeric;
  v_joint  numeric;
begin
  select * into wo from erp.works_order w where w.tenant_id = v_tenant and w.id = p_works_order_id;
  if coalesce(wo.quantity, 0) <= 0 then
    return 0;
  end if;
  select coalesce(sum(x.planned_quantity * x.unit_value_minor) filter (where x.kind = 'by_product'), 0),
         coalesce(sum(x.cost_share_pct) filter (where x.kind = 'co_product'), 0)
    into v_credit, v_shares
    from erp.works_order_output x
   where x.tenant_id = v_tenant and x.works_order_id = p_works_order_id;
  v_joint := greatest(coalesce(p_total, 0) - v_credit, 0);

  if p_item_id = wo.item_id then
    return round(v_joint * (100 - v_shares) / 100.0 / wo.quantity)::bigint;
  end if;
  select * into o from erp.works_order_output x
   where x.tenant_id = v_tenant and x.works_order_id = p_works_order_id and x.item_id = p_item_id;
  if o.id is null then
    return null;
  end if;
  if o.kind = 'by_product' then
    return o.unit_value_minor;
  end if;
  return round(v_joint * o.cost_share_pct / 100.0 / o.planned_quantity)::bigint;
end;
$$;
revoke all on function erp.works_order_output_unit_cost(uuid, uuid, bigint) from public, anon;

-- Whether everything an order makes besides its product is in, within the
-- production policy's short-completion tolerance.
create or replace function erp.works_order_outputs_in(p_works_order_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select not exists (
    select 1
      from erp.works_order_output x
      join erp.works_order w on w.tenant_id = x.tenant_id and w.id = x.works_order_id
     where x.tenant_id = erp.require_tenant_id() and x.works_order_id = p_works_order_id
       and x.quantity_received < x.planned_quantity
             * (1 - coalesce((erp.production_policy(w.entity_id, w.site_id) ->> 'short_completion_pct')::numeric, 0) / 100.0))
$$;
revoke all on function erp.works_order_outputs_in(uuid) from public, anon;

do $receive$
declare
  v_sig   constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def   text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$                 then round(coalesce(wo.standard_cost_minor, v_issued + v_labour) / wo.quantity)::bigint$o$,
    $n$                 -- Its share, where the order makes more than one product (20261013100000).
                 then erp.works_order_output_unit_cost(wo.id, wo.item_id, coalesce(wo.standard_cost_minor, v_issued + v_labour))$n$,
    $o$  if v_done and coalesce((v_policy ->> 'close_on_completion')::boolean, true)$o$,
    $n$  -- Not before its co-products and by-products are in (20261013100000).
  if v_done and coalesce((v_policy ->> 'close_on_completion')::boolean, true)
     and erp.works_order_outputs_in(p_works_order_id)$n$];
  v_hits  integer;
begin
  if position('20261013100000' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$receive$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A co-product or by-product taken in
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.receive_works_order_by_output(p_works_order_output_id uuid, p_quantity numeric,
                                                             p_batch_number text default null,
                                                             p_location_id uuid default null)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  o        erp.works_order_output%rowtype;
  wo       erp.works_order%rowtype;
  it       erp.item%rowtype;
  v_policy jsonb;
  v_batch  uuid;
  v_cost   bigint;
  v_ccy    char(3);
  v_moved  bigint;
  v_prev   text;
begin
  select * into o from erp.works_order_output x
   where x.tenant_id = v_tenant and x.id = p_works_order_output_id for update;
  if o.id is null then
    raise exception 'CLOVEERP_NOT_AN_ORDER_OUTPUT: % is no co-product or by-product of a works order here', p_works_order_output_id
      using errcode = '23503', hint = 'Choose what is to come in from the list.';
  end if;
  select * into wo from erp.works_order w where w.tenant_id = v_tenant and w.id = o.works_order_id for update;
  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null, 'works_order', wo.id, null);

  if wo.status not in ('released', 'in_progress', 'completed') then
    raise exception 'CLOVEERP_WORKS_ORDER_NOT_RUNNING: % is %', wo.order_number, wo.status
      using errcode = '23514', hint = 'Take it in against an order that is still running.';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'CLOVEERP_OUTPUT_NOT_POSITIVE: % is not a receipt against %',
      coalesce(p_quantity::text, 'nothing'), wo.order_number
      using errcode = '22023', hint = 'Give the quantity that came off the line.';
  end if;
  v_policy := erp.production_policy(wo.entity_id, wo.site_id);
  if o.quantity_received + p_quantity
     > o.planned_quantity * (1 + coalesce((v_policy ->> 'over_completion_pct')::numeric, 0) / 100.0) then
    raise exception 'CLOVEERP_OVER_COMPLETION: % would take % to % of %, and the production policy allows % per cent over',
      wo.order_number, o.quantity_received, o.quantity_received + p_quantity, o.planned_quantity,
      coalesce(v_policy ->> 'over_completion_pct', '0')
      using errcode = '23514',
            hint = 'Take in what the order is for, or propose the production policy with more room on the Manufacturing screen.';
  end if;

  select * into it from erp.item i where i.tenant_id = v_tenant and i.id = o.item_id;
  select e.base_currency into v_ccy from erp.entity e where e.tenant_id = v_tenant and e.id = wo.entity_id;

  if it.is_batch_controlled then
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (v_tenant, o.item_id,
            coalesce(p_batch_number, wo.order_number || '-' || it.code || '-' || to_char(clock_timestamp(), 'HH24MISS')),
            case when it.quarantine_on_receipt then 'quarantine'::erp.batch_status else 'released'::erp.batch_status end,
            current_date,
            case when it.shelf_life_days is not null then current_date + it.shelf_life_days end)
    returning id into v_batch;
  end if;

  v_cost := erp.receive_cost(o.item_id, wo.site_id, p_quantity,
                             erp.works_order_output_unit_cost(wo.id, o.item_id, wo.standard_cost_minor),
                             coalesce(v_ccy, 'GBP'), v_batch, null);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code, works_order_id)
  values (v_tenant, wo.entity_id, wo.site_id, 'production_output', o.item_id, v_batch,
          coalesce(p_location_id, erp.default_posting_location(wo.site_id, 'in')),
          case when it.quarantine_on_receipt then 'quarantine'::erp.stock_status else 'available'::erp.stock_status end,
          p_quantity, it.stock_uom_id, v_cost, coalesce(v_ccy, 'GBP'), wo.order_number, wo.id)
  returning id into v_moved;

  -- Out of the order's work in progress into stock, as its product is.
  perform erp.post_works_order_finance(wo.id, 'works_order_output', null, v_moved);

  update erp.works_order_output x
     set quantity_received = x.quantity_received + p_quantity, updated_at = now()
   where x.id = o.id;

  if wo.status = 'released' then
    perform erp.move_works_order(wo.id, 'start', 'in_progress');
  end if;

  insert into erp.production_event (tenant_id, works_order_id, event_kind, item_id, batch_id, quantity, detail, actor_id)
  values (v_tenant, wo.id, 'output_received', o.item_id, v_batch, p_quantity,
          jsonb_build_object('unit_cost_minor', v_cost, 'output_kind', o.kind),
          erp.current_principal_id());

  if v_batch is not null then
    insert into erp.batch_genealogy (tenant_id, parent_batch_id, child_batch_id, quantity, occurred_at)
    select distinct v_tenant, pe.batch_id, v_batch, pe.quantity, clock_timestamp()
      from erp.production_event pe
     where pe.tenant_id = v_tenant and pe.works_order_id = wo.id
       and pe.event_kind = 'issued' and pe.batch_id is not null
    on conflict do nothing;
  end if;

  -- The last of the run in: the order closes itself as it does when its
  -- product is the last thing in (20261001700000).
  if wo.status = 'completed' and erp.works_order_outputs_in(wo.id)
     and coalesce((v_policy ->> 'close_on_completion')::boolean, true) then
    v_prev := coalesce(current_setting('erp.deriving_move', true), '');
    perform set_config('erp.deriving_move', wo.id::text || ':close', true);
    begin
      perform erp.close_works_order(wo.id);
    exception when others then
      if sqlerrm not like 'CLOVEERP_WORKS_ORDER_WIP_DISAGREES:%' then
        perform set_config('erp.deriving_move', v_prev, true);
        raise;
      end if;
    end;
    perform set_config('erp.deriving_move', v_prev, true);
  end if;

  return v_moved;
end;
$$;
revoke all on function erp.receive_works_order_by_output(uuid, numeric, text, uuid) from public, anon;

create or replace function public.erp_receive_works_order_by_output(p_works_order_output_id uuid, p_quantity numeric,
                                                                    p_batch_number text default null,
                                                                    p_location_id uuid default null)
returns bigint
language sql
set search_path = ''
as $$ select erp.receive_works_order_by_output(p_works_order_output_id, p_quantity, p_batch_number, p_location_id) $$;
revoke all on function public.erp_receive_works_order_by_output(uuid, numeric, text, uuid) from public, anon;
grant execute on function public.erp_receive_works_order_by_output(uuid, numeric, text, uuid) to authenticated, service_role;
comment on function public.erp_receive_works_order_by_output(uuid, numeric, text, uuid) is
  'Takes in a co-product or by-product against its works order, at its share of the order''s standard or its value a unit '
  '(20261013100000). Authorises production.execute.';

create or replace function public.erp_works_order_outputs()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'works_order_output_id', x.id, 'works_order_id', w.id, 'order_number', w.order_number,
           'status', w.status, 'output', i.code, 'output_name', i.name,
           'kind', case x.kind when 'co_product' then 'co-product' else 'by-product' end,
           'planned_quantity', x.planned_quantity, 'quantity_received', x.quantity_received,
           'outstanding', greatest(x.planned_quantity - x.quantity_received, 0))
           order by w.order_number, x.seq), '[]'::jsonb)
    from erp.works_order_output x
    join erp.works_order w on w.tenant_id = x.tenant_id and w.id = x.works_order_id
    join erp.item i on i.tenant_id = x.tenant_id and i.id = x.item_id
   where x.tenant_id = erp.require_tenant_id()
     and w.status in ('released', 'in_progress', 'completed')
$$;
revoke all on function public.erp_works_order_outputs() from public, anon;
grant execute on function public.erp_works_order_outputs() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The roll-up gives the product its share; the structure shows the rest
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.made_cost(p_item_id uuid, p_site_id uuid, p_depth integer default 0)
returns table(materials_minor numeric, labour_minor numeric, made boolean)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_bom    erp.bom%rowtype;
  v_rout   erp.routing%rowtype;
  v_mat    numeric := 0;
  v_lab    numeric := 0;
  v_credit numeric := 0;
  v_shares numeric := 0;
  v_factor numeric := 1;
  r        record;
  c        record;
  v_run    numeric;
begin
  if p_depth > 10 then
    raise exception 'CLOVEERP_BILL_TOO_DEEP: more than ten levels, which is a cycle rather than a product'
      using errcode = '23514', hint = 'Look for a component that is, a level or more down, made of the product itself.';
  end if;

  select * into v_bom from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.status = 'active'
     and (b.site_id is null or b.site_id = p_site_id)
   order by (b.site_id is not null) desc, b.version desc limit 1;
  if v_bom.id is null then
    return query select coalesce(erp.unit_cost_at(p_item_id, p_site_id), 0)::numeric, 0::numeric, false;
    return;
  end if;

  v_run := coalesce(nullif(v_bom.output_quantity, 0), 1);
  for r in
    select bl.component_item_id, bl.quantity, bl.scrap_factor
      from erp.bom_line bl
     where bl.tenant_id = v_tenant and bl.bom_id = v_bom.id and not bl.is_alternate
  loop
    select * into c from erp.made_cost(r.component_item_id, p_site_id, p_depth + 1);
    v_mat := v_mat + (c.materials_minor + c.labour_minor) * r.quantity * (1 + coalesce(r.scrap_factor, 0));
  end loop;

  select * into v_rout from erp.routing rt
   where rt.tenant_id = v_tenant and rt.item_id = p_item_id and rt.status = 'active'
     and (rt.site_id is null or rt.site_id = p_site_id)
   order by (rt.site_id is not null) desc, rt.version desc limit 1;
  if v_rout.id is not null then
    select coalesce(sum((coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0) * v_run)
                        / 60.0 * coalesce(ro.cost_rate_minor_per_hour, 0)), 0)
      into v_lab
      from erp.routing_operation ro
     where ro.tenant_id = v_tenant and ro.routing_id = v_rout.id;
  end if;

  -- What the run makes besides the product (20261013100000): its by-products
  -- credited at their value, and what is left shared with its co-products.
  -- Materials and labour keep their proportions.
  select coalesce(sum(o.quantity * o.unit_value_minor) filter (where o.kind = 'by_product'), 0),
         coalesce(sum(o.cost_share_pct) filter (where o.kind = 'co_product'), 0)
    into v_credit, v_shares
    from erp.bom_output o
   where o.tenant_id = v_tenant and o.bom_id = v_bom.id;
  if v_mat + v_lab > 0 then
    v_factor := greatest(v_mat + v_lab - v_credit, 0) / (v_mat + v_lab) * (100 - v_shares) / 100.0;
  end if;

  return query select v_mat * v_factor / v_run / coalesce(nullif(v_bom.yield_factor, 0), 1),
                      v_lab * v_factor / v_run / coalesce(nullif(v_bom.yield_factor, 0), 1),
                      true;
end;
$$;
revoke all on function erp.made_cost(uuid, uuid, integer) from public, anon;

do $structure$
declare
  v_sig  constant text := 'public.erp_product_structure(uuid,uuid,numeric)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    'made', m.made,$o$;
  v_new  constant text := $n$    -- What the run makes besides the product (20261013100000), for the quantity.
    'outputs', coalesce((select jsonb_agg(jsonb_build_object(
                                   'item_id', i.id, 'code', i.code, 'name', i.name,
                                   'kind', case o.kind when 'co_product' then 'co-product' else 'by-product' end,
                                   'quantity', round(o.quantity / coalesce(nullif(v_bom.output_quantity, 0), 1) * v_qty, 6),
                                   'cost_share_pct', o.cost_share_pct, 'unit_value_minor', o.unit_value_minor)
                                   order by o.seq)
                           from erp.bom_output o
                           join erp.item i on i.tenant_id = o.tenant_id and i.id = o.item_id
                          where o.tenant_id = v_tenant and o.bom_id = v_bom.id), '[]'::jsonb),
    'made', m.made,$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('20261013100000' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % outputs anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$structure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_define_bom_outputs', 'erp.define_bom_outputs',
   'Sets a bill''s co-products and by-products, with their share of cost or value a unit; authorises production.order.'),
  ('erp_receive_works_order_by_output', 'erp.receive_works_order_by_output',
   'Takes in a co-product or by-product against its works order; authorises production.execute.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_BOM_OUTPUT_SHARES',
  'Giving a bill''s co-products a hundred per cent or more of its cost between them.',
  'The product itself would carry nothing, and its stock would be valued at nothing.',
  'Give the co-products less than a hundred per cent between them.');
select erp.register_refusal('CLOVEERP_BOM_OUTPUT_IS_THE_PRODUCT',
  'Naming a bill''s own product as one of its co-products or by-products.',
  'The bill makes its product already; counting it twice would value it twice.',
  'Name a different product.');
select erp.register_refusal('CLOVEERP_NOT_AN_ORDER_OUTPUT',
  'Taking in a co-product or by-product that no works order here is to make.',
  'Only what an order''s bill said it makes can be taken in against it, at the cost it carries.',
  'Choose what is to come in from the list.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Co-products and by-products (20261013100000).'
  from (values
    ('Also makes'),
    ('By-products'),
    ('Co-products'),
    ('Co-products and by-products'),
    ('Co-products and by-products to come in'),
    ('Each co-product takes this share of the run''s cost; the product itself carries what they leave.'),
    ('Each by-product is valued at this a unit, taken off the run''s cost before it is shared.'),
    ('Receive a co-product or by-product'),
    ('Set co-products and by-products'),
    ('Share of cost (%)'),
    ('Value each'),
    ('What else a bill''s run makes: co-products sharing its cost, and by-products credited at a value. Setting them again replaces what the bill said; works orders raised from now on carry them.'),
    ('Takes in what a works order makes besides its product, at its share of the order''s standard or its value a unit.'),
    ('No co-products or by-products yet. Set them on a bill from Actions.'),
    ('No co-products or by-products are waiting. They appear once an order is raised from a bill that names them.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.co_product_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_site   uuid;
  v_uom    uuid;
  v_sup    uuid;
  v_oil    uuid;
  v_meal   uuid;
  v_husk   uuid;
  v_seed   uuid;
  v_bom    uuid;
  v_grn    uuid;
  v_wo     uuid;
  v_meal_o uuid;
  v_husk_o uuid;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzcop' || v_tag, 'Co-product Suite',
      'admin@demo-zzcop' || v_tag || '.test', 'Co-product Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzcop' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    perform erp.configure_production('backflush');
    v_tenant := rb.tenant_id;

    v_step := 'seed pressed into oil, with meal and husk';
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    select p.id into v_sup from erp.party p where p.tenant_id = v_tenant and p.status = 'active' order by p.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZCPOIL' || v_tag, 'Pressed oil', v_uom, 'active') returning id into v_oil;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZCPMEAL' || v_tag, 'Seed meal', v_uom, 'active') returning id into v_meal;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZCPHUSK' || v_tag, 'Husk', v_uom, 'active') returning id into v_husk;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZCPSEED' || v_tag, 'Seed', v_uom, 'active') returning id into v_seed;
    -- A hundred seed at £1 each.
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_seed, 100, 100, 'seed');
    perform erp.transition_document(v_grn, 'post');
    -- A run of ten oil takes a hundred seed; pressing is an hour to set up
    -- and three minutes an oil, at £20 an hour. Its standard: £100 of seed
    -- and £30 of pressing.
    v_bom := public.erp_create_bom(v_oil, null, null, 10, null,
      jsonb_build_array(jsonb_build_object('component_item_id', v_seed, 'quantity', 100)));
    perform public.erp_define_work_centre(v_site, 'PRESS-1', 'Press', 8, 5, 100, 2000);
    perform public.erp_define_routing(v_oil, v_site, null,
      '[{"name":"Press","work_centre_code":"PRESS-1","setup_minutes":60,"run_minutes_per_unit":3}]'::jsonb);

    -- ── 1. A bill's outputs ─────────────────────────────────────────────────
    v_step := 'the outputs';
    begin
      perform public.erp_define_bom_outputs(v_bom,
        jsonb_build_array(jsonb_build_object('item_id', v_meal, 'quantity', 20, 'cost_share_pct', 60),
                          jsonb_build_object('item_id', v_husk, 'quantity', 5, 'cost_share_pct', 50)));
      v_ok := false; v_msg := 'two co-products took more than the whole cost';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BOM_OUTPUT_SHARES%'; v_msg := left(sqlerrm, 80);
    end;
    begin
      perform public.erp_define_bom_outputs(v_bom, '[]'::jsonb,
        jsonb_build_array(jsonb_build_object('item_id', v_oil, 'quantity', 1, 'unit_value_minor', 0)));
      v_ok := false; v_msg := v_msg || ' | the product its own by-product';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BOM_OUTPUT_IS_THE_PRODUCT%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    -- Meal takes a quarter of the cost; husk is worth £2 each.
    perform public.erp_define_bom_outputs(v_bom,
      jsonb_build_array(jsonb_build_object('item_id', v_meal, 'quantity', 20, 'cost_share_pct', 25)),
      jsonb_build_array(jsonb_build_object('item_id', v_husk, 'quantity', 5, 'unit_value_minor', 200)));
    v_cases := v_cases + 1;
    case_name := 'a bill names its co-products with a share of cost and its by-products with a value, and is refused the impossible';
    passed := v_state is null and v_ok
          and (select count(*) from erp.bom_output o where o.bom_id = v_bom) = 2
          and jsonb_array_length(public.erp_bom_outputs()) = 2;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. The roll-up gives the oil its share ──────────────────────────────
    -- £130 a run, less £10 of husk, is £120 shared; the oil's three quarters
    -- is £90 over ten: £9 an oil.
    x := public.erp_product_structure(v_oil, v_site, 10);
    v_cases := v_cases + 1;
    case_name := 'the oil rolls up to its share of the run, after the husk''s value, and its structure says what else the run makes';
    passed := v_state is null
          and (x ->> 'rolled_up_minor')::numeric = 900
          and jsonb_array_length(x -> 'outputs') = 2
          and exists (select 1 from jsonb_array_elements(x -> 'outputs') l
                       where l ->> 'code' = 'ZCPMEAL' || v_tag and (l ->> 'quantity')::numeric = 20);
    detail := coalesce(v_state, format('rolled up %s; %s', x ->> 'rolled_up_minor', left((x -> 'outputs')::text, 160)));
    return next;

    -- ── 3. An order carries them ────────────────────────────────────────────
    v_step := 'a works order for ten oil';
    v_wo := public.erp_raise_works_order(v_oil, v_site, 10);
    if (select w.status from erp.works_order w where w.id = v_wo) = 'draft' then
      perform public.erp_release_works_order(v_wo);
    end if;
    select x.id into v_meal_o from erp.works_order_output x where x.works_order_id = v_wo and x.item_id = v_meal;
    select x.id into v_husk_o from erp.works_order_output x where x.works_order_id = v_wo and x.item_id = v_husk;
    v_cases := v_cases + 1;
    case_name := 'a works order raised from the bill is to make its meal and husk, for its quantity';
    passed := v_state is null
          and (select x.planned_quantity from erp.works_order_output x where x.id = v_meal_o) = 20
          and (select x.planned_quantity from erp.works_order_output x where x.id = v_husk_o) = 5
          and (select w.standard_cost_minor from erp.works_order w where w.id = v_wo) = 13000
          and jsonb_array_length(public.erp_works_order_outputs()) = 2;
    detail := coalesce(v_state, (select format('standard %s', w.standard_cost_minor) from erp.works_order w where w.id = v_wo));
    return next;

    -- ── 4. The oil comes in at its share, and the order waits ───────────────
    v_step := 'the oil taken in';
    perform public.erp_receive_works_order_output(v_wo, 10);
    v_cases := v_cases + 1;
    case_name := 'the oil is taken in at its share, £9, and the order does not close while its meal and husk are to come';
    passed := v_state is null
          and (select m.unit_cost_minor from erp.stock_movement m
                where m.works_order_id = v_wo and m.item_id = v_oil and m.movement_type = 'production_output') = 900
          and (select w.status::text from erp.works_order w where w.id = v_wo) = 'completed';
    detail := coalesce(v_state, (select w.status::text from erp.works_order w where w.id = v_wo));
    return next;

    -- ── 5. Meal and husk come in, and the order closes and settles ──────────
    v_step := 'the meal and husk taken in';
    perform public.erp_receive_works_order_by_output(v_meal_o, 20);
    perform public.erp_receive_works_order_by_output(v_husk_o, 5);
    v_cases := v_cases + 1;
    -- Meal: a quarter of £120 over twenty, £1.50. Husk at £2. The three
    -- relieve the order's £130 between them.
    case_name := 'meal comes in at its share and husk at its value, together relieving the whole standard, and the order closes settled';
    passed := v_state is null
          and (select m.unit_cost_minor from erp.stock_movement m
                where m.works_order_id = v_wo and m.item_id = v_meal and m.movement_type = 'production_output') = 150
          and (select m.unit_cost_minor from erp.stock_movement m
                where m.works_order_id = v_wo and m.item_id = v_husk and m.movement_type = 'production_output') = 200
          and (select sum(m.quantity * m.unit_cost_minor) from erp.stock_movement m
                where m.works_order_id = v_wo and m.movement_type = 'production_output') = 13000
          and (select w.status::text from erp.works_order w where w.id = v_wo) = 'closed'
          and erp.works_order_wip(v_wo) = 0;
    detail := coalesce(v_state, (select format('%s, holding %s', w.status, erp.works_order_wip(v_wo))
                                   from erp.works_order w where w.id = v_wo));
    return next;

    -- ── 6. Not past what was planned, nor after the close ───────────────────
    v_step := 'refused';
    begin
      perform public.erp_receive_works_order_by_output(v_husk_o, 1);
      v_ok := false; v_msg := 'husk taken in on a closed order';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_WORKS_ORDER_NOT_RUNNING%'; v_msg := left(sqlerrm, 80);
    end;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_seed, 100, 100, 'seed');
    perform erp.transition_document(v_grn, 'post');
    v_wo := public.erp_raise_works_order(v_oil, v_site, 10);
    if (select w.status from erp.works_order w where w.id = v_wo) = 'draft' then
      perform public.erp_release_works_order(v_wo);
    end if;
    begin
      perform public.erp_receive_works_order_by_output(
        (select x.id from erp.works_order_output x where x.works_order_id = v_wo and x.item_id = v_husk), 50);
      v_ok := false; v_msg := v_msg || ' | ten times the husk';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_OVER_COMPLETION%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'a by-product is refused past what the order was to make, and on an order already closed';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CO_PRODUCT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.co_product_suite() from public, anon, authenticated;

create or replace function erp_test.assert_co_product_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _co_product on commit drop as
    select * from erp_test.co_product_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _co_product;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CO_PRODUCT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CO_PRODUCT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('co-products and by-products: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_co_product_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
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
select erp.assert_write_only_columns();
