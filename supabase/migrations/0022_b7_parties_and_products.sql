-- =============================================================================
-- ERPWare — B7 (part 1/5): parties and products
-- Spec 4.2 (Parties), 4.3 (Products)
--
-- Two invariants drive the shape here.
--
--   4.2: "a party's identity is stable across roles and entities; commercial
--        terms are per role, per entity"
--
--   A supplier who is also a customer is ONE party. The alternative — a
--   supplier table and a customer table — is how an ERP ends up unable to net
--   a receivable against a payable for the same organisation, and unable to
--   answer "who do we deal with" at all. Roles hang off the identity and carry
--   their own attributes; terms hang off the role and the entity, because the
--   same supplier routinely has different payment terms with different
--   subsidiaries.
--
--   4.3: "an item's control flags may not be changed while stock exists in a
--        state the new flags cannot represent"
--
--   Turning off batch control on an item that has batched stock would orphan
--   every existing quantity: the stock is recorded against a batch the item no
--   longer admits to having. Enforced by trigger in migration 0023, once the
--   stock ledger it needs to consult exists.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Parties
-- -----------------------------------------------------------------------------

create type erp.party_role_kind as enum (
  'supplier', 'customer', 'carrier', 'internal', 'regulator', 'manufacturer',
  'broker', 'consignee', 'agent'
);

create table erp.party (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  code          text not null,
  name          text not null,
  legal_name    text,
  -- The identity, not the relationship. Everything commercial lives on a role.
  country_code  char(2) references erp_ref.country(code),
  registration_number text,
  tax_identifier text,
  duns_or_gln   text,
  status        erp.record_status not null default 'active',
  -- Where a party record was merged into another, this points at the survivor
  -- so old references still resolve (spec 5.1: duplicate detection and merge).
  merged_into_id uuid,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, merged_into_id)
    references erp.party (tenant_id, id) on delete restrict,
  constraint party_not_merged_into_self check (merged_into_id is distinct from id)
);

create index on erp.party (tenant_id, status);
create index on erp.party (tenant_id, name);

create table erp.party_role (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  party_id     uuid not null,
  role_kind    erp.party_role_kind not null,
  -- Role-specific attributes rather than a hundred mostly-null columns on the
  -- party: a carrier's service codes have nothing to say about a customer.
  attributes   jsonb not null default '{}'::jsonb,
  -- Spec 5.3: approved-supplier control.
  is_approved  boolean not null default false,
  approved_by  uuid,
  approved_at  timestamptz,
  approval_expires_at date,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, party_id, role_kind),
  foreign key (tenant_id, party_id)
    references erp.party (tenant_id, id) on delete cascade
);

create index on erp.party_role (tenant_id, role_kind) where status = 'active';

create type erp.address_kind as enum (
  'registered', 'billing', 'delivery', 'collection', 'remittance', 'returns'
);

create table erp.party_address (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  party_id     uuid not null,
  address_kind erp.address_kind not null,
  label        text,
  lines        text[] not null default '{}'::text[],
  locality     text,
  region       text,
  postcode     text,
  country_code char(2) references erp_ref.country(code),
  geo          jsonb,
  is_default   boolean not null default false,
  -- Typed and effective-dated: an address change is a fact with a date, and a
  -- delivery note printed last year should still show where it went.
  valid_from   date not null default current_date,
  valid_to     date,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, party_id)
    references erp.party (tenant_id, id) on delete cascade,
  constraint party_address_range check (valid_to is null or valid_to > valid_from)
);

create index on erp.party_address (tenant_id, party_id, address_kind);

create table erp.party_contact (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  party_id     uuid not null,
  contact_kind text not null,
  name         text,
  email        text,
  phone        text,
  role_title   text,
  notes        text,
  is_default   boolean not null default false,
  valid_from   date not null default current_date,
  valid_to     date,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, party_id)
    references erp.party (tenant_id, id) on delete cascade,
  constraint party_contact_range check (valid_to is null or valid_to > valid_from)
);

