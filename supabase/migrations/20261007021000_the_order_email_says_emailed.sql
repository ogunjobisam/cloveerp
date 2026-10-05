set lock_timeout = '30s';

-- =============================================================================
-- 20261007021000  The order email says emailed
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-51). A purchase
-- order's lifecycle names its step "Issue to supplier" and the state it
-- reaches "Issued" (the procurement template, 20260923100000). The section on
-- the order's page that emails the order said "Sent to the supplier", offered
-- "Send to supplier", said an approved order "moves to Sent", and, with no
-- email yet, "Not sent yet". So after Issue the order read "Issued" while the
-- section beside it said it had not been sent: two actions shared one verb,
-- and the dialog named a state the order never shows.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words the section now says, in English and German: "Emailed to the
--      supplier", "Email to supplier", "Email again", "Email this order to
--      the supplier", that an approved order is issued by the same press, and
--      "Not emailed yet". The lifecycle's own names, which are the
--      organisation's, are left as they are.
--
-- The screen's half is in src/components/erp/purchase-order-sends.tsx. The
-- door, what it does and who may press it are unchanged.
--
-- On production: words are added. No routine or table is changed and no row
-- but these is written. No email is sent or changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.en), v.locale, v.value,
       'A screen string, rendered through ui(). The order email says emailed (20261007021000).'
  from (values
    ('Emailed to the supplier', 'en', 'Emailed to the supplier'),
    ('Emailed to the supplier', 'de', 'Per E-Mail an den Lieferanten'),
    ('Email to supplier', 'en', 'Email to supplier'),
    ('Email to supplier', 'de', 'An den Lieferanten mailen'),
    ('Email again', 'en', 'Email again'),
    ('Email again', 'de', 'Erneut mailen'),
    ('Email this order to the supplier', 'en', 'Email this order to the supplier'),
    ('Email this order to the supplier', 'de', 'Diese Bestellung per E-Mail an den Lieferanten senden'),
    ('Emails the order with its PDF attached. An approved order is issued by the same press. Replies come to you.', 'en',
     'Emails the order with its PDF attached. An approved order is issued by the same press. Replies come to you.'),
    ('Emails the order with its PDF attached. An approved order is issued by the same press. Replies come to you.', 'de',
     'Sendet die Bestellung per E-Mail mit dem PDF im Anhang. Eine genehmigte Bestellung wird mit demselben Klick ausgelöst. Antworten gehen an Sie.'),
    ('Not emailed yet. Email it from here, or download the PDF and send it yourself.', 'en',
     'Not emailed yet. Email it from here, or download the PDF and send it yourself.'),
    ('Not emailed yet. Email it from here, or download the PDF and send it yourself.', 'de',
     'Noch nicht per E-Mail gesendet. Senden Sie sie von hier, oder laden Sie das PDF herunter und senden Sie es selbst.')
  ) as v(en, locale, value)
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
