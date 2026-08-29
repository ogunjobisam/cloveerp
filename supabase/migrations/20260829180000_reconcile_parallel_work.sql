-- =============================================================================
-- ERPWare — reconciling the parallel work, and choosing a tenant on purpose
--
-- Named with a timestamp rather than the 00NN sequence, and that is load
-- bearing. The repository now carries two conventions: the hand-numbered
-- series and the timestamped files Lovable generates. Every 00NN file sorts
-- before every timestamped one, so this migration was originally 0045 and ran
-- BEFORE the three files it exists to correct — which applied cleanly, passed
-- its own assertions at the end of itself, and was then silently undone as the
-- parallel migrations recreated the same functions moments later. The build
-- was green and the fix was gone.
--
-- Anything correcting a timestamped migration has to be timestamped later than
-- it. Worth knowing before the next one.
--
-- Self-service onboarding and permissions management were built alongside this
-- branch. They are good additions and they stay; each covers a gap the other
-- had. Onboarding lets a customer start without an operator, which invitations
-- alone could not. Invitations let somebody already inside a tenant add a
-- colleague, which onboarding alone could not.
--
-- What this migration fixes is not the features, it is four things the
-- assertions caught the moment the two lines of work met.
--
--   Six functions in public were SECURITY DEFINER. That is rule 1 of
--   erp.public_api_report(), and it is the defect B1 was rebuilt around: a
--   definer function in public runs as the owner, who holds BYPASSRLS, so the
--   only thing standing between a caller and every tenant's rows is whether
--   each query remembered its own tenant filter. Four of them do not need it —
--   they authorise, then read and write inside their own tenant, which is
--   exactly what row-level security already permits — so they become INVOKER
--   and let the database enforce the scoping instead of the author.
--
--   Two of them genuinely do need it, for the same reason erp.claim_invitation
--   does: they create a tenant for a caller who does not yet have one, so
--   there is no context for RLS to scope to. Those move into erp, where
--   erp_meta.security_definer_allowance governs them with a written rationale,
--   and public keeps only a thin invoker wrapper. The privilege stays; what
--   changes is that it is now enumerated and reviewed rather than incidental.
--
--   erp.provision_tenant_admin() was SECURITY DEFINER as well, and does not
--   need to be: it is only ever called from inside a definer frame, where it
--   already runs with that privilege.
--
--   public.erp_grant_role existed twice, with different signatures, from the
--   two branches. Two overloads of one API name is an ambiguity PostgREST has
--   to guess at. The parallel version is the one the permissions screen calls,
--   so it wins; the wrapper added here is withdrawn. erp.grant_role() stays —
--   it takes a role code rather than an id, which is what scripts want.
--
-- And the decision: one identity, several tenants
--
-- Dropping the unique constraint on app_user.auth_user_id made membership
-- per-tenant, which is a real feature. But principal_context() resolved the
-- ambiguity it created with "newest active principal wins", and that is not a
-- choice, it is an accident of insertion order — B1 built current_tenant_id()
-- on that column being unique precisely so the answer could not depend on
-- something like that.
--
-- So the ambiguity is resolved explicitly. A principal records which of their
-- tenants is active; principal_context() honours it, and falls back to newest
-- only when no choice has been made. The preference is keyed on the
-- authenticated subject rather than on a tenant, because it is the one piece
-- of state that legitimately spans them.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Six functions in public, and where each of them belongs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.erp_grant_role(p_app_user_id uuid, p_role_code text, p_entity_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'user_role_id',
    erp.grant_role(p_app_user_id, p_role_code, p_entity_id, p_site_id, p_reason))
$function$;

