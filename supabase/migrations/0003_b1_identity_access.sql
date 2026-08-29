-- =============================================================================
-- ERPWare — B1 (part 3/4): identity, roles, permissions, segregation of duties
-- Spec: 3.1 (Identity and access)
--
--   "Role-based access with permissions at module and action granularity,
--    scoped by entity, site and, where needed, data class."
--
-- The permission CATALOGUE is product content: the set of things the software
-- can do ships with the release and is identical for every tenant. Roles, and
-- the grants that bind roles to people, are tenant content.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Permission catalogue (product content)
-- -----------------------------------------------------------------------------

create table erp_ref.module (
  code            text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key        text not null,
  sort_order      smallint not null default 100
);

create table erp_ref.permission (
  code            text primary key check (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  module_code     text not null references erp_ref.module(code),
  action          text not null,
  name_key        text not null,
  -- Some permissions are further narrowed by the class of data they touch
  -- (e.g. costs, margins, personal data). Where false, data_classes on a grant
  -- is meaningless and must be empty.
  data_class_aware boolean not null default false,
  -- Marks the permission as one that changes state, for SoD analysis.
  is_mutating     boolean not null default true
);

comment on table erp_ref.permission is
  'Product content. The complete set of module.action pairs the software can '
  'perform. Tenants grant from this list; they never add to it.';

-- -----------------------------------------------------------------------------
-- Identity providers (spec 3.1: "the tenant''s chosen identity provider")
-- -----------------------------------------------------------------------------

create table erp.identity_provider (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null,
  kind            text not null check (kind in ('oidc', 'saml', 'password', 'scim')),
  -- Connection settings only. No secret material: those are KMS references.
  config          jsonb not null default '{}'::jsonb,
  secret_ref      text,
  email_domains   text[] not null default '{}'::text[],
  is_default      boolean not null default false,
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, code)
);

-- Spec 3.1: "service principals for integrations and jobs".
create table erp.service_credential (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  app_user_id     uuid not null,
  label           text not null,
  secret_ref      text not null,
  secret_hint     text,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  last_used_at    timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  foreign key (tenant_id, app_user_id)
    references erp.app_user (tenant_id, id) on delete cascade
);

create index on erp.service_credential (tenant_id, app_user_id) where revoked_at is null;

-- -----------------------------------------------------------------------------
-- Roles and grants (tenant content)
-- -----------------------------------------------------------------------------

create table erp.role (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null,
  -- name_key resolves through the resource layer for roles that came from a
  -- neutral starter template; name carries a tenant's own wording.
  name_key        text,
  name            text,
  description     text,
  -- Roles seeded from a starter template are marked so that promotion and
  -- conformance can tell product-shaped roles from tenant-authored ones.
  from_template   text,
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, code),
  unique (tenant_id, id),
  constraint role_has_a_label check (name_key is not null or name is not null)
);

create table erp.role_permission (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  role_id         uuid not null,
  permission_code text not null references erp_ref.permission(code),
  -- Empty means "every data class". Only meaningful where the permission is
  -- data_class_aware; enforced by trigger below.
  data_classes    text[] not null default '{}'::text[],
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, role_id, permission_code),
  foreign key (tenant_id, role_id)
    references erp.role (tenant_id, id) on delete cascade
);

create or replace function erp.check_data_class_grant()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_aware boolean;
begin
  select p.data_class_aware into v_aware
    from erp_ref.permission p where p.code = new.permission_code;

  if not v_aware and cardinality(new.data_classes) > 0 then
    raise exception 'ERPWARE_DATA_CLASS_NOT_APPLICABLE: permission % is not data-class aware',
      new.permission_code using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger t_role_permission_data_class
  before insert or update on erp.role_permission
  for each row execute function erp.check_data_class_grant();

