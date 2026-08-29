-- =============================================================================
-- ERPWare — provisioning: the first tenant, the first administrator
--
-- Everything built so far assumes a tenant and a principal already exist.
-- Nothing created either. The platform was therefore complete and unreachable:
-- a correctly-signed-in person resolved to no erp.app_user row, so
-- current_tenant_id() returned null and the product deliberately showed
-- nothing. That is the design working, and it is also a dead end until
-- something can make the first row.
--
-- Two different kinds of operation live here, and the difference is the whole
-- point of the file.
--
--   Provisioning a tenant is an OPERATOR action. It happens when no principal
--   exists yet, so there is nobody to authorise it and no tenant to scope it
--   to. erp.authorise() cannot help. It is therefore gated on
--   erp.session_is_trusted() — a connected role that bypasses RLS — which is
--   the same trust boundary B1 already uses and not a new one. It is never
--   exposed on the public API.
--
--   Everything after that is an ORDINARY action inside a tenant: creating a
--   colleague, granting a role, inviting someone. Those go through
--   erp.authorise() like anything else and reach the UI through the public
--   write surface in 0042.
--
-- How a person becomes a principal
--
-- An administrator invites an email; that creates an erp.app_user in 'invited'
-- status with no auth_user_id, and an erp.invitation carrying a single-use
-- token. The invitee signs in with the identity provider and redeems the token,
-- which binds their authenticated subject to the waiting row.
--
-- The token exists rather than matching on the email in the JWT, for two
-- reasons. The narrow one: an unverified email is not proof of anything, and
-- matching on it would let someone sign up as a colleague's address and claim
-- their invitation before they did. The structural one: supabase/ci/
-- 00_host_bootstrap.sql states that auth.uid() is the single point at which
-- this product touches an identity provider, and that nothing else reads a
-- claim. Reading an email claim here would quietly make that false. A token
-- keeps the boundary one function wide.
--
-- The token is stored as a SHA-256 digest and returned exactly once, so the
-- table cannot hand out a credential to anyone who can read it — including an
-- administrator who should not need to.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Invitations
-- -----------------------------------------------------------------------------

create table erp.invitation (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  app_user_id     uuid not null,
  -- The digest, never the token. erp.invite_principal() returns the only copy.
  token_digest    text not null unique,
  expires_at      timestamptz not null,
  claimed_at      timestamptz,
  claimed_by      uuid,
  revoked_at      timestamptz,
  revoked_reason  text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, app_user_id)
    references erp.app_user (tenant_id, id) on delete cascade,
  constraint invitation_expiry_sane check (expires_at > created_at),
  constraint invitation_claimed_has_subject
    check ((claimed_at is null) = (claimed_by is null)),
  -- An invitation is either open, claimed, or revoked. Never two of them.
  constraint invitation_not_both_claimed_and_revoked
    check (claimed_at is null or revoked_at is null)
);

comment on table erp.invitation is
  'A single-use, expiring token binding an authenticated subject to a waiting '
  'erp.app_user. Stores the digest and never the token, so reading this table '
  'does not yield a credential.';

create index on erp.invitation (tenant_id, app_user_id);

-- -----------------------------------------------------------------------------
-- Provisioning a tenant — the operator action
-- -----------------------------------------------------------------------------

