-- A bank account's details are for people.
--
-- Bank reconciliation, pull request 1 of 5, a follow-up to 20261013010000 that
-- the build found. erp.assert_write_only_columns read three columns
-- erp_define_bank_account writes and nothing decides on: the account's name,
-- its sort code and the last four digits of its number. That is their purpose,
-- not a gap: they are how a person tells which real account at which bank the
-- ledger account stands for, on the Bank screen, in every picker that offers a
-- bank account, and on the reconciliation the auditor reads. The ledger decides
-- on the ledger account (erp.company_bank_account); the full account number is
-- never kept. If something comes to decide on one of them — an OFX file
-- refused when its account is not this one — its row here is removed, as the
-- register asks.
--
-- And the Bank tile's title in src/lib/modules.tsx is a screen string, which
-- needs its own row so an organisation can rename it.

insert into erp_meta.write_only_column (schema_name, table_name, column_name, rationale) values
  ('erp', 'bank_account', 'name',
   'Deliberate. The name a person gives a bank account (Barclays current account), shown wherever one is chosen. A label; the ledger decides on the ledger account it posts to.'),
  ('erp', 'bank_account', 'sort_code',
   'Deliberate. The bank''s sort code, so a person and the auditor can tell which real account the ledger account stands for. Identification only; nothing is supposed to branch on it.'),
  ('erp', 'bank_account', 'account_last4',
   'Deliberate. The last four digits of the account number (the full number is never kept), so a person can tell two accounts at one bank apart. Identification only.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The Bank tile (20261013015000).'
  from (values ('Bank')) v(text)
on conflict do nothing;

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_write_only_columns();
select erp.assert_resource_coverage('en');
