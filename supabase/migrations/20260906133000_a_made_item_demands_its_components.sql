-- =============================================================================
-- 20260906133000  A made item demands its components
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.4, material requirements planning. The register said
-- 5.4.mrp was partial for one reason: a planned order for a made item did not
-- raise dependent demand for its components. The planning run projected every
-- stocked item on its own, so a forecast for a finished good produced a
-- purchase suggestion for the finished good and nothing for the parts it is
-- made of — the works order found that out later, when erp.raise_works_order()
-- exploded the bill and the components were not there.
--
-- What changes:
--
--   * erp.bom_low_level_codes(site) — the depth at which each item sits in
--     the bills in force at a site (a component used at two levels takes the
--     deeper one). The run plans items in that order, so every parent's
--     dependent demand exists before its component is projected.
--   * erp.dependent_demand — what a production planned order asks of its
--     components, dated at the order's release, one row per component per
--     order, kept with the run so a question about why a purchase exists
--     reaches the order that caused it.
--   * erp.scheduled_demand() gains a sixth argument, the planning run, and a
--     third arm: the dependent demand that run has raised. The five-argument
--     form stays as a wrapper for the workbench and for anything else that
--     reads the position without a run.
--   * erp.run_planning() re-emitted: an item with a bill in force at the site
--     is planned as a production order, not a purchase; a production order
--     explodes one level (through phantoms, scaled by the bill's output
--     quantity, yield and scrap, exactly as the works order will) into
--     dependent demand; a component's order is pegged to the parent order
--     (demand_kind planned_order); a component the bill demands that nothing
--     plans at the site is a no_supply_source exception, not a silence.
--   * erp.firm_planned_order() re-emitted: a production order firms into a
--     works order (planned_order.converted_works_order_id) through
--     erp.raise_works_order(), whose explosion then agrees with the plan's;
--     a purchase order firms as before. It now authorises planning.firm.
--   * Doors: erp_planned_order_pegging (why an order exists, in both
--     directions), erp_dependent_demand (a run's component demand),
--     erp_firm_planned_order (the conversion, which had no door), and
--     erp_planned_orders re-emitted to say what an order became.
--
-- Proof: erp_test.mrp_explosion_suite() (12 cases, wrapper pinned) on a
-- three-level bill with stock on hand at the middle level, scrap on the bought
-- component and a packaging item nobody plans; the planning suite and the
-- production suite still pass; the register reads 5.4.mrp built.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Low-level codes
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.bom_low_level_codes(p_site_id uuid)
returns table(item_id uuid, low_level_code integer)
language sql
stable
set search_path = ''
as $$
  with recursive bills as (
    -- The bill in force for each made item at this site: a site-specific
    -- bill beats a general one, a later version beats an earlier one. The
    -- same choice erp.raise_works_order() makes, so the plan and the works
    -- order explode the same bill.
    select distinct on (b.item_id) b.id, b.item_id
      from erp.bom b
     where b.tenant_id = erp.current_tenant_id()
       and b.status = 'active'
       and (b.site_id is null or b.site_id = p_site_id)
       and b.effective_from <= current_date
       and (b.effective_to is null or b.effective_to > current_date)
     order by b.item_id, (b.site_id is not null) desc, b.version desc
  ),
  edges as (
    select bi.item_id as parent_item_id, bl.component_item_id
      from bills bi
      join erp.bom_line bl on bl.tenant_id = erp.current_tenant_id()
                          and bl.bom_id = bi.id
                          and not bl.is_alternate
  ),
  walk as (
    select e.parent_item_id as item_id, 0 as depth
      from edges e
     where not exists (select 1 from edges up where up.component_item_id = e.parent_item_id)
    union all
    -- Bounded because erp.check_bom_acyclic() already refuses a cycle; the
    -- bound is belt and braces, not the guard.
    select e.component_item_id, w.depth + 1
      from walk w
      join edges e on e.parent_item_id = w.item_id
     where w.depth < 20
  )
  select w.item_id, max(w.depth)::integer
    from walk w
   group by w.item_id
$$;
revoke all on function erp.bom_low_level_codes(uuid) from public, anon, authenticated;

comment on function erp.bom_low_level_codes(uuid) is
  'Specification v1.6 §5.4. The depth of each item in the bills in force at '
  'a site: a top-level made item is 0, its components 1, theirs 2, and an item '
  'used at two depths takes the deeper. The planning run plans in this order '
  'so that dependent demand exists before the component it falls on is '
  'projected. An item in no bill has no row and plans at level 0.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Dependent demand
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.dependent_demand (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant (id) on delete cascade,
  planning_run_id          uuid not null,
  parent_planned_order_id  uuid not null,
  site_id                  uuid not null,
  item_id                  uuid not null,
  quantity                 numeric(20,6) not null check (quantity > 0),
  uom_id                   uuid not null,
  required_by              date not null,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, planning_run_id)         references erp.planning_run (tenant_id, id) on delete cascade,
  foreign key (tenant_id, parent_planned_order_id) references erp.planned_order (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)                 references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id)                 references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, uom_id)                  references erp.uom (tenant_id, id) on delete restrict
);
create index if not exists dependent_demand_run_item_idx
  on erp.dependent_demand (tenant_id, planning_run_id, item_id, site_id);
