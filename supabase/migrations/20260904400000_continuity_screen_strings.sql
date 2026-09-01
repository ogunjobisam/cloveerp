-- =============================================================================
-- The strings the continuity screen is renamed by
--
-- supabase/ci/screen_strings.sh fails the build for a screen literal with no
-- row in erp_ref.resource, and erp.assert_resource_coverage() fails for a key
-- the app references and no locale resolves. The terminology layer's premise is
-- that renaming is a glossary change with no code impact, and that is only true
-- of strings the register holds.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.operations_continuity', 'en', 'Continuity and incidents', null,
   'Navigation label for the operations screen showing continuity commitments, their restore drills, declared incidents and support access grants.')
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
