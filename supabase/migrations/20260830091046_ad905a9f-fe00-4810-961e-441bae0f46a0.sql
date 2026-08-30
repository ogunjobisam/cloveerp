-- =============================================================================
-- ERPWare — the platform layer: who owns the product, and who works on it
--
-- Everything until now lived inside a tenant. This file adds the one thing
-- above them: a small staff list belonging to the platform itself, and the
-- operator actions that list is allowed to perform — onboarding a company,
-- suspending it, re-issuing its administrator's invitation, and entering it to
-- help.
--
-- It is deliberately NOT tenant-scoped, and therefore deliberately not
-- reachable except through the definer functions below. Both tables are
-- platform_internal in erp_meta.table_policy for the same reason
-- principal_preference is: the row is about a person across tenants, so a
-- tenant filter on it would be a category error.
--
-- Every action here writes erp_meta.platform_audit. Cross-tenant access that
-- is not audited is indistinguishable from a breach after the fact.
-- =============================================================================

create table erp_meta.platform_staff (
  id              uuid primary key default gen_random_uuid(),
  email           text not null,
  auth_user_id    uuid,
  display_name    text not null,
  staff_role      text not null check (staff_role in ('owner', 'operator', 'support')),
  invited_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  revoked_at      timestamptz,
  revoked_reason  text
);

comment on table erp_meta.platform_staff is
  'The people who work on the platform itself. Keyed on email so a person can '
  'be added before they have ever signed in; bound to auth_user_id on first '
  'authenticated use.';

create unique index platform_staff_email_key
  on erp_meta.platform_staff (lower(email));
create unique index platform_staff_auth_user_key
  on erp_meta.platform_staff (auth_user_id) where auth_user_id is not null;

alter table erp_meta.platform_staff enable row level security;

create table erp_meta.platform_audit (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  actor_id      uuid,
  actor_email   text,
  actor_role    text,
  action        text not null,
  tenant_id     uuid,
  tenant_code   text,
  target        text,
  reason        text,
  detail        jsonb not null default '{}'::jsonb
);

comment on table erp_meta.platform_audit is
  'Append-only record of every platform-level action, including each entry '
  'into a customer tenant and the reason given for it.';

create index on erp_meta.platform_audit (occurred_at desc);
alter table erp_meta.platform_audit enable row level security;

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta', 'platform_staff', 'platform_internal',
   'The platform''s own staff list. Spans tenants by definition, so a tenant '
   'filter on it would be meaningless; reachable only through definer functions.'),
  ('erp_meta', 'platform_audit', 'platform_internal',
   'What the platform''s staff did, including entries into customer tenants.')
on conflict do nothing;

insert into erp_meta.attribution_exemption (schema_name, table_name, rationale) values
  ('erp_meta', 'platform_staff',
   'Carries its own invited_by; principal attribution is tenant-scoped and this row is not.'),
  ('erp_meta', 'platform_audit',
   'Carries its own actor columns; the actor is a platform staff member, not a tenant principal.')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Who is asking, and are they allowed
-- -----------------------------------------------------------------------------

create or replace function erp_meta.platform_rank(p_role text)
returns integer
language sql
immutable
set search_path = ''
as $$ select case p_role when 'owner' then 3 when 'operator' then 2
                         when 'support' then 1 else 0 end $$;

create or replace function erp_meta.platform_actor()
returns erp_meta.platform_staff
language sql
stable
security definer
set search_path = ''
as $$
  select s.*
    from erp_meta.platform_staff s
   where s.revoked_at is null
     and ( s.auth_user_id = (select auth.uid())
        or lower(s.email) = lower((select u.email from auth.users u
                                    where u.id = (select auth.uid()))) )
   order by (s.auth_user_id is not null) desc
   limit 1
$$;

comment on function erp_meta.platform_actor is
  'Resolves the authenticated subject to a platform staff row, by bound '
  'identity or by the verified address on the account.';

