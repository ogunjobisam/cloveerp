-- =============================================================================
-- ERPWare — Part 5.5: production
--
-- B7 built product structures and routings — erp.bom, erp.bom_line with scrap
-- factors and alternates and phantoms, erp.routing, erp.routing_operation with
-- setup and run times and cost rates. Nothing writes any of them, and there is
-- no works order at all, so none of it has ever been used to make anything.
--
-- What spec 5.5 asks for, in order, and what was there:
--
--   product structures and routings with engineering
--     change control                                  tables, no control
--   works orders of multiple types                    nothing
--   material availability checking and commitment     nothing
--   component issue by backflush, manual or scanned   nothing
--   execution progress, scrap and time capture        nothing
--   finished goods receipt with batch creation and
--     derived attributes                              nothing
--   electronic batch records from execution events    nothing
--   standard cost roll-up and actual cost capture
--     with variance analysis                          nothing
--
-- This is the largest genuinely absent area in the product, and the one where
-- getting the ledger right matters most: a works order consumes components and
-- produces finished goods, so every one of them is two stock movements and a
-- journal, and the difference between what it should have cost and what it did
-- is the variance analysis the specification asks for by name.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Engineering change control
--
-- Spec 5.5 asks for it on the structures themselves. A bill of materials that
-- can be edited in place is one where nobody can say what a batch made last
-- March was actually made of — and in a business with batch traceability that
-- is the whole reason the traceability exists.
--
-- So the version in force is immutable once anything has been made against it.
-- Changing it means a new version, and the works order records which version it
-- used.
-- -----------------------------------------------------------------------------

create or replace function erp.guard_bom_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bom uuid := coalesce(new.bom_id, old.bom_id);
  v_used integer;
begin
  if nullif(current_setting('erp.purge_tenant_id', true), '') is not null then
    return coalesce(new, old);
  end if;

  select count(*) into v_used
    from erp.works_order wo
   where wo.bom_id = v_bom and wo.status <> 'draft';

  if v_used > 0 then
    raise exception
      'ERPWARE_BOM_IN_USE: % works order(s) have been raised against this bill '
      'of materials; supersede it with a new version rather than editing it',
      v_used
      using errcode = '42501',
      hint = 'A bill of materials that can be edited in place is one where '
             'nobody can say what a batch made last March was made of.';
  end if;

  return coalesce(new, old);
end;
$$;

-- -----------------------------------------------------------------------------
-- Works orders
-- -----------------------------------------------------------------------------

create type erp.works_order_kind as enum
  ('assembly', 'kitting', 'rework', 'repackaging', 'disassembly');

create type erp.works_order_status as enum
  ('draft', 'planned', 'released', 'in_progress', 'completed', 'closed', 'cancelled');

create type erp.issue_method as enum ('backflush', 'manual', 'scanned');

create table if not exists erp.works_order (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid not null,
  site_id      uuid not null,
  order_number text,
  order_kind   erp.works_order_kind not null default 'assembly',
  item_id      uuid not null,
  bom_id       uuid,
  routing_id   uuid,
  quantity     numeric(20,6) not null check (quantity > 0),
  quantity_completed numeric(20,6) not null default 0,
  quantity_scrapped  numeric(20,6) not null default 0,
  uom_id       uuid not null,
  output_batch_id uuid,
  issue_method erp.issue_method not null default 'backflush',
  planned_start date,
  planned_end   date,
  actual_start  timestamptz,
  actual_end    timestamptz,
  status       erp.works_order_status not null default 'draft',
  planned_order_id uuid,
  -- What it should have cost, frozen when the order was released, so the
  -- variance at the end is against the standard that applied at the time
  -- rather than against whatever the standard is now.
  standard_cost_minor bigint,
  actual_cost_minor   bigint,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, order_number),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, bom_id) references erp.bom (tenant_id, id) on delete restrict,
  foreign key (tenant_id, routing_id) references erp.routing (tenant_id, id) on delete restrict,
  foreign key (tenant_id, output_batch_id) references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, planned_order_id)
    references erp.planned_order (tenant_id, id) on delete set null,
  constraint works_order_completion check (quantity_completed >= 0 and quantity_scrapped >= 0)
);

create index if not exists works_order_open
  on erp.works_order (tenant_id, site_id, status)
  where status in ('planned', 'released', 'in_progress');

-- What the order needs, exploded from the bill at the moment it was raised.
-- Exploded rather than derived on demand, because the bill may be superseded
-- while the order is running and what it needs must not change underneath it.
create table if not exists erp.works_order_component (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  works_order_id uuid not null,
  seq          integer not null,
  item_id      uuid not null,
  required_quantity numeric(20,6) not null,
  issued_quantity   numeric(20,6) not null default 0,
  uom_id       uuid not null,
  scrap_factor numeric(10,6) not null default 0,
  is_phantom   boolean not null default false,
  batch_id     uuid,
  location_id  uuid,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, works_order_id, seq),
  foreign key (tenant_id, works_order_id)
    references erp.works_order (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete restrict
);

create table if not exists erp.works_order_operation (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  works_order_id uuid not null,
  seq          integer not null,
  code         text not null,
  name         text,
  work_centre_code text,
  planned_setup_minutes numeric(20,6) not null default 0,
  planned_run_minutes   numeric(20,6) not null default 0,
  actual_minutes        numeric(20,6) not null default 0,
  cost_rate_minor_per_hour bigint not null default 0,
  quantity_completed numeric(20,6) not null default 0,
  quantity_scrapped  numeric(20,6) not null default 0,
  is_milestone boolean not null default false,
  completed_at timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, works_order_id, seq),
  foreign key (tenant_id, works_order_id)
    references erp.works_order (tenant_id, id) on delete cascade
);

-- Spec 5.5: "electronic batch records assembled from execution events". The
-- record is not a document somebody writes at the end; it is the events
-- themselves, in order, which is the only version of it that can be trusted.
create table if not exists erp.production_event (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  works_order_id uuid not null,
  operation_seq integer,
  occurred_at  timestamptz not null default clock_timestamp(),
  event_kind   text not null
                 check (event_kind in ('released', 'started', 'issued', 'completed',
                                       'scrapped', 'time_booked', 'deviation',
                                       'output_received', 'closed')),
  item_id      uuid,
  batch_id     uuid,
  quantity     numeric(20,6),
  minutes      numeric(20,6),
  detail       jsonb not null default '{}'::jsonb,
  actor_id     uuid,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  foreign key (tenant_id, works_order_id)
    references erp.works_order (tenant_id, id) on delete cascade
);

create index if not exists production_event_order
  on erp.production_event (tenant_id, works_order_id, occurred_at);

create trigger t_bom_line_change_control
  before insert or update or delete on erp.bom_line
  for each row execute function erp.guard_bom_change();

-- -----------------------------------------------------------------------------
-- Raising a works order
--
-- The bill is exploded here rather than read as the order runs. A bill that is
-- superseded mid-run must not change what the order in progress needs, and
-- deriving the components on demand would mean exactly that.
--
-- Phantoms are exploded through: a phantom assembly is a level in the bill that
-- is never stocked, so its components belong on this order rather than on one
-- of its own. Not exploding them is how a works order comes to need a
-- subassembly nobody makes.
-- -----------------------------------------------------------------------------

