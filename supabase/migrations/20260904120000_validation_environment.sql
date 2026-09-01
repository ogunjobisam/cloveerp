-- =============================================================================
-- A validation environment, so §3.12's apply path can complete
--
-- erp_ai.apply_proposal() refuses a proposal validated in production —
-- correctly, because "we tested it in production" is not a test. But
-- erp.onboard_tenant() creates exactly one environment, kind production and
-- is_self true, so there was nowhere else for a proposal to have been
-- validated. The refusal was unreachable-by-construction: no organisation this
-- product creates could ever satisfy it.
--
-- The fix is one more row, not a change to the rule. Every organisation now
-- gets a sandbox alongside its production environment: not is_self, not live,
-- and existing only so that "validated somewhere that is not production" is a
-- statement an organisation can make about itself.
--
-- Both functions are PATCHED rather than retyped. The first attempt at the
-- receipt-tolerance migration in this same set rewrote a function from a
-- partial read and silently dropped three behaviours; these are the deployed
-- definitions with one insert added and nothing else, and the diff is checked.
-- =============================================================================

create or replace function erp.onboard_tenant(p_name text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
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

  -- §3.12's validation environment. Not is_self — B6 promotes into the one
  -- that IS this database — and never live, because nothing operational
  -- happens here. It exists so an organisation can say where a proposal was
  -- tried before it was applied.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant_id, 'sandbox', 'Sandbox', 'sandbox', false, false,
          -- Named without its parentheses on purpose:
          -- erp.intelligence_boundary_report() derives its call graph from
          -- function source text, so a call-shaped mention inside this body
          -- reads as a real edge from the transaction path into erp_ai and
          -- erp.assert_intelligence_boundary() fails on a comment.
          'Where a change is tried before it is applied. erp_ai.apply_proposal '
          'refuses a proposal validated in production, and without this there '
          'was nowhere else to have validated one.', 'active');

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
$$;

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
$$;

-- ── Existing organisations ───────────────────────────────────────────────────
--
-- The two functions above only help an organisation created from now on. Every
-- organisation that already exists was provisioned with one environment and
-- still has nowhere to validate, so it gets the same row. Idempotent on
-- (tenant_id, code), and skipped where an organisation already has a
-- non-production environment of its own — somebody who has already made one is
-- better placed than this migration to say what it is for.

insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                             description, status)
select t.id, 'sandbox', 'Sandbox', 'sandbox', false, false,
       'Where a change is tried before it is applied. Added to an organisation '
       'that was provisioned before validation environments existed.',
       'active'
  from erp.tenant t
 where t.status not in ('deleting', 'deleted')
   and exists (select 1 from erp.environment e
                where e.tenant_id = t.id and e.is_self)
   and not exists (select 1 from erp.environment e
                    where e.tenant_id = t.id
                      and not e.is_self and e.kind <> 'production')
on conflict (tenant_id, code) do nothing;

-- ── The assertion ────────────────────────────────────────────────────────────

create or replace function erp.assert_validation_environment_available()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_detail text := '';
  r record;
  v_src text;
