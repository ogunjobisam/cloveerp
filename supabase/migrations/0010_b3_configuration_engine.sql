-- =============================================================================
-- ERPWare — B3 (part 1/2): the configuration engine
-- Spec 3.4:
--   "Configuration objects are typed, versioned, effective-dated,
--    tenant-scoped, with full change history"
--   "Configuration is data, so it is queryable, diffable, promotable and
--    revertible"
--
-- This is the table that objective O1 stands or falls on. "Two tenants with
-- different processes run the same binary" is only true if the difference has
-- somewhere to live that is not a code branch.
--
-- Four properties are enforced rather than intended:
--
--   typed            every configuration type ships with a JSON Schema, and a
--                    value that does not satisfy it is refused at write time.
--                    A configuration store that accepts anything is a hash map
--                    with extra steps.
--
--   effective-dated  active versions of one object cannot overlap in time.
--                    An exclusion constraint, not a convention — because
--                    "which value was in force on the 3rd?" must have exactly
--                    one answer, for ever.
--
--   versioned        values are never updated in place. A change is a new
--                    version; the old one is closed off, not overwritten.
--
--   scoped           values resolve down the organisational hierarchy
--                    (site, then entity, then tenant), so a site can differ
--                    without every other site restating the default.
-- =============================================================================

create extension if not exists btree_gist with schema extensions;

-- -----------------------------------------------------------------------------
-- Configuration types (product content)
--
-- The catalogue of things that CAN be configured ships with the release. A
-- tenant configures from this list; adding to the list is a product change.
-- That boundary is what stops "configuration" becoming an untyped free-for-all.
-- -----------------------------------------------------------------------------

create type erp.config_domain as enum (
  'org_structure', 'policy', 'rule', 'threshold', 'mapping', 'template',
  'approval_chain', 'state_machine', 'terminology', 'report', 'integration',
  'numbering', 'reason_code'
);

create type erp.config_scope_level as enum ('tenant', 'entity', 'site');

create table erp_ref.config_type (
  code            text primary key
                    check (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  domain          erp.config_domain not null,
  module_code     text references erp_ref.module(code),
  name_key        text not null,
  description     text,
  -- The JSON Schema every value of this type must satisfy.
  value_schema    jsonb not null default '{"type":"object"}'::jsonb,
  -- The most specific scope a value of this type may be bound to. A type
  -- declared 'entity' may be set tenant-wide or per entity, but not per site.
  max_scope_level erp.config_scope_level not null default 'site',
  -- Singleton types have one object per scope and need no code of their own.
  is_singleton    boolean not null default false,
  -- A neutral starting value, derived from standards or common practice and
  -- never from a customer's configuration (spec 2.3).
  default_value   jsonb
);

comment on table erp_ref.config_type is
  'Product content. The catalogue of what can be configured, each entry typed '
  'by a JSON Schema. Tenants configure from this list; extending the list is a '
  'product change, which is what keeps configuration typed rather than free.';

-- -----------------------------------------------------------------------------
-- Configuration objects (tenant content) — the identity of a configured thing
-- -----------------------------------------------------------------------------

create table erp.config_object (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  config_type_code text not null references erp_ref.config_type(code),
  -- Null for singleton types.
  code             text,
  -- Scope. Both null = tenant-wide. entity only = that entity. Both = that site.
  entity_id        uuid,
  site_id          uuid,
  description      text,
  status           erp.record_status not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)
    references erp.site (tenant_id, id) on delete cascade,
  constraint config_object_site_needs_entity
    check (site_id is null or entity_id is not null)
);

-- One object per (type, code, scope). The coalesce dance is because NULL scope
-- means "tenant-wide", which is a real value here rather than an unknown.
create unique index config_object_identity
  on erp.config_object (
    tenant_id, config_type_code,
    coalesce(code, ''),
    coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(site_id,   '00000000-0000-0000-0000-000000000000'::uuid));

create index on erp.config_object (tenant_id, config_type_code)
  where status = 'active';

-- A singleton type carries no code; a non-singleton type requires one. Checked
-- against the registry rather than duplicated as a column.
create or replace function erp.check_config_object_shape()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_singleton boolean;
  v_max_scope erp.config_scope_level;
