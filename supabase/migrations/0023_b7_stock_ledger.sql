-- =============================================================================
-- ERPWare — B7 (part 2/5): batches, serials, containers, the stock ledger
-- Spec 4.4 (Stock)
--
-- The invariants this part must hold, verbatim:
--
--   "on-hand quantity equals the sum of movements, always"
--   "corrections are reversing movements, never edits"
--   "negative on-hand is impossible except through explicitly authorised
--    movement types"
--   "a batch's genealogy is continuous and unbroken by any record correction"
--
-- and, from the same section:
--
--   "Derived positions — on hand, available, allocated, in transit,
--    quarantined, blocked, in production — are computed from the ledger and
--    never stored as an editable balance"
--
-- Three design decisions follow from those.
--
-- 1. One ledger, and STATUS travels in it alongside location. A movement has a
--    from (location, status) and a to (location, status). Releasing stock from
--    quarantine is then a movement that changes status without changing place,
--    and "quarantined" is a position derived from the same ledger as "on hand"
--    rather than a flag somebody can toggle. The alternative — a status column
--    on a balance row — is precisely the editable balance the spec forbids.
--
-- 2. Quantities are always POSITIVE, and direction comes from which side is
--    populated. A receipt has only a `to`, an issue only a `from`, a transfer
--    both. Signed quantities invite a correction to be entered as a negative
--    of the original, which reads as a second event rather than a reversal.
--
-- 3. There IS a balance table, and it is a cache with a proof. Computing every
--    availability check from the full ledger does not survive contact with a
--    warehouse. So erp.stock_balance is maintained by the ledger trigger, is
--    unwritable by anything else, and erp.assert_stock_reconciles() compares it
--    against the ledger it came from. A cache without that check is exactly the
--    editable balance under another name.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Movement types (product content)
--
-- A reference table rather than an enum, because each type carries policy —
-- notably which ones may drive a position negative. Spec 4.4 permits that only
-- through "explicitly authorised movement types", so authorisation has to be a
-- property of the type rather than a decision at the call site.
-- -----------------------------------------------------------------------------

create type erp.movement_direction as enum ('in', 'out', 'transfer', 'status_change');

create table erp_ref.movement_type (
  code             text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key         text not null,
  direction        erp.movement_direction not null,
  module_code      text references erp_ref.module(code),
  -- The escape hatch the specification allows, held here so that every
  -- exception is named and countable rather than argued case by case.
  allows_negative  boolean not null default false,
  requires_reason  boolean not null default false,
  affects_valuation boolean not null default true,
  -- Whether this type may be used directly, or only produced by the platform
  -- (reversals, for instance, are generated).
  is_system        boolean not null default false,
  description      text
);

comment on column erp_ref.movement_type.allows_negative is
  'Spec 4.4 permits negative on-hand only through explicitly authorised '
  'movement types. Authorisation lives here, on the type, so the set of '
  'exceptions is a list someone can read rather than a judgement made at each '
  'call site.';

-- -----------------------------------------------------------------------------
-- Batches
-- -----------------------------------------------------------------------------

create type erp.batch_status as enum (
  'unrestricted', 'quarantine', 'blocked', 'rejected', 'expired',
  'released', 'recalled', 'destroyed'
);

create table erp.batch (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  item_id          uuid not null,
  batch_number     text not null,
  status           erp.batch_status not null default 'quarantine',

  -- Attributes (spec 4.4)
  manufactured_on  date,
  expires_on       date,
  retest_on        date,
  best_before_on   date,
  supplier_lot     text,
  origin_country   char(2) references erp_ref.country(code),
  supplier_party_id uuid,
  certificates     jsonb not null default '[]'::jsonb,
  attributes       jsonb not null default '{}'::jsonb,

  -- Catch weight: the mass this batch actually is, per stock unit.
  catch_weight_per_unit numeric(20,6),

  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, item_id, batch_number),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, supplier_party_id)
    references erp.party (tenant_id, id) on delete set null,
  constraint batch_expiry_after_manufacture
    check (expires_on is null or manufactured_on is null or expires_on >= manufactured_on)
);

