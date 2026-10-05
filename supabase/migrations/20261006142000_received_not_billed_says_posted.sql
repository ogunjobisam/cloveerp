set lock_timeout = '30s';

-- =============================================================================
-- 20261006142000  Received, not yet billed says it counts posted receipts
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October, and in the design that
-- followed the owner's decision that a draft goods receipt receives nothing
-- (20261006131000):
--
--   (a) J-48. Purchasing's page carries two tiles over the same read, how
--       many lines are received and not yet billed and what they are worth,
--       and both were labelled "Received, not yet billed", so the page said
--       the same thing twice with two different figures under it.
--   (b) The "Received, not yet billed" panel said it lists what was
--       "Received against a purchase order". Since 20261006131000 only a
--       posted goods receipt receives, so the panel says so.
--   (c) J-69. A document whose lifecycle has ended said "This document has
--       reached a state its lifecycle does not continue from.", a sentence
--       about the machinery rather than the document, and not through ui().
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words the screen now says, as rows in erp_ref.resource: the two
--      tiles' own labels, the panel's description, and the sentence a
--      finished document says. The panel keeps its title, its empty text and
--      what it lists; the tiles keep their figures.
--
-- Production: four rows are added to erp_ref.resource. Nothing else changes.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The words
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Received, not yet billed counts posted receipts (20261006142000).'
  from (values
    ('Lines received, not yet billed'),
    ('Value received, not yet billed'),
    ('Posted goods receipts against a purchase order, still awaiting an invoice.'),
    ('Nothing more happens to this document.')
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