begin
  select ct.is_singleton, ct.max_scope_level
    into v_singleton, v_max_scope
    from erp_ref.config_type ct
   where ct.code = new.config_type_code;

  if v_singleton and new.code is not null then
    raise exception 'ERPWARE_CONFIG_SINGLETON_CODED: % is a singleton type and takes no code',
      new.config_type_code using errcode = '23514';
  end if;

  if not v_singleton and new.code is null then
    raise exception 'ERPWARE_CONFIG_CODE_REQUIRED: % requires a code',
      new.config_type_code using errcode = '23514';
  end if;

  if v_max_scope = 'tenant' and new.entity_id is not null then
    raise exception 'ERPWARE_CONFIG_SCOPE_TOO_NARROW: % may only be set tenant-wide',
      new.config_type_code using errcode = '23514';
  end if;

  if v_max_scope = 'entity' and new.site_id is not null then
    raise exception 'ERPWARE_CONFIG_SCOPE_TOO_NARROW: % may not be set per site',
      new.config_type_code using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger t_config_object_shape
  before insert or update on erp.config_object
  for each row execute function erp.check_config_object_shape();

-- -----------------------------------------------------------------------------
-- Configuration versions — the value, in force over a period
-- -----------------------------------------------------------------------------

create type erp.config_version_status as enum (
  'draft',       -- being authored, not in force
  'active',      -- in force over its effective range
  'superseded',  -- replaced by a later version
  'withdrawn'    -- retired without a replacement
);

