-- =============================================================================
-- 20260906134000  A plan is kept, not replaced
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.4, supply and demand reconciliation with scenario
-- comparison. The register said 5.4.supply_demand was partial because
-- "comparing two plans means keeping two, and the planning run currently
-- replaces rather than versions its output". Reading the run showed something
-- slightly different and worse: it did not replace anything. Every run's
-- suggested orders stayed, counted as supply for the next run, and so a
-- second run after nothing had changed raised nothing — the plan could
-- neither be re-run nor compared.
--
-- What changes:
--
--   * erp.planning_run carries what kind of run it was: a baseline (the plan
--     as things are) or a scenario (a code, a label and a set of assumptions
--     that could be otherwise), and which later baseline superseded it. No
--     run is deleted and no planned order is cancelled by a later run: the
--     history of what each run decided stays readable.
--   * erp.scheduled_supply() counts a planned order as supply only when it is
--     firmed (somebody acted) or belongs to the current baseline. Scenario
--     orders and the suggestions of a superseded baseline never feed the
--     projection, which is what lets a baseline be re-run and a scenario be
--     run beside it without either polluting the other. A scenario is planned
--     as if it were the baseline (five-argument form): firmed orders are its
--     supply, the baseline's own suggestions are not.
--   * erp.run_planning() takes a scenario code, assumptions and a label. A
--     baseline supersedes the previous baseline for the site explicitly and
--     takes no assumptions; a scenario honours exactly three —
--     demand_multiplier, lead_time_days_delta, reorder_point_multiplier — and
--     refuses any other key by name. A scenario's exceptions carry its run so
--     the workbench does not show a planner what a what-if imagined.
--   * A scenario order cannot be firmed (erp.firm_planned_order refuses it):
--     a scenario is a comparison, not a plan.
--   * erp.compare_planning_runs(a, b) — per item, what each run planned and
--     the difference; erp.planning_runs() lists a site's runs with their
--     kind, assumptions and outcome.
--   * Doors: erp_run_planning re-created with the three new arguments (same
--     name, no overload), erp_compare_planning_runs, erp_planning_runs;
--     erp_planned_orders and erp_planning_exceptions re-created to leave
--     scenario rows out unless a run is named.
--
-- Proof: erp_test.planning_scenario_suite() (10 cases, wrapper pinned); the
-- planning, explosion and production suites still pass; the register reads
-- 5.4.supply_demand built.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A run knows what kind of run it was
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.planning_run
  add column if not exists scenario_code        text,
  add column if not exists label                text,
  add column if not exists assumptions          jsonb not null default '{}'::jsonb,
  add column if not exists is_scenario          boolean not null default false,
  add column if not exists superseded_by_run_id uuid,
  add column if not exists superseded_at        timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'erp.planning_run'::regclass
                    and conname = 'planning_run_scenario_has_code') then
    alter table erp.planning_run
      add constraint planning_run_scenario_has_code
      check (is_scenario = (scenario_code is not null));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'erp.planning_run'::regclass
                    and conname = 'planning_run_assumptions_object') then
    alter table erp.planning_run
      add constraint planning_run_assumptions_object
      check (jsonb_typeof(assumptions) = 'object');
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'erp.planning_run'::regclass
                    and conname = 'planning_run_superseded_by_fkey') then
    alter table erp.planning_run
      add constraint planning_run_superseded_by_fkey
      foreign key (tenant_id, superseded_by_run_id)
      references erp.planning_run (tenant_id, id) on delete set null;
  end if;
end $$;

create index if not exists planning_run_current_baseline_idx
  on erp.planning_run (tenant_id, site_id, started_at desc)
  where not is_scenario and superseded_by_run_id is null;

comment on column erp.planning_run.scenario_code is
  'Present on a scenario run: a what-if beside the baseline, with assumptions. '
  'A scenario''s orders are never supply and cannot be firmed.';
comment on column erp.planning_run.assumptions is
  'For a scenario: demand_multiplier (numeric > 0), lead_time_days_delta '
  '(integer), reorder_point_multiplier (numeric >= 0). Any other key is '
  'refused. A baseline carries none.';