create or replace function erp.raise_works_order(
  p_item_id  uuid,
  p_site_id  uuid,
  p_quantity numeric,
  p_kind     erp.works_order_kind default 'assembly',
  p_planned_end date default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_bom    erp.bom%rowtype;
  v_rout   erp.routing%rowtype;
  v_wo     uuid;
  v_uom    uuid;
  v_seq    integer := 0;
  r        record;
  v_number text;
begin
  perform erp.authorise('production.order', null, p_site_id, null, 'item', p_item_id);

  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id;

  select * into v_bom from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id
     and b.status = 'active'
     and (b.site_id is null or b.site_id = p_site_id)
     and b.effective_from <= current_date
     and (b.effective_to is null or b.effective_to > current_date)
   order by (b.site_id is not null) desc, b.version desc
   limit 1;

  if not found then
    raise exception
      'ERPWARE_NO_BILL_OF_MATERIALS: nothing says what % is made of', p_item_id
      using errcode = '23503';
  end if;

  select * into v_rout from erp.routing rt
   where rt.tenant_id = v_tenant and rt.item_id = p_item_id
     and rt.status = 'active'
     and (rt.site_id is null or rt.site_id = p_site_id)
     and rt.effective_from <= current_date
     and (rt.effective_to is null or rt.effective_to > current_date)
   order by (rt.site_id is not null) desc, rt.version desc
   limit 1;

  select i.stock_uom_id into v_uom from erp.item i where i.id = p_item_id;

  -- The same numbering machinery documents use. A works order number that
  -- comes from somewhere else is one that collides with nothing and means
  -- nothing to anybody reading a batch record.
  select erp.next_document_number(n.id) into v_number
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'works_order';

  if v_number is null then
    raise exception
      'ERPWARE_NO_WORKS_ORDER_NUMBERING: configure production before raising one'
      using errcode = '23503',
      hint = 'erp.configure_production() installs the numbering rule.';
  end if;

  insert into erp.works_order (
    tenant_id, entity_id, site_id, order_number, order_kind, item_id,
    bom_id, routing_id, quantity, uom_id, planned_end, issue_method, status)
  values (v_tenant, v_entity, p_site_id, v_number, p_kind, p_item_id,
          v_bom.id, v_rout.id, p_quantity, v_uom,
          coalesce(p_planned_end, current_date),
          -- From the promoted setting, resolved at this site. Reading the
          -- column default instead would make the configuration a setting
          -- nothing consults, which is the defect this whole build keeps
          -- finding one table at a time.
          coalesce(
            (erp.config_value('production.issue_method', null, null,
                              v_entity, p_site_id) #>> '{}')::erp.issue_method,
            'backflush'),
          'draft')
  returning id into v_wo;

  -- The explosion. Recursive through phantoms, bounded, and scaled by the
  -- bill's own output quantity and yield — a bill that makes ten of something
  -- from a hundred components needs ten components per unit, not a hundred.
  for r in
    with recursive explode as (
      -- Cast to unqualified numeric: the recursive term multiplies two
      -- numeric(20,6) values and the result is plain numeric, which must match
      -- the anchor's type exactly.
      select bl.component_item_id, bl.quantity::numeric, bl.uom_id,
             bl.scrap_factor, bl.is_phantom, 1 as depth
        from erp.bom_line bl
       where bl.tenant_id = v_tenant and bl.bom_id = v_bom.id
         and not bl.is_alternate
      union all
      select bl.component_item_id,
             (e.quantity * bl.quantity)::numeric, bl.uom_id, bl.scrap_factor,
             bl.is_phantom, e.depth + 1
        from explode e
        join erp.bom cb on cb.tenant_id = v_tenant
                       and cb.item_id = e.component_item_id
                       and cb.status = 'active'
        join erp.bom_line bl on bl.tenant_id = v_tenant and bl.bom_id = cb.id
                            and not bl.is_alternate
       where e.is_phantom and e.depth < 10
    )
    select * from explode where not is_phantom order by depth, component_item_id
  loop
    v_seq := v_seq + 10;
    insert into erp.works_order_component (
      tenant_id, works_order_id, seq, item_id, required_quantity, uom_id,
      scrap_factor, is_phantom)
    values (v_tenant, v_wo, v_seq, r.component_item_id,
            -- Scrap factor is a loss allowance: making a hundred at two per
            -- cent scrap needs a hundred and two units of component, not
            -- ninety-eight.
            round(p_quantity * r.quantity / coalesce(nullif(v_bom.output_quantity, 0), 1)
                  / coalesce(nullif(v_bom.yield_factor, 0), 1)
                  * (1 + coalesce(r.scrap_factor, 0)), 6),
            coalesce(r.uom_id, v_uom), coalesce(r.scrap_factor, 0), false);
  end loop;

  if v_seq = 0 then
    raise exception
      'ERPWARE_EMPTY_BILL_OF_MATERIALS: % has a bill with no components',
      v_bom.code using errcode = '23514';
  end if;

  if v_rout.id is not null then
    insert into erp.works_order_operation (
      tenant_id, works_order_id, seq, code, name, work_centre_code,
      planned_setup_minutes, planned_run_minutes, cost_rate_minor_per_hour,
      is_milestone)
    select v_tenant, v_wo, ro.seq, ro.code, ro.name, ro.work_centre_code,
           coalesce(ro.setup_minutes, 0),
           coalesce(ro.run_minutes_per_unit, 0) * p_quantity,
           coalesce(ro.cost_rate_minor_per_hour, 0),
           coalesce(ro.is_milestone, false)
      from erp.routing_operation ro
     where ro.tenant_id = v_tenant and ro.routing_id = v_rout.id
     order by ro.seq;
  end if;

  return v_wo;
end;
$$;

comment on function erp.raise_works_order(uuid, uuid, numeric, erp.works_order_kind, date) is
  'Explodes the bill in force onto the order, through phantoms and scaled by '
  'output quantity, yield and scrap. Exploded rather than derived, so a bill '
  'superseded mid-run cannot change what an order in progress needs.';

-- -----------------------------------------------------------------------------
-- Material availability, and committing it
--
-- Spec 5.5: "material availability checking and commitment". The check without
-- the commitment is worthless — two orders both told there is enough, both
-- released, and the second one finds an empty shelf.
-- -----------------------------------------------------------------------------

create or replace function erp.works_order_availability(p_works_order_id uuid)
returns table (item_id uuid, item_code text, required numeric,
               on_hand numeric, committed_elsewhere numeric,
               available numeric, shortfall numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.item_id, i.code,
         c.required_quantity - c.issued_quantity,
         coalesce((select sum(b.quantity) from erp.stock_balance b
                    where b.tenant_id = c.tenant_id and b.item_id = c.item_id
                      and b.site_id = wo.site_id), 0),
         coalesce((select sum(a.quantity) from erp.allocation a
                    where a.tenant_id = c.tenant_id and a.item_id = c.item_id
                      and a.site_id = wo.site_id
                      and a.status in ('reserved', 'committed')
                      and a.document_id is distinct from wo.id), 0),
         coalesce((select sum(b.quantity) from erp.stock_balance b
                    where b.tenant_id = c.tenant_id and b.item_id = c.item_id
                      and b.site_id = wo.site_id), 0)
         - coalesce((select sum(a.quantity) from erp.allocation a
                      where a.tenant_id = c.tenant_id and a.item_id = c.item_id
                        and a.site_id = wo.site_id
                        and a.status in ('reserved', 'committed')
                        and a.document_id is distinct from wo.id), 0),
         greatest(0,
           (c.required_quantity - c.issued_quantity)
           - (coalesce((select sum(b.quantity) from erp.stock_balance b
                         where b.tenant_id = c.tenant_id and b.item_id = c.item_id
                           and b.site_id = wo.site_id), 0)
              - coalesce((select sum(a.quantity) from erp.allocation a
                           where a.tenant_id = c.tenant_id and a.item_id = c.item_id
                             and a.site_id = wo.site_id
                             and a.status in ('reserved', 'committed')
                             and a.document_id is distinct from wo.id), 0)))
    from erp.works_order_component c
    join erp.works_order wo on wo.id = c.works_order_id
    join erp.item i on i.id = c.item_id
   where c.tenant_id = erp.current_tenant_id()
     and c.works_order_id = p_works_order_id
   order by 7 desc, i.code
$$;

create or replace function erp.release_works_order(
  p_works_order_id uuid,
  p_allow_shortage boolean default false
) returns erp.works_order_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
  v_short  text;
  r        record;
  v_std    bigint := 0;
  v_cost   bigint;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  if wo.status not in ('draft', 'planned') then
    raise exception 'ERPWARE_WORKS_ORDER_NOT_RELEASABLE: % is %',
      wo.order_number, wo.status using errcode = '23514';
  end if;

  perform erp.authorise('production.release', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  select string_agg(format('%s short by %s', a.item_code, a.shortfall), '; ')
    into v_short
    from erp.works_order_availability(p_works_order_id) a
   where a.shortfall > 0;

  if v_short is not null and not p_allow_shortage then
    raise exception 'ERPWARE_MATERIAL_SHORTAGE: %', v_short
      using errcode = '23514',
      hint = 'Release with the shortage acknowledged if the material is coming, '
             'or plan it in. Releasing quietly is how a line stops mid-shift.';
  end if;

  -- Commitment, not merely a check. Two orders both told there is enough and
  -- both released is how the second one finds an empty shelf.
  for r in select * from erp.works_order_component
            where tenant_id = v_tenant and works_order_id = p_works_order_id
  loop
    insert into erp.allocation (
      tenant_id, entity_id, site_id, item_id, demand_kind, quantity, uom_id,
      status, required_by)
    values (v_tenant, wo.entity_id, wo.site_id, r.item_id, 'works_order',
            r.required_quantity - r.issued_quantity, r.uom_id, 'committed',
            wo.planned_end);

    -- What it should cost, frozen now. Comparing the finished order against
    -- today's standard rather than the one that applied when it was released
    -- measures the standard changing, not the order.
    select c.unit_cost_minor into v_cost from erp.item_cost c
     where c.tenant_id = v_tenant and c.item_id = r.item_id
       and c.site_id is not distinct from wo.site_id;
    v_std := v_std + round(coalesce(v_cost, 0) * r.required_quantity)::bigint;
  end loop;

  select v_std + coalesce(sum(round((o.planned_setup_minutes + o.planned_run_minutes)
                                    / 60.0 * o.cost_rate_minor_per_hour)), 0)
    into v_std
    from erp.works_order_operation o
   where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id;

  update erp.works_order
     set status = 'released', standard_cost_minor = v_std, updated_at = now()
   where id = p_works_order_id;

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, detail, actor_id)
  values (v_tenant, p_works_order_id, 'released',
          jsonb_build_object('standard_cost_minor', v_std,
                             'shortage_acknowledged', v_short is not null),
          erp.current_principal_id());

  return 'released'::erp.works_order_status;
end;
$$;

-- -----------------------------------------------------------------------------
-- Execution
--
-- Three ways of issuing components, which spec 5.5 names: backflush (issue
-- automatically in proportion to what was completed), manual (somebody says
-- what went in), and scanned (the same, with the batch identified at the point
-- of use). The difference that matters is not the input mechanism — it is that
-- backflush computes the quantity and the other two are told it, and a system
-- that treats a scanned quantity as a suggestion is one where the batch record
-- is fiction.
-- -----------------------------------------------------------------------------

-- Which batch a backflush consumes. Spec 5.5: "policy-driven batch selection".
--
-- The policy is the item's, and B7 has carried it since it was written:
-- erp.item.is_fefo says whether the earliest-expiring batch goes first. Where
-- it does not, the oldest received does, which is what first-in-first-out means
-- for a component nobody is dating.
create or replace function erp.select_batch_for_issue(
  p_item_id uuid,
  p_site_id uuid
) returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select b.batch_id
    from erp.stock_balance b
    join erp.item i on i.id = b.item_id
    left join erp.batch bt on bt.id = b.batch_id
   where b.tenant_id = erp.current_tenant_id()
     and b.item_id = p_item_id
     and b.site_id = p_site_id
     and b.stock_status = 'available'
     and b.quantity > 0
     and (not i.is_batch_controlled or b.batch_id is not null)
   order by case when i.is_fefo then bt.expires_on end nulls last,
            bt.manufactured_on nulls last,
            b.quantity desc
   limit 1
$$;

create or replace function erp.issue_to_works_order(
  p_works_order_id uuid,
  p_component_item_id uuid,
  p_quantity numeric,
  p_batch_id uuid default null,
  p_location_id uuid default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
  c        erp.works_order_component%rowtype;
  v_cost   bigint;
  v_loc    uuid;
  v_id     bigint;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  if wo.status not in ('released', 'in_progress') then
    raise exception
      'ERPWARE_WORKS_ORDER_NOT_RUNNING: % is %, and material is not issued to '
      'an order that has not started', wo.order_number, wo.status
      using errcode = '23514';
  end if;

  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  select * into c from erp.works_order_component
   where tenant_id = v_tenant and works_order_id = p_works_order_id
     and item_id = p_component_item_id for update;

  if not found then
    raise exception
      'ERPWARE_NOT_A_COMPONENT: % is not on this order''s bill', p_component_item_id
      using errcode = '23503',
      hint = 'Issuing something the bill does not name means the batch record '
             'and the product disagree about what is in it.';
  end if;

  -- Where the stock actually is, not the despatch bay. The generic outbound
  -- default is right for a customer despatch and wrong here: components are
  -- picked from wherever they are held, and defaulting to the despatch
  -- location refuses every issue with a negative-stock error that has nothing
  -- to do with there being no stock.
  v_loc := coalesce(
    p_location_id, c.location_id,
    (select isx.default_location_id from erp.item_site isx
      where isx.tenant_id = v_tenant and isx.item_id = p_component_item_id
        and isx.site_id = wo.site_id and isx.default_location_id is not null),
    (select b.location_id from erp.stock_balance b
      where b.tenant_id = v_tenant and b.item_id = p_component_item_id
        and b.site_id = wo.site_id
        and (p_batch_id is null or b.batch_id = p_batch_id)
        and b.stock_status = 'available' and b.quantity > 0
      order by b.quantity desc limit 1));

  if v_loc is null then
    raise exception
      'ERPWARE_NO_COMPONENT_STOCK: nothing of % is available at this site',
      p_component_item_id
      using errcode = '23503',
      hint = 'Issue names a location, and there is no location holding this '
             'component to default to.';
  end if;

  v_cost := erp.issue_cost(p_component_item_id, wo.site_id, p_quantity);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code)
  values (v_tenant, wo.entity_id, wo.site_id, 'production_issue',
          p_component_item_id, p_batch_id, v_loc, 'available', p_quantity,
          c.uom_id, v_cost,
          coalesce((select e.base_currency from erp.entity e
                     where e.tenant_id = v_tenant limit 1), 'GBP'),
          wo.order_number)
  returning id into v_id;

  update erp.works_order_component
     set issued_quantity = issued_quantity + p_quantity, updated_at = now()
   where id = c.id;

  update erp.works_order
     set status = case when status = 'released'
                       then 'in_progress'::erp.works_order_status else status end,
         actual_start = coalesce(actual_start, now()),
         updated_at = now()
   where id = p_works_order_id;

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, item_id, batch_id, quantity,
    detail, actor_id)
  values (v_tenant, p_works_order_id, 'issued', p_component_item_id, p_batch_id,
          p_quantity,
          jsonb_build_object('unit_cost_minor', v_cost,
                             'method', wo.issue_method::text),
          erp.current_principal_id());

  return v_id;
end;
$$;

create or replace function erp.book_operation_time(
  p_works_order_id uuid,
  p_operation_seq  integer,
  p_minutes        numeric,
  p_completed      numeric default 0,
  p_scrapped       numeric default 0
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  update erp.works_order_operation
     set actual_minutes = actual_minutes + p_minutes,
         quantity_completed = quantity_completed + p_completed,
         quantity_scrapped = quantity_scrapped + p_scrapped,
         completed_at = case when p_completed > 0 then now() else completed_at end,
         updated_at = now()
   where tenant_id = v_tenant and works_order_id = p_works_order_id
     and seq = p_operation_seq;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_OPERATION: % on %', p_operation_seq, wo.order_number
      using errcode = '23503';
  end if;

  insert into erp.production_event (
    tenant_id, works_order_id, operation_seq, event_kind, quantity, minutes,
    actor_id)
  values (v_tenant, p_works_order_id, p_operation_seq, 'time_booked',
          p_completed, p_minutes, erp.current_principal_id());

  if p_scrapped > 0 then
    insert into erp.production_event (
      tenant_id, works_order_id, operation_seq, event_kind, quantity, actor_id)
    values (v_tenant, p_works_order_id, p_operation_seq, 'scrapped', p_scrapped,
            erp.current_principal_id());
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Finished goods, with the batch the specification asks for
--
-- Spec 5.5: "finished goods receipt with batch creation and derived
-- attributes". Derived is the operative word: a batch made today from
-- components that expire in a fortnight does not have a twelve-month shelf life
-- whatever the item master says, and a system that stamps the item's default is
-- one that will ship expired product with a valid-looking date on it.
-- -----------------------------------------------------------------------------

create or replace function erp.receive_works_order_output(
  p_works_order_id uuid,
  p_quantity       numeric,
  p_batch_number   text default null,
  p_location_id    uuid default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  wo        erp.works_order%rowtype;
  it        erp.item%rowtype;
  v_batch   uuid;
  v_expires date;
  v_derived date;
  v_loc     uuid;
  v_cost    bigint;
  v_issued  bigint;
  v_labour  bigint;
  r         record;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  if wo.status not in ('released', 'in_progress') then
    raise exception 'ERPWARE_WORKS_ORDER_NOT_RUNNING: % is %',
      wo.order_number, wo.status using errcode = '23514';
  end if;

  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  select * into it from erp.item where tenant_id = v_tenant and id = wo.item_id;

  -- Backflush: what was completed decides what was consumed. Doing this before
  -- the output movement means an order that cannot be backflushed (not enough
  -- component stock) fails before it has produced anything.
  if wo.issue_method = 'backflush' then
    for r in select * from erp.works_order_component
              where tenant_id = v_tenant and works_order_id = p_works_order_id
    loop
      perform erp.issue_to_works_order(
        p_works_order_id, r.item_id,
        round(r.required_quantity * p_quantity / wo.quantity, 6),
        -- Policy-driven batch selection, which spec 5.5 asks for by name. The
        -- policy is the item's own: first-expiring-first-out where it says so,
        -- oldest received otherwise. A backflush that cannot name a batch on a
        -- batch-controlled component is a batch record with a hole in it.
        erp.select_batch_for_issue(r.item_id, wo.site_id));
    end loop;
  end if;

  if it.is_batch_controlled then
    v_expires := case when it.shelf_life_days is not null
                      then current_date + it.shelf_life_days end;

    -- The derived attribute. The earliest expiry among the components that
    -- went in caps the output's own: a batch cannot outlive what it is made of.
    select min(b.expires_on) into v_derived
      from erp.production_event pe
      join erp.batch b on b.id = pe.batch_id
     where pe.tenant_id = v_tenant and pe.works_order_id = p_works_order_id
       and pe.event_kind = 'issued' and b.expires_on is not null;

    if v_derived is not null then
      v_expires := least(coalesce(v_expires, v_derived), v_derived);
    end if;

    insert into erp.batch (
      tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (v_tenant, wo.item_id,
            coalesce(p_batch_number, wo.order_number || '-' ||
                     to_char(clock_timestamp(), 'HH24MISS')),
            'quarantine', current_date, v_expires)
    returning id into v_batch;
  end if;

  -- What it actually cost: the components issued plus the time booked. The
  -- output is valued at that, which is what makes the variance at close real
  -- rather than an assumption.
  select coalesce(sum(round(m.quantity * m.unit_cost_minor)), 0)::bigint
    into v_issued
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.reason_code = wo.order_number
     and m.movement_type = 'production_issue' and not m.is_reversal;

  select coalesce(sum(round(o.actual_minutes / 60.0 * o.cost_rate_minor_per_hour)), 0)::bigint
    into v_labour
    from erp.works_order_operation o
   where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id;

  v_cost := case when p_quantity > 0
                 then round((v_issued + v_labour) / p_quantity)::bigint else 0 end;

  v_loc := coalesce(p_location_id,
                    erp.default_posting_location(wo.site_id, 'in'));

  perform erp.receive_cost(wo.item_id, wo.site_id, p_quantity, v_cost,
                           coalesce((select e.base_currency from erp.entity e
                                      where e.tenant_id = v_tenant limit 1), 'GBP'),
                           v_batch, null);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code)
  values (v_tenant, wo.entity_id, wo.site_id, 'production_output', wo.item_id,
          v_batch, v_loc,
          -- Straight into quarantine where the item says so. A finished good
          -- that must be released before it ships and is receipted as
          -- available can be picked before anybody has looked at it.
          case when it.quarantine_on_receipt then 'quarantine'::erp.stock_status
               else 'available'::erp.stock_status end,
          p_quantity, wo.uom_id, v_cost,
          coalesce((select e.base_currency from erp.entity e
                     where e.tenant_id = v_tenant limit 1), 'GBP'),
          wo.order_number);

  update erp.works_order
     set quantity_completed = quantity_completed + p_quantity,
         output_batch_id = coalesce(output_batch_id, v_batch),
         actual_cost_minor = v_issued + v_labour,
         status = case when quantity_completed + p_quantity >= quantity
                       then 'completed'::erp.works_order_status
                       else 'in_progress'::erp.works_order_status end,
         actual_end = case when quantity_completed + p_quantity >= quantity
                           then now() end,
         updated_at = now()
   where id = p_works_order_id;

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, item_id, batch_id, quantity,
    detail, actor_id)
  values (v_tenant, p_works_order_id, 'output_received', wo.item_id, v_batch,
          p_quantity,
          jsonb_build_object('unit_cost_minor', v_cost,
                             'expires_on', v_expires,
                             'expiry_derived_from_components', v_derived is not null),
          erp.current_principal_id());

  -- Genealogy: which component batches went into which output batch. This is
  -- what a recall reads, and it is assembled from the events rather than
  -- written by hand.
  if v_batch is not null then
    insert into erp.batch_genealogy (
      tenant_id, parent_batch_id, child_batch_id, quantity, occurred_at)
    select distinct v_tenant, pe.batch_id, v_batch, pe.quantity, clock_timestamp()
      from erp.production_event pe
     where pe.tenant_id = v_tenant and pe.works_order_id = p_works_order_id
       and pe.event_kind = 'issued' and pe.batch_id is not null
    on conflict do nothing;
  end if;

  return v_batch;
end;
$$;

comment on function erp.receive_works_order_output(uuid, numeric, text, uuid) is
  'Spec 5.5: finished goods receipt with batch creation and derived attributes. '
  'The output batch cannot outlive the components it is made of, whatever the '
  'item master''s default shelf life says.';

-- -----------------------------------------------------------------------------
-- Standard cost roll-up, and the variance
--
-- Spec 5.5: "standard cost roll-up and actual cost capture with variance
-- analysis". The roll-up is what the finished item should cost given what it is
-- made of and how long it takes; the variance is the difference between that
-- and what an order actually consumed, split so that "we used more material"
-- and "it took longer" are different answers — which is the only reason to
-- measure it at all.
-- -----------------------------------------------------------------------------

create or replace function erp.roll_up_standard_cost(
  p_item_id uuid,
  p_site_id uuid,
  p_depth   integer default 0
) returns bigint
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_bom    erp.bom%rowtype;
  v_rout   erp.routing%rowtype;
  v_total  bigint := 0;
  r        record;
  v_cost   bigint;
begin
  if p_depth > 10 then
    raise exception
      'ERPWARE_BILL_TOO_DEEP: more than ten levels, which is a cycle rather '
      'than a product' using errcode = '23514';
  end if;

  select * into v_bom from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.status = 'active'
     and (b.site_id is null or b.site_id = p_site_id)
   order by (b.site_id is not null) desc, b.version desc limit 1;

  if not found then
    -- A bought item. Its standard is whatever it costs to buy, which is
    -- exactly what the costing engine already knows.
    select c.unit_cost_minor into v_cost from erp.item_cost c
     where c.tenant_id = v_tenant and c.item_id = p_item_id
       and c.site_id is not distinct from p_site_id;
    return coalesce(v_cost, 0);
  end if;

  for r in
    select bl.component_item_id, bl.quantity, bl.scrap_factor
      from erp.bom_line bl
     where bl.tenant_id = v_tenant and bl.bom_id = v_bom.id and not bl.is_alternate
  loop
    v_total := v_total
      + round(erp.roll_up_standard_cost(r.component_item_id, p_site_id, p_depth + 1)
              * r.quantity * (1 + coalesce(r.scrap_factor, 0)))::bigint;
  end loop;

  select * into v_rout from erp.routing rt
   where rt.tenant_id = v_tenant and rt.item_id = p_item_id and rt.status = 'active'
     and (rt.site_id is null or rt.site_id = p_site_id)
   order by (rt.site_id is not null) desc, rt.version desc limit 1;

  if found then
    select v_total + coalesce(sum(round(
             (coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0))
             / 60.0 * coalesce(ro.cost_rate_minor_per_hour, 0))), 0)
      into v_total
      from erp.routing_operation ro
     where ro.tenant_id = v_tenant and ro.routing_id = v_rout.id;
  end if;

  -- Divided by what the bill makes, and by its yield. A bill that makes ten
  -- from a hundred pounds of material makes each one cost ten pounds.
  return round(v_total / coalesce(nullif(v_bom.output_quantity, 0), 1)
               / coalesce(nullif(v_bom.yield_factor, 0), 1))::bigint;
end;
$$;

create or replace function erp.works_order_variance(p_works_order_id uuid)
returns table (kind text, standard_minor bigint, actual_minor bigint,
               variance_minor bigint, explanation text)
language sql
stable
security invoker
set search_path = ''
as $$
  with wo as (
    select * from erp.works_order
     where tenant_id = erp.current_tenant_id() and id = p_works_order_id
  ),
  material_std as (
    select coalesce(sum(round(c.required_quantity
             * coalesce((select ic.unit_cost_minor from erp.item_cost ic
                          where ic.tenant_id = c.tenant_id and ic.item_id = c.item_id
                            and ic.site_id is not distinct from wo.site_id), 0))), 0)::bigint as amt
      from erp.works_order_component c, wo where c.works_order_id = wo.id
  ),
  material_act as (
    select coalesce(sum(round(m.quantity * m.unit_cost_minor)), 0)::bigint as amt
      from erp.stock_movement m, wo
     where m.tenant_id = wo.tenant_id and m.reason_code = wo.order_number
       and m.movement_type = 'production_issue' and not m.is_reversal
  ),
  labour as (
    select coalesce(sum(round((o.planned_setup_minutes + o.planned_run_minutes)
                              / 60.0 * o.cost_rate_minor_per_hour)), 0)::bigint as std,
           coalesce(sum(round(o.actual_minutes / 60.0 * o.cost_rate_minor_per_hour)), 0)::bigint as act
      from erp.works_order_operation o, wo where o.works_order_id = wo.id
  )
  -- Split, because "we used more material" and "it took longer" are different
  -- problems with different owners, and one number cannot say which happened.
  select 'material', material_std.amt, material_act.amt,
         material_act.amt - material_std.amt,
         case when material_act.amt > material_std.amt
              then 'more material was consumed than the bill allows for'
              else 'less material was consumed than the bill allows for' end
    from material_std, material_act
  union all
  select 'labour', labour.std, labour.act, labour.act - labour.std,
         case when labour.act > labour.std
              then 'the operations took longer than the routing says'
              else 'the operations took less time than the routing says' end
    from labour
  union all
  select 'yield', 0::bigint, 0::bigint,
         round(coalesce((select ic.unit_cost_minor from erp.item_cost ic, wo
                          where ic.tenant_id = wo.tenant_id and ic.item_id = wo.item_id
                            and ic.site_id is not distinct from wo.site_id), 0)
               * (select wo.quantity - wo.quantity_completed from wo))::bigint,
         'the difference between what was ordered and what came out'
    from wo
$$;

comment on function erp.works_order_variance(uuid) is
  'Spec 5.5: variance analysis, split into material, labour and yield. One '
  'number cannot say whether more material was used or the job took longer, '
  'and those are different problems with different owners.';

-- -----------------------------------------------------------------------------
-- The electronic batch record
--
-- Spec 5.5: "assembled from execution events". Assembled, not written — a batch
-- record somebody types at the end of the run is a summary of what they
-- remember, and the point of the document is that it is not.
-- -----------------------------------------------------------------------------

create or replace function erp.batch_record(p_works_order_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'works_order', wo.order_number,
    'item', i.code,
    'item_name', i.name,
    'quantity_ordered', wo.quantity,
    'quantity_completed', wo.quantity_completed,
    'quantity_scrapped', wo.quantity_scrapped,
    'bill_of_materials', b.code,
    'bill_version', b.version,
    'routing', rt.code,
    'output_batch', ob.batch_number,
    'output_expires_on', ob.expires_on,
    'started_at', wo.actual_start,
    'finished_at', wo.actual_end,
    'standard_cost_minor', wo.standard_cost_minor,
    'actual_cost_minor', wo.actual_cost_minor,
    'components', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item', ci.code, 'required', c.required_quantity,
               'issued', c.issued_quantity) order by c.seq)
        from erp.works_order_component c
        join erp.item ci on ci.id = c.item_id
       where c.works_order_id = wo.id), '[]'::jsonb),
    'operations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', o.seq, 'code', o.code, 'work_centre', o.work_centre_code,
               'planned_minutes', o.planned_setup_minutes + o.planned_run_minutes,
               'actual_minutes', o.actual_minutes,
               'completed', o.quantity_completed,
               'scrapped', o.quantity_scrapped) order by o.seq)
        from erp.works_order_operation o where o.works_order_id = wo.id), '[]'::jsonb),
    -- The record itself: every event, in order, with who and when.
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', pe.occurred_at, 'kind', pe.event_kind,
               'operation', pe.operation_seq,
               'item', ei.code, 'batch', eb.batch_number,
               'quantity', pe.quantity, 'minutes', pe.minutes,
               'by', u.display_name, 'detail', pe.detail)
             order by pe.occurred_at, pe.id)
        from erp.production_event pe
        left join erp.item ei on ei.id = pe.item_id
        left join erp.batch eb on eb.id = pe.batch_id
        left join erp.app_user u on u.id = pe.actor_id
       where pe.works_order_id = wo.id), '[]'::jsonb),
    'component_batches', coalesce((
      select jsonb_agg(distinct pb.batch_number)
        from erp.production_event pe
        join erp.batch pb on pb.id = pe.batch_id
       where pe.works_order_id = wo.id and pe.event_kind = 'issued'), '[]'::jsonb))
    from erp.works_order wo
    join erp.item i on i.id = wo.item_id
    left join erp.bom b on b.id = wo.bom_id
    left join erp.routing rt on rt.id = wo.routing_id
    left join erp.batch ob on ob.id = wo.output_batch_id
   where wo.tenant_id = erp.current_tenant_id() and wo.id = p_works_order_id