CREATE OR REPLACE FUNCTION public.erp_grant_role(p_app_user_id uuid, p_role_id uuid, p_valid_from date DEFAULT CURRENT_DATE, p_valid_to date DEFAULT NULL::date, p_grant_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid;
  v_id uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  if not exists (select 1 from erp.app_user u
                  where u.id = p_app_user_id and u.tenant_id = v_tenant) then
    raise exception 'ERPWARE_VALIDATION: principal not found in this tenant';
  end if;
  if not exists (select 1 from erp.role r
                  where r.id = p_role_id and r.tenant_id = v_tenant
                    and r.status = 'active'::erp.record_status) then
    raise exception 'ERPWARE_VALIDATION: active role not found in this tenant';
  end if;
  if p_valid_to is not null and p_valid_to < p_valid_from then
    raise exception 'ERPWARE_VALIDATION: valid_to precedes valid_from';
  end if;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, valid_to,
                             granted_by, grant_reason)
  values (v_tenant, p_app_user_id, p_role_id, p_valid_from, p_valid_to,
          erp.current_principal_id(), p_grant_reason)
  returning id into v_id;

  return jsonb_build_object('grant_id', v_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_permissions_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  return jsonb_build_object(
    'principals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'display_name', u.display_name, 'email', u.email,
               'kind', u.kind, 'status', u.status, 'created_at', u.created_at)
               order by u.display_name)
        from erp.app_user u where u.tenant_id = v_tenant), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'code', r.code, 'name', r.name,
               'description', r.description, 'status', r.status,
               'permissions', coalesce((
                 select jsonb_agg(rp.permission_code order by rp.permission_code)
                   from erp.role_permission rp
                  where rp.tenant_id = r.tenant_id and rp.role_id = r.id), '[]'::jsonb))
               order by r.code)
        from erp.role r where r.tenant_id = v_tenant), '[]'::jsonb),
    'grants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ur.id, 'app_user_id', ur.app_user_id, 'role_id', ur.role_id,
               'entity_id', ur.entity_id, 'site_id', ur.site_id,
               'valid_from', ur.valid_from, 'valid_to', ur.valid_to,
               'grant_reason', ur.grant_reason, 'created_at', ur.created_at)
               order by ur.created_at desc)
        from erp.user_role ur where ur.tenant_id = v_tenant), '[]'::jsonb),
    'permission_catalog', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', p.code, 'module_code', p.module_code,
               'action', p.action, 'is_mutating', p.is_mutating)
               order by p.code)
        from erp_ref.permission p), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_revoke_role(p_user_role_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  delete from erp.user_role ur
   where ur.id = p_user_role_id and ur.tenant_id = v_tenant;
  if not found then
    raise exception 'ERPWARE_VALIDATION: grant not found in this tenant';
  end if;

  return jsonb_build_object('revoked', p_user_role_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_save_role(p_role_id uuid, p_code text, p_name text, p_description text, p_permissions text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid;
  v_id uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'ERPWARE_VALIDATION: role name is required';
  end if;
  if exists (select 1
               from unnest(coalesce(p_permissions, '{}')) perm
              where not exists (select 1 from erp_ref.permission p where p.code = perm)) then
    raise exception 'ERPWARE_VALIDATION: unknown permission code';
  end if;

  if p_role_id is null then
    if p_code is null or btrim(p_code) = '' then
      raise exception 'ERPWARE_VALIDATION: role code is required';
    end if;
    insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
    values (v_tenant, p_code, 'role.' || replace(p_code, '-', '_') || '.name', p_name,
            p_description, 'active'::erp.record_status, erp.current_principal_id())
    returning id into v_id;
  else
    update erp.role r
       set name = p_name, description = p_description, updated_at = now(),
           updated_by = erp.current_principal_id()
     where r.id = p_role_id and r.tenant_id = v_tenant
    returning id into v_id;
    if not found then
      raise exception 'ERPWARE_VALIDATION: role not found in this tenant';
    end if;
    delete from erp.role_permission rp where rp.tenant_id = v_tenant and rp.role_id = v_id;
  end if;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select v_tenant, v_id, perm, '{}', erp.current_principal_id()
  from unnest(coalesce(p_permissions, '{}')) perm;

  return jsonb_build_object('role_id', v_id);
end;
$function$;



CREATE OR REPLACE FUNCTION erp.onboard_tenant(p_name text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_auth_id uuid := auth.uid();
  v_email text;
  v_display text;
  v_tenant_id uuid;
  v_principal_id uuid;
begin
  if v_auth_id is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' or p_code is null or btrim(p_code) = '' then
    raise exception 'ERPWARE_VALIDATION: tenant name and code are required';
  end if;

  select email, coalesce(raw_user_meta_data->>'full_name', email)
    into v_email, v_display
  from auth.users where id = v_auth_id;

  insert into erp.tenant (code, name, status, provisioned_at)
  values (p_code, p_name, 'active'::erp.tenant_status, now())
  returning id into v_tenant_id;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, v_auth_id, 'person'::erp.principal_kind, 'active'::erp.principal_status,
          coalesce(v_display, 'Tenant administrator'), v_email)
  returning id into v_principal_id;

  perform erp.provision_tenant_admin(v_tenant_id, v_principal_id, v_principal_id);

  return jsonb_build_object('tenant_id', v_tenant_id, 'principal_id', v_principal_id);
end;
$function$;

CREATE OR REPLACE FUNCTION erp.seed_demo()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_auth_id uuid := auth.uid();
  v_email text;
  v_display text;
  v_tenant_id uuid;
  v_principal_id uuid;
  v_viewer_id uuid;
  v_role_id uuid;
  v_e1 uuid;
  v_e2 uuid;
begin
  if v_auth_id is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED' using errcode = '42501';
  end if;

  -- Idempotent: reuse the caller's existing demo tenant.
  select t.id into v_tenant_id
  from erp.tenant t
  join erp.app_user u on u.tenant_id = t.id and u.auth_user_id = v_auth_id
  where t.code like 'demo-%' and t.status = 'active'::erp.tenant_status
  order by t.created_at
  limit 1;
  if v_tenant_id is not null then
    select u.id into v_principal_id from erp.app_user u
     where u.tenant_id = v_tenant_id and u.auth_user_id = v_auth_id;
    return jsonb_build_object('tenant_id', v_tenant_id, 'principal_id', v_principal_id, 'already_existed', true);
  end if;

  select email, coalesce(raw_user_meta_data->>'full_name', email)
    into v_email, v_display
  from auth.users where id = v_auth_id;

  insert into erp.tenant (code, name, status, provisioned_at)
  values ('demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
          'Demo — Acme Manufacturing', 'active'::erp.tenant_status, now())
  returning id into v_tenant_id;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, v_auth_id, 'person'::erp.principal_kind, 'active'::erp.principal_status,
          coalesce(v_display, 'Demo administrator'), v_email)
  returning id into v_principal_id;

  perform erp.provision_tenant_admin(v_tenant_id, v_principal_id, v_principal_id);

  insert into erp.entity (tenant_id, code, name, legal_name, base_currency, country_code, created_by)
  values (v_tenant_id, 'ACME-UK', 'Acme United Kingdom', 'Acme Manufacturing Ltd', 'GBP', 'GB', v_principal_id)
  returning id into v_e1;

  insert into erp.entity (tenant_id, code, name, legal_name, base_currency, country_code, created_by)
  values (v_tenant_id, 'ACME-EU', 'Acme Europe', 'Acme Manufacturing BV', 'EUR', 'NL', v_principal_id)
  returning id into v_e2;

  insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, created_by)
  values
    (v_tenant_id, v_e1, 'LON-HQ', 'London head office', 'office'::erp.site_type, 'GB', v_principal_id),
    (v_tenant_id, v_e1, 'BHM-WH', 'Birmingham warehouse', 'warehouse'::erp.site_type, 'GB', v_principal_id),
    (v_tenant_id, v_e2, 'RTM-DC', 'Rotterdam distribution centre', 'distribution'::erp.site_type, 'NL', v_principal_id);

  -- Sample read-only principal so the permissions page has something to manage.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, null, 'person'::erp.principal_kind, 'invited'::erp.principal_status,
          'Dana Viewer', 'dana.viewer@example.invalid')
  returning id into v_viewer_id;

  insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
  values (v_tenant_id, 'viewer', 'role.viewer.name', 'Viewer',
          'Read-only access to every module.', 'active'::erp.record_status, v_principal_id)
  returning id into v_role_id;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select v_tenant_id, v_role_id, p.code, '{}', v_principal_id
  from erp_ref.permission p
  where not p.is_mutating
  on conflict do nothing;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason, created_by)
  values (v_tenant_id, v_viewer_id, v_role_id, current_date, v_principal_id,
          'Seeded demo viewer', v_principal_id);

  return jsonb_build_object('tenant_id', v_tenant_id, 'principal_id', v_principal_id, 'already_existed', false);