comment on column erp.planning_run.superseded_by_run_id is
  'The later baseline for the same site. A superseded baseline''s suggested '
  'orders stop counting as supply; its firmed orders still do; nothing is '
  'deleted, so two baselines can be compared.';

-- A scenario's exceptions are the scenario's, not the planner's.
alter table erp.planning_exception
  add column if not exists planning_run_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'erp.planning_exception'::regclass
                    and conname = 'planning_exception_planning_run_fkey') then
    alter table erp.planning_exception
      add constraint planning_exception_planning_run_fkey
      foreign key (tenant_id, planning_run_id)
      references erp.planning_run (tenant_id, id) on delete cascade;
  end if;
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Supply counts the current baseline and what people firmed
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.scheduled_supply(uuid,uuid,date,date)'::regprocedure);
begin
  if position('and po.status in (''suggested'', ''reviewed'', ''firmed'')' in v_src) = 0
     or position('is_scenario' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.scheduled_supply is not the 20260829260000 body';
  end if;
end $$;

-- The five-argument form says who is asking. A scenario is planned as if it
-- were the baseline: firmed orders are supply for it too (somebody acted),
-- but the current baseline's suggestions are not — they are what the
-- baseline decided, and the scenario decides afresh under its assumptions.
create function erp.scheduled_supply(p_item_id uuid, p_site_id uuid, p_from date, p_to date,
                                     p_for_scenario boolean)
returns table(due_on date, quantity numeric, source text)
language sql
stable
set search_path = ''
as $$
  -- Ordered and not yet received.
  select coalesce(dl.required_date, d.required_date, d.document_date),
         dl.quantity - coalesce(dl.quantity_fulfilled, 0),
         'purchase_order'
    from erp.document_line dl
    join erp.document d on d.id = dl.document_id
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.object_state os on os.object_type = 'document' and os.object_id = d.id
    join erp.state s on s.id = os.current_state_id
   where dl.tenant_id = erp.current_tenant_id()
     and dt.base_type_code = 'purchase_order'
     and d.site_id = p_site_id
     and dl.item_id = p_item_id
     and not dl.is_cancelled and not d.is_cancelled
     and s.is_committed and not s.is_terminal
     and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
  union all
  -- Planned and not yet converted: a firmed order always (somebody acted on
  -- it), a suggestion only while its baseline is the current one. A
  -- scenario's orders and a superseded baseline's suggestions are history,
  -- kept to be read and compared, never supply.
  select po.required_by, po.quantity, 'planned_order'
    from erp.planned_order po
    left join erp.planning_run pr on pr.tenant_id = po.tenant_id and pr.id = po.planning_run_id
   where po.tenant_id = erp.current_tenant_id()
     and po.item_id = p_item_id and po.site_id = p_site_id
     and (po.status = 'firmed'
          or (po.status in ('suggested', 'reviewed')
              and not p_for_scenario
              and not coalesce(pr.is_scenario, false)
              and pr.superseded_by_run_id is null))
$$;

create or replace function erp.scheduled_supply(p_item_id uuid, p_site_id uuid, p_from date, p_to date)
returns table(due_on date, quantity numeric, source text)
language sql
stable
set search_path = ''
as $$
  select * from erp.scheduled_supply(p_item_id, p_site_id, p_from, p_to, false)
$$;
revoke all on function erp.scheduled_supply(uuid, uuid, date, date, boolean) from public, anon, authenticated;
revoke all on function erp.scheduled_supply(uuid, uuid, date, date) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The run: baseline or scenario
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.run_planning(uuid,integer,uuid)'::regprocedure);
begin
  if position('insert into erp.dependent_demand (' in v_src) = 0
     or position('demand_multiplier' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_planning is not the 20260906133000 body';
  end if;
end $$;

-- The three-argument form is dropped rather than kept beside the new one: a
-- second erp.run_planning with defaults on both would make a two-argument
-- call ambiguous, and the only caller, the door, is re-created below.
drop function erp.run_planning(uuid, integer, uuid);

create function erp.run_planning(p_site_id uuid, p_horizon_days integer default 180,
                                 p_forecast_version_id uuid default null,
                                 p_scenario_code text default null,
                                 p_assumptions jsonb default '{}'::jsonb,
                                 p_label text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_run      uuid;
  v_entity   uuid;
  v_previous uuid;
  r          record;
  d          record;
  c          record;
  isx        erp.item_site%rowtype;
  pp         erp.planning_policy%rowtype;
  v_bom      erp.bom%rowtype;
  v_kind     erp.planned_order_kind;
  v_on_hand  numeric;
  v_proj     numeric;
  v_qty      numeric;
  v_order    uuid;
  v_orders   integer := 0;
  v_excs     integer := 0;
  v_uom      uuid;
  v_fence    date;
  v_release  date;
  v_lead     integer;
  v_rop      numeric;
  -- The assumptions a scenario may make, and nothing else.
  v_scenario boolean := p_scenario_code is not null;
  v_assume   jsonb := coalesce(p_assumptions, '{}'::jsonb);
  v_mult     numeric;
  v_lt_delta integer;
  v_rop_mult numeric;
  v_key      text;
begin
  perform erp.authorise('planning.run', null, p_site_id, null, 'site', p_site_id);

  if jsonb_typeof(v_assume) <> 'object' then
    raise exception 'CLOVEERP_ASSUMPTIONS_NOT_AN_OBJECT: assumptions are a JSON object of named figures'
      using errcode = '22023',
            hint = 'Pass {"demand_multiplier": 1.2}, {"lead_time_days_delta": 7} or {"reorder_point_multiplier": 1.5}, alone or together.';
  end if;

  if not v_scenario and v_assume <> '{}'::jsonb then
    raise exception 'CLOVEERP_BASELINE_TAKES_NO_ASSUMPTIONS: a baseline is the plan as things are'
      using errcode = '22023',
            hint = 'Give the run a scenario code to plan under assumptions, and compare it with the baseline.';
  end if;

  for v_key in select jsonb_object_keys(v_assume) loop
    if v_key not in ('demand_multiplier', 'lead_time_days_delta', 'reorder_point_multiplier') then
      raise exception 'CLOVEERP_UNKNOWN_ASSUMPTION: % is not something the run can assume', v_key
        using errcode = '22023',
              hint = 'The run honours demand_multiplier, lead_time_days_delta and reorder_point_multiplier.';
    end if;
  end loop;

  v_mult     := coalesce((v_assume ->> 'demand_multiplier')::numeric, 1);
  v_lt_delta := coalesce((v_assume ->> 'lead_time_days_delta')::integer, 0);
  v_rop_mult := coalesce((v_assume ->> 'reorder_point_multiplier')::numeric, 1);

  if v_mult <= 0 or v_rop_mult < 0 then
    raise exception 'CLOVEERP_ASSUMPTION_OUT_OF_RANGE: demand_multiplier must be above zero and reorder_point_multiplier at least zero'
      using errcode = '22023',
            hint = 'A multiplier of 1 means "as the baseline"; 0.5 halves it; 2 doubles it.';
  end if;

  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id;

  insert into erp.planning_run (
    tenant_id, entity_id, site_id, horizon_days, forecast_version_id,
    scenario_code, label, assumptions, is_scenario)
  values (v_tenant, v_entity, p_site_id, p_horizon_days, p_forecast_version_id,
          p_scenario_code, p_label, v_assume, v_scenario)
  returning id into v_run;

  -- A baseline supersedes the previous baseline for the site, explicitly and
  -- before it projects anything: from here the earlier run's suggestions are
  -- history and no longer supply, so this run sees the position afresh.
  -- Nothing is deleted or cancelled; the two runs can be compared.
  if not v_scenario then
    for v_previous in
      select pr.id from erp.planning_run pr
       where pr.tenant_id = v_tenant and pr.site_id = p_site_id
         and not pr.is_scenario and pr.superseded_by_run_id is null
         and pr.id <> v_run
    loop
      update erp.planning_run
         set superseded_by_run_id = v_run, superseded_at = now(), updated_at = now()
       where id = v_previous;
    end loop;
  end if;

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

    -- The scenario's view of this item.
    v_lead := greatest(coalesce(isx.lead_time_days, 0) + v_lt_delta, 0);
    v_rop  := coalesce(isx.reorder_point, 0) * v_rop_mult;

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
                                      current_date + p_horizon_days, v_scenario) s
          union all
          -- Independent demand is scaled by the scenario's multiplier;
          -- dependent demand is not, because it was derived from orders the
          -- multiplier has already scaled.
          select dm.due_on,
                 -dm.quantity * case when dm.source = 'dependent' then 1 else v_mult end,
                 dm.source, dm.document_line_id, dm.forecast_line_id, dm.planned_order_id
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
      if v_proj < v_rop then
        v_qty := case coalesce(pp.lot_sizing, 'lot_for_lot')
                   when 'fixed' then coalesce(pp.fixed_lot_size, 1)
                   when 'order_up_to' then coalesce(isx.order_up_to, 0) - v_proj
                   else coalesce(isx.order_up_to, v_rop, 0) - v_proj
                 end;

        v_qty := greatest(v_qty, coalesce(isx.min_order_quantity, 0));
        if coalesce(isx.order_multiple, 0) > 0 then
          v_qty := ceil(v_qty / isx.order_multiple) * isx.order_multiple;
        end if;

        if v_qty > 0 then
          v_release := d.due_on - v_lead;

          -- Released in the past means the lead time cannot be met. Raising
          -- the order anyway and dating it today would hide that; the
          -- exception is the point.
          if v_release < current_date then
            insert into erp.planning_exception (
              tenant_id, entity_id, site_id, item_id, exception_kind, severity,
              message, detail, planning_run_id)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'lead_time_breach',
                    'high',
                    format('needed on %s, and the lead time of %s days means it '
                           'should have been released on %s',
                           d.due_on, v_lead, v_release),
                    jsonb_build_object('required_by', d.due_on,
                                       'release_on', v_release,
                                       'shortfall', v_rop - v_proj),
                    v_run);
            v_excs := v_excs + 1;
            v_release := current_date;
          end if;

          if v_release <= v_fence then
            -- Inside the fence. Recorded as an exception for a planner rather
            -- than acted on, because the fence exists precisely so that this
            -- decision is a person's.
            insert into erp.planning_exception (
              tenant_id, entity_id, site_id, item_id, exception_kind, severity,
              message, detail, planning_run_id)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'expedite', 'high',
                    'a shortage inside the planning time fence needs a decision',
                    jsonb_build_object('required_by', d.due_on, 'quantity', v_qty),
                    v_run);
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
        message, detail, planning_run_id)
      values (v_tenant, v_entity, p_site_id, r.item_id, 'excess', 'medium',
              'projected stock at the end of the horizon is more than twice the '
              'order-up-to level',
              jsonb_build_object('projected', v_proj, 'order_up_to', isx.order_up_to),
              v_run);
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
      tenant_id, entity_id, site_id, item_id, exception_kind, severity, message, detail,
      planning_run_id)
    values (v_tenant, v_entity, p_site_id, c.item_id, 'no_supply_source', 'high',
            format('a bill of materials needs %s of this component by %s and nothing '
                   'plans it at this site; give it a stocked item-site row with a '
                   'planning policy', c.quantity, c.required_by),
            jsonb_build_object('quantity', c.quantity, 'required_by', c.required_by,
                               'planning_run_id', v_run),
            v_run);
    v_excs := v_excs + 1;
  end loop;

  update erp.planning_run
     set finished_at = now(), orders_raised = v_orders, exceptions_raised = v_excs,
         updated_at = now()
   where id = v_run;

  return v_run;
