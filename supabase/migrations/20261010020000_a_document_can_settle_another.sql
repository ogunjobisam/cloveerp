set lock_timeout = '30s';

-- =============================================================================
-- 20261010020000  A document can settle another
-- -----------------------------------------------------------------------------
-- Found on the order-to-cash re-test on live, 5 October (defect C). Apply cash
-- opened RCPT-000001 and settled INV-000260 with it, and the receipt's Related
-- documents were empty: the invoice it paid was named only as a line's
-- description. erp.document_relation says how two documents relate, and none
-- of its kinds is "this paid that": fulfils, invoices, credits, converts,
-- returns, consumes, corrects, consolidates and mirrors.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.document_relation_kind gains settles: the cash document that paid
--      a document points at it, as a credit note points at the invoice it
--      credits. 20261010021000 writes it, from a receipt to each invoice the
--      receipt paid, and gives every receipt there already is its links.
--
-- A value added to an enum cannot be used in the transaction that added it,
-- and every migration is one transaction, so this file only adds it; the file
-- that follows is the first to write it (as 20260906111000 did for
-- erp.command_status).
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No relation is written here, and nothing that reads a relation of another
-- kind sees this one: every reader names the kind it reads.
--
-- On production: one value is added to an enum. No table is rewritten and no
-- row of any organisation is touched.
-- =============================================================================

alter type erp.document_relation_kind add value if not exists 'settles';

comment on type erp.document_relation_kind is
  'How one document relates to another, pointing from the document that was derived to the one it came from: '
  'fulfils, invoices, credits, converts, returns, consumes, corrects, consolidates, mirrors, and settles, the cash '
  'document that paid it (20261010020000).';

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
