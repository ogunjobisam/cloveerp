-- ═════════════════════════════════════════════════════════════════════════════
-- Despatch performance needs no allowance
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20260916180000 registered five columns the Despatch screen's performance
-- report read from public.erp_delivery_performance() and the door never
-- returned (party, site, deliveries, in_full, otif_pct). 20261004600000 (LPR3,
-- #348) made the report read the door's own columns, so the screen no longer
-- names any of them, and erp.assert_app_columns_exist() refused the rows as
-- stale (CLOVEERP_APP_COLUMN_REGISTER_STALE) once the build reached
-- supabase/ci/app_columns.sh. The register loses the five.
--
-- erp_test.app_column_suite() case 6 proved "a pair the register accounts for
-- is allowed" on erp_delivery_performance|otif_pct. It now proves it on the
-- register's remaining row, erp_change_requests|object_label: deployed body,
-- asserted needle, as 20261004000000 does. Case 9 still finds a row to walk.

set lock_timeout = '30s';

do $suite$
declare
  v_sig    constant text := 'erp_test.app_column_suite()';
  v_def    text := pg_get_functiondef('erp_test.app_column_suite()'::regprocedure);
  v_needle constant text := 'array[''erp_delivery_performance|otif_pct'']';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_APP_COLUMN_SUITE_UNRECOGNISED: expected the registered pair once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle, 'array[''erp_change_requests|object_label'']');
end
$suite$;

delete from erp_meta.app_column_allowance
 where door = 'erp_delivery_performance'
   and column_name in ('party', 'site', 'deliveries', 'in_full', 'otif_pct');

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- The suite whose register rows this removes.
select erp_test.assert_app_column_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
