set lock_timeout = '30s';

-- =============================================================================
-- 20261002100000  The demonstration catches up whatever its administrator last chose
-- -----------------------------------------------------------------------------
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Every deploy since 29 September 17:48 has reported, and done nothing for,
-- the live demonstration:
--
--   DID NOT CATCH UP — demo-cbb10384: Signing in as its administrator resolves
--   to another organisation, so nothing was done there.
--
-- erp.catch_up_demonstrations() acts as the demonstration's administrator and
-- then checks that the organisation that person resolves to is the one it is
-- aimed at. erp.principal_context() resolves a person who belongs to more than
-- one organisation to the one they last chose (erp_meta.principal_preference),
-- or else to their newest membership. So an administrator who once switched
-- to another organisation, or joined one, froze the demonstration: the check
-- refused, rightly, to write anywhere but where it was aimed, and nothing
-- brought the demonstration up to today. That is what a prospect is shown.
-- It changed between the deploys of 27 September 22:03 (caught up) and
-- 29 September 17:48 (refused); no deploy ran in between, so it was the
-- account, not the code.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * For each demonstration it acts on, the catch-up now makes the
--     demonstration the administrator's chosen organisation for the length
--     of the work, inside its own transaction, and puts their own choice back
--     afterwards: the same organisation and time they chose, or no choice at
--     all if they had made none. Nothing outside the transaction ever sees the
--     pinned choice. If the work refuses, the exception rolls the pin back
--     with everything else.
--   * The check that the administrator resolves to the demonstration stays,
--     now as the proof that the pin took rather than the reason nothing ran.
--   * erp_test.demonstration_administrator_elsewhere_suite: an administrator
--     who entered another organisation from the console and chose it is acted
--     as in the demonstration and keeps their choice; one who had chosen
--     nothing is left with nothing. (Newest membership alone cannot be staged
--     in one transaction, which gives every row the same created_at; the
--     chosen case is the one production met.)
-- =============================================================================

do $pin$
declare
  v_sig constant text := 'erp.catch_up_demonstrations(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- The declarations.
    $o$  v_admin  uuid;
$o$,
    $n$  v_admin  uuid;
  -- The administrator's own choice of organisation, kept while the catch-up
  -- pins theirs to the demonstration and put back after (20261002100000).
  v_pref     uuid;
  v_pref_at  timestamptz;
  v_had_pref boolean;
$n$,
    -- The pin, once the organisation is said outright.
    $o$      perform set_config('erp.job_tenant_id', t.id::text, true);
$o$,
    $n$      perform set_config('erp.job_tenant_id', t.id::text, true);

      -- The organisation this administrator resolves to is the one they last
      -- chose, or their newest (erp.principal_context()). An administrator
      -- who switched away, or joined another organisation, froze the
      -- demonstration: the check below refused, rightly, to write anywhere
      -- else. So the demonstration is made their choice for the length of
      -- this work, in this transaction only, and their own is put back
      -- after (20261002100000).
      select p.active_tenant_id, p.chosen_at into v_pref, v_pref_at
        from erp_meta.principal_preference p
       where p.auth_user_id = v_admin;
      v_had_pref := found;
      insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
      values (v_admin, t.id, now())
      on conflict (auth_user_id) do update
        set active_tenant_id = excluded.active_tenant_id, chosen_at = excluded.chosen_at;
$n$,
    -- Put back on the path that refuses.
    $o$            'Signing in as its administrator resolves to another organisation, so nothing was done there.')));
        continue;
$o$,
    $n$            'Signing in as its administrator resolves to another organisation, so nothing was done there.')));
        if v_had_pref then
          update erp_meta.principal_preference
             set active_tenant_id = v_pref, chosen_at = v_pref_at
           where auth_user_id = v_admin;
        else
          delete from erp_meta.principal_preference where auth_user_id = v_admin;
        end if;
        continue;
$n$,
    -- And on the path that works, once the work is drained.
    $o$      set constraints all immediate;

    exception when others then