end;
$$;
revoke all on function erp.run_planning(uuid, integer, uuid, text, jsonb, text) from public, anon, authenticated;

-- A scenario order is a comparison, not a plan.
do $$
declare
  v_src    text := pg_get_functiondef('erp.firm_planned_order(uuid,text)'::regprocedure);
  v_needle text := E'  perform erp.authorise(''planning.firm'', po.entity_id, po.site_id, null, ''planned_order'', po.id);\n';
  v_new    text;
begin
  if position(v_needle in v_src) = 0 or position('CLOVEERP_SCENARIO_ORDER_NOT_FIRMED' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.firm_planned_order is not the 20260906133000 body';
  end if;
  v_new := replace(v_src, v_needle, v_needle
    || E'\n  if exists (select 1 from erp.planning_run pr where pr.id = po.planning_run_id and pr.is_scenario) then\n'
    || E'    raise exception ''CLOVEERP_SCENARIO_ORDER_NOT_FIRMED: % was planned by scenario %, which is a comparison, not a plan'',\n'
    || E'      p_planned_order_id, (select pr.scenario_code from erp.planning_run pr where pr.id = po.planning_run_id)\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Run the baseline with the assumption you have decided on, and firm the order it raises.'';\n'
    || E'  end if;\n');
  execute v_new;
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Comparing and listing runs
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.compare_planning_runs(p_run_a uuid, p_run_b uuid)
returns table(item_id uuid, item_code text, item_name text,
              orders_a integer, orders_b integer,
              quantity_a numeric, quantity_b numeric, difference numeric,
              kind_a text, kind_b text,
              first_release_a date, first_release_b date)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  a erp.planning_run%rowtype;
  b erp.planning_run%rowtype;
begin
  select * into a from erp.planning_run pr where pr.tenant_id = v_tenant and pr.id = p_run_a;
  if not found then
    raise exception 'CLOVEERP_PLANNING_RUN_NOT_FOUND: %', p_run_a
      using errcode = '23503', hint = 'Read erp_planning_runs() for the runs this site has.';
  end if;
  select * into b from erp.planning_run pr where pr.tenant_id = v_tenant and pr.id = p_run_b;
  if not found then
    raise exception 'CLOVEERP_PLANNING_RUN_NOT_FOUND: %', p_run_b
      using errcode = '23503', hint = 'Read erp_planning_runs() for the runs this site has.';
  end if;
  if a.site_id is distinct from b.site_id then
    raise exception 'CLOVEERP_RUNS_ARE_FOR_DIFFERENT_SITES: % and % planned different sites', p_run_a, p_run_b
      using errcode = '22023', hint = 'Compare two runs of the same site.';
  end if;

  perform erp.authorise('planning.read', a.entity_id, a.site_id, null, 'site', a.site_id);

  return query
    with pa as (
      select po.item_id, count(*)::integer as n, sum(po.quantity) as q,
             string_agg(distinct po.order_kind::text, ',') as k, min(po.release_on) as rel
        from erp.planned_order po
       where po.tenant_id = v_tenant and po.planning_run_id = p_run_a and po.status <> 'cancelled'
       group by po.item_id
    ),
    pb as (
      select po.item_id, count(*)::integer as n, sum(po.quantity) as q,
             string_agg(distinct po.order_kind::text, ',') as k, min(po.release_on) as rel
        from erp.planned_order po
       where po.tenant_id = v_tenant and po.planning_run_id = p_run_b and po.status <> 'cancelled'
       group by po.item_id
    )
    select i.id, i.code, i.name,
           coalesce(pa.n, 0), coalesce(pb.n, 0),
           coalesce(pa.q, 0), coalesce(pb.q, 0), coalesce(pb.q, 0) - coalesce(pa.q, 0),
           pa.k, pb.k, pa.rel, pb.rel
      from pa full outer join pb on pb.item_id = pa.item_id
      join erp.item i on i.id = coalesce(pa.item_id, pb.item_id)
     order by abs(coalesce(pb.q, 0) - coalesce(pa.q, 0)) desc, i.code;
end;
$$;
revoke all on function erp.compare_planning_runs(uuid, uuid) from public, anon, authenticated;

create or replace function erp.planning_runs(p_site_id uuid default null, p_limit integer default 50)
returns table(run_id uuid, site_code text, started_at timestamptz, finished_at timestamptz,
              horizon_days integer, is_scenario boolean, scenario_code text, label text,
              assumptions jsonb, orders_raised integer, exceptions_raised integer,
              superseded_by_run_id uuid, is_current_baseline boolean)
language sql
stable
set search_path = ''
as $$
  select pr.id, s.code, pr.started_at, pr.finished_at, pr.horizon_days,
         pr.is_scenario, pr.scenario_code, pr.label, pr.assumptions,
         pr.orders_raised, pr.exceptions_raised, pr.superseded_by_run_id,
         (not pr.is_scenario and pr.superseded_by_run_id is null)
    from erp.planning_run pr
    left join erp.site s on s.id = pr.site_id
   where pr.tenant_id = erp.current_tenant_id()
     and (p_site_id is null or pr.site_id = p_site_id)
   order by pr.started_at desc
   limit greatest(p_limit, 1)
$$;
revoke all on function erp.planning_runs(uuid, integer) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Doors
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists public.erp_run_planning(uuid, integer);
create function public.erp_run_planning(p_site_id uuid, p_horizon_days integer default 180,
                                        p_scenario_code text default null,
                                        p_assumptions jsonb default '{}'::jsonb,
                                        p_label text default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.run_planning(p_site_id, coalesce(p_horizon_days, 180), null, p_scenario_code,
                          coalesce(p_assumptions, '{}'::jsonb), p_label)
$$;

create or replace function public.erp_compare_planning_runs(p_run_a uuid, p_run_b uuid)
returns jsonb
language sql
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
    from erp.compare_planning_runs(p_run_a, p_run_b) c
$$;

create or replace function public.erp_planning_runs(p_site_id uuid default null, p_limit integer default 50)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.started_at desc), '[]'::jsonb)
    from erp.planning_runs(p_site_id, p_limit) r
