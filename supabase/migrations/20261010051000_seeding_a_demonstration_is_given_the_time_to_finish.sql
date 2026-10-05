set lock_timeout = '30s';

-- =============================================================================
-- 20261010051000  Seeding a demonstration is given the time to finish
-- -----------------------------------------------------------------------------
-- Found rehearsing the rebuild of the live demonstration, 5 October. Both
-- presses that build a demonstration run under the authenticated role's
-- eight-second statement timeout, and carry only their search_path:
--
--   erp_seed_demo          Home → "Seed a demo organisation". One call makes
--                          the organisation and configures all of it: ten
--                          module installs and promotions (each promotion runs
--                          erp.determination_coverage_report() twice), the
--                          chart, four years of periods, items, prices, legal
--                          details, devices, contacts and the second person.
--                          About 1 to 1.5 s locally; erp_accept_interview,
--                          which promotes the same way, took 8.3 s on live on
--                          29 September and was cancelled (20261001902000).
--                          A cancelled seed creates nothing, and pressing
--                          again repeats all of it.
--   erp_seed_demo_history  Administration → Tenant → "Build a year of trading
--                          history", pressed in a loop. Under eight seconds
--                          the builder starts no new day after two (a quarter
--                          of the limit), so a call builds about two days and
--                          the year takes two to three hundred calls; one
--                          slow call ends the loop, and a quarter-end call
--                          that also finalises a VAT return can time out
--                          every time it is repeated. The rehearsal met one
--                          timeout in twenty-nine calls.
--
-- ── WHAT THIS IS, AND IS NOT ─────────────────────────────────────────────────
--
-- Each door is given the fifty-five seconds erp_accept_interview
-- (20261001902000), erp_platform_assurance and both purge doors have.
-- PostgREST applies a function's own statement_timeout to the call. No body
-- changes.
--
-- Both do bounded work and build no aggregate in memory, unlike the export
-- whose 55 s was withdrawn on 30 September: the seed configures one
-- organisation; the history builds at most five days per call and starts no
-- new day once a quarter of the limit has gone, which it reads from the
-- session (erp.seed_demo_history() asks pg_settings). Under fifty-five
-- seconds that is 13.75 s, so a call builds its five days and the finaliser
-- after them, and the year is about eighty calls.
--
--   A. alter function ... set statement_timeout = '55s' on both doors, and
--      proved here.
--   B. erp_test.demo_doors_have_time_suite, three cases, and its assertion.
--
-- On production: two functions gain a setting. No table is altered and no
-- row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Fifty-five seconds
-- ─────────────────────────────────────────────────────────────────────────────

alter function public.erp_seed_demo() set statement_timeout = '55s';
alter function public.erp_seed_demo_history(date, date, numeric) set statement_timeout = '55s';

comment on function public.erp_seed_demo() is
  'Makes a demonstration organisation for the caller, or returns the one they already have: the organisation, its '
  'environments and the caller as its administrator (erp.seed_demo()), adopted as the caller''s organisation, then '
  'configured to trade (erp.ensure_demo_configuration()) and given its master data (erp.seed_demo_master_data()). '
  'While self-service sign-up is closed, for platform operators and owners only. Given fifty-five seconds, because '
  'the whole configuration is one call (20261010051000).';

comment on function public.erp_seed_demo_history(date, date, numeric) is
  'Builds a few days of demonstration trading history and returns {done, next_from, built, notes}. Call again with '
  'next_from until done. Refused in a live environment, and, while self-service sign-up is closed, to anybody who is '
  'not a platform operator or owner. Given fifty-five seconds, so a call builds its five days (20261010051000).';

-- Proved here rather than trusted: each door carries the setting.
do $proof$
declare
  v_missing text;
