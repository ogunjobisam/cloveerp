set lock_timeout = '30s';

-- =============================================================================
-- 20261006181000  An empty answer says why
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-95). On Financials,
-- "Eliminations" and "Budget position" each answered a bare "None": the first
-- for a group with nothing eliminated yet, the second for a code no budget in
-- use carries this year. A question answered with nothing should say what the
-- nothing means.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words an inquiry says in place of "None" when its answer is empty
--      (src/components/erp/inquiry.tsx gains an optional `empty` sentence;
--      src/lib/modules.tsx gives these two theirs).
--
-- No door changes: both still answer [] when there is nothing, which is right.
--
-- On production: two screen strings are added. No routine or table is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). An empty answer says why (20261006181000).'
  from (values
    ('Nothing has been eliminated in this group yet.'),
    ('No budget in use has that code this year.')
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