$$;

-- The two listing doors leave a scenario's rows out unless the run is named.
drop function if exists public.erp_planned_orders(uuid, integer);
create function public.erp_planned_orders(p_site_id uuid default null, p_limit integer default 200,
                                          p_planning_run_id uuid default null)
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
      'planning_run_id', po.planning_run_id,
      'scenario_code', pr.scenario_code,
      'pegged_to', (select string_agg(distinct pg.demand_kind, ',')
                      from erp.planned_order_peg pg
                     where pg.tenant_id = po.tenant_id and pg.planned_order_id = po.id)) as x
      from erp.planned_order po
      join erp.item i on i.tenant_id = po.tenant_id and i.id = po.item_id
      left join erp.site s on s.tenant_id = po.tenant_id and s.id = po.site_id
      left join erp.planning_run pr on pr.tenant_id = po.tenant_id and pr.id = po.planning_run_id
     where po.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or po.site_id = p_site_id)
       and (p_planning_run_id is not null and po.planning_run_id = p_planning_run_id
            or p_planning_run_id is null and not coalesce(pr.is_scenario, false))
     order by po.required_by limit greatest(p_limit, 1)) t
$$;

drop function if exists public.erp_planning_exceptions(integer);
create function public.erp_planning_exceptions(p_limit integer default 200, p_planning_run_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'last_seen_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('exception_id', e.id, 'kind', e.exception_kind,
      'severity', e.severity, 'message', e.message, 'item', i.code, 'site', s.code,
      'first_seen_at', e.first_seen_at, 'last_seen_at', e.last_seen_at,
      'acknowledged_at', e.acknowledged_at, 'resolved_at', e.resolved_at,
      'planning_run_id', e.planning_run_id, 'scenario_code', pr.scenario_code) as x
      from erp.planning_exception e
      left join erp.item i on i.tenant_id = e.tenant_id and i.id = e.item_id
      left join erp.site s on s.tenant_id = e.tenant_id and s.id = e.site_id
      left join erp.planning_run pr on pr.tenant_id = e.tenant_id and pr.id = e.planning_run_id
     where e.tenant_id = erp.current_tenant_id() and e.resolved_at is null
       and (p_planning_run_id is not null and e.planning_run_id = p_planning_run_id
            or p_planning_run_id is null and not coalesce(pr.is_scenario, false))
     order by e.last_seen_at desc limit greatest(p_limit, 1)) t