create table erp.config_version (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  config_object_id uuid not null,
  version          integer not null check (version >= 1),
  value            jsonb not null,
  status           erp.config_version_status not null default 'draft',

  -- Effective dating. effective_to is exclusive and null means open-ended.
  effective_from   date not null default current_date,
  effective_to     date,

  -- Provenance. change_set_id is filled in by B6 promotion.
  change_set_id    uuid,
  note             text,
  approved_by      uuid,
  approved_at      timestamptz,

  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,

  primary key (id),
  unique (tenant_id, config_object_id, version),
  foreign key (tenant_id, config_object_id)
    references erp.config_object (tenant_id, id) on delete cascade,
  constraint config_version_range
    check (effective_to is null or effective_to > effective_from),

  -- The property the whole engine rests on: at most one active value per
  -- object per day. "Which value was in force on the 3rd?" has exactly one
  -- answer, and the database is what guarantees it.
  constraint config_version_no_overlap
    exclude using gist (
      tenant_id with =,
      config_object_id with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

create index on erp.config_version (tenant_id, config_object_id, version desc);
create index on erp.config_version (tenant_id, status, effective_from);

comment on constraint config_version_no_overlap on erp.config_version is
  'At most one active version of a configuration object on any given day. '
  'Without this, "which rule was in force at the transaction date" has more '
  'than one answer and every downstream posting becomes unreproducible.';

-- Values are typed: validated against the schema their type registered.
create or replace function erp.validate_config_value()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_schema jsonb;
  v_type   text;
begin
  select ct.value_schema, ct.code
    into v_schema, v_type
    from erp.config_object co
    join erp_ref.config_type ct on ct.code = co.config_type_code
   where co.id = new.config_object_id;

  if not found then
    raise exception 'ERPWARE_CONFIG_OBJECT_NOT_FOUND: %', new.config_object_id
      using errcode = '23503';
  end if;

  if not extensions.jsonb_matches_schema(v_schema::json, new.value) then
    raise exception 'ERPWARE_CONFIG_VALUE_INVALID: value does not satisfy the schema for %',
      v_type
      using errcode = '23514', detail = new.value::text;
  end if;

  return new;
end;
$$;

create trigger t_config_version_validate
  before insert or update of value on erp.config_version
  for each row execute function erp.validate_config_value();

-- An active version is a historical fact about what the system was doing. Its
-- value may not be edited; superseding it with a new version is the only way
-- to change what is in force.
create or replace function erp.protect_active_config_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'active' and new.value is distinct from old.value then
    raise exception
      'ERPWARE_CONFIG_ACTIVE_IMMUTABLE: version % is in force and cannot be edited; supersede it instead',
      old.version using errcode = '42501';
  end if;

  if old.status = 'active' and new.effective_from is distinct from old.effective_from then
    raise exception
      'ERPWARE_CONFIG_ACTIVE_IMMUTABLE: the start of an in-force version cannot be moved';
  end if;

  return new;
end;
$$;

create trigger t_config_version_protect
  before update on erp.config_version
  for each row execute function erp.protect_active_config_version();

-- -----------------------------------------------------------------------------
-- Resolution
--
-- Spec 2.1: "Scoping rules cascade down this hierarchy". A value set at the
-- site wins over one set at the entity, which wins over the tenant default —
-- so a site that differs states only its difference.
-- -----------------------------------------------------------------------------

create or replace function erp.config_value(
  p_type_code text,
  p_code      text default null,
  p_on        date default null,
  p_entity_id uuid default null,
  p_site_id   uuid default null
) returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    (select cv.value
       from erp.config_object co
       join erp.config_version cv
         on cv.tenant_id = co.tenant_id
        and cv.config_object_id = co.id
        and cv.status = 'active'
        and daterange(cv.effective_from, cv.effective_to, '[)')
              @> coalesce(p_on, current_date)
      where co.tenant_id = erp.require_tenant_id()
        and co.config_type_code = p_type_code
        and co.status = 'active'
        and co.code is not distinct from p_code
        -- A scope applies if it is the one asked for, or if it is broader.
        and (co.site_id   is null or co.site_id   = p_site_id)
        and (co.entity_id is null or co.entity_id = p_entity_id)
      -- Most specific wins.
      order by (co.site_id is not null) desc, (co.entity_id is not null) desc
      limit 1),
    -- Falling back to the product's neutral default is deliberate: a tenant
    -- that has not expressed an opinion gets standard behaviour rather than
    -- an error, which is what makes onboarding possible without engineering.
    (select ct.default_value from erp_ref.config_type ct where ct.code = p_type_code)
  )
$$;

comment on function erp.config_value is
  'Resolves a configuration value as at a date, most specific scope first '
  '(site, entity, tenant), falling back to the product''s neutral default.';

-- Which object and version actually answered — for explaining a decision, and
-- for the impact analysis in B10.
create or replace function erp.config_resolution(
  p_type_code text,
  p_code      text default null,
  p_on        date default null,
  p_entity_id uuid default null,
  p_site_id   uuid default null
) returns table (
  config_object_id uuid,
  config_version_id uuid,
  version integer,
  scope text,
  value jsonb,
  effective_from date,
  effective_to date
)
language sql
stable
security invoker
set search_path = ''
as $$
  select co.id, cv.id, cv.version,
         case when co.site_id is not null then 'site'
              when co.entity_id is not null then 'entity'
              else 'tenant' end,
         cv.value, cv.effective_from, cv.effective_to
    from erp.config_object co
    join erp.config_version cv
      on cv.tenant_id = co.tenant_id
     and cv.config_object_id = co.id
     and cv.status = 'active'
     and daterange(cv.effective_from, cv.effective_to, '[)')
           @> coalesce(p_on, current_date)
   where co.tenant_id = erp.require_tenant_id()
     and co.config_type_code = p_type_code
     and co.status = 'active'
     and co.code is not distinct from p_code
     and (co.site_id   is null or co.site_id   = p_site_id)
     and (co.entity_id is null or co.entity_id = p_entity_id)
   order by (co.site_id is not null) desc, (co.entity_id is not null) desc
   limit 1
$$;

-- -----------------------------------------------------------------------------
-- Authoring
--
-- Setting a value is "supersede, then insert" rather than "update". The old
-- version keeps its dates and becomes history.
-- -----------------------------------------------------------------------------

create or replace function erp.set_config_value(
  p_type_code      text,
  p_value          jsonb,
  p_code           text default null,
  p_effective_from date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null,
  p_note           text default null,
  p_activate       boolean default true
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_object  uuid;
  v_from    date := coalesce(p_effective_from, current_date);
  v_version integer;
  v_new     uuid;
begin
  insert into erp.config_object (tenant_id, config_type_code, code, entity_id, site_id)
  values (v_tenant, p_type_code, p_code, p_entity_id, p_site_id)
  on conflict (tenant_id, config_type_code, coalesce(code, ''),
               coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
               coalesce(site_id,   '00000000-0000-0000-0000-000000000000'::uuid))
    do update set status = 'active', updated_at = now()
  returning id into v_object;

  select coalesce(max(cv.version), 0) + 1
    into v_version
    from erp.config_version cv
   where cv.tenant_id = v_tenant and cv.config_object_id = v_object;

  if p_activate then
    -- Close the version currently in force at the new start date, rather than
    -- deleting it: what was in force yesterday stays answerable for ever.
    update erp.config_version cv
       set effective_to = v_from,
           status = case when cv.effective_from >= v_from then 'superseded'
                         else cv.status end,
           updated_at = now()
     where cv.tenant_id = v_tenant
       and cv.config_object_id = v_object
       and cv.status = 'active'
       and (cv.effective_to is null or cv.effective_to > v_from);

    -- A version that would now be empty (superseded before it ever started)
    -- is marked as such rather than left looking active.
    update erp.config_version cv
       set status = 'superseded', updated_at = now()
     where cv.tenant_id = v_tenant
       and cv.config_object_id = v_object
       and cv.status = 'active'
       and cv.effective_to is not null
       and cv.effective_to <= cv.effective_from;
  end if;

  insert into erp.config_version (
    tenant_id, config_object_id, version, value, status, effective_from, note)
  values (
    v_tenant, v_object, v_version, p_value,
    case when p_activate then 'active' else 'draft' end,
    v_from, p_note)
  returning id into v_new;

  return v_new;
end;
$$;

comment on function erp.set_config_value is
  'Records a new configuration value from a date. Never edits what is in '
  'force: the previous version is closed off at the new start date and kept, '
  'so the value that applied to an old transaction is still retrievable.';

-- -----------------------------------------------------------------------------
-- Diffing
--
-- Spec 3.4 asks for configuration to be diffable, and B6 needs it for change
-- sets and blast-radius previews. Flattening to leaf paths makes a diff read
-- as "this setting changed" rather than "this document changed".
-- -----------------------------------------------------------------------------

-- Arrays are leaves. A reordered list of approvers is one changed setting, not
-- N added and N removed ones, and reading it that way makes a diff legible.
create or replace function erp.jsonb_flatten(p_value jsonb, p_prefix text default '')
returns table (path text, value jsonb)
language plpgsql
immutable
set search_path = ''
as $$
declare
  rec record;
  v_child text;
begin
  if jsonb_typeof(p_value) <> 'object' or p_value = '{}'::jsonb then
    path := p_prefix; value := p_value; return next; return;
  end if;

  for rec in select e.key as k, e.value as v from jsonb_each(p_value) e order by e.key loop
    v_child := case when p_prefix = '' then rec.k else p_prefix || '.' || rec.k end;

    if jsonb_typeof(rec.v) = 'object' and rec.v <> '{}'::jsonb then
      return query select f.path, f.value from erp.jsonb_flatten(rec.v, v_child) f;
    else
      path := v_child; value := rec.v; return next;
    end if;
  end loop;
end;
$$;

create or replace function erp.config_diff(p_from jsonb, p_to jsonb)
returns table (path text, change text, old_value jsonb, new_value jsonb)
language sql
immutable
set search_path = ''
as $$
  select coalesce(a.path, b.path),
         case when a.path is null then 'added'
              when b.path is null then 'removed'
              else 'changed' end,
         a.value, b.value
    from erp.jsonb_flatten(coalesce(p_from, '{}'::jsonb)) a
    full outer join erp.jsonb_flatten(coalesce(p_to, '{}'::jsonb)) b
      on a.path = b.path
   where a.value is distinct from b.value
   order by 1
$$;

create or replace function erp.config_version_diff(
  p_config_object_id uuid, p_from_version integer, p_to_version integer)
returns table (path text, change text, old_value jsonb, new_value jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  select d.*
    from erp.config_diff(
      (select cv.value from erp.config_version cv
        where cv.tenant_id = erp.require_tenant_id()
          and cv.config_object_id = p_config_object_id
          and cv.version = p_from_version),
      (select cv.value from erp.config_version cv
        where cv.tenant_id = erp.require_tenant_id()
          and cv.config_object_id = p_config_object_id
          and cv.version = p_to_version)) d
$$;

-- -----------------------------------------------------------------------------
-- History
-- -----------------------------------------------------------------------------

create view erp.config_history as
select
  co.tenant_id,
  co.id                as config_object_id,
  co.config_type_code,
  ct.domain,
  co.code,
  co.entity_id,
  co.site_id,
  case when co.site_id is not null then 'site'
       when co.entity_id is not null then 'entity'
       else 'tenant' end as scope,
  cv.id                as config_version_id,
  cv.version,
  cv.status,
  cv.value,
  cv.effective_from,
  cv.effective_to,
  cv.note,
  cv.change_set_id,
  cv.created_at,
  cv.created_by,
  cv.approved_by,
  cv.approved_at
from erp.config_object co
join erp_ref.config_type ct on ct.code = co.config_type_code
join erp.config_version cv
  on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id;

comment on view erp.config_history is
  'Spec 3.4: full change history. Every value a tenant has ever had in force, '
  'with its dates, its author and the change set that promoted it.';

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
