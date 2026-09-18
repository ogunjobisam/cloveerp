set lock_timeout = '30s';

-- =============================================================================
-- 20260920310000  A suite is run by the build, not by the deploy
-- -----------------------------------------------------------------------------
-- 20260920300000 ended by running erp_test.assert_demonstration_catch_up_suite(),
-- and on the deploy that carried it the replay stopped there with
-- SQLSTATE 57014, the statement timeout. The suite builds a demonstration
-- organisation of its own and runs the whole catch-up against it: 46 s on a
-- build from an empty database, past two minutes on one with three
-- organisations and a year of trading in it. That file is edited in place and
-- registered here; this is the repair.
--
-- The edit removes a statement and adds none, so there is no definition to
-- re-apply and nothing in any schema differs because of it. What a repair still
-- owes is the claim that made the removal safe, which is that dropping the call
-- loses no coverage. That claim is not self-evident — it depends on a catalogue
-- picking the suite up by name — so this file asserts it rather than asserting
-- that the edit happened.
--
-- ── WHAT IS ASSERTED, AND WHY EACH PART ──────────────────────────────────────
--
-- erp.ci_check_catalogue() gathers every routine in erp and erp_test called
-- assert_% that takes no arguments, and supabase/ci/run_checks.sh runs the
-- catalogue on every build. So a suite is run by the build whether or not a
-- migration asks for it, and the CI step "A check that is not run fails the
-- build" is what holds that true. Three things have to be so for the removal to
-- be safe, and each is checked below:
--
--   1. The wrapper is in the catalogue. If a rename or a new argument ever puts
--      it outside, the suite stops being run by anything and nothing would say
--      so — which is the failure this repository fears most, a check that
--      exists and is never run.
--   2. The suite still pins its case count, at both ends. A suite that loses a
--      case reports success; the count guard is what stops that, and there is
--      one in the suite and one in its wrapper.
--   3. Both pin the same number. Two guards disagreeing is one guard.
--
-- ── WHAT THIS COSTS ON A REAL DATABASE ───────────────────────────────────────
--
-- Everything here reads the catalogue and two routine bodies. Its cost is the
-- size of the schema, not the size of anybody's ledger, and it is the same on
-- an empty build as on production. That sentence is the one 20260920250000 and
-- 20260920300000 could not have written about themselves, which is why both had
-- to be edited after a deploy rather than before one.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The build runs the suite, so the deploy does not have to
-- ═════════════════════════════════════════════════════════════════════════════

do $covered$
declare
  v_suite  constant text := 'demonstration_catch_up_suite';
  v_check  constant text := 'assert_demonstration_catch_up_suite';
  v_expected constant integer := 12;
  v_call   text;
  v_body   text;
  v_wrap   text;
begin
  select c.call into v_call
    from erp.ci_check_catalogue() c
   where c.schema_name = 'erp_test' and c.function_name = v_check;

  if v_call is null then
    raise exception
      'CLOVEERP_SUITE_NOT_IN_CATALOGUE: erp_test.%() is not in erp.ci_check_catalogue(), so nothing runs it', v_check
      using errcode = '23503',
            hint = 'The catalogue gathers assert_% routines in erp and erp_test that take no arguments. '
                   'Either give it back that shape, or run it from somewhere that a build reaches.';
  end if;

  v_body := pg_get_functiondef(('erp_test.' || v_suite || '()')::regprocedure);
  v_wrap := pg_get_functiondef(('erp_test.' || v_check || '()')::regprocedure);

  if position('v_cases <> ' || v_expected in v_body) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not hold itself to % cases', v_suite, v_expected
      using errcode = '23514',
            hint = 'A suite that loses a case reports success. Pin the count inside the suite.';
  end if;

  if position('v_all <> ' || v_expected in v_wrap) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not hold the suite to % cases', v_check, v_expected
      using errcode = '23514',
            hint = 'The wrapper counts the rows the suite returned. Pin the same number there.';
  end if;

  raise notice
    'the build runs erp_test.%() from the catalogue as "%", and both ends pin % cases',
    v_check, v_call, v_expected;
end
$covered$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ── Proved ───────────────────────────────────────────────────────────────────
--
-- The same four schema assertions and the same reconciliation 20260920300000
-- now ends with, and for the same reason: their cost is the schema's size, and
-- the reconciliation was measured at 1.7 s on live against three organisations.
-- No suite is run from here. That is the point of the file.

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