begin
  -- 1. Every organisation that has been provisioned has somewhere that is not
  --    production and is not this database. Without one, erp_ai.apply_proposal
  --    cannot complete for that organisation by construction: 'validated'
  --    requires a validation environment recorded, the trigger refuses a
  --    production one, and apply_proposal() refuses the is_self one.
  for r in
    select t.code, t.id from erp.tenant t
     where t.status not in ('deleting', 'deleted')
       and exists (select 1 from erp.environment e
                    where e.tenant_id = t.id and e.is_self)
       and not exists (select 1 from erp.environment e
                        where e.tenant_id = t.id
                          and not e.is_self and e.kind <> 'production')
     order by 1
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  %s has only its own production environment, so no proposal it '
       'raises can ever be applied\n', r.code);
  end loop;

  -- 2. And both provisioning routes still create one. This is the check that
  --    matters over time: the condition above is satisfied by a backfill, and
  --    would stay satisfied for years while a rewritten onboard_tenant quietly
  --    stopped creating the row for anybody new. A function rewritten from a
  --    partial read is exactly how three behaviours were dropped from
  --    erp.receive_against() earlier in this same piece of work.
  foreach v_src in array array['erp.onboard_tenant(text,text)',
                               'erp.provision_tenant(text,text,text,text,'
                               'character,character,text,text,interval)']
  loop
    if position('''sandbox''' in
                pg_catalog.pg_get_functiondef(v_src::regprocedure)) = 0 then
      v_count := v_count + 1;
      v_detail := v_detail || format(
        E'  %s no longer creates a validation environment\n', split_part(v_src, '(', 1));
    end if;
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_NO_VALIDATION_ENVIRONMENT: % finding(s)\n%',
      v_count, v_detail using errcode = '23514';
  end if;

  return format('validation environments: %s organisation(s), %s with somewhere to validate',
    (select count(*) from erp.tenant t
      where t.status not in ('deleting', 'deleted')
        and exists (select 1 from erp.environment e where e.tenant_id = t.id and e.is_self)),
    (select count(*) from erp.tenant t
      where t.status not in ('deleting', 'deleted')
        and exists (select 1 from erp.environment e where e.tenant_id = t.id and e.is_self)
        and exists (select 1 from erp.environment e
                     where e.tenant_id = t.id and not e.is_self and e.kind <> 'production')));
end;
$$;

comment on function erp.assert_validation_environment_available is
  'Every provisioned organisation has an environment that is neither production '
  'nor this database, and both provisioning routes still create one. Spec 3.12 '
  'asks for a test environment first; before this, no organisation had one.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('validation_environment', 'Validation environment available', 'assertion',
        'platform', 'assert_validation_environment_available', '', null, '',
        'Spec 3.12 refuses a proposal validated in production. Every '
        'organisation needs somewhere else to have validated one, and both '
        'provisioning routes have to keep creating it.', true, 30)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind,
  scope = excluded.scope, runs_in_ci = excluded.runs_in_ci;

-- ── The decision this closes ─────────────────────────────────────────────────

update erp_meta.policy_decision set
  decision =
    'Taken, not left. Every organisation now gets a second environment — code '
    'sandbox, kind sandbox, not is_self and not live — created by both '
    'provisioning routes and backfilled for the ones that already existed. The '
    'rule is untouched: a proposal still has to have been validated somewhere '
    'that is not production and is not the environment being promoted into. '
    'There is now somewhere for that to have been.',
  rationale =
    'The recorded reason for leaving it was that giving organisations a second '
    'environment is real B6 work with its own decisions about what a test '
    'environment contains. That turned out to be the wrong shape of question. '
    'B6 promotes into the environment marked is_self and knows the others only '
    'through the manifests they publish, so a validation environment is a row '
    'that names where validation happened, not a second copy of the data. '
    'Nothing had to be decided about its contents because it does not have '
    'any. The alternative considered and rejected in the original decision — '
    'relaxing the rule so a proposal can be applied where it was written — '
    'stays rejected.',
  evidence =
    'erp.assert_validation_environment_available() fails if any provisioned '
    'organisation has only its own production environment, and fails if either '
    'erp.onboard_tenant or erp.provision_tenant stops creating the row. '
    'erp_test.validation_environment_suite() runs a proposal through '
    'erp_ai.apply_proposal() end to end, which no test could do before.',
  status = 'accepted', decided_at = now()
 where code = 'proposal_apply_path_unreachable';


-- ── The suite ────────────────────────────────────────────────────────────────
--
-- The assertion above proves every organisation has the row. It does not prove
-- the row is enough, and "enough" is the whole claim: that erp_ai.apply_proposal()
-- now runs to completion for an organisation this product created, without any
-- of §3.12's four promises having been weakened to get there. So the suite runs
-- a proposal from draft to applied and reads the promoted result back, and then
-- checks that each refusal that used to be unreachable-by-accident is still
-- reachable-on-purpose.

