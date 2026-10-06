set lock_timeout = '30s';

-- =============================================================================
-- 20261010063000  Platform staff are recognised by a confirmed address
-- -----------------------------------------------------------------------------
-- Found by the review of #448. A platform staff row is keyed on email so a
-- person can be added before they ever sign in (20260830091046), and
-- erp_meta.platform_actor() and erp_meta.is_platform_owner() matched a
-- signed-in caller to it by the email on their sign-in alone. An address
-- nobody had confirmed counted: on a project where sign-up is open and
-- confirmation is off, anybody could sign up as the owner's address before
-- the owner did and be the owner. The demonstration project (built from empty
-- by demo_from_empty.yml, its owner registered by email) is exactly that
-- shape until its settings are right.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_meta.platform_actor() and erp_meta.is_platform_owner(): the email
--      branch matches only a sign-in whose email is confirmed
--      (auth.users.email_confirmed_at). A row already bound to a sign-in is
--      matched by its id, as before.
--   B. erp_meta.register_platform_owner() (20261010062000) binds the owner's
--      row to the confirmed sign-in with that address when there is one, so a
--      deployment built from empty has its owner bound before anybody can
--      sign in, and says so.
--   C. erp_test.platform_owner_registered_suite (20261010062000): its owner
--      signs up with a confirmed address, which is now what being recognised
--      takes. Its cases are otherwise unchanged.
--   D. erp_test.platform_owner_confirmed_suite, four cases, and its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Who may be added, how ranks gate, how a row is bound on first use
-- (erp_meta.require_platform()). No door, permission or screen string.
--
-- On production: two functions are replaced, one routine and one suite are
-- redefined and a suite added; no row is written. Every owner and staff row
-- there that anybody uses is bound to its sign-in by id, which this does not
-- touch (checked by the lead before this was written).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Only a confirmed address is matched
-- ─────────────────────────────────────────────────────────────────────────────

do $confirmed$
declare
  r      record;
  v_src  text;
  v_def  text;
  v_old  constant text := $o$where u.id = (select auth.uid()))$o$;
  v_new  constant text := $n$where u.id = (select auth.uid())
                                      -- Confirmed, or it is anybody's
                                      -- address (20261010063000).
                                      and u.email_confirmed_at is not null)$n$;
begin
  for r in
    select * from (values
      ('erp_meta.platform_actor()', 'b13192bed3cfd60bf9a914b36894082a'),
      ('erp_meta.is_platform_owner()', 'a1d4c35d09c594fd2f208b012980ec57')
    ) as x(sig, md5)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261010063000') > 0 then
      raise notice '% already asks for a confirmed address; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.md5 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010063000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$confirmed$;

comment on function erp_meta.platform_actor() is
  'The caller''s platform staff row: bound to their sign-in by id, or, until it is bound, matched by the email of a '
  'sign-in whose address is confirmed (20261010063000).';

