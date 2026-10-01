-- ═════════════════════════════════════════════════════════════════════════════
-- The tenant state has a screen
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20261004500000 (F6, #345) put the go-live panel on /administration/tenant,
-- which reads public.erp_tenant_state() for close_ties_missing. The door was
-- registered in erp_meta.api_only_door as having no screen, so
-- erp.assert_doors_have_a_home() refused the stale row
-- (CLOVEERP_API_ONLY_DOOR_IS_NAMED) once the build reached supabase/ci/app_doors.sh.
-- The door has a home; the row goes.

set lock_timeout = '30s';

delete from erp_meta.api_only_door
 where function_name = 'erp_tenant_state';

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