create index on erp.batch (tenant_id, item_id, status);
create index on erp.batch (tenant_id, expires_on) where expires_on is not null;

-- Spec 4.4: "attributes are amendable through evented amendment with approval,
-- without generating stock movements". An expiry date corrected after a
-- typing error is not a movement of goods, and recording it as one would
-- corrupt the ledger to fix a label.
create table erp.batch_amendment (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  batch_id       uuid not null,
  occurred_at    timestamptz not null default clock_timestamp(),
  field          text not null,
  old_value      jsonb,
  new_value      jsonb,
  reason         text not null,
  approval_request_id uuid,
  approved_by    uuid,
  approved_at    timestamptz,
  actor_id       uuid,
  correlation_id uuid,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete cascade
);

create index on erp.batch_amendment (tenant_id, batch_id, occurred_at desc);

-- -----------------------------------------------------------------------------
-- Serials, with genealogy
-- -----------------------------------------------------------------------------

create table erp.serial (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  item_id        uuid not null,
  serial_number  text not null,
  batch_id       uuid,
  -- Genealogy: the unit this one was built from or split out of.
  parent_serial_id uuid,
  status         erp.batch_status not null default 'unrestricted',
  manufactured_on date,
  expires_on     date,
  attributes     jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, item_id, serial_number),
  foreign key (tenant_id, item_id)  references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, parent_serial_id)
    references erp.serial (tenant_id, id) on delete restrict,
  constraint serial_not_own_parent check (parent_serial_id is distinct from id)
);

create index on erp.serial (tenant_id, item_id, status);
create index on erp.serial (tenant_id, batch_id);

-- Batch genealogy: which batches went into which. Written by production, read
-- by traceability and recall.
create table erp.batch_genealogy (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  parent_batch_id uuid not null,
  child_batch_id  uuid not null,
  quantity       numeric(20,6),
  uom_id         uuid,
  movement_id    bigint,
  document_id    uuid,
  occurred_at    timestamptz not null default clock_timestamp(),
  foreign key (tenant_id, parent_batch_id) references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, child_batch_id)  references erp.batch (tenant_id, id) on delete restrict,
  constraint batch_genealogy_distinct check (parent_batch_id <> child_batch_id),
  unique (tenant_id, parent_batch_id, child_batch_id, movement_id)
);

create index on erp.batch_genealogy (tenant_id, child_batch_id);
create index on erp.batch_genealogy (tenant_id, parent_batch_id);

-- -----------------------------------------------------------------------------
-- Containers — recursive handling units
--
-- Spec 4.4: "Nesting depth is unbounded [...] Moving a container moves
-- everything beneath it as one event."
-- -----------------------------------------------------------------------------

create table erp.container (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  code              text not null,
  container_type    text not null,
  parent_container_id uuid,
  site_id           uuid,
  location_id       uuid,
  -- Materialised ancestry, as with locations: "everything beneath this
  -- container" must be one indexed query, not a recursive walk per movement.
  path              uuid[] not null default '{}'::uuid[],
  depth             smallint not null default 0,
  is_open           boolean not null default true,
  attributes        jsonb not null default '{}'::jsonb,
  status            erp.record_status not null default 'active',
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, parent_container_id)
    references erp.container (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id)     references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, location_id) references erp.location (tenant_id, id) on delete restrict,
  constraint container_not_own_parent check (parent_container_id is distinct from id)
);

create index on erp.container (tenant_id, location_id);
create index on erp.container using gin (path);