create or replace function erp_meta.require_platform(p_min_role text)
returns erp_meta.platform_staff
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  if (select auth.uid()) is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED: sign in first' using errcode = '42501';
  end if;

  v := erp_meta.platform_actor();

  if v.id is null then
    raise exception
      'ERPWARE_NOT_PLATFORM_STAFF: this account is not on the platform staff list'
      using errcode = '42501',
      hint = 'An owner adds platform staff from Platform → Staff.';
  end if;

  if erp_meta.platform_rank(v.staff_role) < erp_meta.platform_rank(p_min_role) then
    raise exception
      'ERPWARE_PLATFORM_ROLE_TOO_LOW: this action needs the % role; you hold %',
      p_min_role, v.staff_role
      using errcode = '42501';
  end if;

  -- Bind the identity the first time it is seen, so later matching does not
  -- depend on the address on the account staying the same.
  if v.auth_user_id is null then
    update erp_meta.platform_staff
       set auth_user_id = (select auth.uid()), updated_at = now()
     where id = v.id;
    v.auth_user_id := (select auth.uid());
  end if;

  return v;
end;
$$;

create or replace function erp_meta.platform_log(
  p_actor erp_meta.platform_staff,
  p_action text,
  p_tenant_id uuid default null,
  p_target text default null,
  p_reason text default null,
  p_detail jsonb default '{}'::jsonb
) returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into erp_meta.platform_audit
    (actor_id, actor_email, actor_role, action, tenant_id, tenant_code,
     target, reason, detail)
  values
    (p_actor.id, p_actor.email, p_actor.staff_role, p_action, p_tenant_id,
     (select t.code from erp.tenant t where t.id = p_tenant_id),
     p_target, p_reason, coalesce(p_detail, '{}'::jsonb))
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp_meta', 'platform_actor',
   'Reads the platform staff list and the account address for the authenticated '
   'subject. Both are outside every tenant, so no tenant context can scope it.'),
  ('erp_meta', 'require_platform',
   'The platform authorisation gate. Must read the staff list, which no tenant owns.'),
  ('erp_meta', 'platform_log',
   'Appends to the platform audit trail, which belongs to no tenant.')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- The public API for platform staff
-- -----------------------------------------------------------------------------

create or replace function public.erp_platform_me()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
  v_any boolean;
begin
  select exists (select 1 from erp_meta.platform_staff where revoked_at is null)
    into v_any;

  if (select auth.uid()) is null then
    return jsonb_build_object('is_staff', false, 'role', null, 'claimable', false);
  end if;

  v := erp_meta.platform_actor();

  return jsonb_build_object(
    'is_staff', v.id is not null,
    'role', v.staff_role,
    'email', v.email,
    'display_name', v.display_name,
    -- Nobody on the list yet: the platform has no owner and the first signed-in
    -- person may claim it. Shown so that state is visible rather than a puzzle.
    'claimable', (not v_any));
end;
$$;

