-- =============================================================================
-- ERPWare — the door a tenant is created through, and the surface it can reach
--
-- Three defects, one cause.
--
-- erp.provision_tenant() creates the environment marked is_self. The two
-- self-service doors — erp.onboard_tenant() and erp.seed_demo(), which arrived
-- on a parallel branch — do not. B6's guard_live_configuration() reads that
-- environment to decide whether a tenant is still being built:
--
--     "Until a tenant declares this environment live, it is being built."
--
-- With no row at all, is_live is null, the guard takes the permissive branch,
-- and it takes it for ever. So a tenant created through the self-service door
-- is not governed leniently while it is built — it is never governed. And
-- erp.promote_change_set() records environment_id as null on a nullable column,
-- so promotion half-works rather than refusing: the promotion history of such a
-- tenant does not say where anything was promoted to.
--
-- The third is the opposite failure. B6 refuses to let the author of a change
-- set approve it, which is right, and which means a self-service user on their
-- own cannot install a single module — every configure_* function authors a
-- change set and there is nobody else to wave it through. The product's answer
-- to "behaviour is configured rather than coded" was, for that user, that they
-- could configure nothing.
--
-- The fix is the window the guard already describes, made real rather than
-- accidental:
--
--   * both self-service doors create the is_self environment, NOT live;
--   * while it is not live, separation of duties has nobody to separate from,
--     so the author may approve — and the module installer approves and
--     promotes in one call, which is what "install" ought to mean;
--   * erp.go_live() closes the window, and refuses to close it over dead
--     configuration;
--   * after that the tenant is governed exactly as a provisioned one is.
--
-- Nothing is relaxed where the product considers a tenant finished.
-- erp.provision_tenant() is untouched: it still declares itself live at the end
-- of provisioning, and still needs two administrators.
--
-- The fourth change here is unrelated to the other three and is the reason
-- they were found. Fifty-eight erp.* operations — receiving, despatching,
-- counting, booking time, closing a period — authorise a permission and are
-- reachable from nowhere. The public API carried the configure_* functions and
-- almost none of the operations they configure. That surface is generated
-- below from the catalogue, so a wrapper cannot drift from what it wraps.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Where a tenant is standing
-- -----------------------------------------------------------------------------

-- One place that answers "which environment IS this database, for this tenant",
-- so the four callers that used to inline the subquery cannot each decide
-- differently what a missing row means. It means refuse.
create or replace function erp.self_environment_id(p_tenant_id uuid default null)
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.require_tenant_id());
  v_env    uuid;
begin
  select e.id into v_env
    from erp.environment e
   where e.tenant_id = v_tenant and e.is_self;

  if v_env is null then
    raise exception
      'ERPWARE_NO_SELF_ENVIRONMENT: tenant % has no environment marked is_self',
      v_tenant
      using errcode = '23502',
      detail = 'B6 promotes into the environment that IS this database. '
               'Without it a promotion cannot say where it happened.',
      hint = 'erp.provision_tenant() and erp.onboard_tenant() both create one.';
  end if;

  return v_env;
end;
$$;

comment on function erp.self_environment_id is
  'The environment that IS this database, for a tenant. Raises rather than '
  'returning null: a promotion with no environment is a promotion whose '
  'history cannot be read, which is worse than a refused one.';

-- Is this tenant still being built? The guard's question, asked out loud so
-- that the installer and the guard cannot answer it differently.
create or replace function erp.tenant_is_live(p_tenant_id uuid default null)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(bool_or(e.is_live), false)
    from erp.environment e
   where e.tenant_id = coalesce(p_tenant_id, erp.require_tenant_id())
     and e.is_self;
$$;

comment on function erp.tenant_is_live is
  'False while a tenant is being built — before it has declared its own '
  'environment live. erp.guard_live_configuration() has always used this '
  'condition; this names it so the bootstrap window is one idea rather than '
  'the same coalesce written in four places.';

-- -----------------------------------------------------------------------------
-- One name for the administrator role
-- -----------------------------------------------------------------------------

-- The self-service door called its role 'tenant-admin'; erp.provision_tenant()
-- called the identical role 'administrator'. Every configure_* function in the
-- product takes p_approver_role and defaults it to 'administrator', so a
-- self-service tenant installing any module authored approval steps naming a
-- role it did not have. That is not a cosmetic difference between two doors: it
-- is the difference between a module that installs and one that does not.
--
-- Nothing outside these two functions ever referenced 'tenant-admin'.
create or replace function erp.provision_tenant_admin(
  p_tenant_id uuid, p_app_user_id uuid, p_granted_by uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_role_id uuid;
begin
  insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
  values (p_tenant_id, 'administrator', 'role.administrator.name', 'Administrator',
          'Full access to every module and action in this tenant.',
          'active'::erp.record_status, p_granted_by)
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
$$;

-- The tenants already carrying the other name. Same role, same grants, same
-- rows: only the code the configure_* functions look for is different.
update erp.role r
   set code = 'administrator', name_key = 'role.administrator.name',
       name = 'Administrator'
 where r.code = 'tenant-admin'
   and not exists (select 1 from erp.role o
                    where o.tenant_id = r.tenant_id and o.code = 'administrator');

-- -----------------------------------------------------------------------------
-- Backfill, before the column stops accepting null
-- -----------------------------------------------------------------------------

-- Every tenant onboarded through the self-service door is missing its
-- environment. Created NOT live, deliberately: these tenants have never
-- declared themselves finished, and inventing that declaration on their behalf
-- would start refusing configuration edits they are in the middle of making.
-- erp.go_live() is how they say it.
do $$
declare
  v_count integer;
begin
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  select t.id, 'production', 'Production', 'production', false, true,
         'This database. Created retrospectively: this tenant was onboarded '
         'before the self-service door created one.', 'active'
    from erp.tenant t
   where not exists (select 1 from erp.environment e
                      where e.tenant_id = t.id and e.is_self)
     and not exists (select 1 from erp.environment e
                      where e.tenant_id = t.id and e.code = 'production');

  get diagnostics v_count = row_count;
  raise notice 'backfilled % self environment(s)', v_count;
end;
$$;

-- A promotion that does not know where it happened is not a record of anything.
update erp.promotion p
   set environment_id = (select e.id from erp.environment e
                          where e.tenant_id = p.tenant_id and e.is_self)
 where p.environment_id is null;

alter table erp.promotion alter column environment_id set not null;

-- -----------------------------------------------------------------------------
-- The two doors, made to produce the same tenant
-- -----------------------------------------------------------------------------

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
  v_env_id uuid;
  v_entity_id uuid;
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

  -- erp.app_user requires an email of every person, so a subject without one
  -- cannot become a principal. Saying that here is worth doing: the alternative
  -- is a check-constraint violation four statements later, naming a table the
  -- caller has never heard of.
  if v_email is null then
    raise exception
      'ERPWARE_NO_EMAIL: the authenticated subject has no email address, and a '
      'person principal must have one'
      using errcode = '23514',
      hint = 'Sign in with an email identity, or have an administrator invite '
             'you with erp.invite_principal().';
  end if;

  insert into erp.tenant (code, name, status, provisioned_at)
  values (p_code, p_name, 'active'::erp.tenant_status, now())
  returning id into v_tenant_id;

  -- The missing row. B6 promotes into the environment that IS this database,
  -- and every function that reads it treats its absence as "not live", which
  -- for a tenant that never gets one means never governed. Not live yet, on
  -- purpose: a tenant has to be built before it can be governed, and
  -- erp.go_live() is where it says it is finished.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant_id, 'production', 'Production', 'production', false, true,
          'This database.', 'active')
  returning id into v_env_id;

  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, v_auth_id, 'person'::erp.principal_kind, 'active'::erp.principal_status,
          coalesce(v_display, 'Tenant administrator'), v_email)
  returning id into v_principal_id;

  perform erp.provision_tenant_admin(v_tenant_id, v_principal_id, v_principal_id);

  -- A root entity, for the same reason erp.provision_tenant() creates one: a
  -- tenant with no legal entity has no chart of accounts, so it has no ledger,
  -- so it cannot install finance, so it cannot install anything that posts.
  -- The self-service door created none, which meant the first thing a new
  -- tenant did was fail.
  --
  -- The defaults match erp.provision_tenant()'s, and are a starting point
  -- rather than a claim about the tenant: currency, country and name are
  -- ordinary master data the administrator edits.
  insert into erp.entity (tenant_id, code, name, legal_name,
                          base_currency, country_code, status, created_by)
  values (v_tenant_id, 'MAIN', p_name, p_name, 'GBP', 'GB', 'active',
          v_principal_id)
  returning id into v_entity_id;

  return jsonb_build_object('tenant_id', v_tenant_id,
                            'principal_id', v_principal_id,
                            'environment_id', v_env_id,
                            'entity_id', v_entity_id,
                            'is_live', false);
