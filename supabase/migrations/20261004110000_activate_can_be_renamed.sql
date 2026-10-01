-- ═════════════════════════════════════════════════════════════════════════════
-- Activate can be renamed
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20261003900000 put an Activate button on the imports screen, beside Roll
-- back, for a loaded contacts or products batch whose drafts are not live yet.
-- Its label had no en resource row, so supabase/ci/screen_strings.sh refused
-- it: a word on a screen that no organisation could rename. The build never
-- reached that step on main, which stopped earlier at the cutover suite.

set lock_timeout = '30s';

insert into erp_ref.resource (key, locale, value, description)
values (erp_ref.ui_key('Activate'), 'en', 'Activate',
        'A screen string declared at its call site and rendered through ui(). The imports screen''s button that sets every draft a loaded contacts or products batch created active, after which the batch no longer rolls back.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

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
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