create or replace function public.erp_platform_claim_ownership(p_display_name text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_email text;
  v       erp_meta.platform_staff;
begin
  if v_uid is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED' using errcode = '42501';
  end if;

  if exists (select 1 from erp_meta.platform_staff where revoked_at is null) then
    raise exception
      'ERPWARE_PLATFORM_ALREADY_OWNED: the platform already has staff; ask an owner to add you'
      using errcode = '42501';
  end if;

  select u.email into v_email from auth.users u where u.id = v_uid;

  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values (coalesce(v_email, v_uid::text), v_uid,
          coalesce(nullif(p_display_name, ''), v_email, 'Owner'), 'owner')
  returning * into v;

  perform erp_meta.platform_log(v, 'platform.ownership_claimed', null, v.email,
                                'First owner: the staff list was empty.');

  return jsonb_build_object('id', v.id, 'role', v.staff_role, 'email', v.email);
end;
$$;

create or replace function public.erp_platform_staff()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'email', s.email, 'display_name', s.display_name,
             'role', s.staff_role, 'bound', s.auth_user_id is not null,
             'created_at', s.created_at, 'revoked_at', s.revoked_at)
             order by erp_meta.platform_rank(s.staff_role) desc, s.display_name)
      from erp_meta.platform_staff s
     where s.revoked_at is null), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_add_staff(
  p_email text, p_display_name text, p_role text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v   erp_meta.platform_staff;
  v_n erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('owner');

  if erp_meta.platform_rank(p_role) = 0 then
    raise exception 'ERPWARE_UNKNOWN_PLATFORM_ROLE: % is not owner, operator or support', p_role
      using errcode = '22023';
  end if;

  insert into erp_meta.platform_staff (email, display_name, staff_role, invited_by)
  values (lower(trim(p_email)), p_display_name, p_role, v.id)
  on conflict (lower(email)) do update
    set staff_role = excluded.staff_role,
        display_name = excluded.display_name,
        revoked_at = null, revoked_reason = null, updated_at = now()
  returning * into v_n;

  perform erp_meta.platform_log(v, 'platform.staff_added', null, v_n.email, null,
                                jsonb_build_object('role', p_role));

  return jsonb_build_object('id', v_n.id, 'email', v_n.email, 'role', v_n.staff_role);
end;
$$;

create or replace function public.erp_platform_set_staff_role(p_id uuid, p_role text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v   erp_meta.platform_staff;
  v_t erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('owner');

  if erp_meta.platform_rank(p_role) = 0 then
    raise exception 'ERPWARE_UNKNOWN_PLATFORM_ROLE: %', p_role using errcode = '22023';
  end if;

  select * into v_t from erp_meta.platform_staff where id = p_id and revoked_at is null;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_STAFF' using errcode = '23503';
  end if;

  -- The platform must never be left without an owner, and the likeliest way to
  -- do that is one owner demoting themselves.
  if v_t.staff_role = 'owner' and p_role <> 'owner'
     and (select count(*) from erp_meta.platform_staff
           where staff_role = 'owner' and revoked_at is null) <= 1 then
    raise exception 'ERPWARE_LAST_OWNER: promote another owner first' using errcode = '23514';
  end if;

  update erp_meta.platform_staff
     set staff_role = p_role, updated_at = now() where id = p_id;

  perform erp_meta.platform_log(v, 'platform.staff_role_changed', null, v_t.email, null,
                                jsonb_build_object('from', v_t.staff_role, 'to', p_role));

  return jsonb_build_object('id', p_id, 'role', p_role);
end;
$$;

create or replace function public.erp_platform_revoke_staff(p_id uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v   erp_meta.platform_staff;
  v_t erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('owner');

  select * into v_t from erp_meta.platform_staff where id = p_id and revoked_at is null;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_STAFF' using errcode = '23503';
  end if;

  if v_t.staff_role = 'owner'
     and (select count(*) from erp_meta.platform_staff
           where staff_role = 'owner' and revoked_at is null) <= 1 then
    raise exception 'ERPWARE_LAST_OWNER: the platform would have no owner' using errcode = '23514';
  end if;

  update erp_meta.platform_staff
     set revoked_at = now(), revoked_reason = p_reason, updated_at = now()
   where id = p_id;

  perform erp_meta.platform_log(v, 'platform.staff_revoked', null, v_t.email, p_reason);

  return jsonb_build_object('id', p_id, 'revoked', true);
end;
$$;

create or replace function public.erp_platform_tenants()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'code', t.code, 'name', t.name,
             'status', t.status::text,
             'created_at', t.created_at,
             'provisioned_at', t.provisioned_at,
             'suspended_at', t.suspended_at,
             'principals', (select count(*) from erp.app_user u where u.tenant_id = t.id),
             'entities', (select count(*) from erp.entity e where e.tenant_id = t.id),
             'sites', (select count(*) from erp.site s where s.tenant_id = t.id),
             'open_invitations', (select count(*) from erp.invitation i
                                   where i.tenant_id = t.id
                                     and i.claimed_at is null and i.revoked_at is null
                                     and i.expires_at > now()))
             order by t.created_at desc)
      from erp.tenant t), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_onboard_company(
  p_code               text,
  p_name               text,
  p_admin_email        text,
  p_admin_display_name text,
  p_base_currency      char(3) default 'GBP',
  p_country_code       char(2) default 'GB',
  p_timezone           text default 'UTC'
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
  r record;
begin
  v := erp_meta.require_platform('operator');

  select * into r from erp.provision_tenant(
    lower(trim(p_code)), p_name, lower(trim(p_admin_email)), p_admin_display_name,
    p_base_currency, p_country_code, 'MAIN', p_timezone, interval '14 days');

  perform erp_meta.platform_log(v, 'platform.company_onboarded', r.tenant_id,
                                p_admin_email, null,
                                jsonb_build_object('code', lower(trim(p_code)), 'name', p_name));

  return jsonb_build_object(
    'tenant_id', r.tenant_id, 'code', lower(trim(p_code)), 'name', p_name,
    'admin_user_id', r.admin_user_id, 'admin_email', lower(trim(p_admin_email)),
    'admin_token', r.admin_token);
end;
$$;

create or replace function public.erp_platform_invite_admin(
  p_tenant_id uuid, p_email text, p_display_name text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  v_user  uuid;
  v_role  uuid;
  v_token text;
begin
  v := erp_meta.require_platform('operator');

  if not exists (select 1 from erp.tenant t where t.id = p_tenant_id) then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and lower(u.email) = lower(trim(p_email));

  if v_user is null then
    insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
    values (p_tenant_id, 'person', 'invited', p_display_name, lower(trim(p_email)), 'en')
    returning id into v_user;
  end if;

  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'administrator' and r.status = 'active';

  if v_role is not null and not exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id and ur.app_user_id = v_user and ur.role_id = v_role)
  then
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (p_tenant_id, v_user, v_role, 'Administrator invited by platform staff.');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
  values (p_tenant_id, v_user,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + interval '14 days');

  perform erp_meta.platform_log(v, 'platform.admin_invited', p_tenant_id, lower(trim(p_email)));

  return jsonb_build_object('app_user_id', v_user, 'email', lower(trim(p_email)),
                            'token', v_token);
end;
$$;

create or replace function public.erp_platform_set_tenant_status(
  p_tenant_id uuid, p_status text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v   erp_meta.platform_staff;
  v_t erp.tenant;
begin
  if p_status not in ('active', 'suspended', 'deleted') then
    raise exception 'ERPWARE_UNKNOWN_TENANT_STATUS: %', p_status using errcode = '22023';
  end if;

  -- Deletion is the one door an operator does not hold the key to.
  v := erp_meta.require_platform(case when p_status = 'deleted' then 'owner' else 'operator' end);

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  update erp.tenant
     set status       = p_status::erp.tenant_status,
         suspended_at = case when p_status = 'suspended' then now() else null end,
         deleted_at   = case when p_status = 'deleted' then now() else deleted_at end,
         updated_at   = now()
   where id = p_tenant_id;

  perform erp_meta.platform_log(v, 'platform.tenant_status_changed', p_tenant_id,
                                v_t.code, p_reason,
                                jsonb_build_object('from', v_t.status::text, 'to', p_status));

  return jsonb_build_object('id', p_tenant_id, 'status', p_status);
end;
$$;

create or replace function public.erp_platform_enter_tenant(
  p_tenant_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  v_t    erp.tenant;
  v_user uuid;
  v_role uuid;
begin
  v := erp_meta.require_platform('support');

  if coalesce(trim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: entering a customer tenant needs a reason'
      using errcode = '22023';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                              email, user_locale)
    values (p_tenant_id, v.auth_user_id, 'person', 'active',
            v.display_name || ' (ERPWare ' || v.staff_role || ')',
            v.email, 'en')
    returning id into v_user;
  else
    update erp.app_user set status = 'active' where id = v_user;
  end if;

  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'administrator' and r.status = 'active';

  if v_role is not null and not exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id and ur.app_user_id = v_user and ur.role_id = v_role)
  then
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (p_tenant_id, v_user, v_role,
            'Platform ' || v.staff_role || ' support access: ' || p_reason);
  end if;

  insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
  values (v.auth_user_id, p_tenant_id)
  on conflict (auth_user_id)
    do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason);

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user);
end;
$$;