end;
$function$;

comment on function erp.onboard_tenant is
  'Creates a tenant for an authenticated caller who has no principal yet, with '
  'the is_self environment B6 needs, not yet live. Until erp.go_live() the '
  'tenant is in its bootstrap window: configuration may be installed by one '
  'person, because there is only one person.';

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
  v_env_id uuid;
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

  -- erp.app_user requires an email of every person, so a subject without one
  -- cannot become a principal. Saying that here is worth doing: the alternative
  -- is a check-constraint violation four statements later, naming a table the
  -- caller has never heard of.
  if v_email is null then
    raise exception
      'ERPWARE_NO_EMAIL: the authenticated subject has no email address, and a '
      'person principal must have one'
      using errcode = '23514',
      hint = 'Sign in with an email identity, or have an administrator invite '
             'you with erp.invite_principal().';
  end if;

  insert into erp.tenant (code, name, status, provisioned_at)
  values ('demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
          'Demo — Acme Manufacturing', 'active'::erp.tenant_status, now())
  returning id into v_tenant_id;

  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant_id, 'production', 'Production', 'production', false, true,
          'This database.', 'active')
  returning id into v_env_id;

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

  return jsonb_build_object('tenant_id', v_tenant_id,
                            'principal_id', v_principal_id,
                            'environment_id', v_env_id,
                            'is_live', false,
                            'already_existed', false);
end;
$function$;

-- -----------------------------------------------------------------------------
-- Separation of duties, and the window in which there is nobody to separate
-- -----------------------------------------------------------------------------

