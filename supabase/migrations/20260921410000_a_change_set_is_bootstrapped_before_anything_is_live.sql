set lock_timeout = '30s';

-- =============================================================================
-- 20260921410000  A change set is bootstrapped before anything is live
-- -----------------------------------------------------------------------------
-- N1 of the simplification plan. Every reseed node in that plan authors its
-- configuration as a change set and promotes it, because state machines and
-- approval chains sit behind erp.guard_live_configuration() and a change set is
-- the only route in. That is three calls and a control between them:
-- erp.submit_change_set(), erp.approve_change_set(), erp.promote_change_set().
--
-- ── WHAT THE PLAN ASKED FOR, AND WHAT IS ACTUALLY MISSING ────────────────────
--
-- The plan asks for "an environment-scoped bootstrap: a non-live environment
-- permits self-approval; a live environment does not". Read against the tree,
-- that rule is already here and has been since 20260829320000:
--
--   * erp.approve_change_set() only refuses the author when
--     erp.tenant_is_live(v_tenant) is true. On an organisation still being
--     built, the author approving their own change is already allowed.
--   * erp.install_module_config() already reads exactly that condition and
--     approves and promotes in the same call when the organisation is not live.
--
-- So nothing has to be permitted that is not permitted today, and this file
-- permits nothing. What is missing is a name for the route. A reseed writing
-- the three calls out by hand is writing erp.install_module_config()'s ending
-- again, and the second copy of a rule is where the rule starts to differ: it
-- is one `if` away from approving on a live organisation, and the reviewer of a
-- four-hundred-line reseed will not be looking at it.
--
-- erp.bootstrap_change_set() is that route, written once, refusing out loud on
-- a live organisation before it does anything at all.
--
-- ── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
--
-- It does not weaken the determination guard. It calls erp.promote_change_set()
-- rather than reproducing it, so CLOVEERP_PROMOTION_BREAKS_DETERMINATION still
-- refuses a promotion that introduces a way for a posting to fail, and the
-- suite below reads the promoter's own body to prove the route was not forked.
-- That refusal is right and is not this node's business.
--
-- It does not touch payment runs. erp.approve_payment_run() refuses the
-- proposer, the demonstration has one active person, and the plan is explicit
-- that the answer there is a second approver in the demonstration rather than a
-- control switched off. Nothing here goes near it.
--
-- It does not weaken the two-person rule on a live organisation. It cannot
-- reach one.
--
-- ── ONE THING THE PLAN GETS WRONG, RECORDED HERE BECAUSE IT MATTERS ──────────
--
-- The plan calls the two-administrator rule "a selling point, not friction" and
-- asks that it stay intact on live. It is intact in the sense that the refusal
-- is still there — but since 20260914098000 the configuration setting
-- approval.administrator_override defaults to allowing an administrator to
-- approve their own, so on a live organisation that has not switched it off,
-- an administrator already approves their own change sets. That was a decision
-- taken deliberately on 14 September. It is not changed here, and it is not
-- hidden either: the suite below proves the refusal still fires on a live
-- organisation once the setting is off, which is what "intact" can honestly
-- mean today.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The route
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.bootstrap_change_set(p_change_set_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cs       erp.change_set%rowtype;
  v_from   erp.change_set_status;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  select * into cs
    from erp.change_set c
   where c.tenant_id = v_tenant and c.id = p_change_set_id;

  if not found then
    raise exception
      'CLOVEERP_CHANGE_SET_NOT_FOUND: no change set % in this organisation', p_change_set_id
      using errcode = '23503',
            hint = 'Check the change set is one of this organisation''s own; a change '
                   'set belonging to another organisation is not visible here.';
  end if;

  -- Before anything is submitted, approved or promoted. A refusal after a
  -- partial run would leave a change set half-way through a route that is not
  -- allowed here at all.
  if erp.tenant_is_live(v_tenant) then
    raise exception
      'CLOVEERP_BOOTSTRAP_ON_A_LIVE_ORGANISATION: % may not be approved and promoted in one call once this organisation is live', cs.code
      using errcode = '42501',
            hint = 'This shortcut exists for an organisation still being built, '
                   'where there is nobody else to approve. On a live one, submit '
                   'the change and ask somebody who may promote configuration to '
                   'approve it and put it in force.';
  end if;

  v_from := cs.status;

  if cs.status = 'draft' then
    perform erp.submit_change_set(p_change_set_id);
  end if;

  perform erp.approve_change_set(p_change_set_id);
  perform erp.promote_change_set(p_change_set_id);

  select * into cs
    from erp.change_set c
   where c.tenant_id = v_tenant and c.id = p_change_set_id;

  return jsonb_build_object(
    'change_set_id', p_change_set_id,
    'code', cs.code,
    'was', v_from,
    'status', cs.status,
    'items', (select count(*) from erp.change_set_item i
               where i.tenant_id = v_tenant and i.change_set_id = p_change_set_id));
end;
$$;

revoke all on function erp.bootstrap_change_set(uuid) from public, anon, authenticated;

comment on function erp.bootstrap_change_set(uuid) is
  'Submits, approves and promotes one change set, and only while the '
  'organisation is still being built. Refuses outright once it is live, where '
  'approving is somebody else''s to do. The route erp.install_module_config() '
  'already takes, written once so a reseed does not write it again.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.change_set_bootstrap_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_cs1    uuid; v_cs2 uuid;
  v_out    jsonb;
  v_u2     uuid; v_tok2 text;
  v_err    text; v_err2 text;
  v_status erp.change_set_status;
  v_value  text;
  v_promoted text;
  v_def    text;
  v_boot   text;
begin
  begin
    v_step := 'an organisation still being built, with one administrator';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzboot-' || v_tag, 'Change Set Bootstrap Suite',
      'admin@zzboot-' || v_tag || '.test', 'Bootstrap Admin');
    perform erp_test.reopen_bootstrap_window(rb.tenant_id);
    insert into auth.users (id, email) values
      (a1, 'admin@zzboot-' || v_tag || '.test'),
      (a2, 'second@zzboot-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    -- The second administrator is invited while the organisation is still
    -- being built, because granting somebody a role afterwards is a different
    -- argument and not this suite's.
    res := public.erp_invite_principal('second@zzboot-' || v_tag || '.test', 'Second Admin');
    v_u2 := (res ->> 'app_user_id')::uuid;
    v_tok2 := res ->> 'token';
    perform erp.grant_role(v_u2, 'administrator', null, null, 'a second person who may promote');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 1. Not live: one call, and the change is in force ───────────────────
    v_step := 'one call takes a draft change set all the way, before go-live';
    v_cs1 := erp.create_change_set('zzboot-words-' || v_tag, 'Suite words',
                                   'A word this organisation prefers', null);
    perform erp.add_change_set_item(v_cs1, 'terminology', 'zzboot.words',
      jsonb_build_object('key', 'nav.home', 'locale', 'en', 'value', 'Front page'),
      'upsert'::erp.change_operation, current_date, 'the change set bootstrap suite');
    v_out := erp.bootstrap_change_set(v_cs1);
    select c.status into v_status from erp.change_set c where c.id = v_cs1;
    select ro.value into v_value
      from erp.resource_override ro
     where ro.tenant_id = rb.tenant_id and ro.key = 'nav.home' and ro.locale = 'en';

    v_cases := v_cases + 1;
    case_name := 'before an organisation is live, one call submits, approves and promotes its own change set, and the change is in force';
    passed := v_state is null
          and v_status = 'promoted'::erp.change_set_status
          and v_out ->> 'was' = 'draft'
          and v_value = 'Front page';
    detail := coalesce(v_state, format('the set is %s, it carried %s item(s), and the word reads %L',
                                       v_status, v_out ->> 'items', coalesce(v_value, '(nothing)')));
    return next;

    -- ── 2. Live: the same call is refused, and nothing has moved ────────────
    v_step := 'the organisation goes live, and the same call is asked for again';
    perform erp_test.close_bootstrap_window(rb.tenant_id);
    v_cs2 := erp.create_change_set('zzboot-words2-' || v_tag, 'Suite words again',
                                   'A second word, asked for after go-live', null);
    perform erp.add_change_set_item(v_cs2, 'terminology', 'zzboot.words2',
      jsonb_build_object('key', 'nav.home', 'locale', 'en', 'value', 'Home page'),
      'upsert'::erp.change_operation, current_date, 'the change set bootstrap suite');
    v_err := null;
    begin
      perform erp.bootstrap_change_set(v_cs2);
    exception when others then
      v_err := left(sqlerrm, 200);
    end;
    select c.status into v_status from erp.change_set c where c.id = v_cs2;

    v_cases := v_cases + 1;
    case_name := 'once the organisation is live the same call is refused by name, and the change set has not moved';
    passed := v_state is null
          and v_err like 'CLOVEERP_BOOTSTRAP_ON_A_LIVE_ORGANISATION%'
          and v_status = 'draft'::erp.change_set_status;
    detail := coalesce(v_state, format('it said %L and the set is still %s',
                                       coalesce(v_err, 'nothing, and promoted it'), v_status));
    return next;

    -- ── 3. Live, two people required: the author is still refused ───────────
    v_step := 'two-person approval switched on, and the author tries their own';
    perform erp_test.administrator_approval_off(rb.tenant_id);
    perform erp.submit_change_set(v_cs2);
    v_err2 := null;
    begin
      perform erp.approve_change_set(v_cs2);
    exception when others then
      v_err2 := left(sqlerrm, 200);
    end;
    select c.status into v_status from erp.change_set c where c.id = v_cs2;

    v_cases := v_cases + 1;
    case_name := 'and on a live organisation that asks for two people, the author of a change set still may not approve it';
    passed := v_state is null
          and v_err2 like 'CLOVEERP_CHANGE_SET_SELF_APPROVAL%'
          and v_status = 'ready'::erp.change_set_status;
    detail := coalesce(v_state, format('it said %L and the set is %s',
                                       coalesce(v_err2, 'nothing, and approved it'), v_status));
    return next;

    -- ── 4. Live: the second person does it the ordinary way ─────────────────
    v_step := 'the second administrator approves and puts it in force';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs2);
    perform erp.promote_change_set(v_cs2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select c.status::text into v_promoted from erp.change_set c where c.id = v_cs2;
    select ro.value into v_value
      from erp.resource_override ro
     where ro.tenant_id = rb.tenant_id and ro.key = 'nav.home' and ro.locale = 'en';

    v_cases := v_cases + 1;
    case_name := 'the second person approves it and puts it in force, which is the whole route the shortcut refuses to take on a live organisation';
    passed := v_state is null
          and v_promoted = 'promoted'
          and v_value = 'Home page';
    detail := coalesce(v_state, format('the set is %s and the word now reads %L',
                                       v_promoted, coalesce(v_value, '(nothing)')));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 5. The shortcut did not fork the promoter ─────────────────────────────
  --
  -- Read rather than run. A fixture that breaks determination on purpose is a
  -- second copy of erp_test.determination_coverage_suite(), which already
  -- proves the refusal fires; what has to be proved HERE is that the shortcut
  -- goes through the promoter at all rather than writing its own, because a
  -- forked promoter is how a guard is lost without anybody removing it.
  v_boot := pg_catalog.pg_get_functiondef('erp.bootstrap_change_set(uuid)'::regprocedure);
  v_def  := pg_catalog.pg_get_functiondef('erp.promote_change_set(uuid,text[],boolean)'::regprocedure);

  v_cases := v_cases + 1;
  case_name := 'the shortcut goes through the promoter instead of writing its own, and the promoter still refuses a change that would break how postings are decided';
  passed := position('erp.promote_change_set(' in v_boot) > 0
        and position('erp.approve_change_set(' in v_boot) > 0
        and position('erp.tenant_is_live(' in v_boot) > 0
        and position('PROMOTION_BREAKS_DETERMINATION' in v_def) > 0
        and position('erp.determination_coverage_report(' in v_def) > 0;
  detail := format('the shortcut names the promoter %s time(s) and the live test %s time(s); the promoter still carries its refusal %s time(s)',
                   (length(v_boot) - length(replace(v_boot, 'erp.promote_change_set(', ''))) / length('erp.promote_change_set('),
                   (length(v_boot) - length(replace(v_boot, 'erp.tenant_is_live(', ''))) / length('erp.tenant_is_live('),
                   (length(v_def) - length(replace(v_def, 'PROMOTION_BREAKS_DETERMINATION', ''))) / length('PROMOTION_BREAKS_DETERMINATION'));
  return next;

  -- ── 6. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzboot-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state, 'the organisation rolled back with both its change sets and both its people');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CHANGE_SET_BOOTSTRAP_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.change_set_bootstrap_suite() from public, anon;

create or replace function erp_test.assert_change_set_bootstrap_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _change_set_bootstrap on commit drop as
    select * from erp_test.change_set_bootstrap_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _change_set_bootstrap;
  drop table _change_set_bootstrap;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CHANGE_SET_BOOTSTRAP_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_CHANGE_SET_BOOTSTRAP_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a change set is bootstrapped before anything is live: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_change_set_bootstrap_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generators, then the proof
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The suite is not run from here. It provisions two organisations' worth of
-- people and takes one of them live, so its cost belongs to its fixture and not
-- to the schema, and 20260920310000 records what happened the last time a
-- migration ran one of those on a deploy. erp.ci_check_catalogue() picks the
-- wrapper up by name and every build runs it.

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
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