create or replace function erp.maintain_container_path()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent_path uuid[];
begin
  if new.parent_container_id is null then
    new.depth := 0;
    new.path  := array[]::uuid[];
  else
    select c.path into v_parent_path
      from erp.container c
     where c.id = new.parent_container_id and c.tenant_id = new.tenant_id;

    if not found then
      raise exception 'ERPWARE_CONTAINER_PARENT_NOT_FOUND: %', new.parent_container_id
        using errcode = '23503';
    end if;

    if new.id = any (v_parent_path) then
      raise exception 'ERPWARE_CONTAINER_CYCLE: % would become its own ancestor', new.id
        using errcode = '23514';
    end if;

    new.path  := v_parent_path || new.parent_container_id;
    new.depth := array_length(new.path, 1);
  end if;
  return new;
end;
$$;

create trigger t_container_path
  before insert or update of parent_container_id on erp.container
  for each row execute function erp.maintain_container_path();

-- -----------------------------------------------------------------------------
-- The stock ledger
-- -----------------------------------------------------------------------------

create type erp.stock_status as enum (
  'available', 'quarantine', 'blocked', 'damaged', 'in_transit',
  'in_production', 'awaiting_inspection', 'on_hold'
);

create table erp.stock_movement (
  id               bigint generated always as identity primary key,
  movement_uid     uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  entity_id        uuid not null,
  site_id          uuid not null,

  movement_type    text not null references erp_ref.movement_type(code),

  item_id          uuid not null,
  batch_id         uuid,
  serial_id        uuid,
  container_id     uuid,

  -- Null on one side means the stock came from, or went to, outside the ledger.
  from_location_id uuid,
  from_status      erp.stock_status,
  to_location_id   uuid,
  to_status        erp.stock_status,

  -- Always positive. Direction is which side is populated.
  quantity         numeric(20,6) not null check (quantity > 0),
  uom_id           uuid not null,
  catch_weight     numeric(20,6),

  -- Cost context (spec 4.4). Minor units, integer.
  unit_cost_minor  bigint,
  currency         char(3) references erp_ref.currency(code),
  cost_context     jsonb not null default '{}'::jsonb,

  document_id      uuid,
  document_line_id uuid,
  reason_code      text,

  occurred_at      timestamptz not null default clock_timestamp(),
  recorded_at      timestamptz not null default clock_timestamp(),

  actor_id         uuid,
  correlation_id   uuid,
  event_id         uuid,

  -- Corrections are reversing movements, never edits (spec 4.4).
  reverses_movement_id bigint,
  is_reversal      boolean not null default false,

  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, item_id)   references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id)  references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, serial_id) references erp.serial (tenant_id, id) on delete restrict,
  foreign key (tenant_id, container_id) references erp.container (tenant_id, id) on delete restrict,
  foreign key (tenant_id, from_location_id) references erp.location (tenant_id, id) on delete restrict,
  foreign key (tenant_id, to_location_id)   references erp.location (tenant_id, id) on delete restrict,
  foreign key (tenant_id, uom_id)    references erp.uom (tenant_id, id) on delete restrict,

  -- A movement from nowhere to nowhere is not a movement.
  constraint stock_movement_has_a_side
    check (from_location_id is not null or to_location_id is not null),
  -- Where a side exists, it has a status: stock is always in some condition.
  constraint stock_movement_from_status
    check ((from_location_id is null) = (from_status is null)),
  constraint stock_movement_to_status
    check ((to_location_id is null) = (to_status is null))
);

create index on erp.stock_movement (tenant_id, item_id, occurred_at desc);
create index on erp.stock_movement (tenant_id, batch_id) where batch_id is not null;
create index on erp.stock_movement (tenant_id, serial_id) where serial_id is not null;
create index on erp.stock_movement (tenant_id, container_id) where container_id is not null;
create index on erp.stock_movement (tenant_id, document_id) where document_id is not null;
create index on erp.stock_movement (tenant_id, site_id, occurred_at desc);
create index on erp.stock_movement (tenant_id, reverses_movement_id)
  where reverses_movement_id is not null;

comment on table erp.stock_movement is
  'The append-only stock ledger. Every quantity in the product is derived from '
  'this table; nothing else is authoritative about how much there is.';