-- Unchanged in every governed tenant: the author of a change set may not
-- approve it. The exception is narrow and stated rather than implied — while
-- the tenant has not declared its environment live it is being built, and the
-- control is asking a person on their own to find a second person who does not
-- exist yet. That is not a control; it is a locked door with the key inside.
--
-- The window is closed by erp.go_live(), which cannot be undone through this
-- API, and provisioned tenants are never in it: erp.provision_tenant() marks
-- the environment live before it returns.
create or replace function erp.approve_change_set(p_change_set_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cs       erp.change_set%rowtype;
  v_status erp.approval_status;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  select * into cs from erp.change_set where tenant_id = v_tenant and id = p_change_set_id;

  if cs.status <> 'ready' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_READY: % is %', cs.code, cs.status
      using errcode = '23514';
  end if;

  if cs.approval_request_id is not null then
    select ar.status into v_status from erp.approval_request ar where ar.id = cs.approval_request_id;
    if v_status <> 'approved' then
      raise exception 'ERPWARE_CHANGE_SET_APPROVAL_PENDING: the approval request is %', v_status
        using errcode = '23514';
    end if;
  end if;

  -- Whoever raised the change may not be the one who waves it through — once
  -- the tenant is live and there is somebody else to be.
  if erp.tenant_is_live(v_tenant)
     and cs.created_by is not null
     and cs.created_by = erp.current_principal_id() then
    raise exception
      'ERPWARE_CHANGE_SET_SELF_APPROVAL: the author of a change set may not approve it'
      using errcode = '42501',
      hint = 'Grant administration.promote to a second principal.';
  end if;

  update erp.change_set
     set status = 'approved', approved_by = erp.current_principal_id(),
         approved_at = now(), updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;
end;
$$;

-- Same function, one line different: the environment is looked up through
-- erp.self_environment_id(), which refuses rather than writing null.
create or replace function erp.promote_change_set(
  p_change_set_id uuid,
  p_scope_kinds   text[] default null,
  p_ignore_schedule boolean default false)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  cs         erp.change_set%rowtype;
  v_promo    uuid;
  v_snapshot uuid;
  v_applied  integer := 0;
  v_env      uuid;
  r          record;
  v_entity   record;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  -- Before the snapshot, so a tenant with no environment fails without having
  -- written anything.
  v_env := erp.self_environment_id(v_tenant);

  select * into cs from erp.change_set
   where tenant_id = v_tenant and id = p_change_set_id for update;

  if cs.status <> 'approved' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_APPROVED: % is %', cs.code, cs.status
      using errcode = '42501';
  end if;

  if cs.scheduled_for is not null and not p_ignore_schedule and now() < cs.scheduled_for then
    raise exception 'ERPWARE_CHANGE_SET_NOT_DUE: % is scheduled for %', cs.code, cs.scheduled_for
      using errcode = '23514';
  end if;

  -- Snapshot first. Rollback is only "one action" if the previous state was
  -- captured before anything moved.
  v_snapshot := erp.take_config_snapshot(
    format('before promotion of %s', cs.code),
    format('pre-%s-%s', cs.code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')));

  insert into erp.promotion (
    tenant_id, change_set_id, environment_id, snapshot_id, scope_kinds, actor_id)
  values (
    v_tenant, p_change_set_id, v_env,
    v_snapshot, p_scope_kinds, erp.current_principal_id())
  returning id into v_promo;

  update erp.change_set
     set status = 'promoting', rollback_snapshot_id = v_snapshot, updated_at = now()
   where id = p_change_set_id;

  -- Opens the window in which configuration may be written in a live
  -- environment. Transaction-scoped, so it closes whatever happens next.
  perform set_config('erp.promotion_id', v_promo::text, true);

  for r in
    select i.id from erp.change_set_item i
     where i.tenant_id = v_tenant
       and i.change_set_id = p_change_set_id
       and (p_scope_kinds is null or i.object_kind = any (p_scope_kinds))
     order by
       -- Roles and terminology before the things that reference them.
       case i.object_kind
         when 'role' then 1 when 'terminology' then 2 when 'config' then 3
         when 'legislation_binding' then 4 when 'event_subscription' then 5
         when 'rule_set' then 6 when 'state_machine' then 7
         when 'approval_chain' then 8 else 9 end,
       i.seq
  loop
    perform erp.apply_change_set_item(r.id);
    v_applied := v_applied + 1;
  end loop;

  -- Spec 3.11: "validated by tests". The pack conformance suite is the test
  -- that matters most here, because a promotion that quietly changes a tax
  -- answer is the expensive kind.
  for v_entity in
    select distinct b.entity_id from erp.entity_legislation_binding b
     where b.tenant_id = v_tenant and b.status = 'active'
  loop
    perform erp.assert_legislation_conformance(v_entity.entity_id);
  end loop;

  update erp.promotion
     set status = 'succeeded', finished_at = now(), applied_count = v_applied
   where id = v_promo;

  update erp.change_set
     set status = 'promoted', promoted_at = now(), updated_at = now()
   where id = p_change_set_id;

  perform set_config('erp.promotion_id', '', true);

  return v_promo;
end;
$$;

-- The change set records where it was authored, by the same rule.
create or replace function erp.create_change_set(
  p_code text,
  p_name text,
  p_description text default null,
  p_scheduled_for timestamptz default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', null);

  insert into erp.change_set (
    tenant_id, code, name, description, scheduled_for, created_by,
    source_environment_id)
  values (
    v_tenant, p_code, p_name, p_description, p_scheduled_for,
    erp.current_principal_id(),
    erp.self_environment_id(v_tenant))
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Installing a module, during the window and after it
-- -----------------------------------------------------------------------------

create or replace function erp.install_module_config(
  p_code        text,
  p_name        text,
  p_description text,
  p_items       jsonb
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_cs   uuid;
  v_item jsonb;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);

  v_cs := erp.create_change_set(p_code, p_name, p_description);

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    perform erp.add_change_set_item(
      v_cs, v_item ->> 'kind', v_item ->> 'key', v_item -> 'payload');
  end loop;

  perform erp.submit_change_set(v_cs);

  -- Submitted and deliberately not approved, once the tenant is live. B6
  -- refuses to let the author of a change set wave it through, and installing
  -- a module is exactly the kind of change that control exists for: these
  -- change sets set the thresholds above which a purchase needs finance and an
  -- order needs credit release.
  --
  -- Before go-live there is no second person for the control to find, and
  -- refusing here made a self-service tenant unconfigurable — which is a
  -- strange end for a product whose claim is that behaviour is configured.
  -- So during the window "install" means installed.
  if not erp.tenant_is_live() then
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
  end if;

  return v_cs;
end;
$$;

comment on function erp.install_module_config is
  'Authors a module''s lifecycle configuration as one B6 change set. Before a '
  'tenant declares itself live the set is approved and promoted in the same '
  'call, because there is nobody else to approve it; afterwards it is left '
  'submitted for a second administrator, which is the control the product '
  'wants once there is a product to control.';

-- -----------------------------------------------------------------------------
-- Declaring the tenant finished
-- -----------------------------------------------------------------------------

create or replace function erp.go_live()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_env    uuid;
  v_live   boolean;
  v_dead   integer;
  v_detail text;
  v_admins integer;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'environment', null);

  v_env := erp.self_environment_id(v_tenant);
  select e.is_live into v_live from erp.environment e where e.id = v_env;

  if v_live then
    raise exception 'ERPWARE_ALREADY_LIVE: this tenant is already live'
      using errcode = '23514',
      hint = 'Configuration changes go through erp.promote_change_set().';
  end if;

  -- Going live over configuration that is known to be wrong would make the
  -- first governed change a repair. The report is scoped by row-level security
  -- to this tenant, so this asks about this tenant only.
  select count(*), string_agg(format('%s (%s)', finding, reference), '; ')
    into v_dead, v_detail
    from erp.dead_configuration_report();

  if v_dead > 0 then
    raise exception 'ERPWARE_DEAD_CONFIGURATION: % finding(s) before go-live: %',
      v_dead, v_detail
      using errcode = '23514',
      hint = 'erp.dead_configuration_report() lists them in full.';
  end if;

  -- After this call the author of a change set may no longer approve it, so a
  -- tenant with one administrator would go live unable to change anything.
  -- Saying so now is better than saying it at the next promotion.
  select count(distinct ur.app_user_id) into v_admins
    from erp.user_role ur
    join erp.role_permission rp
      on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
    join erp.app_user u
      on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
   where ur.tenant_id = v_tenant
     and rp.permission_code = 'administration.promote'
     and u.status in ('active', 'invited')
     and (ur.valid_to is null or ur.valid_to >= current_date);

  if v_admins < 2 then
    raise exception
      'ERPWARE_SINGLE_ADMINISTRATOR: going live needs a second principal '
      'holding administration.promote; found %', v_admins
      using errcode = '23514',
      hint = 'erp.invite_principal() and erp.grant_role(), then call this again.';
  end if;

  update erp.environment set is_live = true, updated_at = now()
   where id = v_env;

  return jsonb_build_object('tenant_id', v_tenant,
                            'environment_id', v_env,
                            'is_live', true,
                            'administrators', v_admins);
end;
$$;

comment on function erp.go_live is
  'Closes a tenant''s bootstrap window: from here configuration changes only '
  'through a promoted change set, and the author of one may not approve it. '
  'Refuses over dead configuration, and refuses a tenant with a single '
  'administrator, because that tenant would be live and unable to change.';

-- -----------------------------------------------------------------------------
-- The finding that would have caught this
-- -----------------------------------------------------------------------------

create or replace function erp.dead_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- The new one, and the reason this migration exists. A tenant with no
  -- environment marked is_self reads as "still being built" to every guard
  -- that asks, for ever, and its promotions record no environment at all.
  select 'a tenant has no environment marked is_self',
         t.code,
         'B6 reads this environment to decide whether the tenant is governed; '
         'with no row it answers "still being built" permanently'
    from erp.tenant t
   where t.status = 'active'
     and not exists (select 1 from erp.environment e
                      where e.tenant_id = t.id and e.is_self)
  union all
  select 'a transition declares effects that nothing executes',
         format('%s.%s', m.code, t.code),
         'erp.perform_transition() does not run transition effects, so this '
         'configuration would be stored and silently ignored'
    from erp.transition t
    join erp.state_machine_version v on v.id = t.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(t.effects, '[]'::jsonb)) > 0
  union all
  select 'a state declares entry or exit actions that nothing executes',
         format('%s.%s', m.code, s.code),
         'on_enter and on_exit are stored and never read'
    from erp.state s
    join erp.state_machine_version v on v.id = s.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(s.on_enter, '[]'::jsonb)) > 0
      or jsonb_array_length(coalesce(s.on_exit, '[]'::jsonb)) > 0
  union all
  select 'a document type names a state machine that does not exist',
         dt.code, format('state_machine_code = %s', dt.state_machine_code)
    from erp.document_type dt
   where dt.status = 'active'
     and dt.state_machine_code is not null
     and not exists (
       select 1 from erp.state_machine m
        where m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
          and m.status = 'active')
  union all
  select 'a document type moves stock but names no movement type',
         dt.code,
         format('base type %s declares affects_stock', dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_stock
     and dt.stock_movement_type is null
  union all
  select 'a document type names a movement type but moves no stock',
         dt.code,
         format('stock_movement_type = %s, but base type %s declares '
                'affects_stock false', dt.stock_movement_type, dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and not bt.affects_stock
     and dt.stock_movement_type is not null
  union all
  select 'a document type reaches the ledger but names no posting rule',
         dt.code,
         format('base type %s declares affects_finance', dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_finance
     and dt.posting_rule_code is null
  union all
  select 'a document type names a posting rule but reaches no ledger',
         dt.code,
         format('posting_rule_code = %s, but base type %s declares '
                'affects_finance false', dt.posting_rule_code, dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and not bt.affects_finance
     and dt.posting_rule_code is not null
  union all
  select 'a document type names a posting rule that has no active version',
         dt.code, format('posting_rule_code = %s', dt.posting_rule_code)
    from erp.document_type dt
   where dt.status = 'active'
     and dt.posting_rule_code is not null
     and not exists (
       select 1 from erp.posting_rule pr
        where pr.tenant_id = dt.tenant_id and pr.code = dt.posting_rule_code
          and pr.status = 'active')
  union all
  select 'a posting rule does not balance',
         format('%s v%s', pr.code, pr.version),
         format('debits less credits is %s per unit of document value',
                erp.posting_rule_imbalance(pr.posting_lines))
    from erp.posting_rule pr
   where pr.status = 'active'
     and erp.posting_rule_imbalance(pr.posting_lines) <> 0
  union all
  select 'a posting rule names an account the entity does not have',
         format('%s v%s', pr.code, pr.version),
         format('account %s', l.value ->> 'account')
    from erp.posting_rule pr
    cross join lateral jsonb_array_elements(pr.posting_lines) l
   where pr.status = 'active'
     and not exists (
       select 1 from erp.account a
        where a.tenant_id = pr.tenant_id
          and a.code = (l.value ->> 'account')
          and a.status = 'active'
          and (pr.entity_id is null or a.entity_id = pr.entity_id))
  union all
  select 'a ledger has no fiscal period covering today',
         l.code,
         format('ledger %s of entity %s', l.code, e.code)
    from erp.ledger l
    join erp.entity e on e.tenant_id = l.tenant_id and e.id = l.entity_id
   where l.status = 'active'
     and not exists (
       select 1 from erp.fiscal_period p
        where p.tenant_id = l.tenant_id and p.ledger_id = l.id
          and current_date between p.starts_on and p.ends_on)
$$;

-- =============================================================================
-- The operational surface
--
-- Fifty-eight erp.* functions authorise a permission, write, and were reachable
-- from nothing. The public API had erp_configure_procurement() but no
-- erp_receive_against(); erp_configure_quality() but no way to record an
-- inspection result. A product whose configuration screens work and whose
-- operations do not is a configuration editor.
--
-- Every wrapper below is generated from the catalogue — invoker, thin, no
-- logic — so it cannot drift from the function it delegates to, and every one
-- names in erp_meta.public_write_allowance the gate its body must call.
-- erp.assert_public_api_safe() then walks the call graph and proves that gate
-- reaches erp.authorise(). Nothing here is trusted because it is short; it is
-- trusted because the assertion re-derives it.
--
-- Left off deliberately:
--   erp.provision_tenant()   — gated on a trusted session, not on a principal.
--   erp.install_module_config() — the modules' own installer, not an action.
--   erp.post_document_stock() / _finance() — posting is a property of the
--     lifecycle, reached by transitioning the document. A second door would
--     make it possible to post something the state machine has not agreed to.
--   erp.create_change_set() / erp.submit_change_set() — arbitrary change-set
--     authoring stays inside the configure_* functions, which is what makes
--     "behaviour is configured" reviewable rather than freehand.
-- =============================================================================

create or replace function public.erp_allocate_landed_cost(p_landed_cost_id uuid)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.allocate_landed_cost(p_landed_cost_id) $$;
create or replace function public.erp_amend_batch(p_batch_id uuid, p_field text, p_value text, p_reason text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.amend_batch(p_batch_id, p_field, p_value, p_reason) $$;
create or replace function public.erp_amend_document_line(p_line_id uuid, p_quantity numeric, p_reason text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.amend_document_line(p_line_id, p_quantity, p_reason) $$;
create or replace function public.erp_apply_calculated_policy(p_item_id uuid, p_site_id uuid)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.apply_calculated_policy(p_item_id, p_site_id) $$;
create or replace function public.erp_apply_cash(p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text DEFAULT NULL::text)
returns TABLE(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint) language sql volatile security invoker set search_path = ''
as $$ select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference) $$;
create or replace function public.erp_apply_mass_change(p_mass_change_id uuid)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.apply_mass_change(p_mass_change_id) $$;
create or replace function public.erp_approve_payment_run(p_proposal_id uuid)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.approve_payment_run(p_proposal_id) $$;
create or replace function public.erp_book_operation_time(p_works_order_id uuid, p_operation_seq integer, p_minutes numeric, p_completed numeric DEFAULT 0, p_scrapped numeric DEFAULT 0)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.book_operation_time(p_works_order_id, p_operation_seq, p_minutes, p_completed, p_scrapped) $$;
create or replace function public.erp_book_shipment(p_shipment_id uuid, p_carrier_code text, p_service_code text, p_cost_minor bigint DEFAULT NULL::bigint)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.book_shipment(p_shipment_id, p_carrier_code, p_service_code, p_cost_minor) $$;
create or replace function public.erp_cancel_command(p_command_id uuid, p_reason text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.cancel_command(p_command_id, p_reason) $$;
create or replace function public.erp_clear_kill_switch(p_kind erp.kill_target_kind, p_key text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.clear_kill_switch(p_kind, p_key) $$;
create or replace function public.erp_close_period(p_fiscal_period_id uuid)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.close_period(p_fiscal_period_id) $$;
create or replace function public.erp_close_quality_event(p_event_id uuid, p_root_cause text, p_corrective_action text, p_preventive_action text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.close_quality_event(p_event_id, p_root_cause, p_corrective_action, p_preventive_action) $$;
create or replace function public.erp_close_works_order(p_works_order_id uuid)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select erp.close_works_order(p_works_order_id) $$;
create or replace function public.erp_commit_allocation(p_allocation_id uuid, p_location_id uuid DEFAULT NULL::uuid, p_batch_id uuid DEFAULT NULL::uuid)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.commit_allocation(p_allocation_id, p_location_id, p_batch_id) $$;
create or replace function public.erp_complete_close_task(p_task_id uuid, p_waiver_reason text DEFAULT NULL::text)
returns text language sql volatile security invoker set search_path = ''
as $$ select erp.complete_close_task(p_task_id, p_waiver_reason) $$;
create or replace function public.erp_configure_tax(p_home_country character DEFAULT 'GB'::bpchar, p_standard_rate numeric DEFAULT 20)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_tax(p_home_country, p_standard_rate) $$;
create or replace function public.erp_disposition_inspection(p_inspection_id uuid, p_disposition erp.disposition, p_note text DEFAULT NULL::text)
returns erp.disposition language sql volatile security invoker set search_path = ''
as $$ select erp.disposition_inspection(p_inspection_id, p_disposition, p_note) $$;
create or replace function public.erp_invoice_against(p_invoice_id uuid, p_order_line_id uuid, p_quantity numeric, p_unit_price_minor bigint DEFAULT NULL::bigint)
returns erp.match_status language sql volatile security invoker set search_path = ''
as $$ select erp.invoice_against(p_invoice_id, p_order_line_id, p_quantity, p_unit_price_minor) $$;
create or replace function public.erp_invoice_from_delivery(p_delivery_id uuid, p_allow_self_invoice boolean DEFAULT false)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.invoice_from_delivery(p_delivery_id, p_allow_self_invoice) $$;
create or replace function public.erp_issue_to_works_order(p_works_order_id uuid, p_component_item_id uuid, p_quantity numeric, p_batch_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.issue_to_works_order(p_works_order_id, p_component_item_id, p_quantity, p_batch_id, p_location_id) $$;
create or replace function public.erp_link_documents(p_from_document_id uuid, p_to_document_id uuid, p_kind erp.document_relation_kind, p_quantity numeric DEFAULT NULL::numeric)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.link_documents(p_from_document_id, p_to_document_id, p_kind, p_quantity) $$;
create or replace function public.erp_load_import(p_batch_id uuid)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.load_import(p_batch_id) $$;
create or replace function public.erp_log_recall_action(p_recall_id uuid, p_action_kind text, p_party_id uuid DEFAULT NULL::uuid, p_impact_id bigint DEFAULT NULL::bigint, p_quantity_recovered numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_evidence_ref text DEFAULT NULL::text)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.log_recall_action(p_recall_id, p_action_kind, p_party_id, p_impact_id, p_quantity_recovered, p_note, p_evidence_ref) $$;
create or replace function public.erp_merge_master_record(p_object_type text, p_survivor_id uuid, p_duplicate_id uuid, p_reason text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.merge_master_record(p_object_type, p_survivor_id, p_duplicate_id, p_reason) $$;
create or replace function public.erp_open_mass_change(p_object_type text, p_selector jsonb, p_changes jsonb, p_reason text DEFAULT NULL::text, p_code text DEFAULT NULL::text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.open_mass_change(p_object_type, p_selector, p_changes, p_reason, p_code) $$;
create or replace function public.erp_open_period_close(p_fiscal_period_id uuid)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.open_period_close(p_fiscal_period_id) $$;
create or replace function public.erp_plan_shipment(p_site_id uuid, p_delivery_ids uuid[], p_planned_despatch date DEFAULT NULL::date)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.plan_shipment(p_site_id, p_delivery_ids, p_planned_despatch) $$;
create or replace function public.erp_post_count(p_task_id uuid)
returns numeric language sql volatile security invoker set search_path = ''
as $$ select erp.post_count(p_task_id) $$;
create or replace function public.erp_price_document_line(p_line_id uuid)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.price_document_line(p_line_id) $$;
create or replace function public.erp_propose_payment_run(p_payment_date date DEFAULT NULL::date, p_currency character DEFAULT NULL::bpchar, p_include_due_within interval DEFAULT '7 days'::interval)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.propose_payment_run(p_payment_date, p_currency, p_include_due_within) $$;
create or replace function public.erp_qualify_supplier(p_party_id uuid, p_valid_for interval DEFAULT '1 year'::interval, p_note text DEFAULT NULL::text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.qualify_supplier(p_party_id, p_valid_for, p_note) $$;
create or replace function public.erp_raise_count_tasks(p_programme_code text)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.raise_count_tasks(p_programme_code) $$;
create or replace function public.erp_raise_customer_return(p_original_document_id uuid, p_reason_code text, p_reason text, p_outcome text DEFAULT 'credit'::text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.raise_customer_return(p_original_document_id, p_reason_code, p_reason, p_outcome) $$;
create or replace function public.erp_raise_quality_event(p_kind erp.quality_event_kind, p_title text, p_severity text, p_site_id uuid DEFAULT NULL::uuid, p_item_id uuid DEFAULT NULL::uuid, p_batch_id uuid DEFAULT NULL::uuid, p_document_id uuid DEFAULT NULL::uuid, p_party_id uuid DEFAULT NULL::uuid, p_due_in interval DEFAULT '14 days'::interval)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.raise_quality_event(p_kind, p_title, p_severity, p_site_id, p_item_id, p_batch_id, p_document_id, p_party_id, p_due_in) $$;
create or replace function public.erp_raise_recall(p_title text, p_reason text, p_classification text, p_batch_ids uuid[], p_clock_code text DEFAULT NULL::text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.raise_recall(p_title, p_reason, p_classification, p_batch_ids, p_clock_code) $$;
create or replace function public.erp_raise_works_order(p_item_id uuid, p_site_id uuid, p_quantity numeric, p_kind erp.works_order_kind DEFAULT 'assembly'::erp.works_order_kind, p_planned_end date DEFAULT NULL::date)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.raise_works_order(p_item_id, p_site_id, p_quantity, p_kind, p_planned_end) $$;
create or replace function public.erp_receive_against(p_receipt_id uuid, p_order_line_id uuid, p_quantity numeric, p_batch_id uuid DEFAULT NULL::uuid)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.receive_against(p_receipt_id, p_order_line_id, p_quantity, p_batch_id) $$;
create or replace function public.erp_receive_works_order_output(p_works_order_id uuid, p_quantity numeric, p_batch_number text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.receive_works_order_output(p_works_order_id, p_quantity, p_batch_number, p_location_id) $$;
create or replace function public.erp_record_count(p_task_id uuid, p_quantity numeric)
returns erp.count_task_status language sql volatile security invoker set search_path = ''
as $$ select erp.record_count(p_task_id, p_quantity) $$;
create or replace function public.erp_record_inspection_result(p_inspection_id uuid, p_characteristic text, p_numeric_value numeric DEFAULT NULL::numeric, p_text_value text DEFAULT NULL::text, p_instrument text DEFAULT NULL::text)
returns boolean language sql volatile security invoker set search_path = ''
as $$ select erp.record_inspection_result(p_inspection_id, p_characteristic, p_numeric_value, p_text_value, p_instrument) $$;
create or replace function public.erp_record_proof_of_delivery(p_shipment_id uuid, p_arrived_at timestamp with time zone, p_signed_by text, p_reference text DEFAULT NULL::text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.record_proof_of_delivery(p_shipment_id, p_arrived_at, p_signed_by, p_reference) $$;
create or replace function public.erp_release_batch(p_batch_id uuid, p_site_id uuid, p_basis text, p_signature text, p_inspection_id uuid DEFAULT NULL::uuid)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.release_batch(p_batch_id, p_site_id, p_basis, p_signature, p_inspection_id) $$;
create or replace function public.erp_release_credit_hold(p_document_id uuid, p_reason text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.release_credit_hold(p_document_id, p_reason) $$;
create or replace function public.erp_release_works_order(p_works_order_id uuid, p_allow_shortage boolean DEFAULT false)
returns erp.works_order_status language sql volatile security invoker set search_path = ''
as $$ select erp.release_works_order(p_works_order_id, p_allow_shortage) $$;
create or replace function public.erp_reopen_period(p_fiscal_period_id uuid, p_reason text)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.reopen_period(p_fiscal_period_id, p_reason) $$;
create or replace function public.erp_replay_message(p_message_id bigint, p_reason text)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.replay_message(p_message_id, p_reason) $$;
create or replace function public.erp_reserve_for_line(p_document_line_id uuid, p_policy_code text DEFAULT NULL::text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.reserve_for_line(p_document_line_id, p_policy_code) $$;
create or replace function public.erp_reverse_mass_change(p_mass_change_id uuid)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.reverse_mass_change(p_mass_change_id) $$;
create or replace function public.erp_rollback_import(p_batch_id uuid)
returns integer language sql volatile security invoker set search_path = ''
as $$ select erp.rollback_import(p_batch_id) $$;
create or replace function public.erp_rollback_to_snapshot(p_snapshot_id uuid, p_reason text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.rollback_to_snapshot(p_snapshot_id, p_reason) $$;
create or replace function public.erp_run_forecast(p_forecast_code text, p_periods integer DEFAULT 6, p_buckets integer DEFAULT 24)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.run_forecast(p_forecast_code, p_periods, p_buckets) $$;
create or replace function public.erp_set_kill_switch(p_kind erp.kill_target_kind, p_key text, p_reason text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.set_kill_switch(p_kind, p_key, p_reason) $$;
create or replace function public.erp_sign_off_forecast(p_version_id uuid, p_note text DEFAULT NULL::text)
returns void language sql volatile security invoker set search_path = ''
as $$ select erp.sign_off_forecast(p_version_id, p_note) $$;
create or replace function public.erp_split_batch(p_batch_id uuid, p_new_number text, p_quantity numeric, p_location_id uuid, p_reason text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.split_batch(p_batch_id, p_new_number, p_quantity, p_location_id, p_reason) $$;
create or replace function public.erp_stage_import(p_object_type text, p_rows jsonb, p_code text DEFAULT NULL::text, p_source text DEFAULT 'manual'::text)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.stage_import(p_object_type, p_rows, p_code, p_source) $$;
create or replace function public.erp_write_off_stock(p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric, p_reason text, p_batch_id uuid DEFAULT NULL::uuid)
returns bigint language sql volatile security invoker set search_path = ''
as $$ select erp.write_off_stock(p_item_id, p_site_id, p_location_id, p_quantity, p_reason, p_batch_id) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_allocate_landed_cost(p_landed_cost_id uuid)',
    'public.erp_amend_batch(p_batch_id uuid, p_field text, p_value text, p_reason text)',
    'public.erp_amend_document_line(p_line_id uuid, p_quantity numeric, p_reason text)',
    'public.erp_apply_calculated_policy(p_item_id uuid, p_site_id uuid)',
    'public.erp_apply_cash(p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text)',
    'public.erp_apply_mass_change(p_mass_change_id uuid)',
    'public.erp_approve_payment_run(p_proposal_id uuid)',
    'public.erp_book_operation_time(p_works_order_id uuid, p_operation_seq integer, p_minutes numeric, p_completed numeric, p_scrapped numeric)',
    'public.erp_book_shipment(p_shipment_id uuid, p_carrier_code text, p_service_code text, p_cost_minor bigint)',
    'public.erp_cancel_command(p_command_id uuid, p_reason text)',
    'public.erp_clear_kill_switch(p_kind erp.kill_target_kind, p_key text)',
    'public.erp_close_period(p_fiscal_period_id uuid)',
    'public.erp_close_quality_event(p_event_id uuid, p_root_cause text, p_corrective_action text, p_preventive_action text)',
    'public.erp_close_works_order(p_works_order_id uuid)',
    'public.erp_commit_allocation(p_allocation_id uuid, p_location_id uuid, p_batch_id uuid)',
    'public.erp_complete_close_task(p_task_id uuid, p_waiver_reason text)',
    'public.erp_configure_tax(p_home_country character, p_standard_rate numeric)',
    'public.erp_disposition_inspection(p_inspection_id uuid, p_disposition erp.disposition, p_note text)',
    'public.erp_invoice_against(p_invoice_id uuid, p_order_line_id uuid, p_quantity numeric, p_unit_price_minor bigint)',
    'public.erp_invoice_from_delivery(p_delivery_id uuid, p_allow_self_invoice boolean)',
    'public.erp_issue_to_works_order(p_works_order_id uuid, p_component_item_id uuid, p_quantity numeric, p_batch_id uuid, p_location_id uuid)',
    'public.erp_link_documents(p_from_document_id uuid, p_to_document_id uuid, p_kind erp.document_relation_kind, p_quantity numeric)',
    'public.erp_load_import(p_batch_id uuid)',
    'public.erp_log_recall_action(p_recall_id uuid, p_action_kind text, p_party_id uuid, p_impact_id bigint, p_quantity_recovered numeric, p_note text, p_evidence_ref text)',
    'public.erp_merge_master_record(p_object_type text, p_survivor_id uuid, p_duplicate_id uuid, p_reason text)',
    'public.erp_open_mass_change(p_object_type text, p_selector jsonb, p_changes jsonb, p_reason text, p_code text)',
    'public.erp_open_period_close(p_fiscal_period_id uuid)',
    'public.erp_plan_shipment(p_site_id uuid, p_delivery_ids uuid[], p_planned_despatch date)',
    'public.erp_post_count(p_task_id uuid)',
    'public.erp_price_document_line(p_line_id uuid)',
    'public.erp_propose_payment_run(p_payment_date date, p_currency character, p_include_due_within interval)',
    'public.erp_qualify_supplier(p_party_id uuid, p_valid_for interval, p_note text)',
    'public.erp_raise_count_tasks(p_programme_code text)',
    'public.erp_raise_customer_return(p_original_document_id uuid, p_reason_code text, p_reason text, p_outcome text)',
    'public.erp_raise_quality_event(p_kind erp.quality_event_kind, p_title text, p_severity text, p_site_id uuid, p_item_id uuid, p_batch_id uuid, p_document_id uuid, p_party_id uuid, p_due_in interval)',
    'public.erp_raise_recall(p_title text, p_reason text, p_classification text, p_batch_ids uuid[], p_clock_code text)',
    'public.erp_raise_works_order(p_item_id uuid, p_site_id uuid, p_quantity numeric, p_kind erp.works_order_kind, p_planned_end date)',
    'public.erp_receive_against(p_receipt_id uuid, p_order_line_id uuid, p_quantity numeric, p_batch_id uuid)',
    'public.erp_receive_works_order_output(p_works_order_id uuid, p_quantity numeric, p_batch_number text, p_location_id uuid)',
    'public.erp_record_count(p_task_id uuid, p_quantity numeric)',
    'public.erp_record_inspection_result(p_inspection_id uuid, p_characteristic text, p_numeric_value numeric, p_text_value text, p_instrument text)',
    'public.erp_record_proof_of_delivery(p_shipment_id uuid, p_arrived_at timestamp with time zone, p_signed_by text, p_reference text)',
    'public.erp_release_batch(p_batch_id uuid, p_site_id uuid, p_basis text, p_signature text, p_inspection_id uuid)',
    'public.erp_release_credit_hold(p_document_id uuid, p_reason text)',
    'public.erp_release_works_order(p_works_order_id uuid, p_allow_shortage boolean)',
    'public.erp_reopen_period(p_fiscal_period_id uuid, p_reason text)',
    'public.erp_replay_message(p_message_id bigint, p_reason text)',
    'public.erp_reserve_for_line(p_document_line_id uuid, p_policy_code text)',
    'public.erp_reverse_mass_change(p_mass_change_id uuid)',
    'public.erp_rollback_import(p_batch_id uuid)',
    'public.erp_rollback_to_snapshot(p_snapshot_id uuid, p_reason text)',
    'public.erp_run_forecast(p_forecast_code text, p_periods integer, p_buckets integer)',
    'public.erp_set_kill_switch(p_kind erp.kill_target_kind, p_key text, p_reason text)',
    'public.erp_sign_off_forecast(p_version_id uuid, p_note text)',
    'public.erp_split_batch(p_batch_id uuid, p_new_number text, p_quantity numeric, p_location_id uuid, p_reason text)',
    'public.erp_stage_import(p_object_type text, p_rows jsonb, p_code text, p_source text)',
    'public.erp_write_off_stock(p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric, p_reason text, p_batch_id uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_allocate_landed_cost', 'erp.allocate_landed_cost',
   'Spreads a landed-cost document over the receipts it belongs to. '
   'Authorises procurement.match and writes only valuation rows against '
   'receipts the caller can already see.'),
  ('erp_amend_batch', 'erp.amend_batch',
   'Amends a batch attribute under inventory.adjust, and records the '
   'reason on the batch record rather than overwriting history.'),
  ('erp_amend_document_line', 'erp.amend_document_line',
   'Changes a line quantity under sales.order. Refuses once the document '
   'has left the states its type allows amendment in.'),
  ('erp_apply_calculated_policy', 'erp.apply_calculated_policy',
   'Writes the calculated reorder policy back onto the item and site '
   'under planning.run, which is the whole point of calculating it.'),
  ('erp_apply_cash', 'erp.apply_cash',
   'Applies a receipt across open subledger items under finance.post. '
   'Allocation only; it creates no ledger entry the posting rules did '
   'not already define.'),
  ('erp_apply_mass_change', 'erp.apply_mass_change',
   'Executes a mass change that was opened, previewed and approved '
   'first. Authorises master_data.write and is reversible through '
   'erp_reverse_mass_change.'),
  ('erp_approve_payment_run', 'erp.approve_payment_run',
   'Approves a proposed payment run under finance.approve_payment, which '
   'is a distinct permission from finance.post precisely so the two can '
   'be held by different people.'),
  ('erp_book_operation_time', 'erp.book_operation_time',
   'Books labour and output against a works order operation under '
   'production.execute. Shop-floor reporting is the highest-frequency '
   'write in the product and needs a first-class door.'),
  ('erp_book_shipment', 'erp.book_shipment',
   'Records the carrier, service and cost against a planned shipment '
   'under logistics.plan.'),
  ('erp_cancel_command', 'erp.cancel_command',
   'Cancels a queued outbound command under administration.integrate. '
   'Cancelling is the safe direction: the message is never sent.'),
  ('erp_clear_kill_switch', 'erp.clear_kill_switch',
   'Restores a target a kill switch disabled. Authorises '
   'administration.configure and is the only way back from '
   'erp_set_kill_switch.'),
  ('erp_close_period', 'erp.close_period',
   'Closes a fiscal period under finance.close_period, after the '
   'checklist opened by erp_open_period_close is complete.'),
  ('erp_close_quality_event', 'erp.close_quality_event',
   'Closes a quality event with its root cause and actions under '
   'quality.disposition. The three narrative fields are required by the '
   'function, not by the caller.'),
  ('erp_close_works_order', 'erp.close_works_order',
   'Closes a works order and settles its variances under '
   'production.release, returning the settlement so the caller can show '
   'it.'),
  ('erp_commit_allocation', 'erp.commit_allocation',
   'Turns a soft allocation into a committed one under sales.despatch, '
   'against stock the balance guard has already agreed exists.'),
  ('erp_complete_close_task', 'erp.complete_close_task',
   'Marks one period-close checklist task complete under '
   'finance.close_period, recording a waiver reason when the task is '
   'being skipped rather than done.'),
  ('erp_configure_tax', 'erp.configure_tax',
   'Submits the tax configuration as a B6 change set through the module '
   'installer, which authorises administration.configure. Nothing takes '
   'effect until the set is approved and promoted.'),
  ('erp_disposition_inspection', 'erp.disposition_inspection',
   'Records the disposition of an inspection under quality.disposition. '
   'Accepting or rejecting material is a decision a person makes, so it '
   'needs a call they can make.'),
  ('erp_invoice_against', 'erp.invoice_against',
   'Matches an invoice line to an order line under procurement.match and '
   'returns the resulting match status, so a mismatch is visible at the '
   'moment it is created.'),
  ('erp_invoice_from_delivery', 'erp.invoice_from_delivery',
   'Raises an invoice from a posted delivery under sales.invoice. '
   'Self-billing is opt-in through an explicit argument rather than a '
   'default.'),
  ('erp_issue_to_works_order', 'erp.issue_to_works_order',
   'Issues components to a works order under production.execute, through '
   'the same stock movement bridge every other issue uses.'),
  ('erp_link_documents', 'erp.link_documents',
   'Records a lineage relation between two documents under '
   'procurement.order. Lineage is read constantly and has to be writable '
   'through the API that reads it.'),
  ('erp_load_import', 'erp.load_import',
   'Commits a validated import batch under master_data.import. Refuses a '
   'batch that has not passed erp_validate_import, and is undone by '
   'erp_rollback_import.'),
  ('erp_log_recall_action', 'erp.log_recall_action',
   'Records one action taken during a recall under quality.recall. A '
   'recall whose actions cannot be logged is a recall with no evidence '
   'it happened.'),
  ('erp_merge_master_record', 'erp.merge_master_record',
   'Merges a duplicate into a survivor under master_data.approve, '
   'keeping the duplicate as a redirect rather than deleting it.'),
  ('erp_open_mass_change', 'erp.open_mass_change',
   'Opens a mass change for preview under master_data.write. Opening '
   'changes nothing: erp_apply_mass_change is the write.'),
  ('erp_open_period_close', 'erp.open_period_close',
   'Raises the period-close checklist under finance.close_period and '
   'returns how many tasks it created.'),
  ('erp_plan_shipment', 'erp.plan_shipment',
   'Groups deliveries into a shipment under logistics.plan, before '
   'anything is booked with a carrier.'),
  ('erp_post_count', 'erp.post_count',
   'Posts a completed stock count under inventory.adjust and returns the '
   'variance, which is the number the count exists to produce.'),
  ('erp_price_document_line', 'erp.price_document_line',
   'Reprices a line through the promoted pricing policies under '
   'sales.price. The price comes from configuration; this call only asks '
   'for it to be applied.'),
  ('erp_propose_payment_run', 'erp.propose_payment_run',
   'Proposes a payment run under finance.approve_payment. Proposing pays '
   'nobody; erp_approve_payment_run does.'),
  ('erp_qualify_supplier', 'erp.qualify_supplier',
   'Records a supplier qualification with an expiry under '
   'master_data.approve, which is what the procurement controls later '
   'check against.'),
  ('erp_raise_count_tasks', 'erp.raise_count_tasks',
   'Raises the count tasks a counting programme is due under '
   'inventory.count.'),
  ('erp_raise_customer_return', 'erp.raise_customer_return',
   'Raises a return against an original document under sales.order, with '
   'the reason and intended outcome recorded on it.'),
  ('erp_raise_quality_event', 'erp.raise_quality_event',
   'Raises a quality event under quality.disposition. A non-conformance '
   'nobody can record is a non-conformance that does not exist.'),
  ('erp_raise_recall', 'erp.raise_recall',
   'Raises a recall over a set of batches under quality.recall, starting '
   'the regulatory clock the configuration defines.'),
  ('erp_raise_works_order', 'erp.raise_works_order',
   'Raises a works order under production.order, which is where every '
   'production movement afterwards hangs from.'),
  ('erp_receive_against', 'erp.receive_against',
   'Receives quantity against a purchase order line under '
   'procurement.receive, posting the inbound movement through the shared '
   'bridge.'),
  ('erp_receive_works_order_output', 'erp.receive_works_order_output',
   'Receives finished output from a works order under '
   'production.execute, creating the batch when the item is '
   'batch-tracked.'),
  ('erp_record_count', 'erp.record_count',
   'Records a counted quantity against a count task under '
   'inventory.count and returns whether the variance needs a recount.'),
  ('erp_record_inspection_result', 'erp.record_inspection_result',
   'Records one measured characteristic under quality.inspect and '
   'returns whether it is within specification.'),
  ('erp_record_proof_of_delivery', 'erp.record_proof_of_delivery',
   'Records proof of delivery against a shipment under '
   'logistics.despatch.'),
  ('erp_release_batch', 'erp.release_batch',
   'Releases a batch for sale under quality.release_batch, which is a '
   'permission deliberately separate from quality.inspect.'),
  ('erp_release_credit_hold', 'erp.release_credit_hold',
   'Releases an order from credit hold under sales.credit_release, with '
   'the reason recorded against the release.'),
  ('erp_release_works_order', 'erp.release_works_order',
   'Releases a works order to the floor under production.release, '
   'refusing on component shortage unless the caller says otherwise '
   'explicitly.'),
  ('erp_reopen_period', 'erp.reopen_period',
   'Reopens a closed fiscal period under finance.reopen_period, which is '
   'its own permission because reopening is not the inverse of closing '
   'in any governance model worth the name.'),
  ('erp_replay_message', 'erp.replay_message',
   'Replays a failed outbound message under administration.integrate, '
   'through the gateway rather than around it.'),
  ('erp_reserve_for_line', 'erp.reserve_for_line',
   'Reserves stock for an order line under sales.order, using the '
   'promoted allocation policy rather than an argument.'),
  ('erp_reverse_mass_change', 'erp.reverse_mass_change',
   'Reverses an applied mass change under master_data.write. This is the '
   'undo the preview promises.'),
  ('erp_rollback_import', 'erp.rollback_import',
   'Rolls back a loaded import batch under master_data.import, which is '
   'the only reason loading one is safe.'),
  ('erp_rollback_to_snapshot', 'erp.rollback_to_snapshot',
   'Restores configuration to a snapshot under administration.promote, '
   'which is B6 one-action rollback and has to be reachable to be worth '
   'having.'),
  ('erp_run_forecast', 'erp.run_forecast',
   'Runs a forecast under planning.forecast, producing a version nobody '
   'has signed off yet.'),
  ('erp_set_kill_switch', 'erp.set_kill_switch',
   'Disables a configuration target without editing it, under '
   'administration.configure. This is the emergency route the '
   'live-configuration guard names in its own hint.'),
  ('erp_sign_off_forecast', 'erp.sign_off_forecast',
   'Signs off a forecast version under planning.forecast, which is what '
   'makes it the one planning consumes.'),
  ('erp_split_batch', 'erp.split_batch',
   'Splits a batch under inventory.adjust, keeping both halves traceable '
   'to the original.'),
  ('erp_stage_import', 'erp.stage_import',
   'Stages import rows under master_data.import. Staging writes nothing '
   'to master data: preview, validate and load are separate calls on '
   'purpose.'),
  ('erp_write_off_stock', 'erp.write_off_stock',
   'Writes stock off under inventory.write_off, which is its own '
   'permission because a write-off is a loss rather than an adjustment.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

create or replace function public.erp_go_live()
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select erp.go_live() $$;

do $$
begin
  execute 'revoke all on function public.erp_go_live() from public, anon';
  execute 'grant execute on function public.erp_go_live() to authenticated';
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_go_live', 'erp.go_live',
   'Closes the tenant''s bootstrap window under administration.configure. It '
   'only ever tightens: after it, configuration changes through a promoted '
   'change set and an author may not approve their own.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- =============================================================================
-- The suite
--
-- The claims worth testing here are all about a window: that it exists, that
-- it is permissive in exactly one respect, that closing it works, and that
-- after it is closed nothing is looser than it was before this migration.
-- =============================================================================

create or replace function erp_test.bootstrap_window_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_onboard jsonb; v_tenant uuid; v_env uuid; v_second uuid; v_tok text;
  res jsonb; v_cs uuid; v_ok boolean; v_msg text; v_promo uuid;
  v_before integer;
begin
  -- ---------------------------------------------------------------------
  -- The self-service door
  -- ---------------------------------------------------------------------

  -- onboard_tenant() reads auth.uid() and then looks the subject up, because
  -- erp.app_user requires an email of every person. So the suite has to put one
  -- there: the self-service door starts at the platform's identity table, and a
  -- test that skipped it would be testing a different function.
  insert into auth.users (id, email) values (a1, 'solo@zzboot.test');
  insert into auth.users (id, email) values (a2, 'second@zzboot.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_onboard := erp.onboard_tenant('Bootstrap Window', 'zzboot');
  v_tenant := (v_onboard ->> 'tenant_id')::uuid;
  v_env    := (v_onboard ->> 'environment_id')::uuid;

  return query select 'the self-service door creates the is_self environment',
    v_env is not null
      and exists (select 1 from erp.environment e
                   where e.id = v_env and e.tenant_id = v_tenant and e.is_self),
    'without it every guard that asks answers "still being built", for ever';

  return query select 'and creates it not yet live',
    not (select e.is_live from erp.environment e where e.id = v_env),
    'a tenant has to be built before it can be governed';

  return query select 'erp.tenant_is_live() agrees',
    not erp.tenant_is_live(v_tenant),
    'the guard and the installer must answer this question the same way';

  -- ---------------------------------------------------------------------
  -- Inside the window
  -- ---------------------------------------------------------------------

  return query select 'and a root entity, so the tenant has a chart of accounts',
    (v_onboard ->> 'entity_id') is not null,
    'without one erp.configure_finance() refuses, and nothing that posts can '
    'be installed at all';

  v_cs := erp.configure_finance();
  perform erp.configure_inventory('average');

  return query select 'a solo administrator can install a module',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'promoted',
    'B6 refuses self-approval; before go-live there is no second person for '
    'it to find, which made a self-service tenant unconfigurable';

  return query select 'and the configuration it promoted is really there',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = v_tenant and pr.status = 'active')
      = (select count(*) from erp.change_set_item i
          where i.change_set_id = v_cs and i.object_kind = 'posting_rule'),
    'promoted is a status on a row; every posting rule the set named has to '
    'be in erp.posting_rule for that status to mean anything';

  return query select 'the promotion records which environment it happened in',
    (select p.environment_id from erp.promotion p
      where p.tenant_id = v_tenant order by p.started_at desc limit 1) = v_env,
    'the column was nullable and the subquery returned null for this tenant, '
    'so promotion half-worked rather than refusing';

  -- ---------------------------------------------------------------------
  -- Closing it
  -- ---------------------------------------------------------------------

  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() succeeded with one administrator';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SINGLE_ADMINISTRATOR%'; v_msg := sqlerrm;
  end;
  return query select 'go-live refuses a tenant with one administrator',
    v_ok, v_msg;

  res := public.erp_invite_principal('second@zzboot.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  return query select 'go-live succeeds once there are two',
    (erp.go_live() ->> 'is_live')::boolean,
    'the second principal is what makes separation of duties possible at all';

  return query select 'and the tenant is live afterwards',
    erp.tenant_is_live(v_tenant),
    'the window is closed by a row, not by a session setting';

  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() succeeded twice';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ALREADY_LIVE%'; v_msg := sqlerrm;
  end;
  return query select 'going live twice is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- After it — nothing is looser than it was
  -- ---------------------------------------------------------------------

  v_cs := erp.configure_sales(15);

  return query select 'after go-live the installer stops at submitted',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'ready',
    'this is the control the product wants once there is a product to control';

  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change set';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CHANGE_SET_SELF_APPROVAL%'; v_msg := sqlerrm;
  end;
  return query select 'and the author may not approve it',
    v_ok, v_msg;

  begin
    insert into erp.rule_set (tenant_id, code, name, status)
    values (v_tenant, 'zzboot-direct', 'Direct edit', 'active');
    v_ok := false; v_msg := 'a live tenant accepted a direct configuration edit';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := sqlerrm;
  end;
  return query select 'the live-configuration guard is now on',
    v_ok, v_msg;

  -- The second administrator can, which is the point of having one.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(v_cs);
  v_promo := erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a second administrator can approve and promote',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'promoted',
    'separation of duties has to be satisfiable or it is only an outage';

  return query select 'that promotion also names the environment',
    (select p.environment_id from erp.promotion p where p.id = v_promo) = v_env,
    'erp.promotion.environment_id is not null now, so this cannot regress '
    'quietly';

  -- ---------------------------------------------------------------------
  -- The refusals the new column and helper are for
  -- ---------------------------------------------------------------------

  begin
    perform erp.self_environment_id(gen_random_uuid());
    v_ok := false; v_msg := 'self_environment_id() returned for an unknown tenant';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_SELF_ENVIRONMENT%'; v_msg := sqlerrm;
  end;
  return query select 'a tenant with no self environment is refused, not defaulted',
    v_ok, v_msg;

  return query select 'the promotion environment cannot be null',
    (select a.attnotnull from pg_attribute a
      where a.attrelid = 'erp.promotion'::regclass and a.attname = 'environment_id'),
    'a promotion whose history cannot say where it happened is not a record';

  -- ---------------------------------------------------------------------
  -- The finding that would have caught the original defect
  -- ---------------------------------------------------------------------

  select count(*) into v_before from erp.dead_configuration_report()
   where finding = 'a tenant has no environment marked is_self';

  -- Cleared rather than deleted: erp.change_set.source_environment_id points at
  -- this row now, which is itself part of the fix.
  update erp.environment set is_self = false where id = v_env;

  return query select 'a tenant with no is_self environment is dead configuration',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a tenant has no environment marked is_self') = v_before + 1,
    'this is the finding that would have made the original hole a build '
    'failure rather than a live tenant nobody governed';

  -- Put it back: the assertions at the end of this migration run over every
  -- tenant, this one included.
  update erp.environment set is_self = true where id = v_env;

  -- ---------------------------------------------------------------------
  -- The operational surface
  -- ---------------------------------------------------------------------

  return query select 'every operational wrapper is on the write allow-list',
    not exists (
      select 1 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname like 'erp\_%'
         and p.provolatile = 'v'
         and not exists (select 1 from erp_meta.public_write_allowance w
                          where w.function_name = p.proname)),
    'the allow-list is the review; a wrapper missing from it is a write '
    'nobody wrote a reason for';

  return query select 'the operational surface reaches the shop floor',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('erp_receive_against', 'erp_record_count',
                          'erp_book_operation_time', 'erp_record_inspection_result',
                          'erp_close_period', 'erp_configure_tax')) = 6,
    'a product whose configuration screens work and whose operations do not '
    'is a configuration editor';

  perform set_config('request.jwt.claims', '', true);
end;
$$;

create or replace function erp_test.assert_bootstrap_window_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 21;
begin
  create temporary table if not exists zz_boot_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_boot_result;
  insert into zz_boot_result select * from erp_test.bootstrap_window_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_boot_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_BOOTSTRAP_WINDOW_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_BOOTSTRAP_WINDOW_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('bootstrap window: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
