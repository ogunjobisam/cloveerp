-- ═════════════════════════════════════════════════════════════════════════════
-- An imported address is read
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.party_address.lines, postcode and country_code were registered in
-- erp_meta.write_only_column by 20260924200000: written from the desk, carried
-- onto the invoice, and consulted by nothing that decides. Since
-- 20261003700000, erp.validate_party_profile_import decides on each of them:
-- an imported address without a first line, or without a town and a postcode,
-- or in a country the product does not list, is refused, and the load adds an
-- address only of a kind the party has no default for.
--
-- erp.assert_write_only_columns() therefore finds the three rows standing past
-- their reason and refuses them, as it should. The rows go; party_address.label
-- stays registered, since nothing decides on a label.

set lock_timeout = '30s';

delete from erp_meta.write_only_column w
 where w.schema_name = 'erp' and w.table_name = 'party_address'
   and w.column_name in ('lines', 'postcode', 'country_code');

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
