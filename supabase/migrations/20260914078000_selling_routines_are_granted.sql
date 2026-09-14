-- =============================================================================
-- The selling routines are granted, not assumed
--
-- 20260914077000 added erp.set_up_selling(), erp.term_unit_cost() and
-- erp_test's selling setup suite, and did not run the execute-grant generator.
-- The build re-runs the generators before its checks, so it was green; the
-- deploy does not, and on 14 September at 11:59 UTC the live proof failed:
--
--   no_public_execute: CLOVEERP_PUBLIC_EXECUTE: 4 finding(s)
--   execute_grants: CLOVEERP_EXECUTE_GRANTS_DRIFTED: 2 finding(s)
--
-- A new routine takes the default ACL, which is EXECUTE to PUBLIC, and the
-- reach the doors need was never written down. The generator is the fix: it
-- revokes PUBLIC across the product schemas, grants authenticated and
-- service_role exactly what erp.invoker_reach_report() reaches, and records
-- the reach. Nothing else changes.
-- =============================================================================

select erp.apply_execute_grants();

select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_public_api_safe();