-- A grant of a role to a principal, narrowed to a scope in the org hierarchy.
-- entity_id NULL = every entity in the tenant. site_id NULL = every site within
-- the granted entity scope.
create table erp.user_role (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  app_user_id     uuid not null,
  role_id         uuid not null,
  entity_id       uuid,
  site_id         uuid,
  valid_from      date not null default current_date,
  valid_to        date,
  granted_by      uuid,
  grant_reason    text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  foreign key (tenant_id, app_user_id)
    references erp.app_user (tenant_id, id) on delete cascade,
  foreign key (tenant_id, role_id)
    references erp.role (tenant_id, id) on delete restrict,
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)
    references erp.site (tenant_id, id) on delete cascade,
  constraint user_role_range check (valid_to is null or valid_to >= valid_from),
  -- A site-scoped grant must name the entity that site sits under, so the
  -- scope is unambiguous when the site is later re-parented.
  constraint user_role_site_needs_entity
    check (site_id is null or entity_id is not null)
);

create unique index user_role_unique_grant
  on erp.user_role (tenant_id, app_user_id, role_id,
                    coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
                    coalesce(site_id,   '00000000-0000-0000-0000-000000000000'::uuid),
                    valid_from);

create index on erp.user_role (tenant_id, app_user_id) where valid_to is null;

-- -----------------------------------------------------------------------------
-- Permission resolution
-- -----------------------------------------------------------------------------

-- Flattens grants to (principal, permission, entity, site, data classes).
-- SECURITY INVOKER: it is protected by the same RLS as its base tables.
create view erp.effective_permission as
select
  ur.tenant_id,
  ur.app_user_id,
  rp.permission_code,
  p.module_code,
  p.action,
  p.is_mutating,
  ur.entity_id,
  ur.site_id,
  rp.data_classes,
  ur.valid_from,
  ur.valid_to,
  r.id as role_id,
  r.code as role_code
from erp.user_role ur
join erp.role r
  on r.tenant_id = ur.tenant_id and r.id = ur.role_id and r.status = 'active'
join erp.role_permission rp
  on rp.tenant_id = ur.tenant_id and rp.role_id = r.id
join erp_ref.permission p
  on p.code = rp.permission_code;

-- The authorisation predicate every server-side entry point calls.
--
-- A NULL p_entity_id / p_site_id means "anywhere the principal holds it" —
-- used for menu visibility. Passing a concrete scope means the grant must be
-- either tenant-wide or an exact match, which is what transaction paths do.
create or replace function erp.has_permission(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_app_user_id     uuid default null
) returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from erp.effective_permission ep
     where ep.app_user_id = coalesce(p_app_user_id, erp.current_principal_id())
       and ep.permission_code = p_permission_code
       and ep.valid_from <= current_date
       and (ep.valid_to is null or ep.valid_to >= current_date)
       and (p_entity_id is null or ep.entity_id is null or ep.entity_id = p_entity_id)
       and (p_site_id   is null or ep.site_id   is null or ep.site_id   = p_site_id)
       and (p_data_class is null
            or cardinality(ep.data_classes) = 0
            or p_data_class = any (ep.data_classes))
  )
$$;

create or replace function erp.require_permission(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null
) returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not erp.has_permission(p_permission_code, p_entity_id, p_site_id, p_data_class) then
    raise exception 'ERPWARE_PERMISSION_DENIED: % (entity=%, site=%, class=%)',
      p_permission_code, p_entity_id, p_site_id, p_data_class
      using errcode = '42501';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Segregation of duties (spec 3.1)
-- "rule definitions, with conflict detection and periodic access review packs"
-- -----------------------------------------------------------------------------

create type erp.sod_severity as enum ('advisory', 'material', 'prohibited');
create type erp.sod_conflict_status as enum ('open', 'mitigated', 'accepted', 'resolved');

create table erp.sod_rule (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null,
  name            text not null,
  description     text,
  -- A conflict exists when one principal holds ANY permission from side A and
  -- ANY permission from side B within an overlapping scope.
  permissions_a   text[] not null check (cardinality(permissions_a) > 0),
  permissions_b   text[] not null check (cardinality(permissions_b) > 0),
  severity        erp.sod_severity not null default 'material',
  mitigation_guidance text,
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, code),
  unique (tenant_id, id)
);