create index if not exists dependent_demand_parent_idx
  on erp.dependent_demand (tenant_id, parent_planned_order_id);

select erp_meta.register_table('erp', 'dependent_demand', 'tenant_scoped',
  'v1.6 §5.4: what a production planned order asks of each component, dated at the order''s release and kept with the planning run that raised it. The peg from a component''s order back to its parent reads through this.');

comment on table erp.dependent_demand is
  'Specification v1.6 §5.4, multi-level explosion. One row per component per '
  'production planned order, scaled by the bill''s output quantity, yield and '
  'scrap exactly as erp.raise_works_order() scales a works order component, '
  'and dated at the parent''s release. The third arm of erp.scheduled_demand().';

-- A planned order can now become a works order as well as a document.
alter table erp.planned_order
  add column if not exists converted_works_order_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'erp.planned_order'::regclass
                    and conname = 'planned_order_converted_works_order_fkey') then
    alter table erp.planned_order
      add constraint planned_order_converted_works_order_fkey
      foreign key (tenant_id, converted_works_order_id)
      references erp.works_order (tenant_id, id) on delete set null;
  end if;
end $$;

comment on column erp.planned_order.converted_works_order_id is
  'The works order a production planned order became when it was firmed. '
  'converted_document_id is the purchase order a purchase kind became; a '
  'converted order has one or the other.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Scheduled demand knows about the run
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.scheduled_demand(uuid,uuid,date,date,uuid)'::regprocedure);
begin
  if position('Forecast demand from the version in force.' in v_src) = 0
     or position('dependent_demand' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.scheduled_demand is not the 20260829260000 body';
  end if;
end $$;

-- The return shape gains a column, which CREATE OR REPLACE cannot do; the
-- five-argument form is dropped and recreated as a wrapper. Nothing but
-- erp.run_planning() and erp.supply_demand_position() call it, and neither
-- names the columns positionally.
drop function erp.scheduled_demand(uuid, uuid, date, date, uuid);

create function erp.scheduled_demand(p_item_id uuid, p_site_id uuid, p_from date, p_to date,
                                     p_forecast_version_id uuid, p_planning_run_id uuid)
returns table(due_on date, quantity numeric, source text,
              document_line_id uuid, forecast_line_id uuid, planned_order_id uuid)
language sql
stable
set search_path = ''
as $$
  -- Firm demand: sales orders committed and not yet despatched.
  select coalesce(dl.required_date, d.required_date, d.document_date),
         dl.quantity - coalesce(dl.quantity_fulfilled, 0),
         'sales_order', dl.id, null::uuid, null::uuid
    from erp.document_line dl
    join erp.document d on d.id = dl.document_id
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.object_state os on os.object_type = 'document' and os.object_id = d.id
    join erp.state s on s.id = os.current_state_id
   where dl.tenant_id = erp.current_tenant_id()
     and dt.base_type_code = 'sales_order'
     and d.site_id = p_site_id
     and dl.item_id = p_item_id
     and not dl.is_cancelled and not d.is_cancelled
     and s.is_committed and not s.is_terminal
     and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
  union all
  -- Forecast demand from the version in force.
  select fl.bucket_start, fl.quantity, 'forecast', null::uuid, fl.id, null::uuid
    from erp.forecast_line fl
    join erp.forecast_version fv on fv.id = fl.forecast_version_id
   where fl.tenant_id = erp.current_tenant_id()
     and fl.item_id = p_item_id and fl.site_id = p_site_id
     and fl.quantity > 0
     and (p_forecast_version_id is null and fv.status = 'active'
          or fv.id = p_forecast_version_id)
     and fl.bucket_start between p_from and p_to
  union all
  -- Dependent demand: what the production orders this run has already raised
  -- ask of this component. Only this run's, because an earlier run's
  -- production orders are already in erp.scheduled_supply() as supply of the
  -- parent, and their component demand was projected by that run.
  select dd.required_by, dd.quantity, 'dependent', null::uuid, null::uuid, dd.parent_planned_order_id
    from erp.dependent_demand dd
   where dd.tenant_id = erp.current_tenant_id()
     and p_planning_run_id is not null
     and dd.planning_run_id = p_planning_run_id
     and dd.item_id = p_item_id and dd.site_id = p_site_id
     and dd.required_by between p_from and p_to
$$;

create function erp.scheduled_demand(p_item_id uuid, p_site_id uuid, p_from date, p_to date,
                                     p_forecast_version_id uuid default null)
returns table(due_on date, quantity numeric, source text,
              document_line_id uuid, forecast_line_id uuid, planned_order_id uuid)
language sql
stable
set search_path = ''
as $$
  select * from erp.scheduled_demand(p_item_id, p_site_id, p_from, p_to, p_forecast_version_id, null::uuid)
$$;

revoke all on function erp.scheduled_demand(uuid, uuid, date, date, uuid, uuid) from public, anon, authenticated;
revoke all on function erp.scheduled_demand(uuid, uuid, date, date, uuid) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The run plans by level and explodes what it makes
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.run_planning(uuid,integer,uuid)'::regprocedure);
begin
  if position('values (v_tenant, v_entity, p_site_id, r.item_id, ''purchase'', v_qty,' in v_src) = 0
     or position('dependent_demand' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_planning is not the 20260829260000 body';
  end if;
end $$;

create or replace function erp.run_planning(p_site_id uuid, p_horizon_days integer default 180,
                                            p_forecast_version_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_run     uuid;
  v_entity  uuid;
  r         record;
  d         record;
  c         record;
  isx       erp.item_site%rowtype;
  pp        erp.planning_policy%rowtype;
  v_bom     erp.bom%rowtype;
  v_kind    erp.planned_order_kind;
  v_on_hand numeric;
  v_proj    numeric;
  v_qty     numeric;
  v_order   uuid;
  v_orders  integer := 0;
  v_excs    integer := 0;
  v_uom     uuid;
  v_fence   date;
  v_release date;
begin
  perform erp.authorise('planning.run', null, p_site_id, null, 'site', p_site_id);

  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id;

  insert into erp.planning_run (
    tenant_id, entity_id, site_id, horizon_days, forecast_version_id)
  values (v_tenant, v_entity, p_site_id, p_horizon_days, p_forecast_version_id)
  returning id into v_run;

  -- Planned in low-level-code order: a finished good before the sub-assembly
  -- it is made of, that before the raw material. Every production order's
  -- dependent demand therefore exists before the component it falls on is
  -- projected, which is the whole of what "multi-level" means.
  for r in
    select isx2.item_id, coalesce(llc.low_level_code, 0) as low_level_code
      from erp.item_site isx2
      join erp.item it on it.id = isx2.item_id
      left join erp.bom_low_level_codes(p_site_id) llc on llc.item_id = isx2.item_id
     where isx2.tenant_id = v_tenant and isx2.site_id = p_site_id
       and isx2.is_stocked and isx2.status = 'active' and it.status = 'active'
     order by coalesce(llc.low_level_code, 0), isx2.item_id
  loop
    select * into isx from erp.item_site
     where tenant_id = v_tenant and item_id = r.item_id and site_id = p_site_id;
    select * into pp from erp.planning_policy
     where tenant_id = v_tenant and code = isx.planning_policy_code and status = 'active';

    -- A policy that plans nothing plans nothing, and saying so beats
    -- silently skipping the item.
    if coalesce(pp.reorder_method, 'none') = 'none' then
      continue;
    end if;

    select coalesce(sum(b.quantity), 0) into v_on_hand
      from erp.stock_balance b
     where b.tenant_id = v_tenant and b.item_id = r.item_id and b.site_id = p_site_id;

    select it.stock_uom_id into v_uom from erp.item it where it.id = r.item_id;

    -- The bill in force decides what kind of order this is. The same choice
    -- erp.raise_works_order() makes, so the plan explodes the bill the works
    -- order will.
    v_bom := null;
    select * into v_bom from erp.bom b
     where b.tenant_id = v_tenant and b.item_id = r.item_id
       and b.status = 'active'
       and (b.site_id is null or b.site_id = p_site_id)
       and b.effective_from <= current_date
       and (b.effective_to is null or b.effective_to > current_date)
     order by (b.site_id is not null) desc, b.version desc
     limit 1;
    v_kind := case when v_bom.id is not null then 'production' else 'purchase' end;

    -- Inside the planning time fence the plan is not allowed to change: an
    -- order placed there is already being acted on, and a planning run that
    -- reshuffles the next fortnight every night is one the planners turn off.
    v_fence := current_date + coalesce(pp.planning_time_fence_days, 0);

    v_proj := v_on_hand;

    for d in
      select x.due_on, sum(x.qty) as qty,
             -- No min() for uuid, and no meaning in one either: what is
             -- wanted is a representative demand to peg against, so take the
             -- first non-null in the bucket.
             (array_agg(x.document_line_id) filter (where x.document_line_id is not null))[1]
               as document_line_id,
             (array_agg(x.forecast_line_id) filter (where x.forecast_line_id is not null))[1]
               as forecast_line_id,
             (array_agg(x.planned_order_id) filter (where x.planned_order_id is not null))[1]
               as planned_order_id,
             string_agg(distinct x.source, ',') as sources
        from (
          select s.due_on, s.quantity as qty, s.source,
                 null::uuid as document_line_id, null::uuid as forecast_line_id,
                 null::uuid as planned_order_id
            from erp.scheduled_supply(r.item_id, p_site_id, current_date,
                                      current_date + p_horizon_days) s
          union all
          select dm.due_on, -dm.quantity, dm.source, dm.document_line_id, dm.forecast_line_id,
                 dm.planned_order_id
            from erp.scheduled_demand(r.item_id, p_site_id, current_date,
                                      current_date + p_horizon_days,
                                      p_forecast_version_id, v_run) dm
        ) x
       where x.due_on is not null
         and x.due_on <= current_date + p_horizon_days
       group by x.due_on
       order by x.due_on
    loop
      v_proj := v_proj + d.qty;

      -- The breach. Ordering when the projection dips below the reorder point
      -- rather than when today's stock does is the entire difference between
      -- planning and reacting.
      if v_proj < coalesce(isx.reorder_point, 0) then
        v_qty := case coalesce(pp.lot_sizing, 'lot_for_lot')
                   when 'fixed' then coalesce(pp.fixed_lot_size, 1)
                   when 'order_up_to' then coalesce(isx.order_up_to, 0) - v_proj
                   else coalesce(isx.order_up_to, isx.reorder_point, 0) - v_proj
                 end;

        v_qty := greatest(v_qty, coalesce(isx.min_order_quantity, 0));
        if coalesce(isx.order_multiple, 0) > 0 then
          v_qty := ceil(v_qty / isx.order_multiple) * isx.order_multiple;
        end if;

        if v_qty > 0 then
          v_release := d.due_on - coalesce(isx.lead_time_days, 0);

          -- Released in the past means the lead time cannot be met. Raising
          -- the order anyway and dating it today would hide that; the
          -- exception is the point.
          if v_release < current_date then
            insert into erp.planning_exception (
              tenant_id, entity_id, site_id, item_id, exception_kind, severity,
              message, detail)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'lead_time_breach',
                    'high',
                    format('needed on %s, and the lead time of %s days means it '
                           'should have been released on %s',
                           d.due_on, coalesce(isx.lead_time_days, 0), v_release),
                    jsonb_build_object('required_by', d.due_on,
                                       'release_on', v_release,
                                       'shortfall', coalesce(isx.reorder_point, 0) - v_proj));
            v_excs := v_excs + 1;
            v_release := current_date;
          end if;

          if v_release <= v_fence then
            -- Inside the fence. Recorded as an exception for a planner rather
            -- than acted on, because the fence exists precisely so that this
            -- decision is a person's.
            insert into erp.planning_exception (
              tenant_id, entity_id, site_id, item_id, exception_kind, severity,
              message, detail)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'expedite', 'high',
                    'a shortage inside the planning time fence needs a decision',
                    jsonb_build_object('required_by', d.due_on, 'quantity', v_qty));
            v_excs := v_excs + 1;
          else
            insert into erp.planned_order (
              tenant_id, entity_id, site_id, item_id, order_kind, quantity,
              uom_id, required_by, release_on, status, planning_run_id, policy_id)
            values (v_tenant, v_entity, p_site_id, r.item_id, v_kind, v_qty,
                    v_uom, d.due_on, v_release, 'suggested', v_run, pp.id)
            returning id into v_order;

            -- Pegging. B7 has a trigger that refuses an unpegged planned order,
            -- which is what makes "why am I ordering this" a query. A
            -- component's order pegs to the parent order that demanded it.
            insert into erp.planned_order_peg (
              tenant_id, planned_order_id, demand_kind,
              demand_document_line_id, demand_planned_order_id, demand_forecast_line_id,
              quantity, required_by)
            values (v_tenant, v_order,
                    case when d.document_line_id is not null then 'sales_order'
                         when d.planned_order_id is not null then 'planned_order'
                         else 'forecast' end,
                    d.document_line_id, d.planned_order_id, d.forecast_line_id,
                    v_qty, d.due_on);

            -- The explosion, one level, dated at the release: the components
            -- are needed when production starts, not when it finishes.
            -- Recursive through phantoms and scaled by the bill's output
            -- quantity, yield and scrap exactly as erp.raise_works_order()
            -- scales a works order component, so the plan and the works order
            -- that firms it ask for the same quantities.
            if v_kind = 'production' then
              insert into erp.dependent_demand (
                tenant_id, planning_run_id, parent_planned_order_id, site_id,
                item_id, quantity, uom_id, required_by)
              select v_tenant, v_run, v_order, p_site_id,
                     e.component_item_id,
                     round(v_qty * e.quantity
                           / coalesce(nullif(v_bom.output_quantity, 0), 1)
                           / coalesce(nullif(v_bom.yield_factor, 0), 1)
                           * (1 + coalesce(e.scrap_factor, 0)), 6),
                     e.uom_id, v_release
                from (
                  with recursive explode as (
                    select bl.component_item_id, bl.quantity::numeric, bl.uom_id,
                           bl.scrap_factor, bl.is_phantom, 1 as depth
                      from erp.bom_line bl
                     where bl.tenant_id = v_tenant and bl.bom_id = v_bom.id
                       and not bl.is_alternate
                    union all
                    select bl.component_item_id,
                           (e2.quantity * bl.quantity)::numeric, bl.uom_id, bl.scrap_factor,
                           bl.is_phantom, e2.depth + 1
                      from explode e2
                      join erp.bom cb on cb.tenant_id = v_tenant
                                     and cb.item_id = e2.component_item_id
                                     and cb.status = 'active'
                      join erp.bom_line bl on bl.tenant_id = v_tenant and bl.bom_id = cb.id
                                          and not bl.is_alternate
                     where e2.is_phantom and e2.depth < 10
                  )
                  select * from explode where not is_phantom
                ) e;
            end if;

            v_orders := v_orders + 1;
            v_proj := v_proj + v_qty;
          end if;
        end if;
      end if;
    end loop;

    -- Excess is the other half of a planning run, and the half that is always
    -- missing: stock nobody is going to need is money on a shelf.
    if v_proj > coalesce(isx.order_up_to, 0) * 2
       and coalesce(isx.order_up_to, 0) > 0 then
      insert into erp.planning_exception (
        tenant_id, entity_id, site_id, item_id, exception_kind, severity,
        message, detail)
      values (v_tenant, v_entity, p_site_id, r.item_id, 'excess', 'medium',
              'projected stock at the end of the horizon is more than twice the '
              'order-up-to level',
              jsonb_build_object('projected', v_proj, 'order_up_to', isx.order_up_to));
      v_excs := v_excs + 1;
    end if;
  end loop;

  -- A component the bills demand that nothing plans at this site. The demand
  -- is recorded above; leaving it there without a word is how a works order
  -- discovers a shortage on the day it is released.
  for c in
    select dd.item_id, sum(dd.quantity) as quantity, min(dd.required_by) as required_by
      from erp.dependent_demand dd
     where dd.tenant_id = v_tenant and dd.planning_run_id = v_run
       and not exists (
         select 1 from erp.item_site x
           join erp.planning_policy pol on pol.tenant_id = x.tenant_id
                                       and pol.code = x.planning_policy_code
                                       and pol.status = 'active'
          where x.tenant_id = v_tenant and x.item_id = dd.item_id and x.site_id = p_site_id
            and x.is_stocked and x.status = 'active'
            and coalesce(pol.reorder_method, 'none') <> 'none')
     group by dd.item_id
  loop
    insert into erp.planning_exception (
      tenant_id, entity_id, site_id, item_id, exception_kind, severity, message, detail)
    values (v_tenant, v_entity, p_site_id, c.item_id, 'no_supply_source', 'high',
            format('a bill of materials needs %s of this component by %s and nothing '
                   'plans it at this site; give it a stocked item-site row with a '
                   'planning policy', c.quantity, c.required_by),
            jsonb_build_object('quantity', c.quantity, 'required_by', c.required_by,
                               'planning_run_id', v_run));
    v_excs := v_excs + 1;
  end loop;

  update erp.planning_run
     set finished_at = now(), orders_raised = v_orders, exceptions_raised = v_excs,
         updated_at = now()
   where id = v_run;

  return v_run;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Firming a production order raises the works order
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.firm_planned_order(uuid,text)'::regprocedure);
begin
  if position('v_doc := erp.create_document(' in v_src) = 0
     or position('converted_works_order_id' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.firm_planned_order is not the 20260829260000 body';
  end if;
end $$;

create or replace function erp.firm_planned_order(p_planned_order_id uuid, p_document_type_code text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  po       erp.planned_order%rowtype;
  v_doc    uuid;
  v_wo     uuid;
begin
  select * into po from erp.planned_order
   where tenant_id = v_tenant and id = p_planned_order_id for update;

  if not found then
    raise exception 'CLOVEERP_PLANNED_ORDER_NOT_FOUND: %', p_planned_order_id
      using errcode = '23503',
            hint = 'Read erp_planned_orders() for the orders the last run raised.';
  end if;

  perform erp.authorise('planning.firm', po.entity_id, po.site_id, null, 'planned_order', po.id);

  if po.status = 'converted' then
    raise exception 'CLOVEERP_PLANNED_ORDER_ALREADY_FIRMED: % became %',
      p_planned_order_id, coalesce(po.converted_document_id, po.converted_works_order_id)
      using errcode = '23514',
            hint = 'Open what it became; a planned order is firmed once.';
  end if;

  if po.status = 'cancelled' then
    raise exception 'CLOVEERP_PLANNED_ORDER_CANCELLED: % was cancelled and cannot be firmed',
      p_planned_order_id
      using errcode = '23514',
            hint = 'Run planning again if the demand still stands.';
  end if;

  -- A made item firms into a works order. erp.raise_works_order() explodes
  -- the same bill the plan exploded, so the components it asks for are the
  -- ones the plan has already projected.
  if po.order_kind = 'production' then
    v_wo := erp.raise_works_order(po.item_id, po.site_id, po.quantity, 'assembly', po.required_by);

    update erp.works_order
       set planned_order_id = po.id, planned_start = po.release_on, updated_at = now()
     where tenant_id = v_tenant and id = v_wo;

    update erp.planned_order
       set status = 'converted', converted_works_order_id = v_wo,
           converted_at = now(), updated_at = now()
     where id = p_planned_order_id;

    return v_wo;
  end if;

  if p_document_type_code is null then
    raise exception 'CLOVEERP_FIRMING_NEEDS_A_DOCUMENT_TYPE: a % planned order becomes a document, and none was named',
      po.order_kind
      using errcode = '22023',
            hint = 'Pass the purchase order type code the organisation uses, for example purchase_order.';
  end if;

  v_doc := erp.create_document(
    p_document_type_code, po.entity_id, po.site_id, po.supplier_party_id,
    current_date, null, null,
    jsonb_build_object('firmed_from_planned_order', po.id));

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, quantity, uom_id, required_date)
  values (v_tenant, v_doc, 1, po.item_id, po.quantity, po.uom_id, po.required_by);

  -- The plan is not deleted. It records what it became, so a question about
  -- why this order exists still reaches the demand that caused it.
  update erp.planned_order
     set status = 'converted', converted_document_id = v_doc,
         converted_at = now(), updated_at = now()
   where id = p_planned_order_id;

  return v_doc;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_planned_order_pegging(p_planned_order_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'planned_order_id', po.id,
           'kind', po.order_kind,
           'item', i.code, 'item_name', i.name,
           'quantity', po.quantity, 'required_by', po.required_by, 'release_on', po.release_on,
           'status', po.status,
           'converted_document_id', po.converted_document_id,
           'converted_works_order_id', po.converted_works_order_id,
           'works_order_number', (select wo.order_number from erp.works_order wo
                                   where wo.id = po.converted_works_order_id),
           -- Upwards: the demand this order exists for.
           'pegs', (select coalesce(jsonb_agg(jsonb_build_object(
                      'demand_kind', pg.demand_kind,
                      'quantity', pg.quantity,
                      'required_by', pg.required_by,
                      'document_number', (select d.document_number
                                            from erp.document_line dl
                                            join erp.document d on d.id = dl.document_id
                                           where dl.id = pg.demand_document_line_id),
                      'forecast_bucket', (select fl.bucket_start from erp.forecast_line fl
                                           where fl.id = pg.demand_forecast_line_id),
                      'parent_planned_order_id', pg.demand_planned_order_id,
                      'parent_item', (select i2.code from erp.planned_order p2
                                        join erp.item i2 on i2.id = p2.item_id
                                       where p2.id = pg.demand_planned_order_id))
                      order by pg.required_by, pg.demand_kind), '[]'::jsonb)
                      from erp.planned_order_peg pg
                     where pg.tenant_id = po.tenant_id and pg.planned_order_id = po.id),
           -- Downwards: what this order asks of its components, and the
           -- orders the same run raised to cover them.
           'components', (select coalesce(jsonb_agg(jsonb_build_object(
                            'item', ci.code, 'item_name', ci.name,
                            'quantity', dd.quantity, 'required_by', dd.required_by,
                            'planned_order_id', (select p3.id from erp.planned_order p3
                                                   join erp.planned_order_peg g3
                                                     on g3.planned_order_id = p3.id
                                                  where g3.demand_planned_order_id = po.id
                                                    and p3.item_id = dd.item_id
                                                  limit 1))
                            order by ci.code), '[]'::jsonb)
                            from erp.dependent_demand dd
                            join erp.item ci on ci.id = dd.item_id
                           where dd.tenant_id = po.tenant_id
                             and dd.parent_planned_order_id = po.id))
    from erp.planned_order po
    join erp.item i on i.id = po.item_id
   where po.tenant_id = erp.current_tenant_id()
     and po.id = p_planned_order_id
$$;

create or replace function public.erp_dependent_demand(p_planning_run_id uuid default null, p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with run as (
    select coalesce(p_planning_run_id,
                    (select pr.id from erp.planning_run pr
                      where pr.tenant_id = erp.current_tenant_id()
                      order by pr.started_at desc limit 1)) as id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'planning_run_id', dd.planning_run_id,
           'parent_planned_order_id', dd.parent_planned_order_id,
           'parent_item', pi.code,
           'item', ci.code, 'item_name', ci.name,
           'site', s.code,
           'quantity', dd.quantity, 'required_by', dd.required_by)
         order by dd.required_by, pi.code, ci.code), '[]'::jsonb)
    from (select * from erp.dependent_demand x
           where x.tenant_id = erp.current_tenant_id()
             and x.planning_run_id = (select id from run)
           order by x.required_by limit greatest(p_limit, 1)) dd
    join erp.planned_order po on po.id = dd.parent_planned_order_id
    join erp.item pi on pi.id = po.item_id
    join erp.item ci on ci.id = dd.item_id
    join erp.site s on s.id = dd.site_id
$$;

create or replace function public.erp_planned_orders(p_site_id uuid default null, p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'required_by'), '[]'::jsonb) from (
    select jsonb_build_object('planned_order_id', po.id, 'kind', po.order_kind,
      'item', i.code, 'item_name', i.name, 'site', s.code, 'quantity', po.quantity,
      'required_by', po.required_by, 'release_on', po.release_on, 'status', po.status,
      'converted', po.converted_document_id is not null or po.converted_works_order_id is not null,
      'converted_document_id', po.converted_document_id,
      'converted_works_order_id', po.converted_works_order_id,
      'pegged_to', (select string_agg(distinct pg.demand_kind, ',')
                      from erp.planned_order_peg pg
                     where pg.tenant_id = po.tenant_id and pg.planned_order_id = po.id)) as x
      from erp.planned_order po
      join erp.item i on i.tenant_id = po.tenant_id and i.id = po.item_id
      left join erp.site s on s.tenant_id = po.tenant_id and s.id = po.site_id
     where po.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or po.site_id = p_site_id)
     order by po.required_by limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_firm_planned_order(p_planned_order_id uuid, p_document_type_code text default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.firm_planned_order(p_planned_order_id, p_document_type_code)
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_planned_order_pegging(uuid)',
    'erp_dependent_demand(uuid, integer)',
    'erp_planned_orders(uuid, integer)',
    'erp_firm_planned_order(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_firm_planned_order', 'erp.firm_planned_order',
   'Firms a planned order into a works order or a purchase order; authorises planning.firm, and the conversion authorises production.order or the document type''s create permission.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The register
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.run_planning(uuid,integer,uuid)',
                         'erp.planned_order_peg',
                         'erp.dependent_demand',
                         'erp.bom_low_level_codes(uuid)',
                         'erp.scheduled_supply(uuid,uuid,date,date)',
                         'erp.scheduled_demand(uuid,uuid,date,date,uuid)',
                         'erp.scheduled_demand(uuid,uuid,date,date,uuid,uuid)',
                         'erp.firm_planned_order(uuid,text)',
                         'erp.raise_works_order(uuid,uuid,numeric,erp.works_order_kind,date)']
 where code = '5.4.mrp';

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.mrp_explosion_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid; csl uuid; csw uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid;
  v_fg uuid; v_sfg uuid; v_rm uuid; v_pack uuid; v_bom2 uuid;
  v_fc uuid; v_ver uuid; v_run uuid; v_due date := current_date + 60;
  v_fg_order uuid; v_sfg_order uuid; v_rm_order uuid; v_wo uuid;
  v_peg record; v_dd record; v_x jsonb; v_n integer; v_q numeric; v_d date;
  v_ok boolean; v_msg text;
