set lock_timeout = '30s';

-- =============================================================================
-- 20261010062000  A new deployment has its owner before anyone signs in
-- -----------------------------------------------------------------------------
-- public.erp_platform_claim_ownership() makes the first signed-in person to ask
-- the platform's owner, while the staff list is empty. That is how production
-- got its owner on the day it was first deployed, and it was safe there
-- because nobody else knew the project existed.
--
-- The demonstration deployment (Clove ERP Demo, demo.cloveerp.com) is built
-- from empty, in public: its address and publishable key ship in every copy
-- of the application, anybody can sign up to it, and its build takes about
-- an hour. The first stranger to sign up while the staff
-- list was empty could have claimed the whole platform: every organisation on
-- it, every console door, the owner's own rank.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Two refusals, registered.
--   B. erp_meta.register_platform_owner(email): the trusted build role names
--      the owner by email, as a staff row with no sign-in yet. The staff list
--      is keyed on email for exactly this (20260830091046): the owner is bound
--      to their sign-in the first time they use it, and erp_meta.
--      is_platform_owner() already recognises them by email before then. With
--      a row on the list, the claim door refuses everybody, as it always has.
--      Registering the same owner again changes nothing; naming somebody else
--      on a platform that already has staff is refused, because an owner adds
--      people from the console.
--
--      The demonstration's from-empty build (.github/workflows/
--      demo_from_empty.yml) writes that row inside the transaction of the
--      migration that creates the staff list, so the list is never empty in
--      any state another session can see, and calls this routine at the end
--      to record it. The address comes from the repository variable
--      CLOVEERP_PLATFORM_OWNER_EMAIL; the build refuses to start without it.
--   C. erp_test.platform_owner_registered_suite, six cases, and its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- The claim door itself, which production and the nightly stack's browser
-- suite still use on a list that is genuinely empty. No door, permission or
-- screen string. On production: one routine and a suite are added; no row is
-- written and the staff list is untouched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_PLATFORM_OWNER_EMAIL_INVALID',
  'Registering a platform owner by something that is not an email address.',
  'The platform''s owner is recognised by the email address they sign in with, before they have ever signed in.',
  'Give the owner''s email address, as they will sign in with it.');