-- Commercial terms: per role, per entity. The invariant made concrete.
create table erp.party_role_terms (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  party_role_id     uuid not null,
  entity_id         uuid not null,
  currency          char(3) references erp_ref.currency(code),
  payment_terms_code text,
  payment_days      smallint,
  tax_rule_code     text,
  incoterms_code    text,
  incoterms_place   text,
  price_list_code   text,
  -- Money in minor units, never floating point (spec 4.10).
  credit_limit_minor bigint check (credit_limit_minor is null or credit_limit_minor >= 0),
  credit_status     text not null default 'ok'
                      check (credit_status in ('ok', 'watch', 'hold', 'stop')),
  is_blocked        boolean not null default false,
  block_reason      text,
  valid_from        date not null default current_date,
  valid_to          date,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id),
  foreign key (tenant_id, party_role_id)
    references erp.party_role (tenant_id, id) on delete cascade,
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  constraint party_role_terms_range check (valid_to is null or valid_to > valid_from),
  -- One set of terms in force per role per entity at a time.
  constraint party_role_terms_no_overlap
    exclude using gist (
      tenant_id with =,
      party_role_id with =,
      entity_id with =,
      daterange(valid_from, valid_to, '[)') with &&
    )
);

create index on erp.party_role_terms (tenant_id, entity_id, party_role_id);

-- -----------------------------------------------------------------------------
-- Units of measure
--
-- Spec 4.3: stock, purchase, sales and packing units with conversions, and
-- catch-weight support. Catch weight is the case where the unit you count in
-- and the unit you sell in are not proportional — a carcass is one item but
-- weighs what it weighs — so the conversion is per batch, not per item.
-- -----------------------------------------------------------------------------

create type erp.uom_class as enum (
  'quantity', 'mass', 'volume', 'length', 'area', 'time', 'packaging'
);

create table erp.uom (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  code        text not null,
  name        text not null,
  uom_class   erp.uom_class not null,
  -- Decimal places permitted. An item counted in pieces cannot be 2.5 of them.
  decimals    smallint not null default 0 check (decimals between 0 and 6),
  is_base     boolean not null default false,
  status      erp.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

-- One base unit per class, so any two units of a class are convertible.
create unique index uom_one_base_per_class
  on erp.uom (tenant_id, uom_class) where is_base;

create table erp.uom_conversion (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  from_uom_id   uuid not null,
  to_uom_id     uuid not null,
  -- to_quantity = from_quantity * factor. Numeric, never float.
  factor        numeric(30,12) not null check (factor > 0),
  -- Null means the conversion holds for every item. Set for item-specific
  -- packaging: a case of one product is not a case of another.
  item_id       uuid,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  foreign key (tenant_id, from_uom_id) references erp.uom (tenant_id, id) on delete cascade,
  foreign key (tenant_id, to_uom_id)   references erp.uom (tenant_id, id) on delete cascade,
  constraint uom_conversion_distinct check (from_uom_id <> to_uom_id)
);

create unique index uom_conversion_identity
  on erp.uom_conversion (tenant_id, from_uom_id, to_uom_id,
                         coalesce(item_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- -----------------------------------------------------------------------------
-- Items
-- -----------------------------------------------------------------------------

create type erp.item_lifecycle as enum (
  'draft', 'active', 'restricted', 'discontinued', 'obsolete'
);

create table erp.item (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  code               text not null,
  name               text not null,
  item_class         text,
  item_group         text,
  lifecycle          erp.item_lifecycle not null default 'draft',

  -- Control flags. These decide what the stock ledger is allowed to record,
  -- which is why 0023 refuses to change them while stock contradicts them.
  is_batch_controlled    boolean not null default false,
  is_serial_controlled   boolean not null default false,
  has_expiry             boolean not null default false,
  quarantine_on_receipt  boolean not null default false,
  is_fefo                boolean not null default false,
  is_catch_weight        boolean not null default false,
  shelf_life_days        integer check (shelf_life_days is null or shelf_life_days > 0),
  min_remaining_shelf_life_days integer,

  -- Units
  stock_uom_id       uuid not null,
  purchase_uom_id    uuid,
  sales_uom_id       uuid,

  -- Regulatory and physical attributes, typed per tenant by configuration
  -- rather than by columns the product would have to guess at.
  regulatory         jsonb not null default '{}'::jsonb,
  attributes         jsonb not null default '{}'::jsonb,
  gross_weight_g     numeric(20,6),
  net_weight_g       numeric(20,6),
  volume_ml          numeric(20,6),

  status             erp.record_status not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, stock_uom_id)    references erp.uom (tenant_id, id) on delete restrict,
  foreign key (tenant_id, purchase_uom_id) references erp.uom (tenant_id, id) on delete restrict,
  foreign key (tenant_id, sales_uom_id)    references erp.uom (tenant_id, id) on delete restrict,
  -- Expiry without batch control has nowhere to live: an expiry date is an
  -- attribute of a batch, not of an item.
  constraint item_expiry_needs_batches
    check (not has_expiry or is_batch_controlled),
  -- FEFO means "first expired, first out". Without expiry there is no order.
  constraint item_fefo_needs_expiry
    check (not is_fefo or has_expiry),
  -- Catch weight means the stock unit and the selling unit are not
  -- proportional, which is a per-batch fact and so needs batches.
  constraint item_catch_weight_needs_batches
    check (not is_catch_weight or is_batch_controlled)
);

create index on erp.item (tenant_id, lifecycle) where status = 'active';
create index on erp.item (tenant_id, item_class);
create index on erp.item using gin (attributes jsonb_path_ops);

-- Spec 4.3: descriptions (localised). Tenant-authored, so not resource keys.
create table erp.item_description (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  item_id      uuid not null,
  locale       text not null references erp_ref.locale(code),
  description  text not null,
  short_description text,
  -- What appears on a customer-facing document, where that differs from the
  -- internal description.
  document_description text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, item_id, locale),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade
);

create table erp.item_barcode (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  item_id     uuid not null,
  barcode     text not null,
  barcode_kind text not null default 'ean13',
  uom_id      uuid,
  is_primary  boolean not null default false,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (id),
  unique (tenant_id, barcode),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, uom_id)  references erp.uom (tenant_id, id) on delete restrict
);

