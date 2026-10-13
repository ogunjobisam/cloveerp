-- A bank account's name is read.
--
-- Bank reconciliation, pull request 2 of 5, a follow-up to 20261013015000. That
-- migration registered the account's name in erp_meta.write_only_column as a
-- label nothing decides on. Importing and withdrawing a statement
-- (20261013020000) now name the account in what they answer and record, which
-- erp.write_only_column_report counts as reading it, so the register's row is
-- kept past its reason. It goes, as the register asks. The sort code and the
-- last four digits stay registered: nothing reads them yet.

delete from erp_meta.write_only_column
 where schema_name = 'erp' and table_name = 'bank_account' and column_name = 'name';

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_write_only_columns();