create table erp.sod_conflict (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  sod_rule_id     uuid not null,
  app_user_id     uuid not null,
  entity_id       uuid,
  site_id         uuid,
  matched_a       text[] not null,
  matched_b       text[] not null,
  detected_at     timestamptz not null default now(),
  status          erp.sod_conflict_status not null default 'open',
  mitigation_note text,
  reviewed_by     uuid,
  reviewed_at     timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  foreign key (tenant_id, sod_rule_id)
    references erp.sod_rule (tenant_id, id) on delete cascade,
  foreign key (tenant_id, app_user_id)
    references erp.app_user (tenant_id, id) on delete cascade
);

create unique index sod_conflict_open_unique
  on erp.sod_conflict (tenant_id, sod_rule_id, app_user_id,
                       coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
                       coalesce(site_id,   '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'open';

-- Recomputes conflicts for the current tenant. Idempotent: re-running does not
-- duplicate an open conflict, and clears ones whose grants have gone away.
create or replace function erp.detect_sod_conflicts()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_found  integer := 0;
begin
  with pairs as (
    select
      sr.id  as sod_rule_id,
      a.app_user_id,
      coalesce(a.entity_id, b.entity_id) as entity_id,
      coalesce(a.site_id,   b.site_id)   as site_id,
      array_agg(distinct a.permission_code) as matched_a,
      array_agg(distinct b.permission_code) as matched_b
    from erp.sod_rule sr
    join erp.effective_permission a
      on a.tenant_id = sr.tenant_id
     and a.permission_code = any (sr.permissions_a)
     and a.valid_from <= current_date
     and (a.valid_to is null or a.valid_to >= current_date)
    join erp.effective_permission b
      on b.tenant_id = sr.tenant_id
     and b.app_user_id = a.app_user_id
     and b.permission_code = any (sr.permissions_b)
     and b.valid_from <= current_date
     and (b.valid_to is null or b.valid_to >= current_date)
     -- Scopes overlap when either side is unscoped or they name the same node.
     and (a.entity_id is null or b.entity_id is null or a.entity_id = b.entity_id)
     and (a.site_id   is null or b.site_id   is null or a.site_id   = b.site_id)
    where sr.tenant_id = v_tenant
      and sr.status = 'active'
    group by sr.id, a.app_user_id,
             coalesce(a.entity_id, b.entity_id),
             coalesce(a.site_id,   b.site_id)
  ),
  upserted as (
    insert into erp.sod_conflict
      (tenant_id, sod_rule_id, app_user_id, entity_id, site_id, matched_a, matched_b)
    select v_tenant, p.sod_rule_id, p.app_user_id, p.entity_id, p.site_id,
           p.matched_a, p.matched_b
      from pairs p
    on conflict do nothing
    returning 1
  )
  select count(*) into v_found from upserted;

  -- Close conflicts whose underlying grants no longer overlap.
  update erp.sod_conflict c
     set status = 'resolved', updated_at = now()
   where c.tenant_id = v_tenant
     and c.status = 'open'
     and not exists (
       select 1
         from erp.effective_permission a
         join erp.sod_rule sr on sr.id = c.sod_rule_id and sr.tenant_id = c.tenant_id
         join erp.effective_permission b
           on b.tenant_id = a.tenant_id
          and b.app_user_id = a.app_user_id
          and b.permission_code = any (sr.permissions_b)
          and (a.entity_id is null or b.entity_id is null or a.entity_id = b.entity_id)
          and (a.site_id   is null or b.site_id   is null or a.site_id   = b.site_id)
        where a.tenant_id = c.tenant_id
          and a.app_user_id = c.app_user_id
          and a.permission_code = any (sr.permissions_a)
          and a.valid_from <= current_date
          and (a.valid_to is null or a.valid_to >= current_date)
          and b.valid_from <= current_date
          and (b.valid_to is null or b.valid_to >= current_date)
     );

  return v_found;
end;
$$;

-- Periodic access review packs.
create type erp.access_review_status as enum ('draft', 'in_review', 'complete', 'cancelled');
create type erp.access_review_decision as enum ('pending', 'retain', 'revoke', 'modify');

create table erp.access_review (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null,
  name            text not null,
  period_start    date not null,
  period_end      date not null,
  status          erp.access_review_status not null default 'draft',
  opened_at       timestamptz,
  closed_at       timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, code),
  unique (tenant_id, id),
  constraint access_review_period check (period_end >= period_start)
);

create table erp.access_review_item (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  access_review_id  uuid not null,
  app_user_id       uuid not null,
  user_role_id      uuid,
  -- Snapshot of what was under review, so the pack stays readable after the
  -- underlying grant is changed or removed.
  grant_snapshot    jsonb not null,
  decision          erp.access_review_decision not null default 'pending',
  decided_by        uuid,
  decided_at        timestamptz,
  decision_note     text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id),
  foreign key (tenant_id, access_review_id)
    references erp.access_review (tenant_id, id) on delete cascade,
  foreign key (tenant_id, app_user_id)
    references erp.app_user (tenant_id, id) on delete cascade
);

