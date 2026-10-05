set lock_timeout = '30s';

-- =============================================================================
-- 20261006200000  VAT checks are grouped
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-99). The next return
-- on the VAT returns screen listed every finding public.erp_vat_boxes answers
-- above the Finalise press, the ones that block the return and the ones that
-- only ask to be checked alike, one line each. The demonstration buys from
-- suppliers abroad, so 63 lines of "is from a supplier in DE/NL/IE; the reverse
-- charge is not computed" filled the card above Finalise, unpaged.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words the screen now says. A finding that blocks the return is still
--      listed in full. The ones that only ask to be checked are grouped by
--      their kind: one line each, with the first of them and "62 more of the
--      same kind", which unfolds to the rest. The grouping is the screen's
--      (src/lib/vat-returns.ts, groupFindings, held by its bun test); the door
--      answers what it answered before.
--
-- On production: one screen string is added. No function is changed, no table
-- is altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). VAT checks are grouped (20261006200000).'
  from (values
    ('more of the same kind')
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