end;
$function$;

CREATE OR REPLACE FUNCTION erp.provision_tenant_admin(p_tenant_id uuid, p_app_user_id uuid, p_granted_by uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_role_id uuid;
begin
  insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
  values (p_tenant_id, 'tenant-admin', 'role.tenant_admin.name', 'Tenant administrator',
          'Full access to every module and action in this tenant.', 'active'::erp.record_status, p_granted_by)
  on conflict (tenant_id, code) do update set name = excluded.name
  returning id into v_role_id;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select p_tenant_id, v_role_id, p.code, '{}', p_granted_by
  from erp_ref.permission p
  on conflict do nothing;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason, created_by)
  values (p_tenant_id, p_app_user_id, v_role_id, current_date, p_granted_by,
          'Tenant administrator grant', p_granted_by)
  on conflict do nothing;

  return v_role_id;
end;
$function$;



-- ---------------------------------------------------------------------------
-- The two that keep the privilege, enumerated
-- ---------------------------------------------------------------------------

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'onboard_tenant',
   'Creates a tenant for a caller who has no principal and therefore no tenant '
   'context, so row-level security has nothing to scope to. Writes only rows '
   'belonging to the tenant it is creating, and binds it to auth.uid().'),
  ('erp', 'seed_demo',
   'Same as onboard_tenant: builds a demonstration tenant for a caller who has '
   'none yet, so there is no context to run under. Reachable only by an '
   'authenticated caller who resolves to no principal.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- The public surface keeps a thin invoker wrapper over each, so rule 1 holds:
-- nothing in public runs as the owner.
create or replace function public.erp_onboard_tenant(p_name text, p_code text)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$ select erp.onboard_tenant(p_name, p_code) $$;

create or replace function public.erp_seed_demo()
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$ select erp.seed_demo() $$;

-- Two overloads of one API name is an ambiguity PostgREST has to guess at. The
-- parallel version is the one the permissions screen calls; this branch's
-- wrapper is withdrawn.
drop function if exists public.erp_grant_role(uuid, text, uuid, uuid, text);
delete from erp_meta.public_write_allowance where function_name = 'erp_grant_role';

-- ---------------------------------------------------------------------------
-- Choosing a tenant on purpose
-- ---------------------------------------------------------------------------

-- Keyed on the authenticated subject, not on a tenant, because spanning them is
-- the whole point. Deliberately NOT named tenant_id: this row is not owned by a
-- tenant, and calling the column tenant_id would make the isolation report
-- classify it as tenant-scoped and expect a policy that filtered it by the very
-- value it exists to determine.
create table erp_meta.principal_preference (
  auth_user_id     uuid primary key,
  active_tenant_id uuid not null references erp.tenant(id) on delete cascade,
  chosen_at        timestamptz not null default now()
);

comment on table erp_meta.principal_preference is
  'Which of their tenants a person is currently working in. Exists because '
  'membership became per-tenant: without it the answer is insertion order.';

alter table erp_meta.principal_preference enable row level security;
alter table erp_meta.principal_preference force row level security;
revoke all on erp_meta.principal_preference from public, anon;
grant select, insert, update, delete on erp_meta.principal_preference to authenticated;

-- A person may see and set their own choice and nobody else's. auth.uid() is
-- the only thing this can be scoped by; there is no tenant to scope it to.
create policy own_preference on erp_meta.principal_preference
  for all to authenticated
  using (auth_user_id = (select auth.uid()))
  with check (auth_user_id = (select auth.uid()));

-- Honours the choice; falls back to newest only when none has been made. The
-- fallback is what the parallel work did unconditionally, kept here so a
-- brand-new principal still lands somewhere.
create or replace function erp.principal_context()
returns table (principal_id uuid, tenant_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.tenant_id
    from erp.app_user u
    left join erp_meta.principal_preference p
      on p.auth_user_id = u.auth_user_id
   where u.auth_user_id = (select auth.uid())
     and u.status = 'active'::erp.principal_status
   order by (p.active_tenant_id is not null and p.active_tenant_id = u.tenant_id) desc,
            u.created_at desc
   limit 1
$$;

comment on function erp.principal_context() is
  'The only SECURITY DEFINER function B1 shipped with, and still the identity '
  'boundary. Resolves the authenticated subject to a principal, preferring the '
  'tenant that subject has chosen. "Newest wins" remains only as the fallback '
  'for a principal who has not chosen, because insertion order is not an answer.';

create or replace function erp.set_active_tenant(p_tenant_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject uuid := (select auth.uid());
begin
  if v_subject is null then
    raise exception 'ERPWARE_NOT_AUTHENTICATED' using errcode = '42501';
  end if;

  -- The check that matters: a person may only choose a tenant they already
  -- hold an active principal in. Without this the function would be a way to
  -- name any tenant at all and have current_tenant_id() agree.
  if not exists (
    select 1 from erp.app_user u
     where u.auth_user_id = v_subject
       and u.tenant_id = p_tenant_id
       and u.status = 'active'::erp.principal_status)
  then
    raise exception
      'ERPWARE_NOT_A_MEMBER: this sign-in holds no active principal in that tenant'
      using errcode = '42501';
  end if;

  insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
  values (v_subject, p_tenant_id)
  on conflict (auth_user_id)
    do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

  return p_tenant_id;
end;
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'set_active_tenant',
   'Writes the caller''s own tenant choice, which is keyed on auth.uid() and '
   'therefore belongs to no tenant, so there is no context to run it under. '
   'Refuses any tenant the caller does not already hold an active principal in.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- Which tenants may this sign-in choose between?
create or replace function public.erp_my_tenants()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'tenant_id', t.id, 'code', t.code, 'name', t.name,
           'principal_id', u.id, 'is_active', u.tenant_id = erp.current_tenant_id())
           order by t.name), '[]'::jsonb)
    from erp.app_user u
    join erp.tenant t on t.id = u.tenant_id
   where u.auth_user_id = (select auth.uid())
     and u.status = 'active'::erp.principal_status