-- -----------------------------------------------------------------------------
-- Positions
--
-- erp.stock_position is the TRUTH: the ledger, aggregated. Nothing writes it.
-- -----------------------------------------------------------------------------

create view erp.stock_position as
with sides as (
  select m.tenant_id, m.site_id, m.to_location_id as location_id, m.item_id,
         m.batch_id, m.serial_id, m.container_id, m.to_status as stock_status,
         m.quantity as delta
    from erp.stock_movement m
   where m.to_location_id is not null
  union all
  select m.tenant_id, m.site_id, m.from_location_id, m.item_id,
         m.batch_id, m.serial_id, m.container_id, m.from_status,
         -m.quantity
    from erp.stock_movement m
   where m.from_location_id is not null
)
select tenant_id, site_id, location_id, item_id, batch_id, serial_id,
       container_id, stock_status,
       sum(delta) as quantity
  from sides
 group by tenant_id, site_id, location_id, item_id, batch_id, serial_id,
          container_id, stock_status
having sum(delta) <> 0;

comment on view erp.stock_position is
  'On hand, by every dimension, derived from the ledger. This is the truth; '
  'erp.stock_balance is a cache of it and is proved against it by '
  'erp.assert_stock_reconciles().';

-- The cache. Written only by the ledger trigger; see erp.guard_stock_balance().
create table erp.stock_balance (
  id            bigint generated always as identity primary key,
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  site_id       uuid not null,
  location_id   uuid not null,
  item_id       uuid not null,
  batch_id      uuid,
  serial_id     uuid,
  container_id  uuid,
  stock_status  erp.stock_status not null,
  quantity      numeric(20,6) not null default 0,
  updated_at    timestamptz not null default now()
);

-- The real key. An expression index rather than a primary key because the
-- nullable dimensions have to collapse to a single row per position: in SQL
-- two NULL batches are not equal, but two unbatched positions in the same
-- location are the same position.
create unique index stock_balance_position
  on erp.stock_balance (
    tenant_id, site_id, location_id, item_id,
    coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
    stock_status);

create index on erp.stock_balance (tenant_id, item_id, site_id)
  where quantity <> 0;
create index on erp.stock_balance (tenant_id, batch_id) where batch_id is not null;

comment on table erp.stock_balance is
  'A cache of erp.stock_position, maintained by the ledger trigger and '
  'unwritable by anything else. Availability checks in a warehouse cannot '
  'aggregate the whole ledger per scan, but a cache without a reconciliation '
  'test is the editable balance the specification forbids — so there is one.';