create or replace function erp_test.validation_environment_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();
  v jsonb; v_t uuid; v_person uuid; v_robot uuid;
  v_prod uuid; v_sandbox uuid;
  v_cs uuid; v_p uuid; v_p2 uuid; v_applied uuid;
  v_ok boolean; v_msg text; v_sandbox_row erp.environment%rowtype;
begin
  insert into auth.users (id, email) values (a1, 'validation@zzval.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v := erp.onboard_tenant('Validation', 'zzval');
  v_t := (v ->> 'tenant_id')::uuid;
  v_person := (v ->> 'principal_id')::uuid;
  v_prod := (v ->> 'environment_id')::uuid;

  select * into v_sandbox_row from erp.environment
   where tenant_id = v_t and not is_self;
  v_sandbox := v_sandbox_row.id;

  -- ── The row ─────────────────────────────────────────────────────────────

  return query select 'onboarding creates somewhere that is not production',
    v_sandbox is not null and v_sandbox_row.kind <> 'production'
      and not v_sandbox_row.is_self,
    format('%s, kind %s, is_self %s', coalesce(v_sandbox_row.code, '(none)'),
           coalesce(v_sandbox_row.kind::text, '-'), coalesce(v_sandbox_row.is_self, false));

  return query select 'and it is not live, because nothing operational happens there',
    not coalesce(v_sandbox_row.is_live, true),
    'a live validation environment would take B6''s configuration guards with '
    'it, which is the opposite of somewhere to try a change';

  -- The falsification, run rather than argued: take the row away and the
  -- assertion has to notice. Done before anything points at it, because the
  -- foreign key from a proposal is on delete restrict.
  delete from erp.environment where id = v_sandbox;
  begin
    perform erp.assert_validation_environment_available();
    v_ok := false; v_msg := 'the assertion passed with an organisation that has nowhere to validate';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_VALIDATION_ENVIRONMENT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'removing it fails the assertion', v_ok, v_msg;

  insert into erp.environment (tenant_id, id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_t, v_sandbox, 'sandbox', 'Sandbox', 'sandbox', false, false,
          'Restored by the suite.', 'active');

  -- ── A proposal, end to end ──────────────────────────────────────────────

  insert into erp.app_user (tenant_id, kind, status, display_name, email)
  values (v_t, 'service', 'active', 'Configuration intelligence',
          'robot@zzval.test')
  returning id into v_robot;

  v_cs := erp.create_change_set('ZZVAL-1', 'A department the machine suggested');
  perform erp.add_change_set_item(v_cs, 'department', 'PLANNING',
    jsonb_build_object('code', 'PLANNING', 'name', 'Planning'));

  insert into erp_ai.proposal
    (tenant_id, kind, title, rationale, change_set_id, status,
     produced_by, producer_label)
  values (v_t, 'authoring', 'Add a planning department',
          'Every other department in this organisation appears on approval '
          'bands and this one does not, which is usually an omission.',
          v_cs, 'proposed', v_robot, 'suite')
  returning id into v_p;

  -- Promise 2 is still enforced: production is refused as the place it was
  -- proved. This is the case that could not fail before, because production
  -- was the only environment there was.
  begin
    update erp_ai.proposal
       set status = 'validated', validated_in_environment_id = v_prod,
           validated_at = now()
     where id = v_p;
    v_ok := false; v_msg := 'a proposal was validated in production';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_VALIDATED_IN_PRODUCTION%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'validating in production is still refused', v_ok, v_msg;

  update erp_ai.proposal
     set status = 'validated', validated_in_environment_id = v_sandbox,
         validated_at = now()
   where id = v_p;

  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);

  v_applied := erp_ai.apply_proposal(v_p, 'Reviewed by the suite.');

  return query select 'a proposal validated in the sandbox applies',
    v_applied = v_cs,
    'before this migration no organisation could reach this line: '
    'apply_proposal() refuses the is_self environment, the trigger refuses '
    'production, and those were the same row';

  return query select 'and the change it carried is really in the surface',
    exists (select 1 from erp.department d
             where d.tenant_id = v_t and d.code = 'PLANNING'),
    'promotion went through erp.promote_change_set() unchanged, which is the '
    'point: there is no second path';

  return query select 'the proposal is recorded as applied, by a named person',
    (select p.status = 'applied' and p.reviewed_by = v_person
       from erp_ai.proposal p where p.id = v_p),
    (select format('%s, reviewed by %s', p.status,
                   coalesce(p.reviewed_by::text, 'nobody'))
       from erp_ai.proposal p where p.id = v_p);

  -- ── The promises that were never the problem ────────────────────────────

  v_cs := erp.create_change_set('ZZVAL-2', 'A second department');
  perform erp.add_change_set_item(v_cs, 'department', 'QUALITY',
    jsonb_build_object('code', 'QUALITY', 'name', 'Quality'));

  insert into erp_ai.proposal
    (tenant_id, kind, title, rationale, change_set_id, status,
     validated_in_environment_id, validated_at, produced_by, producer_label)
  values (v_t, 'authoring', 'Add a quality department',
          'Written by the same person who would be applying it, which is the '
          'case §3.12 promise 1 exists to refuse.',
          v_cs, 'validated', v_sandbox, now(), v_person, 'suite')
  returning id into v_p2;

  begin
    perform erp_ai.apply_proposal(v_p2);
    v_ok := false; v_msg := 'the producer applied their own proposal';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PROPOSAL_SELF_APPROVED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'the producer of a proposal still cannot apply it', v_ok, v_msg;

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  delete from auth.users where id = a1;

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp.environment e where e.tenant_id = v_t),
    'environments cascade with the tenant, as every tenant-scoped table does';
