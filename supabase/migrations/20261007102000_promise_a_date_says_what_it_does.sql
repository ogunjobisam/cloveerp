set lock_timeout = '30s';

-- =============================================================================
-- 20261007102000  Promise a date says what it does
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-78). "Promise a date"
-- is offered on Sales and on the Sales order step, where an order is chosen
-- first, so it reads as promising that order a date. It does not:
-- public.erp_promise_date(product, site, quantity) is a lookup for one
-- product at one site, the earliest day that many could be ready from stock
-- not already promised and supply on its way, and it writes nothing. The
-- form said none of this, and after it nothing on the order had changed.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words the form now says under its heading.
--
-- The screen's half is in src/routes/sales/index.tsx. The door, what it
-- answers and who may ask it are unchanged.
--
-- On production: one row is added to erp_ref.resource where it is not there
-- already. No routine or table is changed and no row of any organisation is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). What Promise a date does, on Sales (20261007102000, J-78).'
  from (values
    ('Checks one product at one site: the earliest day this many could be ready, from stock not already promised and supply on its way. No order is changed.')
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