create or replace function public.erp_platform_leave_tenant(p_tenant_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  update erp.app_user
     set status = 'disabled'
   where tenant_id = p_tenant_id and auth_user_id = v.auth_user_id;

  delete from erp_meta.principal_preference
   where auth_user_id = v.auth_user_id and active_tenant_id = p_tenant_id;

  perform erp_meta.platform_log(v, 'platform.tenant_left', p_tenant_id, null,
                                'Support access ended.');

  return jsonb_build_object('tenant_id', p_tenant_id, 'left', true);
end;
$$;

create or replace function public.erp_platform_audit(
  p_action text default null,
  p_tenant_id uuid default null,
  p_limit integer default 200)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(x order by x->>'occurred_at' desc)
      from (
        select jsonb_build_object(
                 'id', a.id, 'occurred_at', a.occurred_at,
                 'actor_email', a.actor_email, 'actor_role', a.actor_role,
                 'action', a.action, 'tenant_code', a.tenant_code,
                 'target', a.target, 'reason', a.reason, 'detail', a.detail) as x
          from erp_meta.platform_audit a
         where (p_action is null or a.action = p_action)
           and (p_tenant_id is null or a.tenant_id = p_tenant_id)
         order by a.occurred_at desc
         limit greatest(1, least(coalesce(p_limit, 200), 1000))) s), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- Registration and grants