create index on erp.access_review_item (tenant_id, access_review_id, decision);

-- -----------------------------------------------------------------------------
-- Access log (spec 3.1: "All access decisions logged and reportable")
-- Append-only; see migration 0004 for the revocation of update/delete rights.
-- -----------------------------------------------------------------------------

create table erp.access_log (
  id                bigint generated always as identity primary key,
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  occurred_at       timestamptz not null default now(),
  app_user_id       uuid,
  permission_code   text,
  entity_id         uuid,
  site_id           uuid,
  data_class        text,
  granted           boolean not null,
  object_type       text,
  object_id         uuid,
  reason            text,
  correlation_id    uuid,
  source            text not null default 'api'
);

create index on erp.access_log (tenant_id, occurred_at desc);
create index on erp.access_log (tenant_id, app_user_id, occurred_at desc);
create index on erp.access_log (tenant_id, granted, occurred_at desc) where not granted;

-- Records a decision and returns it, so call sites can write
--   if not erp.log_access_decision(...) then ... end if;
--
-- SECURITY INVOKER: `authenticated` already holds INSERT on erp.access_log and
-- matches its insert policy, so there is nothing to escalate for. As a definer
-- it would resolve its tenant inside a frame where erp.session_is_trusted()
-- answers yes, letting a caller forge a log entry into another tenant by
-- setting the job GUC first.
create or replace function erp.log_access_decision(
  p_permission_code text,
  p_granted         boolean,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_object_type     text default null,
  p_object_id       uuid default null,
  p_reason          text default null,
  p_correlation_id  uuid default null
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  insert into erp.access_log (
    tenant_id, app_user_id, permission_code, entity_id, site_id, data_class,
    granted, object_type, object_id, reason, correlation_id)
  values (
    v_tenant, erp.current_principal_id(), p_permission_code, p_entity_id,
    p_site_id, p_data_class, p_granted, p_object_type, p_object_id, p_reason,
    p_correlation_id);
  return p_granted;
end;
$$;

-- Checks and logs in one call: the path a server entry point should use.
create or replace function erp.authorise(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_object_type     text default null,
  p_object_id       uuid default null,
  p_correlation_id  uuid default null
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_granted boolean;
begin
  v_granted := erp.has_permission(p_permission_code, p_entity_id, p_site_id, p_data_class);
  perform erp.log_access_decision(
    p_permission_code, v_granted, p_entity_id, p_site_id, p_data_class,
    p_object_type, p_object_id,
    case when v_granted then null else 'no matching grant' end,
    p_correlation_id);

  if not v_granted then
    raise exception 'ERPWARE_PERMISSION_DENIED: %', p_permission_code
      using errcode = '42501';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Attribution + tenant-immutability triggers
-- -----------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'identity_provider', 'service_credential', 'role', 'role_permission',
    'user_role', 'sod_rule', 'sod_conflict', 'access_review', 'access_review_item'
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