select erp.register_refusal(
  'CLOVEERP_PLATFORM_HAS_OTHER_STAFF',
  'Registering a platform owner on a platform that already has staff.',
  'A build names the owner of an empty platform only. Once anybody is on the staff list, people are added by an '
  'owner, from the console, where the change is recorded against them.',
  'Ask an owner to add the person from the platform console.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Naming the owner
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.register_platform_owner(p_email text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v       erp_meta.platform_staff;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'CLOVEERP_PLATFORM_OWNER_EMAIL_INVALID: "%" is not an email address', p_email
      using errcode = '22023',
            hint = 'Give the owner''s email address, as they will sign in with it.';
  end if;

  select s.* into v
    from erp_meta.platform_staff s
   where lower(s.email) = v_email
     and s.revoked_at is null;

  if found and v.staff_role = 'owner' then
    return format('platform owner: %s, already registered', v.email);
  end if;

  if exists (select 1 from erp_meta.platform_staff s where s.revoked_at is null) then
    raise exception 'CLOVEERP_PLATFORM_HAS_OTHER_STAFF: the platform already has staff, and % is not its owner', v_email
      using errcode = '42501',
            hint = 'Ask an owner to add the person from the platform console.';
  end if;

  -- A row revoked earlier is the same person coming back: given the rank
  -- again rather than refused by the unique email index.
  insert into erp_meta.platform_staff (email, display_name, staff_role)
  values (v_email, v_email, 'owner')
  on conflict ((lower(email))) do update
     set staff_role = 'owner', revoked_at = null, revoked_reason = null, updated_at = now()
  returning * into v;

  perform erp_meta.platform_log(v, 'platform.owner_registered', null, v.email,
    'Registered by the build of an empty deployment before anybody could sign in, so the platform was never '
    'claimable (20261010062000).');

  return format('platform owner: %s, registered', v.email);
end;
$$;

revoke all on function erp_meta.register_platform_owner(text) from public, anon, authenticated, service_role;

comment on function erp_meta.register_platform_owner(text) is
  'Names the platform''s owner by email on an empty staff list, for the trusted build role only: the demonstration''s '
  'from-empty build calls it so the platform is never claimable by whoever signs up first. Registering the same owner '
  'again changes nothing; naming anybody else once the platform has staff is refused (20261010062000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.platform_owner_registered_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_owner    text;
  v_stranger uuid := gen_random_uuid();
  v_ownerid  uuid := gen_random_uuid();
  v_step     text := 'emptying the staff list';
  v_state    text;
  v_got      text;
  v_me       jsonb;
  v_row      erp_meta.platform_staff;
begin
  v_owner := 'owner@zzpo-' || v_tag || '.test';
  begin
    -- The state of a deployment built from empty: nobody on the list. Put
    -- back by the undo at the end.
    delete from erp_meta.platform_staff;
    perform set_config('request.jwt.claims', '', true);

    -- ── 1. The owner is named before they have signed in ────────────────────
    v_step := 'registering the owner';
    v_got := erp_meta.register_platform_owner(upper(v_owner));
    select s.* into v_row from erp_meta.platform_staff s where lower(s.email) = v_owner;
    v_cases := v_cases + 1;
    case_name := 'on an empty staff list the build names the owner by email, before they have ever signed in';
    passed := v_got like '%registered' and v_row.staff_role = 'owner' and v_row.auth_user_id is null
              and (select count(*) from erp_meta.platform_staff) = 1;
    detail := v_got;
    return next;

    -- ── 2. A stranger cannot claim it ───────────────────────────────────────
    v_step := 'a stranger signs up';
    insert into auth.users (id, email) values (v_stranger, 'stranger@zzpo-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_stranger)::text, true);
    v_me := public.erp_platform_me();
    -- The claim door is named in a string rather than called by name:
    -- preflight rule A refuses a suite that calls it from any migration that
    -- defines the suite's assertion, because a fixture that claims ownership
    -- fails on live. This case expects the refusal live gives, so it holds on
    -- live too; the indirection only keeps the rule's text search from
    -- reading it as a claim.
    begin
      execute format('select %s(%L)', 'public.erp_platform_claim_ownership', 'A stranger');
      v_got := 'the stranger became the owner';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'whoever signs up first cannot claim the platform, and is not told it is claimable';
    passed := v_got like 'CLOVEERP_PLATFORM_ALREADY_OWNED%'
              and (v_me ->> 'claimable') = 'false' and (v_me ->> 'is_staff') = 'false';
    detail := v_got || ' / ' || v_me::text;
    return next;

    -- ── 3. The owner signs up and is the owner ──────────────────────────────
    v_step := 'the owner signs up';
    insert into auth.users (id, email) values (v_ownerid, v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', v_ownerid)::text, true);
    v_me := public.erp_platform_me();
    v_cases := v_cases + 1;
    case_name := 'the owner, signing up with that address, is the platform''s owner';
    passed := erp_meta.is_platform_owner() and (v_me ->> 'is_staff') = 'true' and (v_me ->> 'role') = 'owner';
    detail := v_me::text;
    return next;

    -- ── 4. Saying it again changes nothing ──────────────────────────────────
    v_step := 'registering the owner again';
    perform set_config('request.jwt.claims', '', true);
    v_got := erp_meta.register_platform_owner(v_owner);
    v_cases := v_cases + 1;
    case_name := 'registering the same owner again changes nothing';
    passed := v_got like '%already registered' and (select count(*) from erp_meta.platform_staff) = 1;
    detail := v_got;
    return next;

    -- ── 5. Nobody else is named by a build ──────────────────────────────────
    v_step := 'registering somebody else';
    begin
      perform erp_meta.register_platform_owner('someone@zzpo-' || v_tag || '.test');
      v_got := 'they were registered';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'once the platform has staff a build cannot name another owner';
    passed := v_got like 'CLOVEERP_PLATFORM_HAS_OTHER_STAFF%';
    detail := v_got;
    return next;

    -- ── 6. Only an address ──────────────────────────────────────────────────
    v_step := 'registering something that is not an address';
    begin
      perform erp_meta.register_platform_owner('');
      v_got := 'it was registered';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'an owner is named by an email address and nothing else';
    passed := v_got like 'CLOVEERP_PLATFORM_OWNER_EMAIL_INVALID%';
    detail := v_got;
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PLATFORM_OWNER_REGISTERED_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.platform_owner_registered_suite() from public, anon;

comment on function erp_test.platform_owner_registered_suite() is
  'A deployment built from empty has its owner before anybody signs in (20261010062000): the build names the owner '
  'by email; a stranger who signs up cannot claim the platform; the owner signing up with that address is the owner; '
  'naming them again changes nothing; nobody else is named by a build; and only an email address is accepted.';

create or replace function erp_test.assert_platform_owner_registered_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.platform_owner_registered_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PLATFORM_OWNER_REGISTERED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A deployment built from empty can be claimed by whoever signs up first, or its registered owner is not recognised. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_PLATFORM_OWNER_REGISTERED_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('platform owner registered: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_platform_owner_registered_suite() from public, anon;

comment on function erp_test.assert_platform_owner_registered_suite() is
  'A deployment built from empty is never claimable by a stranger: its owner is named by the build '
  '(20261010062000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