comment on function erp_meta.is_platform_owner() is
  'Whether the caller is a platform owner: by the sign-in their row is bound to, or by a confirmed address on a row '
  'not yet bound (20261010063000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The registered owner is bound to their confirmed sign-in
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.register_platform_owner(p_email text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_uid   uuid;
  v       erp_meta.platform_staff;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'CLOVEERP_PLATFORM_OWNER_EMAIL_INVALID: "%" is not an email address', p_email
      using errcode = '22023',
            hint = 'Give the owner''s email address, as they will sign in with it.';
  end if;

  -- The sign-in the owner already has, if they have one, and only if its
  -- address is confirmed (20261010063000).
  select u.id into v_uid
    from auth.users u
   where lower(u.email) = v_email
     and u.email_confirmed_at is not null
   order by u.id
   limit 1;

  select s.* into v
    from erp_meta.platform_staff s
   where lower(s.email) = v_email
     and s.revoked_at is null;

  if found and v.staff_role = 'owner' then
    if v.auth_user_id is null and v_uid is not null then
      update erp_meta.platform_staff
         set auth_user_id = v_uid, updated_at = now()
       where id = v.id;
      return format('platform owner: %s, bound to its confirmed sign-in, already registered', v.email);
    end if;
    return format('platform owner: %s, already registered', v.email);
  end if;

  if exists (select 1 from erp_meta.platform_staff s where s.revoked_at is null) then
    raise exception 'CLOVEERP_PLATFORM_HAS_OTHER_STAFF: the platform already has staff, and % is not its owner', v_email
      using errcode = '42501',
            hint = 'Ask an owner to add the person from the platform console.';
  end if;

  -- A row revoked earlier is the same person coming back: given the rank
  -- again rather than refused by the unique email index.
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values (v_email, v_uid, v_email, 'owner')
  on conflict ((lower(email))) do update
     set staff_role = 'owner', revoked_at = null, revoked_reason = null,
         auth_user_id = coalesce(excluded.auth_user_id, erp_meta.platform_staff.auth_user_id),
         updated_at = now()
  returning * into v;

  perform erp_meta.platform_log(v, 'platform.owner_registered', null, v.email,
    'Registered by the build of an empty deployment before anybody could sign in, so the platform was never '
    'claimable (20261010062000).');

  return format('platform owner: %s, registered%s', v.email,
                case when v.auth_user_id is not null then ' and bound to its confirmed sign-in' else '' end);
end;
$$;

revoke all on function erp_meta.register_platform_owner(text) from public, anon, authenticated, service_role;

comment on function erp_meta.register_platform_owner(text) is
  'Names the platform''s owner by email on an empty staff list, for the trusted build role only, bound to the '
  'confirmed sign-in with that address when there is one (20261010063000): the demonstration''s from-empty build '
  'calls it so the platform is never claimable by whoever signs up first. Registering the same owner again changes '
  'nothing but the binding; naming anybody else once the platform has staff is refused (20261010062000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The registered-owner suite's owner confirms their address
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.platform_owner_registered_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$insert into auth.users (id, email) values (v_ownerid, v_owner);$o$;
  v_new  constant text := $n$-- With the address confirmed, which being recognised takes (20261010063000).
    insert into auth.users (id, email, email_confirmed_at) values (v_ownerid, v_owner, now());$n$;
begin
  if strpos(v_src, '20261010063000') > 0 then
    raise notice '% already confirms its owner; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '1e69eb5a1b06157dd4c0bfddd7b9d9c3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010063000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.platform_owner_confirmed_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_owner  text;
  v_uid    uuid := gen_random_uuid();
  v_step   text := 'emptying the staff list';
  v_state  text;
  v_got    text;
  v_me     jsonb;
  v_row    erp_meta.platform_staff;
begin
  v_owner := 'owner@zzpoc-' || v_tag || '.test';
  begin
    -- A deployment whose owner was registered by email, and somebody who has
    -- signed up with that address and not confirmed it.
    delete from erp_meta.platform_staff;
    perform set_config('request.jwt.claims', '', true);
    perform erp_meta.register_platform_owner(v_owner);
    insert into auth.users (id, email) values (v_uid, v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);

    -- ── 1. Not the owner ────────────────────────────────────────────────────
    v_step := 'an unconfirmed address';
    v_me := public.erp_platform_me();
    v_cases := v_cases + 1;
    case_name := 'a sign-up with the owner''s address that nobody confirmed is not the owner';
    passed := not erp_meta.is_platform_owner() and (v_me ->> 'is_staff') = 'false';
    detail := v_me::text;
    return next;

    -- ── 2. Not staff at all ─────────────────────────────────────────────────
    v_step := 'the console, unconfirmed';
    begin
      perform erp_meta.require_platform('support');
      v_got := 'the console let it in';
    exception when others then
      v_got := sqlerrm;
    end;
    select s.* into v_row from erp_meta.platform_staff s where lower(s.email) = v_owner;
    v_cases := v_cases + 1;
    case_name := 'the console refuses it, and the owner''s row is not bound to it';
    passed := v_got like 'CLOVEERP_NOT_PLATFORM_STAFF%' and v_row.auth_user_id is null;
    detail := v_got;
    return next;

    -- ── 3. Confirmed, it is ─────────────────────────────────────────────────
    v_step := 'the address confirmed';
    update auth.users set email_confirmed_at = now() where id = v_uid;
    v_me := public.erp_platform_me();
    v_cases := v_cases + 1;
    case_name := 'once the address is confirmed, the same sign-in is the owner';
    passed := erp_meta.is_platform_owner() and (v_me ->> 'role') = 'owner';
    detail := v_me::text;
    return next;

    -- ── 4. The build binds it ───────────────────────────────────────────────
    v_step := 'registering the owner again';
    perform set_config('request.jwt.claims', '', true);
    v_got := erp_meta.register_platform_owner(v_owner);
    select s.* into v_row from erp_meta.platform_staff s where lower(s.email) = v_owner;
    v_cases := v_cases + 1;
    case_name := 'registering the owner binds their row to the confirmed sign-in with that address';
    passed := v_row.auth_user_id = v_uid and v_got like '%bound to its confirmed sign-in%';
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
    raise exception 'CLOVEERP_PLATFORM_OWNER_CONFIRMED_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.platform_owner_confirmed_suite() from public, anon;

comment on function erp_test.platform_owner_confirmed_suite() is
  'Platform staff are recognised by a confirmed address (20261010063000): an unconfirmed sign-up with the owner''s '
  'address is not the owner and the console refuses it; confirmed, it is; registering the owner binds the row to it.';

create or replace function erp_test.assert_platform_owner_confirmed_suite()
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
    from erp_test.platform_owner_confirmed_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PLATFORM_OWNER_CONFIRMED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An address nobody confirmed is matched to a platform staff row. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_PLATFORM_OWNER_CONFIRMED_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('platform owner confirmed: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_platform_owner_confirmed_suite() from public, anon;

comment on function erp_test.assert_platform_owner_confirmed_suite() is
  'Nobody is platform staff by an address they have not confirmed (20261010063000).';

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
