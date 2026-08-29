-- =============================================================================
-- ERPWare — B1 (part 1/4): core schema, enums, session context, tenant root
-- Spec: Part 2 (Tenancy and Isolation), Part 3.1 (Identity and access)
--
-- `tenant` is the outermost scope of every object in the system. There is no
-- unscoped operational table; migration 0004 enforces that as an invariant.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists erp;

comment on schema erp is
  'ERPWare product schema. Every operational table in here carries a tenant_id '
  'and is protected by a row-level security policy keyed on the session tenant.';

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

create type erp.isolation_mode as enum (
  'shared_schema',      -- logical isolation: tenant-scoped rows + RLS (default)
  'dedicated_schema',   -- physical isolation within a shared database
  'dedicated_database'  -- physical isolation in its own database
);

create type erp.tenant_status as enum (
  'provisioning', 'active', 'suspended', 'exporting', 'deleting', 'deleted'
);

create type erp.principal_kind as enum ('person', 'service');

create type erp.principal_status as enum (
  'invited', 'active', 'suspended', 'disabled'
);

create type erp.record_status as enum ('draft', 'active', 'inactive', 'archived');

-- -----------------------------------------------------------------------------
-- Session context
--
-- Spec 2.2: "Tenant context is derived from the authenticated session only —
-- never from a request parameter, header or client-supplied value."
--
-- current_principal_id() resolves the authenticated JWT subject to an ERPWare
-- principal. current_tenant_id() derives tenant from that principal alone.
--
-- Background jobs and integrations have no JWT, so they run under a trusted
-- database role and declare their tenant through the erp.job_tenant_id GUC.
-- That GUC is honoured ONLY for roles that hold BYPASSRLS (service_role and
-- the postgres owner) — a client connecting as `authenticated` or `anon` can
-- set the GUC all it likes and it will be ignored.
-- -----------------------------------------------------------------------------

create or replace function erp.session_is_trusted()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select r.rolbypassrls
       from pg_catalog.pg_roles r
      where r.rolname = current_user),
    false)
$$;

comment on function erp.session_is_trusted() is
  'True when the connected database role bypasses RLS (service_role, owner). '
  'Only such sessions may assert a tenant context via GUC.';

-- -----------------------------------------------------------------------------
-- Attribution
--
-- Spec 4.10: "Every business object carries created and modified attribution."
-- -----------------------------------------------------------------------------

create or replace function erp.touch_attribution()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.created_by := coalesce(new.created_by, erp.current_principal_id());
    new.updated_at := new.created_at;
    new.updated_by := new.created_by;
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(erp.current_principal_id(), old.updated_by);
  end if;
  return new;
end;
$$;

-- Guards the tenant column against being repointed at another tenant, which
-- would move a row across the isolation boundary in a single UPDATE.
create or replace function erp.freeze_tenant_id()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tenant_id is distinct from old.tenant_id then
    raise exception 'ERPWARE_TENANT_REASSIGNMENT: tenant_id is immutable on %', tg_table_name
      using errcode = '42501';
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- tenant — the isolation root (spec 4.1)
-- -----------------------------------------------------------------------------