create or replace function erp.guard_stock_balance()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Only the ledger may move a balance. The flag is set by the movement
  -- trigger and cleared when its transaction ends.
  if nullif(current_setting('erp.ledger_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  if nullif(current_setting('erp.purge_tenant_id', true), '') is not null then
    return coalesce(new, old);
  end if;

  raise exception
    'ERPWARE_DERIVED_BALANCE: stock_balance is derived from the ledger and cannot be written directly'
    using errcode = '42501',
          hint = 'Record a stock movement. A balance that can be typed is not a balance.';
end;
$$;

create trigger t_stock_balance_guard
  before insert or update or delete on erp.stock_balance
  for each row execute function erp.guard_stock_balance();

-- -----------------------------------------------------------------------------
-- Applying a movement
-- -----------------------------------------------------------------------------

create or replace function erp.apply_stock_movement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allows_negative boolean;
  v_requires_reason boolean;
  v_direction       erp.movement_direction;
  v_item            erp.item%rowtype;
  v_resulting       numeric(20,6);
begin
  select mt.allows_negative, mt.requires_reason, mt.direction
    into v_allows_negative, v_requires_reason, v_direction
    from erp_ref.movement_type mt where mt.code = new.movement_type;

  if v_requires_reason and coalesce(new.reason_code, '') = '' then
    raise exception 'ERPWARE_MOVEMENT_REASON_REQUIRED: % requires a reason code',
      new.movement_type using errcode = '23514';
  end if;

  -- Control flags decide what the ledger may record.
  select * into v_item from erp.item i where i.id = new.item_id;

  if v_item.is_batch_controlled and new.batch_id is null then
    raise exception 'ERPWARE_BATCH_REQUIRED: % is batch controlled', v_item.code
      using errcode = '23514';
  end if;
  if not v_item.is_batch_controlled and new.batch_id is not null then
    raise exception 'ERPWARE_BATCH_NOT_APPLICABLE: % is not batch controlled', v_item.code
      using errcode = '23514';
  end if;
  if v_item.is_serial_controlled and new.serial_id is null then
    raise exception 'ERPWARE_SERIAL_REQUIRED: % is serial controlled', v_item.code
      using errcode = '23514';
  end if;

  perform set_config('erp.ledger_write', 'on', true);

  -- Outbound side
  if new.from_location_id is not null then
    insert into erp.stock_balance as b (
      tenant_id, site_id, location_id, item_id, batch_id, serial_id,
      container_id, stock_status, quantity)
    values (
      new.tenant_id, new.site_id, new.from_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, new.from_status, -new.quantity)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 stock_status)
      -- excluded.quantity is already negative on this side, so one expression
      -- serves both directions.
      do update set quantity = b.quantity + excluded.quantity, updated_at = now()
    returning b.quantity into v_resulting;

    if v_resulting < 0 and not coalesce(v_allows_negative, false) then
      raise exception
        'ERPWARE_NEGATIVE_STOCK: % would leave %.% at % in %',
        new.movement_type, v_item.code, coalesce(new.batch_id::text, ''),
        v_resulting, new.from_status
        using errcode = '23514',
              hint = 'Only movement types marked allows_negative may drive a position below zero.';
    end if;
  end if;

  -- Inbound side
  if new.to_location_id is not null then
    insert into erp.stock_balance as b (
      tenant_id, site_id, location_id, item_id, batch_id, serial_id,
      container_id, stock_status, quantity)
    values (
      new.tenant_id, new.site_id, new.to_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, new.to_status, new.quantity)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 stock_status)
      do update set quantity = b.quantity + excluded.quantity, updated_at = now();
  end if;

  perform set_config('erp.ledger_write', '', true);
  return new;
end;
$$;

create trigger t_stock_movement_apply
  after insert on erp.stock_movement
  for each row execute function erp.apply_stock_movement();

-- Corrections are reversing movements, never edits.
create or replace function erp.reverse_stock_movement(
  p_movement_id bigint, p_reason text)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  m        erp.stock_movement%rowtype;
  v_new    bigint;
begin
  select * into m from erp.stock_movement
   where tenant_id = v_tenant and id = p_movement_id;

  if not found then
    raise exception 'ERPWARE_MOVEMENT_NOT_FOUND: %', p_movement_id using errcode = '23503';
  end if;

  if exists (select 1 from erp.stock_movement r
              where r.tenant_id = v_tenant and r.reverses_movement_id = p_movement_id) then
    raise exception 'ERPWARE_MOVEMENT_ALREADY_REVERSED: % has already been reversed', p_movement_id
      using errcode = '23514';
  end if;

  -- The mirror image: the two sides swap, so the pair sums to nothing while
  -- both remain visible. The original is never touched.
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
    container_id, from_location_id, from_status, to_location_id, to_status,
    quantity, uom_id, catch_weight, unit_cost_minor, currency, cost_context,
    document_id, document_line_id, reason_code, occurred_at, actor_id,
    correlation_id, reverses_movement_id, is_reversal)
  values (
    m.tenant_id, m.entity_id, m.site_id, m.movement_type, m.item_id, m.batch_id,
    m.serial_id, m.container_id,
    m.to_location_id, m.to_status,      -- swapped
    m.from_location_id, m.from_status,  -- swapped
    m.quantity, m.uom_id, m.catch_weight, m.unit_cost_minor, m.currency,
    m.cost_context, m.document_id, m.document_line_id, p_reason,
    clock_timestamp(), erp.current_principal_id(), erp.current_correlation_id(),
    m.id, true)
  returning id into v_new;

  return v_new;
