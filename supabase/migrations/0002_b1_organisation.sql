-- =============================================================================
-- ERPWare — B1 (part 2/4): organisational hierarchy
-- Spec: 2.1 (tenant -> entity -> site -> location), 4.1 (Organisation)
--
-- Invariant 4.1: "every operational object resolves to exactly one entity and,
-- where physical, exactly one site."
--
-- The hierarchy is stitched together with COMPOSITE foreign keys that carry
-- tenant_id through every link. A site therefore cannot reference an entity in
-- another tenant even if application code asks it to: the reference itself is
-- (tenant_id, id), so a cross-tenant parent is a foreign key violation rather
-- than a leak.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- erp_ref — product content (spec 2.3)
--
-- "Product content ships with the release and is identical for every tenant."
-- Tenant-neutral, readable by all tenants, writable by none of them.
-- -----------------------------------------------------------------------------

create schema if not exists erp_ref;

comment on schema erp_ref is
  'Product content: tenant-neutral reference data that ships with the release. '
  'Identical for every tenant, derived from standards, never from a customer.';

create table erp_ref.currency (
  code            char(3) primary key,      -- ISO 4217
  name            text not null,
  minor_units     smallint not null default 2 check (minor_units between 0 and 4),
  is_active       boolean not null default true
);

comment on column erp_ref.currency.minor_units is
  'Decimal places. Money is stored as an integer count of these (spec 4.10): '
  'no floating point anywhere in the money path.';

create table erp_ref.country (
  code            char(2) primary key,      -- ISO 3166-1 alpha-2
  name            text not null,
  default_currency char(3) references erp_ref.currency(code),
  is_active       boolean not null default true
);

-- -----------------------------------------------------------------------------
-- calendar — working days, shifts, holidays (spec 4.1)
-- "drives all lead-time and date arithmetic"
-- -----------------------------------------------------------------------------

create table erp.calendar (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null,
  name            text not null,
  timezone        text not null default 'UTC',
  -- Index 0 = Monday .. 6 = Sunday. A working-day mask rather than a row per
  -- day, so the common case needs no expansion.
  working_days    boolean[] not null default '{t,t,t,t,t,f,f}'
                    check (array_length(working_days, 1) = 7),
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, code),
  -- The target of every composite tenant-carrying foreign key below.
  unique (tenant_id, id)
);

create table erp.calendar_exception (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  calendar_id     uuid not null,
  exception_date  date not null,
  is_working      boolean not null default false,
  description_key text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, calendar_id, exception_date),
  foreign key (tenant_id, calendar_id)
    references erp.calendar (tenant_id, id) on delete cascade
);

create table erp.shift (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  calendar_id     uuid not null,
  code            text not null,
  name            text not null,
  starts_at       time not null,
  ends_at         time not null,
  crosses_midnight boolean not null default false,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, calendar_id, code),
  foreign key (tenant_id, calendar_id)
    references erp.calendar (tenant_id, id) on delete cascade
);

-- -----------------------------------------------------------------------------
-- entity — legal entity (spec 4.1)
-- -----------------------------------------------------------------------------

create table erp.entity (
  id                  uuid not null default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  code                text not null,
  name                text not null,
  legal_name          text,
  -- Consolidation grouping. Same tenant by construction.
  parent_entity_id    uuid,
  base_currency       char(3) not null references erp_ref.currency(code),
  country_code        char(2) references erp_ref.country(code),
  reporting_locale    text not null default 'en',
  document_locale     text not null default 'en',
  fiscal_year_start_month smallint not null default 1
                        check (fiscal_year_start_month between 1 and 12),
  calendar_id         uuid,
  registration_number text,
  status              erp.record_status not null default 'active',
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  primary key (id),
  unique (tenant_id, code),
  unique (tenant_id, id),
  foreign key (tenant_id, parent_entity_id)
    references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, calendar_id)
    references erp.calendar (tenant_id, id) on delete restrict,
  constraint entity_not_own_parent check (parent_entity_id is distinct from id)
);

create index on erp.entity (tenant_id, status);

-- Spec 4.7: statutory reporting per jurisdiction. Registrations are per entity
-- and effective-dated, because a registration starts and ends.
create table erp.entity_tax_registration (
  id                  uuid not null default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  entity_id           uuid not null,
  jurisdiction        text not null,
  registration_type   text not null,
  registration_number text not null,
  valid_from          date not null,
  valid_to            date,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  primary key (id),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  constraint tax_registration_range check (valid_to is null or valid_to >= valid_from)
);

create index on erp.entity_tax_registration (tenant_id, entity_id, jurisdiction);

-- -----------------------------------------------------------------------------
-- site — physical or logical operating location under an entity (spec 4.1)
-- -----------------------------------------------------------------------------

create type erp.site_type as enum (
  'warehouse', 'production', 'distribution', 'retail',
  'office', 'third_party', 'virtual', 'in_transit'
);

create table erp.site (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  entity_id       uuid not null,
  code            text not null,
  name            text not null,
  site_type       erp.site_type not null,
  timezone        text not null default 'UTC',
  calendar_id     uuid,
  country_code    char(2) references erp_ref.country(code),
  address         jsonb not null default '{}'::jsonb,
  -- A site that is not physical holds no stock and owns no locations.
  is_physical     boolean not null default true,
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, code),
  unique (tenant_id, id),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, calendar_id)
    references erp.calendar (tenant_id, id) on delete restrict
);

create index on erp.site (tenant_id, entity_id, status);

