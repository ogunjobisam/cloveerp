-- ═════════════════════════════════════════════════════════════════════════════
-- The first of the month is not after itself
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.migration_cutover_suite() takes its as-at date as the first of the
-- current month, loads opening stock as at it, writes 105 units off today, and
-- asserts that the as-at figure ignores the write-off, because it is "dated
-- today, after as-at". On the first of a month today IS the as-at date, so the
-- write-off counts and the suite fails, out by 105 × 250 = 26,250. It did on
-- 1 October, on every branch.
--
-- The as-at date is now the day before today when today is the first, so it is
-- always strictly before the write-off. January the first stays as it was: the
-- suite configures this fiscal year only, and the day before it is outside the
-- calendar, which staging rightly refuses.
--
-- 20260904460000 and four later migrations end by running the suite, and they
-- cannot be edited, so a build from an empty cluster would still run the old
-- body on the first. Those five calls are in
-- supabase/ci/replay_superseded_calls.txt, superseded by this migration; the
-- catalogue walks the suite as it is now on every build.

set lock_timeout = '30s';

do $asat$
declare
  v_sig    constant text := 'erp_test.migration_cutover_suite()';
  v_def    text := pg_get_functiondef('erp_test.migration_cutover_suite()'::regprocedure);
  v_needle constant text := 'v_asat date := date_trunc(''month'', current_date)::date;';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_CUTOVER_SUITE_UNRECOGNISED: expected the as-at date once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle,
    'v_asat date := case when current_date = date_trunc(''month'', current_date)::date '
    || 'and extract(month from current_date) <> 1 then current_date - 1 '
    || 'else date_trunc(''month'', current_date)::date end;');
end
$asat$;

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
select erp.assert_ci_coverage();
