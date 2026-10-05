set lock_timeout = '30s';

-- =============================================================================
-- 20261007031000  The line pickers say what their number is
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-61). The order-line
-- pickers on "Record a shipping notice", "Record the supplier's answer" and
-- "Receive what arrived" read "RM-300 — 6", and nothing said the 6 was what
-- was ordered; the tester took it for what was still open, which the notice
-- refuses more than. "Receive this order" read "1 — RM-300 — Hex bolt — 6"
-- with the same silence about its 6, which there is what is left to receive.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words the pickers now say, one row each in erp_ref.resource:
--        "{item}: {quantity} ordered"               the supplier's answer, and
--                                                   what arrived;
--        "{item}: {open} of {quantity} still open"  a shipping notice, with
--                                                   what the order's page
--                                                   already reads as open;
--        "Line {line}: {item}, {open} left to receive"  receiving an order.
--
-- The wait the tester met on these pickers is not theirs: each reads one
-- order's lines and waited behind the live stall of that night, which is
-- decision 2's to close (erp.credit_position rewritten set-based).
--
-- Production: three resource rows are added. No function, table or other row
-- is changed.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The line pickers say what their number is (20261007031000).'
  from (values
    ('{item}: {quantity} ordered'),
    ('{item}: {open} of {quantity} still open'),
    ('Line {line}: {item}, {open} left to receive')
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
