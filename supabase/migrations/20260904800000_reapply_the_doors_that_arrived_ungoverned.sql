-- =============================================================================
-- Three definitions, re-applied — because editing a migration that has already
-- run changes nothing where it has already run
--
-- The same shape as 20260903155000_reapply_edited_definitions.sql, and for the
-- same reason, arrived at from the opposite direction.
--
-- Three dashboard migrations of 3 September left the schema wrong:
--
--   20260903013541  took `update erp.environment set is_live = true` out of
--                   erp.provision_tenant(), so the builder stopped building a
--                   finished organisation and fifteen suites lost a property
--                   they depend on
--   20260903014640  replaced public.erp_entities() with a STABLE sql body
--                   carrying no gate, while its allow-list row went on naming
--                   erp.authorise, and added erp_create_site unregistered
--   20260903020414  added erp_create_location, also unregistered
--
-- The first attempt at this put the repairs in two NEW migrations back-dated to
-- 20260903030000 and 20260903040000, so that a build from empty would fix the
-- schema before the next migration to assert. That works, and it is why the
-- build was green. It also broke the preview branch on every commit from
-- 5fbd1f6 onward, and the failure is worth writing down because nothing else
-- in the repository says it:
--
--   Supabase pushes only migrations NEWER than the remote's last applied
--   version, and refuses the whole batch when it finds a local file that
--   sorts before it.
--
-- The preview's head was already 20260904770000. So the two back-dated files
-- were not merely skipped — they took every valid migration in the same push
-- down with them, and the branch sat at MIGRATIONS_FAILED with 208 of 220
-- applied while the build went on passing. Green from empty, dead everywhere
-- that is not empty: exactly the gap 20260903155000 was written about.
--
-- So the repairs go where the rule says they go. Each definition is corrected
-- in the migration that broke it, which is what a build from empty replays,
-- and re-applied here, which is what every environment past that point
-- receives. The three files are named in supabase/ci/migrations_edited.txt
-- against this one.
--
-- Nothing below weakens a rule to make a check pass. erp_create_site and
-- erp_create_location genuinely write and genuinely authorise, which is what
-- the allow-list exists to record; both are thin wrappers, so each declares the
-- erp.* function it delegates to rather than erp.authorise, because the
-- register checks that a door's declared gate appears in that door's own body.
-- =============================================================================

-- ── The gate goes back on ────────────────────────────────────────────────────

create or replace function public.erp_entities()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'entity_id', e.id, 'code', e.code, 'name', e.name,
      'base_currency', e.base_currency, 'country_code', e.country_code) as x
      from erp.entity e
     where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_entities() is
  'The organisation''s active legal entities. Gated on finance.read and '
  'recorded, because which entities exist is part of how an organisation is '
  'structured; it briefly lost both and the register went on claiming '
  'otherwise.';

revoke all on function public.erp_entities() from public, anon;
grant execute on function public.erp_entities() to authenticated, service_role;

-- ── The two writers, registered ──────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_site', 'erp.create_site',
   'Creates a site and the standard bays that go with it, under '
   'administration.configure. A new organisation cannot raise a purchase '
   'order, a receipt or a despatch until it has one, so this is the door that '
   'makes an empty organisation usable.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_location', 'erp.create_location',
   'Creates a location within a site, under administration.configure. A '
   'receipt posts into a receiving location and a despatch picks from '
   'storage, so a site that has run out of the bays it was given needs a way '
   'to add another.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ── Provisioning goes back to building a finished organisation ───────────────

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

-- The doors and the proof that they are governed, in the same transaction.
select erp.assert_public_api_safe();