create table erp.tenant (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique
                        check (code ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'),
  name                text not null,
  status              erp.tenant_status not null default 'provisioning',
  isolation_mode      erp.isolation_mode not null default 'shared_schema',
  -- Spec 2.5: tenant data can be pinned to a region.
  residency_region    text not null default 'eu-central-1',
  -- Spec 2.5: retention obligations the tenant specifies.
  retention_policy    jsonb not null default '{}'::jsonb,
  default_locale      text not null default 'en',
  default_timezone    text not null default 'UTC',
  provisioned_at      timestamptz,
  suspended_at        timestamptz,
  deleted_at          timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid
);

comment on table erp.tenant is
  'The isolation root. Every other operational row in the product references '
  'exactly one of these and may never reference two.';

-- Spec 2.2: "per-tenant data encryption keys, so a key compromise or a key
-- revocation is bounded to one tenant". The key material itself lives in the
-- KMS; this table records identity, rotation and destruction.
create table erp.tenant_key (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  purpose             text not null check (purpose in ('data', 'storage', 'export', 'backup')),
  kms_key_ref         text not null,
  key_version         integer not null default 1,
  activated_at        timestamptz not null default now(),
  rotated_at          timestamptz,
  -- Spec 2.5: deletion with cryptographic key destruction.
  destroyed_at        timestamptz,
  destruction_witness text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  unique (tenant_id, purpose, key_version)
);

create index on erp.tenant_key (tenant_id, purpose) where destroyed_at is null;

create trigger t_tenant_attribution
  before insert or update on erp.tenant
  for each row execute function erp.touch_attribution();

create trigger t_tenant_key_attribution
  before insert or update on erp.tenant_key
  for each row execute function erp.touch_attribution();

create trigger t_tenant_key_freeze
  before update on erp.tenant_key
  for each row execute function erp.freeze_tenant_id();

-- -----------------------------------------------------------------------------
-- app_user — a principal within exactly one tenant (spec 2.1, 3.1)
--
-- "Users belong to exactly one tenant. Cross-tenant identity does not exist;
--  a person needing access to two tenants holds two accounts."
--
-- auth_user_id is unique, so one authenticated identity resolves to exactly one
-- tenant. Service principals (integrations, job runners) have no auth identity.
-- -----------------------------------------------------------------------------

create table erp.app_user (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  -- Unique across the whole table: an authenticated identity can never resolve
  -- to two tenants, which is what makes current_tenant_id() unambiguous.
  auth_user_id        uuid unique,
  kind                erp.principal_kind not null default 'person',
  status              erp.principal_status not null default 'invited',
  display_name        text not null,
  email               text,
  -- Spec 3.10: separate axes for user language, document language and
  -- reporting language.
  user_locale         text,
  document_locale     text,
  reporting_locale    text,
  timezone            text,
  last_seen_at        timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  -- Target of every tenant-carrying composite foreign key onto a principal.
  constraint app_user_tenant_id_key unique (tenant_id, id),
  constraint app_user_email_per_tenant unique (tenant_id, email),
  -- A person authenticates; a service principal does not.
  constraint app_user_person_has_identity
    check (kind <> 'person' or email is not null),
  constraint app_user_service_has_no_auth_identity
    check (kind <> 'service' or auth_user_id is null)
);

create index on erp.app_user (tenant_id, status);

create trigger t_app_user_attribution
  before insert or update on erp.app_user
  for each row execute function erp.touch_attribution();

create trigger t_app_user_freeze
  before update on erp.app_user
  for each row execute function erp.freeze_tenant_id();

-- -----------------------------------------------------------------------------
-- Session context resolution
--
-- Defined here rather than earlier because it reads erp.app_user: the tenant of
-- a session is a property of the authenticated principal and nothing else.
--
-- Two things are load-bearing about the shape below.
--
-- 1. principal_context() is SECURITY DEFINER, because erp.app_user's own
--    row-level security policy calls erp.current_tenant_id(). Without the
--    privilege escalation the two would re-enter each other until the stack ran
--    out. It takes no argument, reads one table keyed on the JWT subject, and
--    returns at most the caller's own row.
--
-- 2. Everything else is SECURITY INVOKER, and that is not incidental. Inside a
--    SECURITY DEFINER frame the current user is the function's owner, who holds
--    BYPASSRLS — so erp.session_is_trusted() would answer "yes" for every
--    caller. Had current_tenant_id() been made SECURITY DEFINER as well, any
--    caller could have set the job GUC and been handed a tenant context they
--    have no claim to. The trust check has to run in the caller's own frame.
--
-- Migration 0006 turns that reasoning into a build-time check: any SECURITY
-- DEFINER function in the product schemas outside the allow-list fails the
-- isolation report.
-- -----------------------------------------------------------------------------

create or replace function erp.principal_context()
returns table (principal_id uuid, tenant_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.tenant_id
    from erp.app_user u
   where u.auth_user_id = (select auth.uid())
     and u.status = 'active'
$$;

comment on function erp.principal_context() is
  'The only SECURITY DEFINER function in the product schemas. Resolves the '
  'authenticated JWT subject to its ERPWare principal and tenant, bypassing '
  'row-level security so that the policy on erp.app_user does not re-enter '
  'this lookup.';

create or replace function erp.current_principal_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select pc.principal_id from erp.principal_context() pc
$$;

create or replace function erp.current_tenant_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(
    -- 1. Authenticated human or service principal: tenant comes from the
    --    principal record, which is reachable only via the JWT subject.
    (select pc.tenant_id from erp.principal_context() pc),
    -- 2. Trusted backend session (job runner, integration worker, migration).
    --    session_is_trusted() is evaluated HERE, in the invoker's frame, so it
    --    reports the role that actually connected.
    case
      when erp.session_is_trusted()
        then nullif(current_setting('erp.job_tenant_id', true), '')::uuid
      else null
    end
  )
$$;

comment on function erp.current_tenant_id() is
  'The tenant scope of the current session. Derived from the authenticated '
  'principal, or from a declared job context on a trusted backend role. '
  'Never from a client-supplied parameter, header or claim.';

-- Spec 3.8: "Every query path, background job, export, report and integration
-- call runs inside a tenant context; jobs without one cannot start."
create or replace function erp.require_tenant_id()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  v_tenant := erp.current_tenant_id();
  if v_tenant is null then
    raise exception 'ERPWARE_NO_TENANT_CONTEXT: operation attempted outside a tenant context'
      using errcode = '42501';
  end if;
  return v_tenant;
end;
$$;

create or replace function erp.set_job_tenant(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'ERPWARE_UNTRUSTED_CONTEXT_ASSERTION: role % may not assert a tenant context', current_user
      using errcode = '42501';
  end if;
  perform set_config('erp.job_tenant_id', p_tenant_id::text, false);
end;
$$;

comment on function erp.set_job_tenant(uuid) is
  'Opens a tenant context for a background job. Refuses on any role that does '
  'not already bypass RLS, so it cannot be used to escalate from a client.';
