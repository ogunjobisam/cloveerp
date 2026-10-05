set lock_timeout = '30s';

-- =============================================================================
-- 20261007090000  A business partner's role reads as a word
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-107). On Common data
-- the three lists that offer a business partner's roles (New business
-- partner, Create a business partner with roles, Add a role to a business
-- partner) offered the database's own codes, "customer", "consignee",
-- "regulator", and the open partner record printed the same codes in its
-- Roles pills. Five of the nine roles already have the word a person reads
-- (Customer, Supplier, Carrier, Internal, Regulator); four have none.
--
-- The partner record also ended in a sentence saying addresses, contacts and
-- credit "are governed separately and are not read here", which pointed
-- nowhere. Contacts, the VAT number and payment terms are now kept on the
-- record itself (20261007091000 and 20261007092000); what stays elsewhere is
-- the address, set from this screen, and a customer's credit limit, set on
-- Sales, and the record now says so with a way to each.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words for the four roles that had none: Manufacturer, Broker,
--      Consignee and Agent.
--   B. The words of the record's closing section, which names where the
--      address and the credit limit are set.
--
-- The product record's "Group" becomes "Category", the word the New product
-- form asks for it by; both rows exist already.
--
-- On production: six rows are added to erp_ref.resource where they are not
-- there already. No function is changed and no row of any organisation is
-- changed.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A business partner''s role, or the partner record''s closing section, '
       'on Common data (20261007090000, J-107).'
  from (values
    ('Manufacturer'),
    ('Broker'),
    ('Consignee'),
    ('Agent'),
    ('Addresses and credit'),
    ('A business partner''s addresses are set on this screen. A customer''s credit limit is set on Sales.')
  ) as v(text)
on conflict (key, locale) do nothing;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
