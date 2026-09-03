-- A tenant provisioned by the platform console was declared live in the same
-- breath as it was created. That closed the bootstrap window immediately: the
-- only administrator could author change sets and never approve them (an
-- author may not approve their own), so a brand-new organisation could not be
-- configured at all. The build window exists precisely for this; provisioning
-- should leave it open and let erp.go_live() close it.

create or replace function erp.provision_tenant(p_code text, p_name text, p_admin_email text, p_admin_display_name text, p_base_currency character DEFAULT 'GBP'::bpchar, p_country_code character DEFAULT 'GB'::bpchar, p_entity_code text DEFAULT 'MAIN'::text, p_timezone text DEFAULT 'UTC'::text, p_admin_valid_for interval DEFAULT '14 days'::interval)
 RETURNS TABLE(tenant_id uuid, entity_id uuid, admin_user_id uuid, role_id uuid, environment_id uuid, admin_token text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
declare
  v_tenant uuid;
  v_entity uuid;
  v_admin  uuid;
  v_role   uuid;
  v_env    uuid;
  v_token  text;
begin
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

  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  insert into erp.entity (tenant_id, code, name, legal_name,
                          base_currency, country_code, status)
  values (v_tenant, p_entity_code, p_name, p_name,
          p_base_currency, p_country_code, 'active')
  returning id into v_entity;

  -- B6 requires exactly one environment marked is_self: the one that IS this
  -- database. Created NOT live and LEFT not live: the organisation is built,
  -- not yet governed. Its first administrator is its only administrator, and
  -- an author may not approve their own change set, so declaring it live here
  -- made the organisation impossible to configure. erp.go_live() — which
  -- requires a second administrator — is what closes the window.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant, 'production', 'Production', 'production', false, true,
          'This database.', 'active')
  returning id into v_env;

  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant, 'sandbox', 'Sandbox', 'sandbox', false, false,
          'Where a change is tried before it is applied. erp_ai.apply_proposal '
          'refuses a proposal validated in production, and without this there '
          'was nowhere else to have validated one.', 'active');

  insert into erp.role (tenant_id, code, name, description, status)
  values (v_tenant, 'administrator', 'Administrator',
          'Holds every permission the product defines. Created at provisioning '
          'so the tenant has a way in; narrow it once real roles exist.',
          'active')
  returning id into v_role;

  insert into erp.role_permission (tenant_id, role_id, permission_code)
  select v_tenant, v_role, p.code from erp_ref.permission p;

  insert into erp.app_user (tenant_id, kind, status, display_name, email,
                            user_locale, timezone)
  values (v_tenant, 'person', 'invited', p_admin_display_name, p_admin_email,
          'en', p_timezone)
  returning id into v_admin;

  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  values (v_tenant, v_admin, v_role,
          'First administrator, created when the tenant was provisioned.');

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
  values (v_tenant, v_admin,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + p_admin_valid_for);

  return query select v_tenant, v_entity, v_admin, v_role, v_env, v_token;
end;
$$;

comment on function erp.provision_tenant is
  'Creates a tenant, its root entity, the is_self environment B6 needs, a '
  'validation environment, an administrator role holding every permission, '
  'and the first administrator as an invited principal with the token that '
  'lets them in. Leaves the self environment not live: the organisation is in '
  'its build window until erp.go_live() closes it.';

-- Organisations already stranded by the old behaviour: provisioned, declared
-- live, and never able to put a single change set in force. Reopen the window
-- for those, and only those. An organisation that has promoted anything is
-- genuinely governed and is left alone.
update erp.environment e
   set is_live = false, updated_at = now()
 where e.is_self
   and e.is_live
   and not exists (select 1 from erp.promotion p
                    where p.tenant_id = e.tenant_id and p.status = 'succeeded')
   and not exists (select 1 from erp.change_set c
                    where c.tenant_id = e.tenant_id and c.status = 'promoted');
