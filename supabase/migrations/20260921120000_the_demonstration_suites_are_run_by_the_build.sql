set lock_timeout = '30s';

-- =============================================================================
-- 20260921120000  The demonstration suites are run by the build
-- -----------------------------------------------------------------------------
-- 20260921110000 ended by running three demonstration suites, and on the deploy
-- that carried it the replay stopped there with SQLSTATE 57014, the statement
-- timeout, on the second of them. Each builds a demonstration organisation of
-- its own and trades it, so each costs whatever its fixture does rather than
-- what the schema is: seconds on a build from an empty database, past the
-- configured two minutes on one with three organisations and a year of trading
-- in it. That file is edited in place and registered here; this is the repair.
--
-- It is the third time this shape has taken a deploy down, and the second time
-- with a suite: 20260920250000 wrote journals before the generators,
-- 20260920300000 ran a suite from a migration, and 20260920310000 removed that
-- call and wrote the rule down. 20260921110000 then made three calls of the
-- same kind, one of them to the very suite 20260920310000 had removed. Nothing
-- in CI could see it, because CI builds from empty — which is the reason the
-- rule exists and not an excuse for missing it.
--
-- The edit removes three statements and adds none, so there is no definition to
-- re-apply and nothing in any schema differs because of it. What a repair still
-- owes is the claim that made the removal safe, which is that dropping the
-- calls loses no coverage. That claim is not self-evident — it depends on a
-- catalogue picking each suite up by name — so this file asserts it rather than
-- asserting that the edit happened.
--
-- ── WHY ALL THREE WENT, AND NOT TWO ──────────────────────────────────────────
--
-- Asked of each rather than answered once. A call may stay where its cost is
-- the schema's size; none of these is:
--
--   demonstration_close_frontier_suite  provisions an organisation, configures
--     it, seeds a day and runs erp.demonstration_catch_up() twice, the second
--     of which trades three weeks.
--   demonstration_reopen_suite  provisions another, seeds a day three months
--     back, closes every historic period through the doors — each close running
--     its tie checks — and then has the catch-up reopen, trade and re-close
--     them. It is the one that timed out.
--   demonstration_catch_up_suite  provisions a third and runs the whole
--     catch-up against it. 20260920310000 removed this same call from
--     20260920300000's tail for this same reason; 20260921110000 reintroduced
--     it. Its claim is restated here because this file is removing a call to it
--     too, and a repair that leaves one of its own removals unasserted is
--     trusting the last one to have covered it.
--
-- ── WHAT IS ASSERTED, AND WHY EACH PART ──────────────────────────────────────
--
-- erp.ci_check_catalogue() gathers every routine in erp and erp_test called
-- assert_% that takes no arguments, and supabase/ci/run_checks.sh runs the
-- catalogue on every build. So a suite is run by the build whether or not a
-- migration asks for it, and the CI step "A check that is not run fails the
-- build" is what holds that true. Three things have to be so for each removal
-- to be safe, and each is checked below, for each of the three:
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
-- The block below reads the catalogue and six routine bodies. Its cost is the
-- size of the schema, not the size of anybody's ledger, and it is the same on
-- an empty build as on production: no organisation is provisioned, nothing is
-- traded, no period is closed and no ledger is read.
--
-- The assertions at the foot are the ordinary schema proof, with one exception
-- named rather than glossed: erp.assert_whole_database_reconciles() does grow
-- with the ledger — 1.7 s on live over three organisations (20260920300000) —
-- and it stays, because it is the only thing here that would notice a data
-- fault.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The build runs all three, so the deploy does not have to
-- ═════════════════════════════════════════════════════════════════════════════

do $covered$
declare
  v_suite    text;
  v_check    text;
  v_expected integer;
  v_call     text;
  v_body     text;
  v_wrap     text;
  s          record;
begin
  -- The suite, its wrapper, and the number both ends must pin.
  for s in
    select * from (values
      ('demonstration_close_frontier_suite', 'assert_demonstration_close_frontier_suite',  5),
      ('demonstration_reopen_suite',         'assert_demonstration_reopen_suite',          6),
      ('demonstration_catch_up_suite',       'assert_demonstration_catch_up_suite',       12)
    ) as v(suite, wrapper, expected)
  loop
    v_suite    := s.suite;
    v_check    := s.wrapper;
    v_expected := s.expected;

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
  end loop;
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
-- The same schema assertions 20260920310000 ends with, and for the same reason:
-- their cost is the schema's size, and the reconciliation was measured at 1.7 s
-- on live against three organisations. No suite is run from here. That is the
-- point of the file.

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
