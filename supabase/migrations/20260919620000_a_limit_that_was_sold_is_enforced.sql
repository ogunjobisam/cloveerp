set lock_timeout = '30s';

-- =============================================================================
-- 20260919620000  A limit that was sold is enforced
-- -----------------------------------------------------------------------------
-- 20260904190000 wrote erp.require_entitlement(). It reads the plan, compares
-- what an addition would make against what the plan allows, and refuses by
-- name. It has never had a caller outside a test.
--
-- Every call to it on this branch before today is in a suite:
-- 20260904200000 calls it twice to prove it refuses, and 20260919010000 calls
-- it once to prove it no longer refuses a document. The register said so about
-- itself: the note on the users entitlement has read "no invitation or grant
-- calls it" since 20260914095000, and 20260918910000 repeated it.
--
-- So the three figures the price list sells — full users, companies, sites —
-- were measured, reported and invoiced, and never refused. A Starter customer
-- could add an eleventh full user, a second company and a second site, and the
-- only thing that happened was that erp.report_entitlement_breaches() swept
-- them a few hours later and told an administrator they had gone past what
-- they had bought. The customer was told off rather than stopped, which is the
-- opposite way round: a limit you can cross is a bill you did not agree to.
--
-- The v1 Definition of Done says it plainly. ENT-03: a Starter organisation
-- adding an eleventh full user is blocked or asked to move up. ENT-04: a
-- Starter organisation adding a second company, then a second site, is
-- blocked, and Standard permits three companies and ten sites and then blocks.
-- Both were unmet. This meets them.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Where each of the three calls goes, and why there
--
--   sites       erp.create_site(), before the row is written. A site is
--               created in one place and it is always a creation, so the check
--               is one line and there is nothing to work out.
--
--   companies   erp.create_entity(), before it hands over to
--               erp.upsert_entity(). The door above it refuses a code already
--               in use, so reaching that line always means one more company.
--               erp.upsert_entity() itself is deliberately NOT the place: it
--               is also the update path, and it is what provisioning and the
--               promoter call, where adding one to a count would be a lie in
--               the first case and a refusal in the second.
--
--   users       erp.grant_role() and public.erp_set_user_roles(), after the
--               grant is written.
--
-- The users one is the one that needed thinking about, because a seat is not a
-- field anybody sets. erp.person_seats() derives it from the permissions a
-- person's roles reach — light where every one of them is light, full
-- otherwise — and only the full ones count against the plan (20260914095000,
-- 20260918910000). So there is no moment called "a full user is created". A
-- person becomes one when they are given roles that reach a full permission,
-- and stops being one when those roles end.
--
-- That rules out the invitation. erp.invite_principal() writes a person with
-- no roles at all: at that moment they are nobody's seat, and refusing there
-- would refuse the wrong thing. It also rules out erp.claim_invitation(),
-- which is where the count as the meter reads it actually moves, because
-- erp.person_seats() only counts somebody whose status is active. Refusing a
-- claim would put the refusal on the person signing in for the first time,
-- for a decision their administrator took days earlier — and it would leave
-- the administrator able to commit the organisation to eleven seats in perfect
-- silence, which is the defect this migration exists to remove.
--
-- So the grant is the honest point, and the count the grant is measured
-- against has to include the people who have been given full roles and have
-- not signed in yet. erp.full_users_committed() is that count: people of the
-- organisation, invited or active, whose grants in force today reach a full
-- permission. For everybody who has signed in it is the same set
-- erp.person_seats() calls full, which the suite asserts rather than assumes;
-- the difference is only the ones still holding an unclaimed invitation.
--
-- It is not a second meter. erp.entitlement_usage('users') is untouched, and
-- it is still what the agreement page, the console and the invoice read. What
-- the grant doors pass to erp.require_entitlement() is the difference between
-- the two — the seats already committed that the meter cannot see yet — as
-- p_adding, which is exactly what that parameter means: what this would make.
-- When everybody has signed in the difference is nought and the two agree.
--
-- Signing in therefore charges nothing, because the seat was charged when the
-- roles were given. The suite proves that too: a claim moves a person from one
-- column of the same total to the other.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The count is compared before and after, not assumed to have risen
--
-- Each grant door reads the committed count before it writes and again after,
-- and asks for entitlement only when the second is larger. That matters for
-- the remedy: public.erp_set_user_roles() is the door that takes roles away as
-- well as the one that gives them, and an organisation already over a limit —
-- because the plan was lowered beneath it, or because the seats were committed
-- before there was a subscription — must be able to use it to get back under.
-- A check that simply asked "are we over?" after every write would refuse the
-- fix as readily as the cause.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this deliberately does not touch
--
--   An organisation with no subscription. erp.require_entitlement() returns
--   silently when the limit is null, and erp.entitlement_limit() is null both
--   for a plan that states "unlimited" and for an organisation that has no
--   subscription at all. That is the behaviour the whole of Part 18 was landed
--   on, and everything in this repository that stands an organisation up
--   depends on it: erp.provision_tenant() and every suite fixture, the
--   demonstration, the platform's own organisation. The suite proves it rather
--   than trusting the comment — a second organisation with no subscription
--   does every one of the three things and is refused none of them.
--
--   Provisioning. erp.provision_tenant() writes erp.entity, erp.site's absence,
--   erp.app_user and erp.user_role with plain INSERTs and calls none of the
--   three doors, so a new organisation is built exactly as before. So does
--   erp.ensure_demo_configuration(), including the NORTH-DC site
--   20260918100000 added: a direct insert, not erp.create_site(). Checked, not
--   assumed — every caller of the three doors outside a suite is a public
--   wrapper of the door itself.
--
--   erp.restore_principal(). It gives access back with no roles, deliberately,
--   so it cannot raise the count; the roles come back through the grant doors,
--   where they are counted.
--
--   A role edit that reclassifies what a role reaches, which can turn several
--   people full at once. That is a change to what a role means rather than to
--   who is in the organisation, it has no natural "adding one" to refuse, and
--   erp.report_entitlement_breaches() still sweeps it. Named here so the next
--   person does not have to work out whether it was missed.
--
--   The other four entitlement kinds. environments and retention_months are
--   unchanged; documents_per_month and movements_per_month were removed
--   outright by 20260919010000 because nobody was sold them.
--
-- Everything below is anchored on the live body read through
-- pg_get_functiondef(), never on the file: 20260904980000 rewrote every
-- refusal prefix in every body, which is why erp.create_site() on a built
-- database does not say what 20260903022024 wrote. Each needle is required to
-- occur exactly once, each result is read back, and the marker that proves an
-- earlier patch survived is asserted alongside it.
--
-- The last full definition of each, read rather than assumed:
--
--   erp.create_site()             20260903022024, then the prefix sweep
--   erp.create_entity()           20260906080000
--   erp.grant_role()              20260914065000
--   public.erp_set_user_roles()   20260914074000
--
-- The last of those is why this file was renumbered once already. The first
-- attempt anchored the roles door on 20260914065000, which is where its duties
-- were settled but not where it was last written: 20260914074000 re-emitted it
-- with erp.require_user_managers_remain(), and in doing so moved one space in
-- its declarations. The guard caught it and the build refused, which is what
-- the guard is for. The marker asserted below is now that user-manager check,
-- so the same mistake cannot pass next time.
--
-- It was renumbered a second time for section 5. A migration is written once,
-- and neither refused file ever reached a database, so each is replaced rather
-- than corrected.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The count a grant is measured against
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.full_users_committed(p_tenant_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  -- The same set erp.person_seats() calls full, widened by one thing: somebody
  -- still holding an unclaimed invitation. They have been given the roles, the
  -- organisation has decided to have them, and the only thing outstanding is
  -- their first sign-in — so they are a seat that has been committed even
  -- though the meter, which counts active people, cannot see them yet.
  --
  -- Read the same way erp.has_permission() reads a grant: in force today, on an
  -- active role. A grant opened for a platform support visit is not a seat the
  -- organisation bought, and is left out exactly as erp.person_seats() leaves
  -- it out. Neither is a service principal, which is why this counts people.
  -- Somebody whose access has been removed or suspended cannot use the product
  -- and is not counted either.
  select count(*)::integer
    from erp.app_user u
   where u.tenant_id = p_tenant_id
     and u.kind = 'person'
     and u.status in ('active', 'invited')
     and exists (
       select 1
         from erp.user_role ur
         join erp.role r
           on r.tenant_id = ur.tenant_id and r.id = ur.role_id and r.status = 'active'
         join erp.role_permission rp
           on rp.tenant_id = ur.tenant_id and rp.role_id = r.id
         join erp_ref.permission p
           on p.code = rp.permission_code
        where ur.tenant_id = u.tenant_id
          and ur.app_user_id = u.id
          and ur.valid_from <= current_date
          and (ur.valid_to is null or ur.valid_to >= current_date)
          and coalesce(ur.grant_reason, '') not like 'Platform % support access:%'
          and coalesce(p.seat, 'full') = 'full')
$$;

comment on function erp.full_users_committed(uuid) is
  'How many full seats an organisation has committed itself to: its people, '
  'invited or signed in, whose grants in force today reach a permission that '
  'needs a full seat. The same set erp.person_seats() calls full once everybody '
  'has signed in, and the number the grant doors measure against the plan, so '
  'that the refusal reaches the administrator who gave the roles rather than '
  'the person who later accepts the invitation (20260919620000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'full_users_committed',
        'Counts seats for one organisation, named as an argument, and returns a '
        'number and nothing else. Definer for the reason erp.entitlement_usage() '
        'is: it is read from a door running as the signed-in administrator, and '
        'the permission catalogue it has to join to is reference data a session '
        'role does not reach. It refuses rather than grants, so the elevation '
        'can only ever narrow what the caller may do.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Sites: refused where a site is created
-- ═════════════════════════════════════════════════════════════════════════════

do $sites$
declare
  v_sig    constant text := 'erp.create_site(text,text,text,uuid,character,text)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := $n$  insert into erp.site (tenant_id, entity_id, code, name, site_type,$n$;
  v_new    constant text := $n$  -- The plan's sites, refused where a site is created (20260919620000).
  -- Silent where the organisation has no subscription, which is what lets
  -- provisioning, the demonstration and every fixture go on as they were.
  perform erp.require_entitlement('sites', 1);

  insert into erp.site (tenant_id, entity_id, code, name, site_type,$n$;
begin
  -- 20260904980000 swept the retired refusal prefix through every body. If that
  -- has not survived, this is not the body this migration read.
  if position('CLOVEERP_SITE_CODE_REQUIRED' in v_def) = 0
     or position('CLOVEERP_ENTITY_REQUIRED' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry the refusals the sweep left behind', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  if (select count(*) from regexp_matches(v_def, 'insert into erp\.site \(tenant_id, entity_id, code, name, site_type,', 'g')) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not write its site exactly once', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if (select count(*) from regexp_matches(v_def, 'erp\.require_entitlement\(''sites'', 1\)', 'g')) <> 1
     or position('CLOVEERP_SITE_CODE_REQUIRED' in v_def) = 0 then
    raise exception 'CLOVEERP_PATCH_DID_NOT_LAND: % does not ask for the sites entitlement once, or lost what it had', v_sig;
  end if;
end
$sites$;

comment on function erp.create_site(text, text, text, uuid, character, text) is
  'Creates a site of one company with the places a receipt needs, under '
  'administration.configure. Refuses a site beyond what the plan allows '
  '(20260919620000), and refuses nothing on that account where the organisation '
  'has no subscription.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Companies: refused where a company is created
-- ═════════════════════════════════════════════════════════════════════════════

do $companies$
declare
  v_sig    constant text := 'erp.create_entity(text,text,text,character,character,text,text,smallint,text)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := $n$  return erp.upsert_entity(p_code, p_name, p_legal_name, p_base_currency, p_country_code,$n$;
  v_new    constant text := $n$  -- The plan's companies, refused where a company is created (20260919620000).
  -- The refusal above means reaching this line is always one more company;
  -- erp.upsert_entity() is left alone because it is also the update path and
  -- the one provisioning and the promoter call.
  perform erp.require_entitlement('companies', 1);
  return erp.upsert_entity(p_code, p_name, p_legal_name, p_base_currency, p_country_code,$n$;
begin
  if position('CLOVEERP_ENTITY_EXISTS' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not refuse a company code already in use', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  if (select count(*) from regexp_matches(v_def, 'return erp\.upsert_entity\(p_code, p_name, p_legal_name, p_base_currency, p_country_code,', 'g')) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not hand over to the writer exactly once', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if (select count(*) from regexp_matches(v_def, 'erp\.require_entitlement\(''companies'', 1\)', 'g')) <> 1
     or position('CLOVEERP_ENTITY_EXISTS' in v_def) = 0 then
    raise exception 'CLOVEERP_PATCH_DID_NOT_LAND: % does not ask for the companies entitlement once, or lost what it had', v_sig;
  end if;
end
$companies$;

comment on function erp.create_entity(text, text, text, character, character, text, text, smallint, text) is
  'Creates a company of the organisation: code, name, currency, country, '
  'locales, fiscal year start, optional parent. Refuses a code in use, and a '
  'company beyond what the plan allows (20260919620000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Users: refused where somebody becomes a full user
-- ═════════════════════════════════════════════════════════════════════════════

do $grant$
declare
  v_sig    constant text := 'erp.grant_role(uuid,text,uuid,uuid,text,date,date,text)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_n1     constant text := $n$  v_before uuid[];$n$;
  v_r1     constant text := $n$  v_before uuid[];
  v_seats  integer;
  v_after  integer;$n$;
  v_n2     constant text := $n$  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d);$n$;
  v_r2     constant text := $n$  v_seats := erp.full_users_committed(v_tenant);
  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d);$n$;
  v_n3     constant text := $n$  return v_id;$n$;
  v_r3     constant text := $n$  -- A grant that makes somebody a full user is where one of the plan's
  -- included users is spent (20260919620000). Counted after the write, so what
  -- is measured is what the organisation would actually have; the refusal
  -- takes its own grant down with it. What is passed is the difference between
  -- the seats committed and the seats the meter can see, because somebody
  -- given full roles who has not signed in yet is a seat either way.
  v_after := erp.full_users_committed(v_tenant);
  if v_after > v_seats then
    perform erp.require_entitlement('users',
              v_after - coalesce(erp.entitlement_usage('users'), 0));
  end if;

  return v_id;$n$;
begin
  if position('CLOVEERP_UNKNOWN_ROLE' in v_def) = 0
     or position('erp.settle_duties(' in v_def) = 0
     or position('erp.require_not_own_roles(' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the body 20260914065000 wrote', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  if (select count(*) from regexp_matches(v_def, '  v_before uuid\[\];', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, '  v_before := array\(select d\.sod_rule_id', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, '\n  return v_id;', 'g')) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not declare, settle and return the way this migration reads it', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  v_def := replace(v_def, v_n1, v_r1);
  v_def := replace(v_def, v_n2, v_r2);
  v_def := replace(v_def, v_n3, v_r3);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if (select count(*) from regexp_matches(v_def, 'erp\.require_entitlement\(''users''', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'erp\.full_users_committed\(v_tenant\)', 'g')) <> 2
     or position('erp.settle_duties(' in v_def) = 0 then
    raise exception 'CLOVEERP_PATCH_DID_NOT_LAND: % does not count the seats twice and ask once, or lost its duties', v_sig;
  end if;
end
$grant$;

comment on function erp.grant_role(uuid, text, uuid, uuid, text, date, date, text) is
  'Grants a role under administration.roles. Refuses the caller''s own roles '
  'once live, settles the person''s segregation of duties, and refuses a grant '
  'that would take the organisation past the full users its plan includes '
  '(20260919620000).';

do $roles$
declare
  v_sig    constant text := 'public.erp_set_user_roles(uuid,text[],text,text)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_n1     constant text := $n$  v_grant    uuid;$n$;
  v_r1     constant text := $n$  v_grant    uuid;
  v_seats    integer;
  v_after    integer;$n$;
  v_n2     constant text := $n$  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d);$n$;
  v_r2     constant text := $n$  v_seats := erp.full_users_committed(v_tenant);
  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d);$n$;
  v_n3     constant text := $n$  return jsonb_build_object(
    'granted', v_added,$n$;
  v_r3     constant text := $n$  -- Setting the whole set can give seats and take them away in one call
  -- (20260919620000). Only a rise is refused: an organisation that is already
  -- over a limit has to be able to use this very door to get back under it.
  v_after := erp.full_users_committed(v_tenant);
  if v_after > v_seats then
    perform erp.require_entitlement('users',
              v_after - coalesce(erp.entitlement_usage('users'), 0));
  end if;

  return jsonb_build_object(
    'granted', v_added,$n$;
begin
  if position('CLOVEERP_UNKNOWN_ROLE' in v_def) = 0
     or position('erp.end_grant(v_tenant, v_grant)' in v_def) = 0
     or position('erp.settle_duties(' in v_def) = 0
     -- 20260914074000's own addition, which is what makes this the last body
     -- rather than 20260914065000's.
     or position('erp.require_user_managers_remain(' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the body 20260914074000 wrote', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  if (select count(*) from regexp_matches(v_def, '  v_grant    uuid;', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, '  v_before := array\(select d\.sod_rule_id', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'return jsonb_build_object\(\n    ''granted'', v_added,', 'g')) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not declare, settle and answer the way this migration reads it', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  v_def := replace(v_def, v_n1, v_r1);
  v_def := replace(v_def, v_n2, v_r2);
  v_def := replace(v_def, v_n3, v_r3);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if (select count(*) from regexp_matches(v_def, 'erp\.require_entitlement\(''users''', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'erp\.full_users_committed\(v_tenant\)', 'g')) <> 2
     or position('erp.end_grant(v_tenant, v_grant)' in v_def) = 0
     or position('erp.require_user_managers_remain(' in v_def) = 0 then
    raise exception 'CLOVEERP_PATCH_DID_NOT_LAND: % does not count the seats twice and ask once, or lost its withdrawals', v_sig;
  end if;
end
$roles$;

comment on function public.erp_set_user_roles(uuid, text[], text, text) is
  'Replaces the organisation-wide roles a person holds with exactly the set '
  'given: unticked grants end (kept on file where they began before today), '
  'ticked ones are granted. Refuses your own roles once live, and a change that '
  'would leave nobody able to manage users (20260914074000). In a live '
  'organisation a prohibited segregation-of-duties pairing the change '
  'introduces is refused unless p_sod_override_reason records an exception, '
  'which needs administration.promote. A change that would take the '
  'organisation past the full users its plan includes is refused; one that '
  'reduces them never is (20260919620000). Returns granted, revoked and the '
  'person''s conflicts.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The refusal is one a customer now meets, so it says what to do
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two halves, and until today neither of them mattered, because nothing could
-- reach the refusal.
--
-- The hint on the raise was written for whoever was reading the database's own
-- error text. Its second sentence explains a decision we took — that the
-- refusal is named rather than silent — which is not something anybody can act
-- on. From today it is read by a customer on the day they outgrow their plan,
-- so it says what the register says.
--
-- And the register. A hint is what the database says; a registered refusal is
-- what the desk resolves into words on a screen, in an organisation's own
-- wording where it has set one. erp.assert_refusals_name_next_action() is
-- satisfied by either, which is how a refusal nobody could reach went this
-- long with only the first.
--
-- Re-emitting the raise is also what lets the registration be checked. The
-- file that raises this refusal was written before 20260904980000 and still
-- carries the retired prefix; only the sweep makes it say Clove on a built
-- database, and a check that reads the files rather than the database cannot
-- see that. Rule B of supabase/ci/preflight.sh refuses a registration whose
-- code it cannot find being raised, and it is right to: a registered refusal
-- raised nowhere is what erp.assert_refusals_name_next_action() fails on. The
-- literal below is the one the database holds.
--
-- Left alone, and named rather than quietly fixed: the message reads "% allows
-- % %" with the plan's code in the first place, and erp.entitlement_limit()
-- prefers a band the contract sold over the plan's own figure. An organisation
-- whose agreement sold it twenty full users on a plan that includes fifteen is
-- therefore told that the plan allows twenty, which names the wrong document
-- for a right number. The figure the customer is refused on is correct either
-- way; the sentence around it is work on wording rather than on enforcement,
-- and a migration doing both would be two migrations sharing a file.

do $hint$
declare
  v_sig    constant text := 'erp.require_entitlement(text,numeric)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := $n$    raise exception
      'CLOVEERP_ENTITLEMENT_EXCEEDED: % allows % %, and this would make %',
      v_plan, v_limit, v_kind.unit, v_used + p_adding
      using errcode = '23514',
            detail = format('%s: %s', v_kind.title, v_kind.counts_what),
            hint = 'Raise the plan, or release what is no longer needed. The '
                   'refusal is named rather than silent so the next invoice '
                   'holds no surprise.';$n$;
  v_new    constant text := $n$    raise exception
      'CLOVEERP_ENTITLEMENT_EXCEEDED: % allows % %, and this would make %',
      v_plan, v_limit, v_kind.unit, v_used + p_adding
      using errcode = '23514',
            detail = format('%s: %s', v_kind.title, v_kind.counts_what),
            hint = 'Move up to a plan that covers what is needed, or free one '
                   'up by removing what is no longer used. What the plan '
                   'covers and how much of it is in use are both on the '
                   'Commercial screen.';$n$;
begin
  if position('erp.entitlement_usage(p_code)' in v_def) = 0
     or position('erp.report_entitlement_breaches()' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the body 20260904190000 wrote', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  if (select count(*) from regexp_matches(v_def, 'holds no surprise\.', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'CLOVEERP_ENTITLEMENT_EXCEEDED', 'g')) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry the refusal and its hint exactly once each', v_sig
      using hint = 'Read the live body before writing a needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('holds no surprise' in v_def) <> 0
     or position('Commercial screen' in v_def) = 0
     or (select count(*) from regexp_matches(v_def, 'CLOVEERP_ENTITLEMENT_EXCEEDED', 'g')) <> 1 then
    raise exception 'CLOVEERP_PATCH_DID_NOT_LAND: % still says what it said, or lost its refusal', v_sig;
  end if;
end
$hint$;

comment on function erp.require_entitlement is
  'Specification v1.2 §18.1. Refuses when an addition would take an '
  'organisation past what its plan or its agreement covers, names the figure '
  'and what the addition would make, and says what to do about it. Returns '
  'silently where no subscription is recorded, so an organisation provisioned '
  'before Part 18 is unaffected until it is given a plan. Called from '
  'erp.create_site(), erp.create_entity(), erp.grant_role() and '
  'public.erp_set_user_roles() since 20260919620000; until then, from nowhere.';

select erp.register_refusal('CLOVEERP_ENTITLEMENT_EXCEEDED',
  'Adding more than the plan covers.',
  'A plan states how many people, companies and sites it covers, and those figures are what the price was worked out from. Going past one quietly would mean either an invoice nobody agreed to or a bill that never catches up with what is being used, and both of those are found out late.',
  'Move up to a plan that covers what is needed, or free one up by removing what is no longer used. What the plan covers and how much of it is in use are both on the Commercial screen.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register said nothing calls it. Something does now.
-- ═════════════════════════════════════════════════════════════════════════════

update erp_meta.entitlement_kind
   set note = 'What a plan includes, and what an extra full user adds to. Until 20260914095000 this counted every active person; light users are counted apart now. Since 20260918910000 it also counts whoever approves a purchase order, a payment or a discount, because those commit the company. Since 20260919620000 it is refused where somebody is given the roles that make them a full user, counting whoever has been given them and not yet signed in, so the refusal reaches the administrator who decided rather than the person who accepts the invitation.'
 where code = 'users';

update erp_meta.entitlement_kind
   set note = 'A company is the unit a chart of accounts and a ledger hang from, so it is the unit a plan is priced in. Refused in erp.create_entity() since 20260919620000, and not in erp.upsert_entity(), which is also the update path and the one provisioning and the promoter call.'
 where code = 'companies';

update erp_meta.entitlement_kind
   set note = 'Sites drive warehouse and device usage, which is where volume comes from. Refused in erp.create_site() since 20260919620000, before the row is written.'
 where code = 'sites';

do $register$
declare v_left text;
begin
  select string_agg(k.code, ', ' order by k.code) into v_left
    from erp_meta.entitlement_kind k
   where k.code in ('users', 'companies', 'sites')
     and k.note not like '%20260919620000%';
  if v_left is not null then
    raise exception 'CLOVEERP_REGISTER_SHORT: % still says nothing calls the refusal', v_left
      using hint = 'Row security refused the update, or the register no longer holds these three kinds.';
  end if;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.entitlement_enforced_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 7;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 8);
  ra        record; rb record;
  v_a       uuid; v_b uuid;
  s_a       uuid := gen_random_uuid();
  s_b       uuid := gen_random_uuid();
  s_first   uuid := gen_random_uuid();
  s_light   uuid := gen_random_uuid();
  v_role    uuid;
  v_person  uuid; v_token text;
  v_first   uuid; v_first_token text;
  v_light   uuid; v_light_token text;
  i         integer;
  v_site1   uuid; v_site2 uuid;
  v_company text; v_site_first text; v_site_second text;
  v_at      text; v_past text;
  v_light_given text; v_light_seat text;
  v_before_claim integer; v_after_claim integer;
  v_use_before numeric; v_use_after numeric; v_claim text;
  v_person_seats integer; v_committed integer;
  v_b_company text; v_b_sites text; v_b_users text;
  v_b_full  integer;
begin
  begin
  -- ── An organisation on Starter, with a subscription that says so ─────────
  v_step := 'provisioning the organisation on a plan';
  perform set_config('request.jwt.claims', '', true);
  select * into ra from erp.provision_tenant('zzent-a-' || v_tag, 'Entitlement Starter',
                                             'admin@zzent-a-' || v_tag || '.test', 'Starter Admin');
  v_a := ra.tenant_id;
  update erp.environment set is_live = false where tenant_id = v_a and is_self;
  select * into rb from erp.provision_tenant('zzent-b-' || v_tag, 'Entitlement Unsubscribed',
                                             'admin@zzent-b-' || v_tag || '.test', 'Unsubscribed Admin');
  v_b := rb.tenant_id;
  update erp.environment set is_live = false where tenant_id = v_b and is_self;

  -- Written straight in, the way erp.provision_entitlement_from_contract()
  -- writes it from a signed contract, and in the same place 20260904200000
  -- writes its own: inside the organisation's context, before anybody signs
  -- in. No contract and no platform organisation here on purpose — this suite
  -- is about the limit, and a fixture that has to be the only platform
  -- organisation is a fixture a live database refuses.
  perform set_config('erp.job_tenant_id', v_a::text, true);
  insert into erp_meta.subscription
    (tenant_id, tenant_code, plan_code, term_start, currency)
  values (v_a, 'zzent-a-' || v_tag, 'starter', current_date, 'GBP');
  perform set_config('erp.job_tenant_id', '', true);

  insert into auth.users (id, email) values
    (s_a, 'admin@zzent-a-' || v_tag || '.test'),
    (s_b, 'admin@zzent-b-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', s_a)::text, true);
  perform erp.claim_invitation(ra.admin_token);

  -- ── 1. A second company ─────────────────────────────────────────────────
  v_step := 'a second company on a plan that allows one';
  v_cases := v_cases + 1;
  begin
    perform erp.create_entity('ZZENT2', 'Second company', null, 'GBP', 'GB');
    v_company := 'it was created';
  exception when others then
    v_company := left(sqlerrm, 120);
  end;
  case_name := 'a second company on a plan that allows one is refused where the company is created, and the refusal names the plan';
  passed := v_company like 'CLOVEERP_ENTITLEMENT_EXCEEDED%'
        and v_company like '%starter%'
        and erp.entitlement_usage('companies', v_a) = 1;
  detail := format('%s; the organisation still has %s company',
                   v_company, erp.entitlement_usage('companies', v_a));
  return next;

  -- ── 2. The site the plan allows, and the one after it ───────────────────
  v_step := 'the first site and the second';
  v_cases := v_cases + 1;
  begin
    v_site1 := erp.create_site('ZZENT-WH', 'Starter warehouse', 'warehouse');
    v_site_first := 'created';
  exception when others then
    v_site_first := left(sqlerrm, 120);
  end;
  begin
    v_site2 := erp.create_site('ZZENT-WH2', 'Second warehouse', 'warehouse');
    v_site_second := 'it was created';
  exception when others then
    v_site_second := left(sqlerrm, 120);
  end;
  case_name := 'the site the plan allows is created and the one after it is refused, at the door that creates a site';
  passed := v_site_first = 'created'
        and v_site1 is not null
        and v_site_second like 'CLOVEERP_ENTITLEMENT_EXCEEDED%'
        and v_site2 is null
        and erp.entitlement_usage('sites', v_a) = 1;
  detail := format('first: %s; second: %s; %s site(s) standing',
                   v_site_first, v_site_second, erp.entitlement_usage('sites', v_a));
  return next;

  -- ── 3. Ten full users, and the eleventh ─────────────────────────────────
  --
  -- The administrator provisioning made is the first. Nine more take the
  -- organisation to the ten Starter includes, and the next is refused. Each is
  -- invited outside the guarded block and granted inside it, so that catching
  -- the refusal rolls back the grant and nothing else.
  v_step := 'nine more full users, then one past the plan';
  v_cases := v_cases + 1;
  for i in 1..9 loop
    select p.app_user_id, p.token into v_person, v_token
      from erp.invite_principal('full' || i || '@zzent-a-' || v_tag || '.test',
                                'Full User ' || i) p;
    if i = 1 then v_first := v_person; v_first_token := v_token; end if;
    perform erp.grant_role(v_person, 'administrator', null, null, 'a full seat');
  end loop;
  v_at := format('%s committed, %s allowed', erp.full_users_committed(v_a),
                 erp.entitlement_limit('users', v_a));

  select p.app_user_id, p.token into v_person, v_token
    from erp.invite_principal('full10@zzent-a-' || v_tag || '.test', 'Full User 10') p;
  begin
    perform erp.grant_role(v_person, 'administrator', null, null, 'the seat past the plan');
    v_past := 'it was granted';
  exception when others then
    v_past := left(sqlerrm, 120);
  end;
  case_name := 'full users up to the plan are given their roles, and the one past it is refused by name';
  passed := erp.full_users_committed(v_a) = 10
        and v_past like 'CLOVEERP_ENTITLEMENT_EXCEEDED%'
        and v_past like '%would make 11%';
  detail := format('at the limit: %s; one past it: %s; %s committed after the refusal',
                   v_at, v_past, erp.full_users_committed(v_a));
  return next;

  -- ── 4. A light user past the full limit ─────────────────────────────────
  v_step := 'a light user past the full limit';
  v_cases := v_cases + 1;
  insert into erp.role (tenant_id, code, name, status)
  values (v_a, 'zz_light', 'Suite light seat', 'active')
  returning id into v_role;
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  values (v_a, v_role, 'reporting.read'), (v_a, v_role, 'master_data.read');

  select p.app_user_id, p.token into v_light, v_light_token
    from erp.invite_principal('light@zzent-a-' || v_tag || '.test', 'Light User') p;
  begin
    perform erp.grant_role(v_light, 'zz_light', null, null, 'reads and reports');
    v_light_given := 'granted';
  exception when others then
    v_light_given := left(sqlerrm, 120);
  end;
  insert into auth.users (id, email) values (s_light, 'light@zzent-a-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', s_light)::text, true);
  perform erp.claim_invitation(v_light_token);
  perform set_config('request.jwt.claims', json_build_object('sub', s_a)::text, true);
  v_light_seat := erp.person_seat(v_light);
  case_name := 'a light user past the full limit is allowed, because a plan includes full users and caps no light ones';
  passed := v_light_given = 'granted'
        and v_light_seat = 'light'
        and erp.full_users_committed(v_a) = 10
        and erp.entitlement_usage('light_users', v_a) = 1
        and erp.entitlement_limit('light_users', v_a) is null;
  detail := format('%s, seat %s; %s full committed, %s light used against %s',
                   v_light_given, coalesce(v_light_seat, 'none'),
                   erp.full_users_committed(v_a),
                   erp.entitlement_usage('light_users', v_a),
                   coalesce(erp.entitlement_limit('light_users', v_a)::text, 'no limit'));
  return next;

  -- ── 5. Signing in charges nothing ───────────────────────────────────────
  v_step := 'one of the nine signs in';
  v_cases := v_cases + 1;
  v_before_claim := erp.full_users_committed(v_a);
  v_use_before   := erp.entitlement_usage('users', v_a);
  insert into auth.users (id, email) values (s_first, 'full1@zzent-a-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', s_first)::text, true);
  begin
    perform erp.claim_invitation(v_first_token);
    v_claim := 'signed in';
  exception when others then
    v_claim := left(sqlerrm, 120);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', s_a)::text, true);
  v_after_claim := erp.full_users_committed(v_a);
  v_use_after   := erp.entitlement_usage('users', v_a);
  select count(*)::integer into v_person_seats
    from erp.person_seats(v_a) s where s.seat = 'full';
  v_committed := erp.full_users_committed(v_a);
  case_name := 'signing in charges nothing, because the seat was charged when the roles were given';
  passed := v_claim = 'signed in'
        and v_before_claim = 10 and v_after_claim = 10
        and v_use_before = 1 and v_use_after = 2
        and v_person_seats = 2 and v_committed = 10;
  detail := format('%s; committed %s then %s; the meter %s then %s; the people signed in and counted full %s',
                   v_claim, v_before_claim, v_after_claim, v_use_before, v_use_after, v_person_seats);
  return next;

  -- ── 6. An organisation with no subscription ─────────────────────────────
  v_step := 'the organisation with no subscription does all of it';
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', s_b)::text, true);
  perform erp.claim_invitation(rb.admin_token);
  begin
    perform erp.create_entity('ZZENTB2', 'Second company', null, 'GBP', 'GB');
    v_b_company := 'created';
  exception when others then
    v_b_company := left(sqlerrm, 120);
  end;
  begin
    perform erp.create_site('ZZENTB-WH', 'First warehouse', 'warehouse');
    perform erp.create_site('ZZENTB-WH2', 'Second warehouse', 'warehouse');
    v_b_sites := 'created';
  exception when others then
    v_b_sites := left(sqlerrm, 120);
  end;
  begin
    for i in 1..10 loop
      select p.app_user_id, p.token into v_person, v_token
        from erp.invite_principal('full' || i || '@zzent-b-' || v_tag || '.test',
                                  'Full User ' || i) p;
      perform erp.grant_role(v_person, 'administrator', null, null, 'a full seat');
    end loop;
    v_b_users := 'granted';
  exception when others then
    v_b_users := left(sqlerrm, 120);
  end;
  v_b_full := erp.full_users_committed(v_b);
  case_name := 'an organisation with no subscription is refused none of it, which is what every organisation stood up before a plan depends on';
  passed := erp.entitlement_limit('users', v_b) is null
        and erp.entitlement_limit('companies', v_b) is null
        and erp.entitlement_limit('sites', v_b) is null
        and v_b_company = 'created' and v_b_sites = 'created' and v_b_users = 'granted'
        and v_b_full = 11
        and erp.entitlement_usage('companies', v_b) = 2
        and erp.entitlement_usage('sites', v_b) = 2;
  detail := format('company: %s; sites: %s; users: %s; %s full seats, %s companies, %s sites and no limit on any of them',
                   v_b_company, v_b_sites, v_b_users, v_b_full,
                   erp.entitlement_usage('companies', v_b), erp.entitlement_usage('sites', v_b));
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  -- ── 7. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code like 'zzent-_-' || v_tag)
        and not exists (select 1 from erp_meta.subscription s where s.tenant_code like 'zzent-_-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (s_a, s_b, s_first, s_light));
  detail := coalesce(v_state,
                     'both organisations rolled back with their subscription, their people and their sites');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: entitlement_enforced_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.entitlement_enforced_suite() from public, anon;

comment on function erp_test.entitlement_enforced_suite() is
  'The three figures the price list sells, refused where the thing is made. On '
  'an organisation on Starter with a subscription: a second company is refused '
  'by name, the first site is created and the second refused, nine more full '
  'users reach the ten the plan includes and the eleventh is refused, a light '
  'user past that limit is allowed, and signing in moves nobody because the '
  'seat was charged at the grant. On an organisation with no subscription every '
  'one of those goes through. Rolls back everything it made.';

create or replace function erp_test.assert_entitlement_enforced_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 7;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _entitlement_enforced on commit drop as
    select * from erp_test.entitlement_enforced_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _entitlement_enforced;
  drop table _entitlement_enforced;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ENTITLEMENT_ENFORCED_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case before the door: something the plan does not cover went through, or something it does cover was refused.';
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: entitlement_enforced_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a limit that was sold is enforced: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_entitlement_enforced_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.apply_execute_grants() is not optional here: three invoker doors now
-- reach erp.full_users_committed(), erp.require_entitlement() and what those
-- reach in turn, and a routine a door reaches that was never granted fails at
-- runtime on a live database while a build from empty says nothing.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_entitlement_enforced_suite();
-- The register gained a refusal, and this is the suite that reads the register
-- and refuses wording only the people who build Clove ERP would follow.
select erp_test.assert_plain_words_suite();
-- erp_test.assert_light_users_suite() is deliberately NOT run here, though it
-- is the suite nearest this work. Its fixture designates its own throwaway
-- organisation as the platform's, which a live database already has; that is
-- the shape of failure that killed the deploy of 20260919010000. It is in
-- erp.ci_check_catalogue() and runs on every build, which is where a fixture
-- that must be the only platform organisation belongs.

select erp.assert_entitlements_enforceable();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_resource_coverage('en');
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