$$;

comment on function erp.batch_record(uuid) is
  'Spec 5.5: the electronic batch record, assembled from the execution events. '
  'A record somebody types at the end of a run is a summary of what they '
  'remember, and the point of the document is that it is not.';

create or replace function erp.close_works_order(p_works_order_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
  v_var    jsonb;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  if wo.status not in ('completed', 'in_progress') then
    raise exception 'ERPWARE_WORKS_ORDER_NOT_CLOSABLE: % is %',
      wo.order_number, wo.status using errcode = '23514';
  end if;

  perform erp.authorise('production.release', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  -- Release the commitment. A closed order still holding stock nobody is going
  -- to use is how a planning run decides there is nothing available.
  update erp.allocation
     set status = 'released', updated_at = now()
   where tenant_id = v_tenant and site_id = wo.site_id
     and demand_kind = 'works_order' and status = 'committed'
     and item_id in (select c.item_id from erp.works_order_component c
                      where c.works_order_id = p_works_order_id);

  select jsonb_agg(to_jsonb(v)) into v_var
    from erp.works_order_variance(p_works_order_id) v;

  update erp.works_order set status = 'closed', updated_at = now()
   where id = p_works_order_id;

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, detail, actor_id)
  values (v_tenant, p_works_order_id, 'closed',
          jsonb_build_object('variance', v_var), erp.current_principal_id());

  return v_var;
end;
$$;

-- -----------------------------------------------------------------------------
-- Production, installed
--
-- And a third empty registry, found on the way in. erp_ref.config_type has
-- never had a row either, which means B3's configuration engine — scoped
-- values, effective dating, schema validation, the lot — has never held a
-- single setting. Registering one here rather than storing the issue method in
-- a column is the point: which way components are consumed is a policy, and a
-- policy that lives in a column is one no environment can differ on.
-- -----------------------------------------------------------------------------

insert into erp_ref.config_type (
  code, domain, module_code, name_key, description, value_schema,
  max_scope_level, is_singleton, default_value)
values (
  'production.issue_method', 'policy', 'production',
  'config.production.issue_method',
  'How components are consumed by a works order: computed from what was '
  'completed, told by an operator, or identified at the point of use.',
  jsonb_build_object('type', 'string',
                     'enum', jsonb_build_array('backflush', 'manual', 'scanned')),
  -- A singleton: there is one issue method per scope, not a named list of
  -- them, and declaring otherwise makes the engine demand a code for a setting
  -- that has no name.
  'site', true, to_jsonb('backflush'::text))
on conflict (code) do update
  set value_schema = excluded.value_schema, description = excluded.description;

insert into erp_ref.resource (key, locale, value) values
  ('config.production.issue_method', 'en', 'Component issue method')
on conflict (key, locale) do nothing;

create or replace function erp.configure_production(
  p_issue_method erp.issue_method default 'backflush'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_cs     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'works_order', null);

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  insert into erp.numbering_rule (
    tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'works_order', v_entity, 'WO-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  -- The variance accounts. Split, because the split is the point of measuring.
  insert into erp.account (
    tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
  select v_tenant, v_entity, a.code, a.name, 'expense'::erp.account_type, true,
         e.base_currency, 'active'
    from (values
      ('5100', 'Work in progress'),
      ('9200', 'Material usage variance'),
      ('9300', 'Labour efficiency variance')
    ) as a(code, name)
    join erp.entity e on e.id = v_entity
  on conflict (tenant_id, entity_id, code) do update set status = 'active';

  v_cs := erp.install_module_config(
    'production', 'Production',
    'How works orders consume material and how the difference between what '
    'they should have cost and what they did is accounted for.',
    jsonb_build_array(
      jsonb_build_object('kind','config','key','production.issue_method','payload',
        jsonb_build_object(
          'config_type','production.issue_method',
          'value', to_jsonb(p_issue_method::text)))));

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.production_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Two rules that were written here and then removed, which is worth saying
  -- rather than silently not having them.
  --
  -- "a bill contains the item it makes" and "a bill makes nothing" are both
  -- already impossible: B7's erp.check_bom_acyclic() refuses the first row and
  -- a check constraint refuses the second. A report looking for either could
  -- never return anything, which would make those assertions the exact thing
  -- this report exists to catch — configuration that reads as a control and
  -- can never fire. The suite found them by trying to violate them and being
  -- refused by the database first.
  --
  -- A routing operation with a cost rate and no time,
  -- contributes nothing to the standard and looks as though it does.
  select 'a routing operation has a cost rate and no time',
         format('%s.%s', rt.code, ro.seq),
         'it contributes nothing to the standard cost and reads as though it does'
    from erp.routing_operation ro
    join erp.routing rt on rt.id = ro.routing_id
   where rt.status = 'active'
     and coalesce(ro.cost_rate_minor_per_hour, 0) > 0
     and coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0) = 0
  union all
  -- Works order numbering, without which nothing can be raised.
  select 'production is configured and works orders cannot be numbered',
         'works_order',
         'erp.raise_works_order() will refuse; erp.configure_production() '
         'installs the rule'
    from erp.works_order wo
   where not exists (select 1 from erp.numbering_rule n
                      where n.tenant_id = wo.tenant_id and n.code = 'works_order')
   limit 1
$$;

create or replace function erp.assert_production_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.production_configuration_report();
  if v_count > 0 then
    raise exception 'ERPWARE_PRODUCTION_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return 'production: every bill can be exploded and costed';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_batch_record(p_works_order_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select erp.batch_record(p_works_order_id) $$;

create or replace function public.erp_works_order_variance(p_works_order_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb)
        from erp.works_order_variance(p_works_order_id) v $$;

create or replace function public.erp_works_order_availability(p_works_order_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb)
        from erp.works_order_availability(p_works_order_id) a $$;

create or replace function public.erp_configure_production()
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_production() $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_batch_record(uuid)',
    'public.erp_works_order_variance(uuid)',
    'public.erp_works_order_availability(uuid)',
    'public.erp_configure_production()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_production', 'erp.configure_production',
   'Installs works order numbering and the variance accounts, and submits the '
   'issue method as a B6 change set the caller cannot approve.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.production_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid; csr uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid; v_sup uuid;
  v_fg uuid; v_comp1 uuid; v_comp2 uuid; v_phantom uuid;
  v_bom uuid; v_pbom uuid; v_rout uuid; v_wo uuid; v_grn uuid;
  v_batch uuid; v_cbatch uuid; v_std bigint; v_var jsonb; v_rec jsonb;
  v_n numeric; v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzprod','Production Suite','a@zzprod.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzprod.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  csi := erp.configure_inventory('average');
  csr := erp.configure_production('manual');

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'the issue method is a promoted setting, not a column default',
    erp.config_value('production.issue_method') #>> '{}' = 'manual',
    'B3''s configuration engine had never held a single setting';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','production','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;

  insert into erp.item (tenant_id,code,name,stock_uom_id,is_batch_controlled,shelf_life_days,status)
  values (r.tenant_id,'FG','Finished good',v_uom,true,365,'active') returning id into v_fg;
  insert into erp.item (tenant_id,code,name,stock_uom_id,is_batch_controlled,status)
  values (r.tenant_id,'C1','Component one',v_uom,true,'active') returning id into v_comp1;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'C2','Component two',v_uom,'active') returning id into v_comp2;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'SUB','Phantom subassembly',v_uom,'active') returning id into v_phantom;

  -- A bill with a phantom in it, so the explosion has something to explode
  -- through rather than merely to copy.
  insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                       output_quantity, yield_factor, status, effective_from)
  values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active',
          current_date - 1)
  returning id into v_bom;

  insert into erp.bom (tenant_id, code, item_id, version, name,
                       output_quantity, yield_factor, status, effective_from)
  values (r.tenant_id, 'SUB-1', v_phantom, 1, 'Phantom', 1, 1, 'active',
          current_date - 1)
  returning id into v_pbom;

  insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity,
                            uom_id, scrap_factor, is_phantom)
  values (r.tenant_id, v_bom, 10, v_comp1, 2, v_uom, 0.05, false),
         (r.tenant_id, v_bom, 20, v_phantom, 1, v_uom, 0, true);
  insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity,
                            uom_id, scrap_factor, is_phantom)
  values (r.tenant_id, v_pbom, 10, v_comp2, 3, v_uom, 0, false);

  insert into erp.routing (tenant_id, code, item_id, site_id, version, name,
                           status, effective_from)
  values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
  returning id into v_rout;
  insert into erp.routing_operation (
    tenant_id, routing_id, seq, code, name, work_centre_code,
    setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
  values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 30, 2, 6000);

  -- A batch for the batch-controlled component, because B7 refuses a movement
  -- of one without it — which is the behaviour that makes the genealogy below
  -- worth anything.
  insert into erp.batch (tenant_id, item_id, batch_number, status,
                         manufactured_on, expires_on)
  values (r.tenant_id, v_comp1, 'C1-A', 'released', current_date - 30,
          current_date + 60)
  returning id into v_cbatch;

  -- Component stock, received properly so it has a cost.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_comp1, 1000, 500, 'component one');
  perform erp.add_document_line(v_grn, v_comp2, 1000, 200, 'component two');
  update erp.document_line set batch_id = v_cbatch
   where document_id = v_grn and item_id = v_comp1;
  perform erp.transition_document(v_grn,'post');

  -- ---------------------------------------------------------------------------
  -- Raising: explosion, phantoms, scrap.
  -- ---------------------------------------------------------------------------
  v_wo := erp.raise_works_order(v_fg, v_site, 100);

  return query select 'the phantom is exploded through, not ordered',
    not exists (select 1 from erp.works_order_component c
                 where c.works_order_id = v_wo and c.item_id = v_phantom)
    and exists (select 1 from erp.works_order_component c
                 where c.works_order_id = v_wo and c.item_id = v_comp2),
    'a phantom is a level in the bill that is never stocked';

  return query select 'scrap factor is a loss allowance, so it adds',
    (select c.required_quantity from erp.works_order_component c
      where c.works_order_id = v_wo and c.item_id = v_comp1) = 210,
    '100 units at two each with five per cent scrap is 210, not 190';

  return query select 'the routing becomes the order''s operations',
    (select o.planned_run_minutes from erp.works_order_operation o
      where o.works_order_id = v_wo and o.seq = 10) = 200,
    'two minutes a unit for a hundred units';

  -- ---------------------------------------------------------------------------
  -- Availability and commitment.
  -- ---------------------------------------------------------------------------
  return query select 'availability is checked against what is not already committed',
    (select a.shortfall from erp.works_order_availability(v_wo) a
      where a.item_code = 'C1') = 0,
    'a thousand on hand against two hundred and ten needed';

  perform erp.release_works_order(v_wo);
  return query select 'releasing commits the material rather than merely checking it',
    (select count(*) from erp.allocation a
      where a.tenant_id = r.tenant_id and a.demand_kind = 'works_order'
        and a.status = 'committed') = 2,
    'two orders both told there is enough is how the second finds an empty shelf';

  v_std := (select wo.standard_cost_minor from erp.works_order wo where wo.id = v_wo);
  return query select 'and freezes what it should cost',
    v_std > 0,
    format('standard %s, frozen at release rather than read at close', v_std);

  -- ---------------------------------------------------------------------------
  -- Engineering change control.
  -- ---------------------------------------------------------------------------
  begin
    update erp.bom_line set quantity = 3
     where bom_id = v_bom and component_item_id = v_comp1;
    v_ok := false; v_msg := 'a bill was edited while an order was running against it';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,54); end;
  return query select 'a bill in use cannot be edited in place', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Execution.
  -- ---------------------------------------------------------------------------
  perform erp.issue_to_works_order(v_wo, v_comp1, 210, v_cbatch);
  perform erp.issue_to_works_order(v_wo, v_comp2, 300);
  perform erp.book_operation_time(v_wo, 10, 260, 100, 0);

  return query select 'issuing moves stock out and records it as an event',
    (select c.issued_quantity from erp.works_order_component c
      where c.works_order_id = v_wo and c.item_id = v_comp1) = 210
    and (select count(*) from erp.production_event pe
          where pe.works_order_id = v_wo and pe.event_kind = 'issued') = 2,
    'the batch record is the events, so the events have to be real';

  begin
    perform erp.issue_to_works_order(v_wo, v_fg, 1);
    v_ok := false; v_msg := 'something not on the bill was issued';
  exception when sqlstate '23503' then v_ok := true; v_msg := left(sqlerrm,54); end;
  return query select 'and only what the bill names may be issued', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Output, and the derived expiry.
  -- ---------------------------------------------------------------------------
  v_batch := erp.receive_works_order_output(v_wo, 100);

  return query select 'the output batch cannot outlive its components',
    (select b.expires_on from erp.batch b where b.id = v_batch) = current_date + 60,
    'the item says three hundred and sixty-five days; a component expires in sixty';

  return query select 'and its genealogy names the batches that went in',
    exists (select 1 from erp.batch_genealogy g
             where g.child_batch_id = v_batch and g.parent_batch_id = v_cbatch),
    'this is what a recall reads, and it is assembled rather than written';

  return query select 'the finished good is valued at what it actually cost',
    (select c.unit_cost_minor from erp.item_cost c
      where c.item_id = v_fg and c.site_id = v_site) > 0
    and (select m.unit_cost_minor from erp.stock_movement m
          where m.item_id = v_fg and m.movement_type = 'production_output') =
        (select round(wo.actual_cost_minor / 100)::bigint from erp.works_order wo
          where wo.id = v_wo),
    'components issued plus time booked, divided by what came out';

  return query select 'and the stock ledger still reconciles',
    (select count(*) from erp.stock_reconciliation_report()) = 0,
    'two movements per works order, and B7''s invariant unbroken';

  -- ---------------------------------------------------------------------------
  -- Variance, split.
  -- ---------------------------------------------------------------------------
  v_var := erp.close_works_order(v_wo);

  return query select 'the labour variance is measured against the routing',
    (select (v ->> 'variance_minor')::bigint from jsonb_array_elements(v_var) v
      where v ->> 'kind' = 'labour') = 3000,
    '260 minutes booked against 230 planned at 6000 an hour is 30 minutes over';

  return query select 'and the material variance is separate from it',
    (select (v ->> 'variance_minor')::bigint from jsonb_array_elements(v_var) v
      where v ->> 'kind' = 'material') = 0,
    'one number cannot say whether more material was used or it took longer';

  return query select 'closing releases the commitment',
    not exists (select 1 from erp.allocation a
                 where a.tenant_id = r.tenant_id and a.demand_kind = 'works_order'
                   and a.status = 'committed'),
    'a closed order still holding stock makes planning think there is none';

  -- ---------------------------------------------------------------------------
  -- The batch record.
  -- ---------------------------------------------------------------------------
  v_rec := erp.batch_record(v_wo);
  return query select 'the batch record is assembled from the events',
    jsonb_array_length(v_rec -> 'events') >= 6
    and jsonb_array_length(v_rec -> 'components') = 2
    and (v_rec ->> 'output_batch') is not null,
    format('%s events, %s components, batch %s',
           jsonb_array_length(v_rec -> 'events'),
           jsonb_array_length(v_rec -> 'components'),
           v_rec ->> 'output_batch');

  return query select 'and it names the component batches a recall would follow',
    jsonb_array_length(v_rec -> 'component_batches') = 1,
    'one batch-controlled component was issued against a batch';

  -- ---------------------------------------------------------------------------
  -- Cost roll-up.
  -- ---------------------------------------------------------------------------
  return query select 'the standard rolls up through the bill and the routing',
    erp.roll_up_standard_cost(v_fg, v_site) > 0,
    format('%s per unit', erp.roll_up_standard_cost(v_fg, v_site));

  -- ---------------------------------------------------------------------------
  -- Configuration assertions.
  -- ---------------------------------------------------------------------------
  return query select 'every bill can be exploded and costed',
    (select count(*) from erp.production_configuration_report()) = 0,
    'no cycles, no bills that make nothing, no unpaid operations';

  -- A cycle is refused by B7 at the row, so there is nothing for a
  -- configuration report to find. This asserts the guard rather than
  -- duplicating it.
  begin
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id)
    values (r.tenant_id, v_pbom, 20, v_phantom, 1, v_uom);
    v_ok := false; v_msg := 'a bill was allowed to contain its own output';
  exception when others then
    v_ok := (sqlerrm like '%BOM_SELF_REFERENCE%' or sqlerrm like '%CYCLE%');
    v_msg := left(sqlerrm, 50);
  end;
  return query select 'a bill cannot contain the item it makes', v_ok, v_msg;

  begin
    update erp.bom set output_quantity = 0 where id = v_pbom;
    v_ok := false; v_msg := 'a bill was allowed to make nothing';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 50); end;
  return query select 'and a bill cannot make nothing', v_ok, v_msg;

  -- The rule that can fire: an operation charging for time it does not take.
  update erp.routing_operation
     set setup_minutes = 0, run_minutes_per_unit = 0 where routing_id = v_rout;
  return query select 'an operation with a rate and no time fails the build',
    (select count(*) from erp.production_configuration_report()
      where finding = 'a routing operation has a cost rate and no time') = 1,
    'it contributes nothing to the standard and reads as though it does';
  update erp.routing_operation
     set setup_minutes = 30, run_minutes_per_unit = 2 where routing_id = v_rout;

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_production_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 24;
begin
  create temporary table if not exists zz_prod_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_prod_result;
  insert into zz_prod_result select * from erp_test.production_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_prod_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_PRODUCTION_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_PRODUCTION_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail
      using errcode = 'P0001';
  end if;

  return format('production: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_production_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