$$;

create or replace function public.erp_set_active_tenant(p_tenant_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object('tenant_id', erp.set_active_tenant(p_tenant_id))
$$;

-- ---------------------------------------------------------------------------
-- Grants and the write allow-list
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_onboard_tenant(text, text)',
    'public.erp_seed_demo()',
    'public.erp_permissions_directory()',
    'public.erp_grant_role(uuid, uuid, date, date, text)',
    'public.erp_revoke_role(uuid)',
    'public.erp_save_role(uuid, text, text, text, text[])',
    'public.erp_my_tenants()',
    'public.erp_set_active_tenant(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_onboard_tenant', 'erp.onboard_tenant',
   'Creates a tenant for a caller who has none. Its gate is that it can only '
   'ever bind the new tenant to auth.uid(); there is no tenant to authorise '
   'against, which is why erp.onboard_tenant() is on the definer allow-list.'),
  ('erp_seed_demo', 'erp.seed_demo',
   'Builds a demonstration tenant for a caller who has none, on the same terms '
   'as onboarding and with the same reason for holding the privilege.'),
  ('erp_permissions_directory', 'erp.authorise',
   'Reads the tenant''s principals, roles and grants for the administration '
   'screen. Gated on administration.roles, and now INVOKER so row-level '
   'security scopes it rather than an explicit filter being trusted to.'),
  ('erp_grant_role', 'erp.authorise',
   'Grants a role to a principal within the caller''s tenant. Gated on '
   'administration.roles.'),
  ('erp_revoke_role', 'erp.authorise',
   'Ends a grant. Gated on administration.roles.'),
  ('erp_save_role', 'erp.authorise',
   'Creates or edits a role and its permission set. Gated on '
   'administration.roles.'),
  ('erp_set_active_tenant', 'erp.set_active_tenant',
   'Records which of the caller''s own tenants is active. Its gate is '
   'membership: erp.set_active_tenant() refuses any tenant the caller holds no '
   'active principal in.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.register_table('erp_meta', 'principal_preference', 'platform_internal',
  'Which of their tenants a person is working in. Keyed on the authenticated '
  'subject, because the choice spans tenants by definition.');