create or replace function erp.provision_tenant(
  p_code               text,
  p_name               text,
  p_admin_email        text,
  p_admin_display_name text,
  p_base_currency      char(3) default 'GBP',
  p_country_code       char(2) default 'GB',
  p_entity_code        text default 'MAIN',
  p_timezone           text default 'UTC',
  p_admin_valid_for    interval default interval '14 days'
) returns table (tenant_id uuid, entity_id uuid, admin_user_id uuid, role_id uuid,
                 environment_id uuid, admin_token text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_entity uuid;
  v_admin  uuid;
  v_role   uuid;
  v_env    uuid;
  v_token  text;
begin
  -- The only gate available: no tenant exists yet, so there is nothing for
  -- erp.authorise() to scope to and no principal to check.
  if not erp.session_is_trusted() then
    raise exception
      'ERPWARE_UNTRUSTED_PROVISIONING: provisioning a tenant requires a '
      'session whose role bypasses row-level security; % does not', current_user
      using errcode = '42501',
      detail = 'Run this as the database owner or service_role. It is '
               'deliberately not on the public API.';
  end if;

  if exists (select 1 from erp.tenant t where t.code = p_code) then
    raise exception 'ERPWARE_TENANT_EXISTS: %', p_code using errcode = '23505';
  end if;

  insert into erp.tenant (code, name, status, provisioned_at,
                          default_timezone, default_locale)
  values (p_code, p_name, 'active', now(), p_timezone, 'en')
  returning id into v_tenant;

  -- Everything below writes tenant-scoped rows, and the attribution and
  -- freeze triggers on them read the tenant context. Set it transaction-locally
  -- — never for the session — so a pooled connection cannot carry it to
  -- whoever is served next.
  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  insert into erp.entity (tenant_id, code, name, legal_name,
                          base_currency, country_code, status)
  values (v_tenant, p_entity_code, p_name, p_name,
          p_base_currency, p_country_code, 'active')
  returning id into v_entity;

  -- B6 requires exactly one environment marked is_self: the one that IS this
  -- database. Without it promotion has no idea where it is standing.
  --
  -- Created NOT live, and flipped at the end of this function. B6's
  -- guard_live_configuration() refuses direct edits to configuration tables —
  -- erp.role among them — once the self environment is live, and it is right
  -- to: after provisioning, a role changes through a promoted change set or it
  -- does not change. But the tenant has to be built before it can be governed,
  -- and the guard says so itself: "until a tenant declares this environment
  -- live, it is being built". So this builds, and then declares.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant, 'production', 'Production', 'production', false, true,
          'This database.', 'active')
  returning id into v_env;

  insert into erp.role (tenant_id, code, name, description, status)
  values (v_tenant, 'administrator', 'Administrator',
          'Holds every permission the product defines. Created at provisioning '
          'so the tenant has a way in; narrow it once real roles exist.',
          'active')
  returning id into v_role;

  -- Every permission, rather than a curated list, because a first
  -- administrator who cannot reach part of the product cannot delegate it
  -- either. data_classes empty means "every class" for the ones that are
  -- class-aware.
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  select v_tenant, v_role, p.code from erp_ref.permission p;

  insert into erp.app_user (tenant_id, kind, status, display_name, email,
                            user_locale, timezone)
  values (v_tenant, 'person', 'invited', p_admin_display_name, p_admin_email,
          'en', p_timezone)
  returning id into v_admin;

  -- Unscoped: entity_id null means the whole tenant, which is what a first
  -- administrator needs and what every later grant should narrow.
  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  values (v_tenant, v_admin, v_role,
          'First administrator, created when the tenant was provisioned.');

  -- Without this the tenant is provisioned and unreachable. The administrator
  -- is 'invited' with no auth_user_id, so erp.principal_context() resolves
  -- nothing; and erp.set_job_principal() refuses to adopt a person, by design.
  -- An invitation is the only door into a new tenant, so provisioning has to
  -- open it.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
  values (v_tenant, v_admin,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + p_admin_valid_for);

  -- Built. Now governed: from here every configuration edit goes through B6.
  update erp.environment set is_live = true where id = v_env;

  return query select v_tenant, v_entity, v_admin, v_role, v_env, v_token;
end;
$$;

comment on function erp.provision_tenant is
  'Creates a tenant, its root entity, the is_self environment B6 needs, an '
  'administrator role holding every permission, and the first administrator '
  'as an invited principal with the token that lets them in. Operator action: '
  'gated on a trusted session because no principal exists yet to authorise it.';

-- -----------------------------------------------------------------------------
-- Ordinary actions inside a tenant
-- -----------------------------------------------------------------------------