begin
  begin
    select * into r from erp.provision_tenant('zzmrp', 'Explosion Suite', 'a@zzmrp.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zzmrp.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csl := erp.configure_planning(95, 7);
    csw := erp.configure_production();
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csl); perform erp.promote_change_set(csl);
    perform erp.approve_change_set(csw); perform erp.promote_change_set(csw);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;

    -- A three-level bill: FG is made of two SFG and one PACK; SFG is made of
    -- three RM at ten per cent scrap. Nothing plans PACK.
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'SFG', 'Sub-assembly', v_uom, 'active') returning id into v_sfg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'RM', 'Raw material', v_uom, 'active') returning id into v_rm;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'PACK', 'Carton', v_uom, 'active') returning id into v_pack;

    perform erp.seed_demo_bom(v_fg, v_sfg, v_site);
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id)
    select r.tenant_id, b.id, 20, v_pack, 1, v_uom from erp.bom b
     where b.tenant_id = r.tenant_id and b.item_id = v_fg;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name, output_quantity,
                         status, effective_from)
    values (r.tenant_id, 'SFG-BOM', v_sfg, v_site, 1, 'Sub-assembly bill', 1, 'active', current_date - 30)
    returning id into v_bom2;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor)
    values (r.tenant_id, v_bom2, 10, v_rm, 3, v_uom, 0.1);

    insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, planning_policy_code,
                               lead_time_days, min_order_quantity, order_multiple, status)
    values (r.tenant_id, v_fg,  v_site, true, 'standard', 5, 0, 0,  'active'),
           (r.tenant_id, v_sfg, v_site, true, 'standard', 3, 0, 0,  'active'),
           (r.tenant_id, v_rm,  v_site, true, 'standard', 7, 0, 10, 'active');

    -- Five sub-assemblies already on the shelf.
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency)
    values (r.tenant_id, r.entity_id, v_site, 'goods_receipt', v_sfg, v_recv, 'available', 5, v_uom, 1000, 'GBP');

    -- The only independent demand: a forecast for ten finished goods in two
    -- months, in force.
    insert into erp.forecast (tenant_id, code, name, entity_id, site_id, bucket, status)
    values (r.tenant_id, 'MRP-M', 'Explosion monthly', r.entity_id, v_site, 'month', 'active')
    returning id into v_fc;
    insert into erp.forecast_version (tenant_id, forecast_id, version, method, parameters, status,
                                      horizon_from, horizon_to, note)
    values (r.tenant_id, v_fc, 1, 'manual', '{}'::jsonb, 'active', current_date, current_date + 180,
            'written by the explosion suite')
    returning id into v_ver;
    insert into erp.forecast_line (tenant_id, forecast_version_id, item_id, site_id, bucket_start, quantity, uom_id)
    values (r.tenant_id, v_ver, v_fg, v_site, v_due, 10, v_uom);

    return query select 'low-level codes place a component below every parent that uses it',
      (select array_agg(llc.low_level_code order by llc.low_level_code)
         from erp.bom_low_level_codes(v_site) llc
        where llc.item_id in (v_fg, v_sfg, v_rm, v_pack)) = array[0, 1, 1, 2]
      and (select llc.low_level_code from erp.bom_low_level_codes(v_site) llc where llc.item_id = v_rm) = 2,
      'FG 0, SFG 1, PACK 1, RM 2';

    v_run := erp.run_planning(v_site, 180);

    select po.id into v_fg_order from erp.planned_order po
     where po.planning_run_id = v_run and po.item_id = v_fg;
    select po.id into v_sfg_order from erp.planned_order po
     where po.planning_run_id = v_run and po.item_id = v_sfg;
    select po.id into v_rm_order from erp.planned_order po
     where po.planning_run_id = v_run and po.item_id = v_rm;

    return query select 'a forecast for a made item raises a production order, not a purchase',
      v_fg_order is not null
      and (select po.order_kind::text from erp.planned_order po where po.id = v_fg_order) = 'production'
      and (select po.quantity from erp.planned_order po where po.id = v_fg_order) = 10
      and (select po.release_on from erp.planned_order po where po.id = v_fg_order) = v_due - 5
      and (select pr.orders_raised from erp.planning_run pr where pr.id = v_run) = 3,
      format('FG production 10, released %s; three orders in the run', v_due - 5);

    return query select 'the order explodes one level into dependent demand dated at its release',
      (select count(*) from erp.dependent_demand dd where dd.parent_planned_order_id = v_fg_order) = 2
      and (select dd.quantity from erp.dependent_demand dd
            where dd.parent_planned_order_id = v_fg_order and dd.item_id = v_sfg) = 20
      and (select dd.quantity from erp.dependent_demand dd
            where dd.parent_planned_order_id = v_fg_order and dd.item_id = v_pack) = 10
      and (select bool_and(dd.required_by = v_due - 5) from erp.dependent_demand dd
            where dd.parent_planned_order_id = v_fg_order),
      format('SFG 20 and PACK 10, both by %s', v_due - 5);

    select pg.* into v_peg from erp.planned_order_peg pg where pg.planned_order_id = v_sfg_order;
    return query select 'the component is planned after the parent and pegged to it',
      v_sfg_order is not null
      and v_peg.demand_kind = 'planned_order'
      and v_peg.demand_planned_order_id = v_fg_order
      and (select po.order_kind::text from erp.planned_order po where po.id = v_sfg_order) = 'production',
      'SFG pegged to the FG order, itself a production order';

    return query select 'stock on hand nets the dependent demand',
      (select po.quantity from erp.planned_order po where po.id = v_sfg_order) = 15,
      'twenty demanded, five on the shelf, fifteen planned';

    return query select 'scrap and the lot multiple reach the bought component',
      v_rm_order is not null
      and (select dd.quantity from erp.dependent_demand dd
            where dd.parent_planned_order_id = v_sfg_order and dd.item_id = v_rm) = 49.5
      and (select po.quantity from erp.planned_order po where po.id = v_rm_order) = 50
      and (select po.order_kind::text from erp.planned_order po where po.id = v_rm_order) = 'purchase',
      'fifteen at three each and ten per cent scrap is 49.5, bought in tens';

    return query select 'lead times offset through the levels',
      (select po.release_on from erp.planned_order po where po.id = v_sfg_order) = v_due - 5 - 3
      and (select po.release_on from erp.planned_order po where po.id = v_rm_order) = v_due - 5 - 3 - 7
      and (select po.required_by from erp.planned_order po where po.id = v_rm_order) = v_due - 5 - 3,
      format('FG starts %s, SFG starts %s, RM is ordered %s', v_due - 5, v_due - 8, v_due - 15);

    return query select 'a component nobody plans is an exception, not a silence',
      exists (select 1 from erp.planning_exception e
               where e.item_id = v_pack and e.exception_kind = 'no_supply_source'
                 and (e.detail ->> 'quantity')::numeric = 10
                 and e.message like '%nothing plans it at this site%')
      and not exists (select 1 from erp.planned_order po where po.planning_run_id = v_run and po.item_id = v_pack),
      'PACK: no_supply_source for ten';

    v_x := public.erp_planned_order_pegging(v_sfg_order);
    return query select 'the pegging door answers why, in both directions',
      v_x -> 'pegs' -> 0 ->> 'parent_item' = 'FG'
      and v_x -> 'pegs' -> 0 ->> 'demand_kind' = 'planned_order'
      and v_x -> 'components' -> 0 ->> 'item' = 'RM'
      and (v_x -> 'components' -> 0 ->> 'planned_order_id')::uuid = v_rm_order
      and jsonb_array_length(public.erp_dependent_demand(v_run)) = 3
      and (public.erp_planned_order_pegging(v_fg_order) -> 'pegs' -> 0 ->> 'demand_kind') = 'forecast',
      'SFG: from the FG order, for the RM order; FG: from the forecast';

    v_wo := erp.firm_planned_order(v_fg_order, null);
    begin
      perform erp.firm_planned_order(v_fg_order, null);
      v_ok := false; v_msg := 'firmed twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLANNED_ORDER_ALREADY_FIRMED:%'; v_msg := left(sqlerrm, 80);
    end;
    return query select 'firming a production order raises a works order with its components, once',
      v_wo is not null
      and (select wo.planned_order_id from erp.works_order wo where wo.id = v_wo) = v_fg_order
      and (select wo.quantity from erp.works_order wo where wo.id = v_wo) = 10
      and (select wo.planned_start from erp.works_order wo where wo.id = v_wo) = v_due - 5
      and (select c.required_quantity from erp.works_order_component c
            where c.works_order_id = v_wo and c.item_id = v_sfg) = 20
      and (select po.converted_works_order_id from erp.planned_order po where po.id = v_fg_order) = v_wo
      and (select po.status::text from erp.planned_order po where po.id = v_fg_order) = 'converted'
      and not exists (select 1 from erp.scheduled_supply(v_fg, v_site, current_date, current_date + 180) s
                       where s.source = 'planned_order')
      and v_ok,
      format('works order for ten with twenty SFG; %s', v_msg);

    return query select 'the register says material requirements planning is built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.4.mrp') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.4.mrp'),
      '5.4.mrp';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzmrp');
  detail := 'the organisation, its bills and its plan rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_mrp_explosion_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _mrp_explosion on commit drop as
    select * from erp_test.mrp_explosion_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _mrp_explosion;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_MRP_EXPLOSION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_MRP_EXPLOSION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('mrp explosion: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_mrp_explosion_suite() from public, anon, authenticated;
revoke all on function erp_test.mrp_explosion_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_mrp_explosion_suite();
select erp_test.assert_planning_suite();
select erp_test.assert_production_suite();
select erp.assert_part5_coverage();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