$$;

-- The workbench is the planner's, not the scenario's.
do $$
declare v_src text := pg_get_functiondef('erp.planner_workbench(uuid)'::regprocedure);
begin
  if position('and e.resolved_at is null' in v_src) = 0 or position('is_scenario' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.planner_workbench is not the 20260829260000 body';
  end if;
  execute replace(v_src, 'and e.resolved_at is null',
    E'and e.resolved_at is null\n     and not exists (select 1 from erp.planning_run pr where pr.id = e.planning_run_id and pr.is_scenario)');
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_run_planning(uuid, integer, text, jsonb, text)',
    'erp_compare_planning_runs(uuid, uuid)',
    'erp_planning_runs(uuid, integer)',
    'erp_planned_orders(uuid, integer, uuid)',
    'erp_planning_exceptions(integer, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_run_planning', 'erp.run_planning',
   'Runs planning for a site as a baseline or a named scenario under assumptions; authorises planning.run.'),
  ('erp_compare_planning_runs', 'erp.compare_planning_runs',
   'Compares what two runs of one site planned, per item; authorises planning.read, so it cannot be STABLE.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.planning_run',
                         'erp.run_planning(uuid,integer,uuid,text,jsonb,text)',
                         'erp.scheduled_supply(uuid,uuid,date,date)',
                         'erp.scheduled_supply(uuid,uuid,date,date,boolean)',
                         'erp.scheduled_demand(uuid,uuid,date,date,uuid,uuid)',
                         'erp.supply_demand_position(uuid,uuid,integer)',
                         'erp.compare_planning_runs(uuid,uuid)',
                         'erp.planning_runs(uuid,integer)']
 where code = '5.4.supply_demand';