end $$;

comment on function erp_test.validation_environment_suite is
  'Spec 3.12 end to end: a proposal validated in the sandbox is applied, the '
  'change it carried lands through erp.promote_change_set(), and both refusals '
  'that guard the path still fire.';

create or replace function erp_test.assert_validation_environment_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Two on the row, one falsification, one refusal on the way in, three on the
  -- applied proposal, one refusal on self-approval, and the cleanup.
  c_expected constant integer := 9;
begin
  create temporary table if not exists zz_validation_env_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_validation_env_result;
  insert into zz_validation_env_result
    select * from erp_test.validation_environment_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_pass, v_total, v_detail
    from zz_validation_env_result;

  if v_total <> c_expected then
    raise exception
      'ERPWARE_SUITE_SHRANK: %/% cases ran, % expected — a case that stops '
      'running stops proving anything', v_pass, v_total, c_expected
      using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_VALIDATION_ENV_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('validation environment: %s/%s', v_pass, v_total);
end $$;

-- ── And the trap this piece of work walked into ──────────────────────────────
--
-- Recorded rather than worked around quietly, because the workaround is a
-- comment in two function bodies and comments do not survive being rewritten.

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence, decided_by)
values
  ('intelligence_boundary_reads_source_text',
   'The intelligence boundary is derived from function source text, so a '
   'mention reads as a call',
   'Spec 3.12, promise 3',
   'Left as it stands, and recorded. The check is deliberately conservative: '
   'it over-reports rather than under-reports, and a false edge fails the '
   'build loudly where a missed edge would pass it silently.',
   'erp.intelligence_boundary_report() builds its call graph with '
   'position(callee || ''('' in caller.prosrc). Writing the name of an erp_ai '
   'function inside a comment or a string literal in a transaction-path '
   'function is therefore indistinguishable from calling it — which is how '
   'this migration first failed the build, on a sentence in a description. '
   'Stripping comments and literals before matching would remove the false '
   'edge and would not add the missing one: a call assembled by EXECUTE '
   'format() is invisible to a text scan either way, so the check would look '
   'more precise while covering no more. The direction of the error is the '
   'thing worth keeping.',
   'open',
   'The build failed with "erp.seed_demo_operations reaches '
   'erp_ai.apply_proposal at depth 12" over a mention in erp.onboard_tenant''s '
   'sandbox description, and passed once the parentheses were removed.',
   null)
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, status = excluded.status,
  evidence = excluded.evidence;

select erp.assert_validation_environment_available();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();
