set lock_timeout = '30s';

-- =============================================================================
-- 20261007152000  Closing a quality event says what it needs
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-91). The Close step
-- of Quality said "An event closes once you have decided what happens to it
-- and logged the actions." But an event has no decision to make: a complaint
-- or a near miss may name no batch at all, and erp.close_quality_event asks
-- for three things only, why it happened (the root cause), what was done
-- about this one (the corrective action) and what stops the next (the
-- preventive action). The design is right; the step said something else.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words the Close step now says: "An event closes with why it
--      happened and what was done to fix it and stop it recurring." The old
--      sentence, which nothing else says, is removed.
--
-- The screen's half is in src/lib/modules.tsx. Closing an event, what it asks
-- for and who may do it are unchanged.
--
-- On production: one sentence replaces another. No routine or table is
-- changed and no row of any organisation is written.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). What closing a quality event needs (20261007152000).'
  from (values
    ('An event closes with why it happened and what was done to fix it and stop it recurring.')
  ) as v(text)
on conflict (key, locale) do nothing;

delete from erp_ref.resource
 where key = erp_ref.ui_key('An event closes once you have decided what happens to it and logged the actions.');

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
