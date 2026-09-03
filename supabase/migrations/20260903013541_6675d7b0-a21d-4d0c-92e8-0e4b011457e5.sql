-- EDITED AFTER IT WAS APPLIED. See supabase/ci/migrations_edited.txt; the
-- repair that carries this to environments which already ran the original is
-- 20260904800000_reapply_the_doors_that_arrived_ungoverned.sql.
--
-- As written from the dashboard, this removed the last line of
-- erp.provision_tenant():
--
--   update erp.environment set is_live = true where id = v_env;
--
-- The problem it was solving is real. An organisation created from the
-- superadmin console was handed to a customer already governed, with exactly
-- one administrator — who authors every change set and may therefore approve
-- none of them. Nothing could be installed.
--
-- But taking the liveness out of the builder is not where the fix belongs, and
-- a build from empty says so out loud:
--
--   ERPWARE_CHANGE_SET_EMPTY: nothing to promote
--     erp_test.starter_pack_acceptance_suite()
--
-- erp.install_module_config() finishes an install itself inside the bootstrap
-- window and leaves it for a second person outside one, so every suite that
-- provisions a tenant and then approves what an installer authored finds the
-- change set already promoted. Fifteen suites depend on that behaviour, and two
-- cases of erp_test.provisioning_suite() assert the property directly: the self
-- environment exists and is live, and configuration cannot be edited directly
-- once it is. Removing it deletes a true property of the product.
--
-- The two callers want different things, and that is the whole of it. A fixture
-- or an operator calling erp.provision_tenant() directly wants an organisation
-- that is finished. The console is creating one for somebody else to finish. So
-- the builder goes back to building a governed organisation, and
-- 20260904770000 makes public.erp_platform_onboard_company() hand its
-- organisation over in the bootstrap window instead — which is where
-- erp.onboard_tenant() has left self-service organisations since
-- 20260829320000, and which erp.go_live() closes once there is a second
-- administrator to close it over.

CREATE OR REPLACE FUNCTION erp.provision_tenant(p_code text, p_name text, p_admin_email text, p_admin_display_name text, p_base_currency character DEFAULT 'GBP'::bpchar, p_country_code character DEFAULT 'GB'::bpchar, p_entity_code text DEFAULT 'MAIN'::text, p_timezone text DEFAULT 'UTC'::text, p_admin_valid_for interval DEFAULT '14 days'::interval)
 RETURNS TABLE(tenant_id uuid, entity_id uuid, admin_user_id uuid, role_id uuid, environment_id uuid, admin_token text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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

  -- §3.12's validation environment. Not is_self — B6 promotes into the one
  -- that IS this database — and never live, because nothing operational
  -- happens here. It exists so an organisation can say where a proposal was
  -- tried before it was applied.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant, 'sandbox', 'Sandbox', 'sandbox', false, false,
          -- Named without its parentheses on purpose:
          -- erp.intelligence_boundary_report() derives its call graph from
          -- function source text, so a call-shaped mention inside this body
          -- reads as a real edge from the transaction path into erp_ai and
          -- erp.assert_intelligence_boundary() fails on a comment.
          'Where a change is tried before it is applied. erp_ai.apply_proposal '
          'refuses a proposal validated in production, and without this there '
          'was nowhere else to have validated one.', 'active');

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
$function$

;

comment on function erp.provision_tenant(text, text, text, text, character, character, text, text, interval) is
  'Creates a tenant, its root entity, the is_self environment B6 needs, a '
  'validation environment, an administrator role holding every permission, and '
  'the first administrator as an invited principal with the token that lets '
  'them in. Declares the environment live at the end: this builds a finished '
  'organisation. public.erp_platform_onboard_company() is the door that hands '
  'one to a customer, and it reopens the bootstrap window so the person '
  'receiving it can configure it.';

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