end;
$$;

comment on function erp.reverse_stock_movement is
  'The only correction mechanism. Both the original and its mirror stay in the '
  'ledger, so the history shows that something was corrected and when — which '
  'an edit would erase.';

-- Moving a container moves everything beneath it, as one event (spec 4.4).
create or replace function erp.move_container(
  p_container_id uuid,
  p_to_location_id uuid,
  p_reason text default null)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_corr   uuid := coalesce(erp.current_correlation_id(), gen_random_uuid());
  v_count  integer := 0;
  r        record;
begin
  perform erp.set_correlation_id(v_corr);

  -- Every position held by this container or anything nested inside it. One
  -- correlation id ties the resulting movements together as a single act.
  for r in
    select b.* from erp.stock_balance b
     where b.tenant_id = v_tenant
       and b.quantity > 0
       and (b.container_id = p_container_id
            or b.container_id in (select c.id from erp.container c
                                   where c.tenant_id = v_tenant
                                     and p_container_id = any (c.path)))
  loop
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
      container_id, from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, reason_code, actor_id, correlation_id)
    select v_tenant,
           (select s.entity_id from erp.site s where s.id = r.site_id),
           r.site_id, 'container_move', r.item_id, r.batch_id, r.serial_id,
           r.container_id, r.location_id, r.stock_status, p_to_location_id, r.stock_status,
           r.quantity,
           (select i.stock_uom_id from erp.item i where i.id = r.item_id),
           p_reason, erp.current_principal_id(), v_corr;
    v_count := v_count + 1;
  end loop;

  update erp.container
     set location_id = p_to_location_id, updated_at = now()
   where tenant_id = v_tenant
     and (id = p_container_id or p_container_id = any (path));

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Allocation, in two stages (spec 4.4)
--
-- A reservation says "this much of this item at this site is spoken for" and
-- can be made the moment an order is taken. A commitment says "these specific
-- units, in this batch, in this location" and can only be made once the policy
-- has chosen them. Collapsing the two forces a picker's batch decision at
-- order-entry time, which is why the spec separates them.
-- -----------------------------------------------------------------------------

create type erp.allocation_status as enum (
  'reserved', 'committed', 'picked', 'released', 'cancelled', 'consumed'
);

create table erp.allocation (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  site_id        uuid not null,
  item_id        uuid not null,
  -- What the stock is for.
  document_id    uuid,
  document_line_id uuid,
  demand_kind    text not null default 'sales_order',
  quantity       numeric(20,6) not null check (quantity > 0),
  uom_id         uuid not null,
  status         erp.allocation_status not null default 'reserved',
  -- The scope the reservation applies to, and the policy that will pick within
  -- it (FEFO, FIFO, a nominated location set).
  location_scope jsonb not null default '{}'::jsonb,
  policy_code    text,
  required_by    date,
  priority       integer not null default 100,
  -- Spec 5.6: unmet detailed allocation classified by cause, so a shortage is
  -- visible and attributable rather than silent.
  unmet_quantity numeric(20,6) not null default 0 check (unmet_quantity >= 0),
  unmet_cause    text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, item_id)   references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, uom_id)    references erp.uom (tenant_id, id) on delete restrict
);

create index on erp.allocation (tenant_id, item_id, site_id)
  where status in ('reserved', 'committed', 'picked');
create index on erp.allocation (tenant_id, document_id);

create table erp.allocation_line (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  allocation_id  uuid not null,
  location_id    uuid not null,
  batch_id       uuid,
  serial_id      uuid,
  container_id   uuid,
  stock_status   erp.stock_status not null default 'available',
  quantity       numeric(20,6) not null check (quantity > 0),
  status         erp.allocation_status not null default 'committed',
  picked_at      timestamptz,
  picked_by      uuid,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, allocation_id)
    references erp.allocation (tenant_id, id) on delete cascade,
  foreign key (tenant_id, location_id) references erp.location (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id)    references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, serial_id)   references erp.serial (tenant_id, id) on delete restrict,
  foreign key (tenant_id, container_id) references erp.container (tenant_id, id) on delete restrict
);

