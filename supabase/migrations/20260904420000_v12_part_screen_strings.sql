-- =============================================================================
-- The strings the four v1.2 Part screens are renamed by
--
-- Devices and scanning (§14), Output and printing (§15), Plan and usage (§18)
-- and Report versions and runs (§19) each add a tile to the launchpad and the
-- rail, and a tile's label is a nav.* key resolved through erp_ref.resource.
-- A key with no row falls back to the code's own title, which no tenant can
-- rename and erp.terminology_alignment_report() cannot see. Same convention as
-- 20260904400000 for the continuity screen.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.operations_devices', 'en', 'Devices and scanning', null,
   'Navigation label for the operations screen showing registered devices, what each may do, scan rules and the device action queue.'),
  ('nav.operations_output', 'en', 'Output and printing', null,
   'Navigation label for the operations screen showing output template versions, printers, output requests with their renders and deliveries, and suppressed email addresses.'),
  ('nav.administration_commercial', 'en', 'Plan and usage', null,
   'Navigation label for the administration screen showing the organisation''s plan, subscription, entitlements against their limits, and usage meters.'),
  ('nav.reporting_reproducibility', 'en', 'Report versions and runs', null,
   'Navigation label for the reporting screen showing report versions, the governed view each reads, and every run with the parameters it used.')
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