-- Per-site planning and control parameters (spec 4.3).
create table erp.item_site (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  item_id            uuid not null,
  site_id            uuid not null,
  is_stocked         boolean not null default true,
  default_location_id uuid,
  -- Planning parameters; the planning engine reads these (spec 4.6).
  planning_policy_code text,
  safety_stock       numeric(20,6),
  reorder_point      numeric(20,6),
  order_up_to        numeric(20,6),
  min_order_quantity numeric(20,6),
  order_multiple     numeric(20,6),
  lead_time_days     integer,
  abc_class          char(1),
  count_class        text,
  status             erp.record_status not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  unique (tenant_id, item_id, site_id),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, default_location_id)
    references erp.location (tenant_id, id) on delete set null
);

-- Price lists and cost records with validity ranges (spec 4.3).
create type erp.price_kind as enum (
  'sales_list', 'purchase_list', 'contract', 'promotion',
  'standard_cost', 'last_cost', 'average_cost'
);

create table erp.item_price (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  item_id       uuid not null,
  price_kind    erp.price_kind not null,
  price_list_code text,
  entity_id     uuid,
  site_id       uuid,
  -- Set for a contract or customer-specific price.
  party_role_id uuid,
  currency      char(3) not null references erp_ref.currency(code),
  -- Minor units, integer. A price of £12.34 is 1234.
  amount_minor  bigint not null,
  per_quantity  numeric(20,6) not null default 1 check (per_quantity > 0),
  uom_id        uuid,
  min_quantity  numeric(20,6) not null default 0,
  valid_from    date not null default current_date,
  valid_to      date,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, party_role_id)
    references erp.party_role (tenant_id, id) on delete cascade,
  foreign key (tenant_id, uom_id) references erp.uom (tenant_id, id) on delete restrict,
  constraint item_price_range check (valid_to is null or valid_to > valid_from)
);

create index on erp.item_price (tenant_id, item_id, price_kind, valid_from desc);

-- -----------------------------------------------------------------------------
-- Product structures
-- -----------------------------------------------------------------------------

create table erp.bom (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  item_id        uuid not null,
  site_id        uuid,
  version        integer not null default 1 check (version >= 1),
  name           text,
  -- Output of one run of this structure, in the item's stock unit.
  output_quantity numeric(20,6) not null default 1 check (output_quantity > 0),
  -- Expected yield: 0.98 means 2% is lost to the process itself.
  yield_factor   numeric(10,6) not null default 1
                   check (yield_factor > 0 and yield_factor <= 1),
  status         erp.config_version_status not null default 'draft',
  effective_from date not null default current_date,
  effective_to   date,
  -- Spec 5.5: engineering change control.
  change_reference text,
  approved_by    uuid,
  approved_at    timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code, version),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  constraint bom_range check (effective_to is null or effective_to > effective_from),
  -- One structure in force per item per site at a time, or "how do we make
  -- this" has more than one answer.
  constraint bom_no_overlap
    exclude using gist (
      tenant_id with =,
      item_id with =,
      coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid) with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