begin
  select string_agg(s.sig, ', ') into v_missing
    from unnest(array[
      'public.erp_seed_demo()',
      'public.erp_seed_demo_history(date,date,numeric)']) as s(sig)
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.oid = s.sig::regprocedure
        and 'statement_timeout=55s' = any (coalesce(p.proconfig, '{}')));
  if v_missing is not null then
    raise exception 'CLOVEERP_DEMO_DOOR_TIMEOUT_MISSING: no statement_timeout of 55s on %', v_missing;
  end if;
end
$proof$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demo_doors_have_time_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_step    text := 'reading the doors';
  v_state   text;
  v_timeout text := current_setting('statement_timeout');
  v_conf    text[];
  v_res     jsonb;
  -- A week with no month end in it, and so no pay day: five ordinary days.
  v_from    constant date := (date_trunc('month', current_date) - interval '6 months')::date + 9;
begin
  begin
    -- ── 1. The seed ─────────────────────────────────────────────────────────
    select p.proconfig into v_conf from pg_catalog.pg_proc p
     where p.oid = 'public.erp_seed_demo()'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'seeding a demonstration organisation is given fifty-five seconds, because the whole configuration is one call';
    passed := 'statement_timeout=55s' = any (coalesce(v_conf, '{}'));
    detail := format('public.erp_seed_demo() carries %s', coalesce(v_conf::text, 'nothing'));
    return next;

    -- ── 2. The history ──────────────────────────────────────────────────────
    select p.proconfig into v_conf from pg_catalog.pg_proc p
     where p.oid = 'public.erp_seed_demo_history(date,date,numeric)'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'each call of the trading history is given fifty-five seconds';
    passed := 'statement_timeout=55s' = any (coalesce(v_conf, '{}'));
    detail := format('public.erp_seed_demo_history() carries %s', coalesce(v_conf::text, 'nothing'));
    return next;

    -- ── 3. And under it a call builds its five days ─────────────────────────
    -- The builder reads the limit from the session, as it does under
    -- PostgREST, and starts no new day once a quarter of it has gone.
    v_step := 'a demonstration configured to trade';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdtm-' || v_tag, 'Demo Doors Time Suite', 'admin@zzdtm-' || v_tag || '.test', 'Doors Time Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdtm-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    -- Without a limit of its own the door has the signed-in role's eight
    -- seconds, under which a call stops starting days after two.
    v_step := 'five days under the door''s own limit';
    perform set_config('statement_timeout',
                       coalesce((select split_part(c, '=', 2) from unnest(v_conf) c
                                  where c like 'statement_timeout=%'), '8s'), true);
    v_res := erp.seed_demo_history(v_from, v_from + 9, 1);
    perform set_config('statement_timeout', v_timeout, true);
    v_cases := v_cases + 1;
    case_name := 'under the door''s own limit a call builds the five days a call may build, and says where the next one starts';
    passed := v_state is null
          and (v_res ->> 'built_through')::date = v_from + 4
          and (v_res ->> 'next_from')::date = v_from + 5
          and (v_res ->> 'built')::integer > 0;
    detail := coalesce(v_state, format('under %s: %s', v_conf, left((v_res - 'notes')::text, 200)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('statement_timeout', v_timeout, true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMO_DOORS_HAVE_TIME_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_doors_have_time_suite() from public, anon;

comment on function erp_test.demo_doors_have_time_suite() is
  'The two presses that build a demonstration are given fifty-five seconds (20261010051000), and under that limit a '
  'call of the trading history builds its five days.';

create or replace function erp_test.assert_demo_doors_have_time_suite()
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
    from erp_test.demo_doors_have_time_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_DOORS_HAVE_TIME_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A press that builds a demonstration has lost its fifty-five seconds, or no longer builds five days under them. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DEMO_DOORS_HAVE_TIME_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration doors have time: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_doors_have_time_suite() from public, anon;

comment on function erp_test.assert_demo_doors_have_time_suite() is
  'Seeding a demonstration and building its history are each given fifty-five seconds (20261010051000).';

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