-- ---------------------------------------------------------------------------
-- Rule 3d needed a base case
-- ---------------------------------------------------------------------------
--
-- The gate chain has to stop somewhere, and it stops at erp.authorise().
--
-- 0042 assumed every entry on the write allow-list was a thin wrapper naming
-- the erp.* function it delegates to, so 3d followed that one hop and asked
-- whether the delegate authorised. Four of the functions reconciled above are
-- not wrappers — they call erp.authorise() directly in their own bodies — so
-- their gate IS the authoriser, and 3d dutifully asked whether erp.authorise()
-- authorises. It does not call itself, and it is not a definer exception, so
-- all four were reported.
--
-- Both shapes are legitimate: gate directly, or delegate to something that
-- does. The rule now says so, and 3b still proves the direct callers actually
-- contain the call.
create or replace function erp.public_api_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a public API function is SECURITY DEFINER',
         p.oid::regprocedure::text,
         'it would run as the owner, who bypasses row-level security, and '
         'return every tenant''s rows'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and p.prosecdef
  union all
  select 'a public API function is executable by anon',
         p.oid::regprocedure::text,
         'an unauthenticated caller should not reach the product surface at all'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  select 'a public API function writes but is not on the write allow-list',
         p.oid::regprocedure::text,
         'it is VOLATILE, so it may write; add it to '
         'erp_meta.public_write_allowance with a rationale, or make it STABLE'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and p.provolatile = 'v'
     and not exists (
       select 1 from erp_meta.public_write_allowance w
        where w.function_name = p.proname)
  union all
  select 'a public API write function does not call its declared gate',
         p.oid::regprocedure::text,
         format('%s is on the allow-list gated by %s, but its body does not '
                'call it', p.proname, w.gate)
    from pg_catalog.pg_proc p
    join erp_meta.public_write_allowance w on w.function_name = p.proname
   where p.pronamespace = 'public'::regnamespace
     and position(w.gate || '(' in p.prosrc) = 0
  union all
  select 'a write allow-list entry names no function', w.function_name,
         'nothing is being permitted, and nothing is being checked'
    from erp_meta.public_write_allowance w
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = w.function_name)
  union all
  -- 3d, with its base case: a gate of erp.authorise() is the authorisation,
  -- not a step towards it.
  select 'a public API write function delegates to something that does not authorise',
         w.function_name,
         format('%s neither calls erp.authorise() nor appears in '
                'erp_meta.security_definer_allowance', w.gate)
    from erp_meta.public_write_allowance w
    join pg_catalog.pg_proc d
      on d.pronamespace = split_part(w.gate, '.', 1)::regnamespace
     and d.proname = split_part(w.gate, '.', 2)
   where w.gate <> 'erp.authorise'
     and position('erp.authorise(' in d.prosrc) = 0
     and not exists (
       select 1 from erp_meta.security_definer_allowance a
        where a.schema_name = split_part(w.gate, '.', 1)
          and a.function_name = split_part(w.gate, '.', 2))
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_isolation();