$o$,
    $n$      set constraints all immediate;

      if v_had_pref then
        update erp_meta.principal_preference
           set active_tenant_id = v_pref, chosen_at = v_pref_at
         where auth_user_id = v_admin;
      else
        delete from erp_meta.principal_preference where auth_user_id = v_admin;
      end if;

    exception when others then
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) by 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[v_i], ''))) / length(v_pairs[v_i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, (v_i + 1) / 2, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[v_i], v_pairs[v_i + 1]);
  end loop;
  execute v_def;
end
$pin$;

comment on function erp.catch_up_demonstrations(text) is
  'Brings every active demonstration organisation (demo-%), or the one named, up to today, acting as its '
  'administrator in that organisation whatever organisation they last chose: their choice is pinned to the '
  'demonstration for the length of the work and put back after (20261002100000). One note per organisation.';

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_administrator_elsewhere_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  a3      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  r_demo  record;
  r_other record;
  r_demo2 record;
  res     jsonb;
  v_out   jsonb;
  v_out2  jsonb;
  v_note  text;
  v_note2 text;
  v_chosen_at timestamptz := now() - interval '3 days';
  v_pref  record;
begin
  begin
    v_step := 'a demonstration, and another organisation its administrator also belongs to and last chose';
    perform set_config('request.jwt.claims', '', true);
    select * into r_demo from erp.provision_tenant(
      'demo-zzel' || v_tag, 'Demonstration Elsewhere Suite',
      'admin@zzel-' || v_tag || '.test', 'Demo Admin');
    select * into r_other from erp.provision_tenant(
      'zzelo-' || v_tag, 'Elsewhere Suite Other',
      'other@zzel-' || v_tag || '.test', 'Other Admin');
    -- A demonstration is not live; the catch-up refuses one that is.
    update erp.environment set is_live = false where tenant_id = r_demo.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzel-' || v_tag || '.test'),
                                              (a2, 'other@zzel-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r_demo.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(r_other.admin_token);
    -- A sign-in is bound to one principal by invitation, so the second comes
    -- the way a second organisation comes in life: platform staff entering
    -- one from the console, with a reason (20260916023000).
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('admin@zzel-' || v_tag || '.test', a1, 'Demo Admin', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform public.erp_platform_enter_tenant(r_other.tenant_id,
      'Suite: a demonstration administrator who entered another organisation');
    perform set_config('request.jwt.claims', '', true);
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
    values (a1, r_other.tenant_id, v_chosen_at)
    on conflict (auth_user_id) do update
      set active_tenant_id = excluded.active_tenant_id, chosen_at = excluded.chosen_at;

    v_step := 'the catch-up, aimed at the demonstration';
    v_out := erp.catch_up_demonstrations('demo-zzel' || v_tag);
    v_note := v_out -> 0 -> 'notes' ->> 0;

    -- ── 1. Acted as in the demonstration ─────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'an administrator who last chose another organisation is acted as in the demonstration';
    -- The demonstration's own answer, from erp.demonstration_catch_up(): the
    -- work ran there, past the check that used to stop it, and finished,
    -- which is the path that puts the administrator's choice back.
    passed := v_note not like 'Signing in as its administrator resolves to another organisation%'
          and v_note like 'It has no history the builder made%';
    detail := coalesce(v_note, 'no note');
    return next;

    -- ── 2. Their choice is kept ──────────────────────────────────────────
    select p.active_tenant_id, p.chosen_at into v_pref
      from erp_meta.principal_preference p where p.auth_user_id = a1;
    v_cases := v_cases + 1;
    case_name := 'and keeps the organisation they chose, and when they chose it';
    passed := v_pref.active_tenant_id = r_other.tenant_id and v_pref.chosen_at = v_chosen_at;
    detail := format('chose %s at %s', v_pref.active_tenant_id, v_pref.chosen_at);
    return next;

    v_step := 'a second demonstration whose administrator also entered another organisation and has no choice recorded';
    select * into r_demo2 from erp.provision_tenant(
      'demo-zzem' || v_tag, 'Demonstration Newest Suite',
      'admin2@zzel-' || v_tag || '.test', 'Demo Admin Two');
    update erp.environment set is_live = false where tenant_id = r_demo2.tenant_id and is_self;
    insert into auth.users (id, email) values (a3, 'admin2@zzel-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(r_demo2.admin_token);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('admin2@zzel-' || v_tag || '.test', a3, 'Demo Admin Two', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform public.erp_platform_enter_tenant(r_other.tenant_id,
      'Suite: a demonstration administrator whose newest organisation is another');
    perform set_config('request.jwt.claims', '', true);
    delete from erp_meta.principal_preference where auth_user_id = a3;
    v_out2 := erp.catch_up_demonstrations('demo-zzem' || v_tag);
    v_note2 := v_out2 -> 0 -> 'notes' ->> 0;

    -- ── 3. No choice, and none left behind ───────────────────────────────
    -- The pin is taken back by deleting it, not left in place: an
    -- administrator who had chosen nothing still has chosen nothing.
    v_cases := v_cases + 1;
    case_name := 'an administrator who had chosen no organisation is acted as in the demonstration and left with no choice';
    passed := v_note2 like 'It has no history the builder made%'
          and not exists (select 1 from erp_meta.principal_preference p where p.auth_user_id = a3);
    detail := coalesce(v_note2, 'no note');
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 4. Undone ─────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t
                         where t.code in ('demo-zzel' || v_tag, 'zzelo-' || v_tag, 'demo-zzem' || v_tag))
        and not exists (select 1 from auth.users u where u.id in (a1, a2, a3));
  detail := coalesce(v_state, 'the demonstrations rolled back with their administrators');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATION_ADMINISTRATOR_ELSEWHERE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_administrator_elsewhere_suite() from public, anon;

comment on function erp_test.demonstration_administrator_elsewhere_suite() is
  'The demonstration catch-up acts as the administrator in the demonstration whatever organisation they last '
  'chose, and leaves their choice as it was, or absent (20261002100000).';

create or replace function erp_test.assert_demonstration_administrator_elsewhere_suite()
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
    from erp_test.demonstration_administrator_elsewhere_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_ADMINISTRATOR_ELSEWHERE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A demonstration would freeze, or an administrator would lose the organisation they chose. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_DEMONSTRATION_ADMINISTRATOR_ELSEWHERE_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration administrator elsewhere: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_administrator_elsewhere_suite() from public, anon;

comment on function erp_test.assert_demonstration_administrator_elsewhere_suite() is
  'The demonstration catch-up is not frozen by an administrator who chose another organisation (20261002100000).';

select erp_test.assert_demonstration_administrator_elsewhere_suite();

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