create or replace function erp.invite_principal(
  p_email        text,
  p_display_name text,
  p_valid_for    interval default interval '7 days'
) returns table (app_user_id uuid, token text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_user   uuid;
  v_token  text;
begin
  perform erp.authorise('administration.users', null, null, null, 'app_user', null);

  insert into erp.app_user (tenant_id, kind, status, display_name, email)
  values (v_tenant, 'person', 'invited', p_display_name, p_email)
  returning id into v_user;

  -- 32 bytes of CSPRNG output. Returned once, below, and never recoverable
  -- from the table afterwards.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
  values (v_tenant, v_user,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + p_valid_for);

  return query select v_user, v_token;
end;
$$;

comment on function erp.invite_principal is
  'Creates an invited principal and returns its single-use token. This is the '
  'only moment the token exists in readable form.';

create or replace function erp.create_service_principal(
  p_display_name text
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('administration.users', null, null, null, 'app_user', null);

  -- No email and no auth identity: a service principal does not authenticate,
  -- it is asserted by a trusted session through erp.set_job_principal(). The
  -- table's own constraints already refuse an auth_user_id here.
  insert into erp.app_user (tenant_id, kind, status, display_name)
  values (v_tenant, 'service', 'active', p_display_name)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.create_service_principal is
  'The principal a worker runs as. Spec 2.4 wants service accounts to be '
  'first-class, and B10 depends on them being a kind that cannot approve.';

create or replace function erp.grant_role(
  p_app_user_id uuid,
  p_role_code   text,
  p_entity_id   uuid default null,
  p_site_id     uuid default null,
  p_reason      text default null,
  p_valid_from  date default current_date,
  p_valid_to    date default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_role   uuid;
  v_id     uuid;
begin
  perform erp.authorise('administration.roles', p_entity_id, p_site_id, null,
                        'user_role', null);

  select r.id into v_role from erp.role r
   where r.tenant_id = v_tenant and r.code = p_role_code and r.status = 'active';

  if v_role is null then
    raise exception 'ERPWARE_UNKNOWN_ROLE: %', p_role_code using errcode = '23503';
  end if;

  insert into erp.user_role (tenant_id, app_user_id, role_id, entity_id, site_id,
                             valid_from, valid_to, granted_by, grant_reason)
  values (v_tenant, p_app_user_id, v_role, p_entity_id, p_site_id,
          p_valid_from, p_valid_to, erp.current_principal_id(), p_reason)
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Redeeming an invitation
--
-- The one operation that legitimately runs with no tenant context: the caller
-- is authenticated but resolves to no principal yet, which is exactly the
-- state this ends. Row security on erp.app_user and erp.invitation would hide
-- the very rows it must find, so it is SECURITY DEFINER — and therefore
-- registered in erp_meta.security_definer_allowance with a rationale, like the
-- only other one.
--
-- It reads auth.uid() and nothing else. Possession of the token is the proof.
-- -----------------------------------------------------------------------------

create or replace function erp.claim_invitation(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject uuid := (select auth.uid());
  v_digest  text;
  inv       erp.invitation%rowtype;
begin
  if v_subject is null then
    raise exception
      'ERPWARE_NOT_AUTHENTICATED: redeeming an invitation requires a signed-in '
      'session'
      using errcode = '42501';
  end if;

  if p_token is null or length(p_token) < 32 then
    raise exception 'ERPWARE_INVALID_INVITATION_TOKEN' using errcode = '22023';
  end if;

  v_digest := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select * into inv from erp.invitation i
   where i.token_digest = v_digest
     for update;

  -- One message for every failure mode below, deliberately. Distinguishing
  -- "no such token" from "already claimed" from "expired" tells someone
  -- probing tokens which guesses were closer.
  if not found
     or inv.claimed_at is not null
     or inv.revoked_at is not null
     or inv.expires_at <= now()
  then
    raise exception
      'ERPWARE_INVITATION_NOT_OPEN: that invitation cannot be redeemed'
      using errcode = '42501';
  end if;

  -- An authenticated subject belongs to exactly one principal, ever. The
  -- unique constraint on app_user.auth_user_id enforces it; this is the
  -- readable error for the same condition.
  if exists (select 1 from erp.app_user u where u.auth_user_id = v_subject) then
    raise exception
      'ERPWARE_IDENTITY_ALREADY_BOUND: this sign-in is already a principal'
      using errcode = '23505';
  end if;

  update erp.app_user
     set auth_user_id = v_subject, status = 'active'
   where tenant_id = inv.tenant_id and id = inv.app_user_id
     and auth_user_id is null;

  if not found then
    raise exception
      'ERPWARE_INVITATION_NOT_OPEN: that invitation cannot be redeemed'
      using errcode = '42501';
  end if;

  update erp.invitation
     set claimed_at = now(), claimed_by = v_subject
   where id = inv.id;

  return inv.app_user_id;
end;
$$;

comment on function erp.claim_invitation is
  'Binds an authenticated subject to the principal an administrator invited. '
  'Runs with no tenant context because ending that state is its whole job. '
  'Reads auth.uid() and a token digest; never an email claim.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'claim_invitation',
  'Runs before the caller has a principal, so row security on erp.app_user and '
  'erp.invitation would hide the rows it exists to find. Scoped to a single '
  'unclaimed, unexpired, unrevoked token digest; binds auth.uid() to one '
  'waiting row and can do nothing else.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp_meta.register_table('erp', 'invitation', 'tenant_scoped',
  'Single-use tokens binding an authenticated subject to a waiting principal.');

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
