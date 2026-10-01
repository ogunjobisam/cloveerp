-- ═════════════════════════════════════════════════════════════════════════════
-- Activate is a word somebody can change
-- ═════════════════════════════════════════════════════════════════════════════
--
-- #343 put an Activate button on the import batches list
-- (src/routes/master-data/imports.tsx), rendered through ui() like every
-- RpcButton label, with no row in erp_ref.resource. supabase/ci/screen_strings.sh
-- refused it — 1 of 2697 — once the build got that far, which on #343 it never
-- did. The row, so a tenant can rename it.

set lock_timeout = '30s';

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Sets a loaded contacts or products batch live (20261003900000).'
  from (values
    ('Activate')
  ) as v(text)
on conflict do nothing;

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