-- -----------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_platform_me()',
    'public.erp_platform_claim_ownership(text)',
    'public.erp_platform_staff()',
    'public.erp_platform_add_staff(text, text, text)',
    'public.erp_platform_set_staff_role(uuid, text)',
    'public.erp_platform_revoke_staff(uuid, text)',
    'public.erp_platform_tenants()',
    'public.erp_platform_onboard_company(text, text, text, text, char, char, text)',
    'public.erp_platform_invite_admin(uuid, text, text)',
    'public.erp_platform_set_tenant_status(uuid, text, text)',
    'public.erp_platform_enter_tenant(uuid, text)',
    'public.erp_platform_leave_tenant(uuid)',
    'public.erp_platform_audit(text, uuid, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
select 'public', fn,
       'Platform-level operation. It exists precisely to act above tenants, so '
       'no tenant context can scope it; it is gated on erp_meta.require_platform() '
       'and writes erp_meta.platform_audit.'
  from unnest(array[
    'erp_platform_me','erp_platform_claim_ownership','erp_platform_staff',
    'erp_platform_add_staff','erp_platform_set_staff_role','erp_platform_revoke_staff',
    'erp_platform_tenants','erp_platform_onboard_company','erp_platform_invite_admin',
    'erp_platform_set_tenant_status','erp_platform_enter_tenant',
    'erp_platform_leave_tenant','erp_platform_audit']) fn
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
select fn, 'erp_meta.require_platform',
       'Platform staff action, gated on the platform staff list rather than on '
       'erp.authorise(), because it is performed above every tenant.'
  from unnest(array[
    'erp_platform_me','erp_platform_claim_ownership','erp_platform_staff',
    'erp_platform_add_staff','erp_platform_set_staff_role','erp_platform_revoke_staff',
    'erp_platform_tenants','erp_platform_onboard_company','erp_platform_invite_admin',
    'erp_platform_set_tenant_status','erp_platform_enter_tenant',
    'erp_platform_leave_tenant','erp_platform_audit']) fn
on conflict do nothing;

-- The account that has been used to build and verify this product becomes the
-- first owner, so the console is reachable the moment it ships.
insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
select u.email, u.id, 'ERPWare Owner', 'owner'
  from auth.users u
 where lower(u.email) = 'admin@erpware.dev'
on conflict do nothing;