create table erp.bom_line (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  bom_id          uuid not null,
  seq             integer not null,
  component_item_id uuid not null,
  quantity        numeric(20,6) not null check (quantity > 0),
  uom_id          uuid not null,
  -- Expected loss of THIS component in THIS process, distinct from the
  -- structure's overall yield: one component may be wasteful while others
  -- are not.
  scrap_factor    numeric(10,6) not null default 0
                    check (scrap_factor >= 0 and scrap_factor < 1),
  -- An alternate is interchangeable by design; a substitute is a fallback.
  -- The difference matters to planning and to quality.
  is_alternate    boolean not null default false,
  alternate_group text,
  substitute_for_line_id uuid,
  is_phantom      boolean not null default false,
  operation_seq   integer,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, bom_id, seq),
  foreign key (tenant_id, bom_id) references erp.bom (tenant_id, id) on delete cascade,
  foreign key (tenant_id, component_item_id)
    references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, uom_id) references erp.uom (tenant_id, id) on delete restrict,
  foreign key (tenant_id, substitute_for_line_id)
    references erp.bom_line (tenant_id, id) on delete cascade
);

create index on erp.bom_line (tenant_id, bom_id, seq);
create index on erp.bom_line (tenant_id, component_item_id);

create table erp.routing (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  item_id        uuid,
  site_id        uuid,
  version        integer not null default 1,
  name           text,
  status         erp.config_version_status not null default 'draft',
  effective_from date not null default current_date,
  effective_to   date,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code, version),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  constraint routing_range check (effective_to is null or effective_to > effective_from)
);

create table erp.routing_operation (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  routing_id      uuid not null,
  seq             integer not null,
  code            text not null,
  name            text,
  resource_code   text,
  work_centre_code text,
  -- Setup is paid once per run; run time scales with quantity. Conflating them
  -- makes small batches look cheap and large ones expensive.
  setup_minutes   numeric(12,4) not null default 0 check (setup_minutes >= 0),
  run_minutes_per_unit numeric(12,6) not null default 0 check (run_minutes_per_unit >= 0),
  queue_minutes   numeric(12,4) not null default 0,
  move_minutes    numeric(12,4) not null default 0,
  cost_rate_minor_per_hour bigint,
  is_milestone    boolean not null default false,
  instructions    text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, routing_id, seq),
  foreign key (tenant_id, routing_id) references erp.routing (tenant_id, id) on delete cascade
);

-- -----------------------------------------------------------------------------
-- A structure may not contain itself
--
-- A bill of materials that reaches its own output item, at any depth, makes
-- explosion non-terminating and cost roll-up meaningless. Cheap to check on
-- write; impossible to recover from once planning has run on it.
-- -----------------------------------------------------------------------------

create or replace function erp.check_bom_acyclic()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_output uuid;
  v_cycle  boolean;
begin
  select b.item_id into v_output from erp.bom b where b.id = new.bom_id;

  if v_output = new.component_item_id then
    raise exception 'ERPWARE_BOM_SELF_REFERENCE: an item cannot be a component of itself'
      using errcode = '23514';
  end if;

  -- Walk down from the new component: if the structure's own output item
  -- appears anywhere beneath it, this line closes a loop.
  with recursive descent as (
    select new.component_item_id as item_id, 1 as depth
    union all
    select bl.component_item_id, d.depth + 1
      from descent d
      join erp.bom b
        on b.tenant_id = new.tenant_id and b.item_id = d.item_id
       and b.status in ('active', 'draft')
      join erp.bom_line bl
        on bl.tenant_id = b.tenant_id and bl.bom_id = b.id
     where d.depth < 50
  )
  select exists (select 1 from descent where item_id = v_output) into v_cycle;

  if v_cycle then
    raise exception
      'ERPWARE_BOM_CYCLE: adding this component would make the structure contain itself'
      using errcode = '23514',
            hint = 'Explosion would not terminate and cost roll-up would not converge.';
  end if;

  return new;
end;
$$;

create trigger t_bom_line_acyclic
  before insert or update of component_item_id, bom_id on erp.bom_line
  for each row execute function erp.check_bom_acyclic();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