-- Every other row that named the three-argument run now names the six.
update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.run_planning(uuid,integer,uuid)',
                                            'erp.run_planning(uuid,integer,uuid,text,jsonb,text)')
 where 'erp.run_planning(uuid,integer,uuid)' = any(artefacts);

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.planning_scenario_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid; csl uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_item uuid; v_fc uuid; v_ver uuid;
  v_run1 uuid; v_run2 uuid; v_scn uuid; v_scn2 uuid; v_due date := current_date + 60;
  v_o1 uuid; v_o2 uuid; v_os uuid; v_x jsonb; v_cmp record;
  v_ok boolean; v_msg text;
begin
  begin
    select * into r from erp.provision_tenant('zzpsc', 'Scenario Suite', 'a@zzpsc.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zzpsc.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csl := erp.configure_planning(95, 7);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csl); perform erp.promote_change_set(csl);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;
    insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, planning_policy_code,
                               lead_time_days, min_order_quantity, order_multiple, status)
    values (r.tenant_id, v_item, v_site, true, 'standard', 14, 0, 10, 'active');

    insert into erp.forecast (tenant_id, code, name, entity_id, site_id, bucket, status)
    values (r.tenant_id, 'SCN-M', 'Scenario monthly', r.entity_id, v_site, 'month', 'active')
    returning id into v_fc;
    insert into erp.forecast_version (tenant_id, forecast_id, version, method, parameters, status,
                                      horizon_from, horizon_to, note)
    values (r.tenant_id, v_fc, 1, 'manual', '{}'::jsonb, 'active', current_date, current_date + 180,
            'written by the scenario suite')
    returning id into v_ver;
    insert into erp.forecast_line (tenant_id, forecast_version_id, item_id, site_id, bucket_start, quantity, uom_id)
    values (r.tenant_id, v_ver, v_item, v_site, v_due, 100, v_uom);

    -- Two baselines, nothing changed between them.
    v_run1 := erp.run_planning(v_site, 180);
    select po.id into v_o1 from erp.planned_order po where po.planning_run_id = v_run1;
    v_run2 := erp.run_planning(v_site, 180);
    select po.id into v_o2 from erp.planned_order po where po.planning_run_id = v_run2;

    return query select 'a baseline supersedes the previous baseline explicitly and keeps its orders',
      v_o1 is not null and v_o2 is not null
      and (select pr.superseded_by_run_id from erp.planning_run pr where pr.id = v_run1) = v_run2
      and (select pr.superseded_by_run_id from erp.planning_run pr where pr.id = v_run2) is null
      and (select po.status::text from erp.planned_order po where po.id = v_o1) = 'suggested'
      and (select po.quantity from erp.planned_order po where po.id = v_o2) = 100
      and (select count(*) from erp.scheduled_supply(v_item, v_site, current_date, current_date + 180) s
            where s.source = 'planned_order') = 1
      and (select bool_and(x.run_id in (v_run1, v_run2)) from erp.planning_runs(v_site, 10) x)
      and (select x.is_current_baseline from erp.planning_runs(v_site, 10) x where x.run_id = v_run2),
      'the second run planned the same hundred; the first is history, not supply';

    v_scn := erp.run_planning(v_site, 180, null, 'DOUBLE', '{"demand_multiplier": 2}'::jsonb, 'Demand doubles');
    select po.id into v_os from erp.planned_order po where po.planning_run_id = v_scn;
    return query select 'a scenario plans under its assumption and says it is one',
      v_os is not null
      and (select po.quantity from erp.planned_order po where po.id = v_os) = 200
      and (select pr.is_scenario from erp.planning_run pr where pr.id = v_scn)
      and (select pr.label from erp.planning_run pr where pr.id = v_scn) = 'Demand doubles'
      and (select pr.superseded_by_run_id from erp.planning_run pr where pr.id = v_run2) is null,
      'DOUBLE planned two hundred and left the baseline alone';

    return query select 'a scenario''s orders never feed supply, and the listing leaves them out',
      (select count(*) from erp.scheduled_supply(v_item, v_site, current_date, current_date + 180) s
        where s.source = 'planned_order') = 1
      and jsonb_array_length(public.erp_planned_orders(v_site, 200)) = 2
      and jsonb_array_length(public.erp_planned_orders(v_site, 200, v_scn)) = 1
      and public.erp_planned_orders(v_site, 200, v_scn) -> 0 ->> 'scenario_code' = 'DOUBLE',
      'one supply row; the baseline history lists two orders, the scenario one';

    begin
      perform erp.firm_planned_order(v_os, 'purchase_order');
      v_ok := false; v_msg := 'firmed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SCENARIO_ORDER_NOT_FIRMED:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a scenario order cannot be firmed', v_ok, v_msg;

    begin
      perform erp.run_planning(v_site, 180, null, 'ODD', '{"weather": "wet"}'::jsonb);
      v_ok := false; v_msg := 'ran';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_ASSUMPTION: weather%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'an assumption the run cannot honour is refused by name', v_ok, v_msg;

    begin
      perform erp.run_planning(v_site, 180, null, null, '{"demand_multiplier": 2}'::jsonb);
      v_ok := false; v_msg := 'ran';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BASELINE_TAKES_NO_ASSUMPTIONS:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a baseline takes no assumptions', v_ok, v_msg;

    select * into v_cmp from erp.compare_planning_runs(v_run2, v_scn);
    return query select 'two runs compare per item, with the difference',
      v_cmp.item_code = 'WID' and v_cmp.quantity_a = 100 and v_cmp.quantity_b = 200
      and v_cmp.difference = 100 and v_cmp.orders_a = 1 and v_cmp.orders_b = 1
      and jsonb_array_length(public.erp_compare_planning_runs(v_run2, v_scn)) = 1,
      'WID: 100 in the baseline, 200 under DOUBLE, +100';

    v_scn2 := erp.run_planning(v_site, 180, null, 'SLOW', '{"lead_time_days_delta": 10, "reorder_point_multiplier": 1}'::jsonb);
    return query select 'a lead-time assumption moves the release earlier',
      (select po.release_on from erp.planned_order po where po.planning_run_id = v_scn2) = v_due - 24
      and (select po.release_on from erp.planned_order po where po.id = v_o2) = v_due - 14
      and (select count(*) from erp.planning_exception e where e.planning_run_id = v_scn2) = 0,
      format('baseline releases %s, SLOW releases %s', v_due - 14, v_due - 24);

    return query select 'the register says supply and demand reconciliation is built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.4.supply_demand') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.4.supply_demand')
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.4.mrp'),
      '5.4.supply_demand';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzpsc');
  detail := 'the organisation and its four runs rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_planning_scenario_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _planning_scenario on commit drop as
    select * from erp_test.planning_scenario_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _planning_scenario;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PLANNING_SCENARIO_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_PLANNING_SCENARIO_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('planning scenarios: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_planning_scenario_suite() from public, anon, authenticated;
revoke all on function erp_test.planning_scenario_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_planning_scenario_suite();
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