create index on erp.allocation_line (tenant_id, allocation_id);
create index on erp.allocation_line (tenant_id, location_id, batch_id)
  where status in ('committed', 'picked');

-- Available = on hand, less what is committed to somebody else.
create view erp.stock_availability as
select
  b.tenant_id, b.site_id, b.location_id, b.item_id, b.batch_id, b.stock_status,
  b.quantity                            as on_hand,
  coalesce(c.committed, 0)              as committed,
  b.quantity - coalesce(c.committed, 0) as available
from erp.stock_balance b
left join lateral (
  -- Joined back to the allocation for its item: an allocation line names a
  -- location and a batch, and for unbatched stock that pair alone would match
  -- commitments against a different item in the same bin.
  select sum(al.quantity) as committed
    from erp.allocation_line al
    join erp.allocation a
      on a.tenant_id = al.tenant_id and a.id = al.allocation_id
   where al.tenant_id = b.tenant_id
     and al.location_id = b.location_id
     and al.batch_id is not distinct from b.batch_id
     and al.stock_status = b.stock_status
     and a.item_id = b.item_id
     and al.status in ('committed', 'picked')
) c on true
where b.quantity <> 0;

-- -----------------------------------------------------------------------------
-- Item control flags may not contradict the stock that exists (spec 4.3)
-- -----------------------------------------------------------------------------

create or replace function erp.check_item_control_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_has_stock boolean;
begin
  if new.is_batch_controlled = old.is_batch_controlled
     and new.is_serial_controlled = old.is_serial_controlled
     and new.has_expiry = old.has_expiry then
    return new;
  end if;

  select exists (
    select 1 from erp.stock_balance b
     where b.tenant_id = new.tenant_id and b.item_id = new.id and b.quantity <> 0
  ) into v_has_stock;

  if not v_has_stock then
    return new;
  end if;

  if old.is_batch_controlled and not new.is_batch_controlled then
    raise exception
      'ERPWARE_CONTROL_FLAG_LOCKED: % holds batched stock; turning off batch control would orphan it',
      old.code using errcode = '23514';
  end if;

  if not old.is_batch_controlled and new.is_batch_controlled then
    raise exception
      'ERPWARE_CONTROL_FLAG_LOCKED: % holds unbatched stock; turning on batch control would leave it unidentifiable',
      old.code using errcode = '23514';
  end if;

  if old.is_serial_controlled <> new.is_serial_controlled then
    raise exception
      'ERPWARE_CONTROL_FLAG_LOCKED: % holds stock; serial control cannot be changed while it does',
      old.code using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger t_item_control_flags
  before update of is_batch_controlled, is_serial_controlled, has_expiry on erp.item
  for each row execute function erp.check_item_control_flags();

select erp_meta.register_table('erp', 'stock_movement', 'tenant_scoped_append_only',
  'Spec 4.4: the ledger is append-only and corrections are reversing movements.');
select erp_meta.register_table('erp', 'batch_amendment', 'tenant_scoped_append_only',
  'An evented record of attribute amendments. Evidence, not working state.');
select erp_meta.register_table('erp', 'batch_genealogy', 'tenant_scoped_append_only',
  'Spec 4.4: genealogy is continuous and unbroken by any record correction.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'stock_movement',
   'Append-only ledger already carrying actor, reason, timestamps and document reference.'),
  ('erp', 'batch_amendment', 'Append-only evidence with its own actor and reason.'),
  ('erp', 'batch_genealogy', 'Append-only lineage derived from production movements.'),
  ('erp', 'stock_balance',
   'Derived from the ledger and unwritable directly; auditing a cache records nothing the ledger does not.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