-- Spec 4.1: sites carry licences. Regulatory posture is a property of the site.
create table erp.site_licence (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  site_id         uuid not null,
  licence_type    text not null,
  licence_number  text not null,
  issuing_body    text,
  valid_from      date not null,
  valid_to        date,
  scope           jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  foreign key (tenant_id, site_id)
    references erp.site (tenant_id, id) on delete cascade,
  constraint site_licence_range check (valid_to is null or valid_to >= valid_from)
);

create index on erp.site_licence (tenant_id, site_id, valid_to);

-- -----------------------------------------------------------------------------
-- location — structure within a site (spec 4.1)
-- hierarchical (zone, aisle, rack, bin), typed, with capacity, storage
-- conditions and count classification.
-- -----------------------------------------------------------------------------

create type erp.location_type as enum (
  'receiving', 'bulk', 'pick', 'quarantine', 'staging',
  'despatch', 'damages', 'production', 'scrap', 'transit', 'virtual'
);

create table erp.location (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  site_id         uuid not null,
  parent_location_id uuid,
  code            text not null,
  name            text,
  location_type   erp.location_type not null,
  depth           smallint not null default 0 check (depth >= 0),
  -- Materialised ancestry, maintained by trigger. Makes "everything beneath
  -- this location" a single indexed query rather than a recursive walk.
  path            uuid[] not null default '{}'::uuid[],
  capacity        jsonb not null default '{}'::jsonb,
  storage_conditions jsonb not null default '{}'::jsonb,
  count_class     text,
  is_pickable     boolean not null default true,
  -- Blocked locations still hold stock; they simply cannot be allocated from.
  is_blocked      boolean not null default false,
  block_reason_code text,
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, site_id, code),
  unique (tenant_id, id),
  foreign key (tenant_id, site_id)
    references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, parent_location_id)
    references erp.location (tenant_id, id) on delete restrict,
  constraint location_not_own_parent check (parent_location_id is distinct from id)
);

create index on erp.location (tenant_id, site_id, location_type)
  where status = 'active';
create index on erp.location using gin (path);

-- Keeps depth/path correct and refuses cycles and cross-site parenting.
create or replace function erp.maintain_location_path()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_parent_path uuid[];
  v_parent_site uuid;
begin
  if new.parent_location_id is null then
    new.depth := 0;
    new.path  := array[]::uuid[];
  else
    select l.path, l.site_id into v_parent_path, v_parent_site
      from erp.location l
     where l.id = new.parent_location_id
       and l.tenant_id = new.tenant_id;

    if not found then
      raise exception 'ERPWARE_LOCATION_PARENT_NOT_FOUND: % is not a location in this tenant',
        new.parent_location_id using errcode = '23503';
    end if;

    if v_parent_site is distinct from new.site_id then
      raise exception 'ERPWARE_LOCATION_CROSS_SITE: a location may not be nested under a location at another site'
        using errcode = '23514';
    end if;

    if new.id = any (v_parent_path) then
      raise exception 'ERPWARE_LOCATION_CYCLE: % would become its own ancestor', new.id
        using errcode = '23514';
    end if;

    new.path  := v_parent_path || new.parent_location_id;
    new.depth := array_length(new.path, 1);
  end if;
  return new;
end;
$$;

create trigger t_location_path
  before insert or update of parent_location_id, site_id on erp.location
  for each row execute function erp.maintain_location_path();

-- -----------------------------------------------------------------------------
-- Attribution + tenant-immutability triggers for this migration's tables
-- -----------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'calendar', 'calendar_exception', 'shift', 'entity',
    'entity_tax_registration', 'site', 'site_licence', 'location'
  ] loop
    execute format(
      'create trigger t_%1$s_attribution before insert or update on erp.%1$I
         for each row execute function erp.touch_attribution()', t);
    execute format(
      'create trigger t_%1$s_freeze before update on erp.%1$I
         for each row execute function erp.freeze_tenant_id()', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Calendar arithmetic (spec 4.1: "drives all lead-time and date arithmetic")
-- -----------------------------------------------------------------------------

create or replace function erp.is_working_day(p_calendar_id uuid, p_date date)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_mask boolean[];
  v_exception boolean;
begin
  select c.working_days into v_mask
    from erp.calendar c
   where c.id = p_calendar_id;

  if v_mask is null then
    raise exception 'ERPWARE_CALENDAR_NOT_FOUND: %', p_calendar_id using errcode = '23503';
  end if;

  select ce.is_working into v_exception
    from erp.calendar_exception ce
   where ce.calendar_id = p_calendar_id
     and ce.exception_date = p_date;

  if found then
    return v_exception;
  end if;

  -- isodow: 1 = Monday .. 7 = Sunday; the mask is 0-indexed from Monday.
  return v_mask[extract(isodow from p_date)::int];
end;
$$;

create or replace function erp.add_working_days(
  p_calendar_id uuid, p_from date, p_days integer)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v_date date := p_from;
  v_step integer := case when p_days < 0 then -1 else 1 end;
  v_left integer := abs(p_days);
  v_guard integer := 0;
begin
  while v_left > 0 loop
    v_date := v_date + v_step;
    v_guard := v_guard + 1;
    if v_guard > 100000 then
      raise exception 'ERPWARE_CALENDAR_NO_WORKING_DAYS: calendar % has no working days', p_calendar_id;
    end if;
    if erp.is_working_day(p_calendar_id, v_date) then
      v_left := v_left - 1;
    end if;
  end loop;
  return v_date;
end;
$$;
