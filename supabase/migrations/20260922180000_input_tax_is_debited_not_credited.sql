set lock_timeout = '30s';

-- =============================================================================
-- 20260922180000  Input tax is debited, and the report was reading it backwards
-- -----------------------------------------------------------------------------
-- Found by the suite 20260922170000 added, not by reasoning about the code: the
-- one-button route was made to carry the supplier's VAT, the ledger carried the
-- same figure, and erp.tax_outside_the_ledger_report() said they disagreed —
--
--   the tax on a posted document is not the tax its journal carries
--   PINV-2026-000001: 20000 was determined and -20000 reached a tax control
--   account on journal none
--
-- Twenty thousand determined and minus twenty thousand posted. The figures are
-- the same figure with opposite signs, which is not a disagreement about an
-- amount; it is the report subtracting in the wrong order.
--
-- ── THE ARITHMETIC ───────────────────────────────────────────────────────────
--
-- The report computes what reached the ledger as
--
--   sum(jl.credit_minor - jl.debit_minor)
--
-- over the tax control lines, and says why in its own comment: "A credit to tax
-- control is tax charged, so the ledger's figure is the credit less the debit."
--
-- That is true of a sale. Tax charged on a sales invoice is owed to the
-- authority and is credited. It is exactly wrong of a purchase: the tax a
-- supplier charged is tax the company reclaims, and it is debited —
-- erp_test.supplier_tax_suite() has asserted so since 20260916410000, in those
-- terms, "the tax a supplier charged is debited to the tax account".
--
-- So for every purchase invoice carrying tax the report has compared a positive
-- determination with a negative posting and found them different. Every one.
--
-- ── WHY IT LOOKED INTERMITTENT ───────────────────────────────────────────────
--
-- erp_test.invoice_tax_suite() case 9 asks this report for findings, over a
-- fixture that includes a slice of seeded demonstration trading. Whether that
-- slice happens to contain a supplier bill carrying tax in the window decides
-- whether the report finds anything, so the case failed on some runs and passed
-- on others with nothing in the tree having changed — the behaviour recorded on
-- issue #246, where four failures over two days produced no diagnosis because
-- the case reports a bare finding count and not the finding.
--
-- This is a defect in the report, not in the ledger and not in the return. No
-- posting was wrong; the check over them was.
--
-- ── WHAT IS CHANGED, AND WHAT IS NOT ─────────────────────────────────────────
--
-- Only the purchase side. The sale side keeps credit less debit, because that
-- side has been right all along and every suite that reads a sales figure
-- agrees with it. The direction is asked of erp.document_trade_side(), which is
-- the same function erp.state_supplier_tax() asks before it will transcribe a
-- supplier's figure at all, so "which side is this" has one answer in the
-- product rather than two.
--
-- The second arm of the report — an invoice left undetermined because the
-- product cannot tell a sale from a purchase — is untouched.
-- =============================================================================

do $report$
declare
  v_sig constant text := 'erp.tax_outside_the_ledger_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  -- What each posted document determined, and what its journal actually put on\n'
    || E'  -- a tax control account. A credit to tax control is tax charged, so the\n'
    || E'  -- ledger''s figure is the credit less the debit.\n';
  v_new constant text :=
       E'  -- What each posted document determined, and what its journal actually put on\n'
    || E'  -- a tax control account, in the direction that document''s side uses\n'
    || E'  -- (20260922180000).\n'
    || E'  --\n'
    || E'  -- A credit to tax control is tax charged on something sold, and owed to the\n'
    || E'  -- authority. A debit is tax a supplier charged, and reclaimable. Reading\n'
    || E'  -- both as credit less debit made every purchase look like a disagreement of\n'
    || E'  -- exactly twice its own tax, which is what this check was refusing for\n'
    || E'  -- months on whichever runs happened to contain a supplier bill with VAT.\n';
  v_old_sum constant text :=
    E'          coalesce((select sum(jl.credit_minor - jl.debit_minor)\n';
  v_new_sum constant text :=
       E'          coalesce((select sum(case when erp.document_trade_side(doc.id) = ''purchase''\n'
    || E'                                    then jl.debit_minor - jl.credit_minor\n'
    || E'                                    else jl.credit_minor - jl.debit_minor end)\n';
  v_hits integer;
begin
  if position('20260922180000' in v_def) > 0 then
    raise exception
      'CLOVEERP_TAX_REPORT_UNRECOGNISED: % already reads the direction from the side', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TAX_REPORT_UNRECOGNISED: % explains its arithmetic % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_sum, ''))) / length(v_old_sum);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TAX_REPORT_UNRECOGNISED: % sums its tax control lines % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_old_sum, v_new_sum);
  execute v_def;
end
$report$;

-- ═════════════════════════════════════════════════════════════════════════════
-- And the case that failed says which arm and which finding
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The other half of issue #246, and the reason it cost four builds. Case 9 of
-- erp_test.invoice_tax_suite() has two independent conjuncts — no finding of
-- the first kind, and this invoice's tax control lines adding to its determined
-- figure — and reported a count of findings of both kinds and nothing at all
-- about the second conjunct. "1 finding(s) in the report" is consistent with
-- three different defects in three different places.
--
-- Patched to name what it found. A check whose failure cannot be read is a
-- check that costs a build every time it is right.

do $detail$
declare
  v_sig constant text := 'erp_test.invoice_tax_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'  detail := format(''%s finding(s) in the report'', (select count(*) from erp.tax_outside_the_ledger_report()));\n';
  v_new constant text :=
       E'  detail := format(''%s finding(s) of a posted document''''s tax not being its journal''''s%s; '' ||\n'
    || E'                   ''this invoice determined %s and its journal carries %s'',\n'
    || E'                   (select count(*) from erp.tax_outside_the_ledger_report() tl\n'
    || E'                     where tl.finding like ''the tax on a posted document%''),\n'
    || E'                   coalesce((select '': '' || string_agg(tl.reference || '' ('' || tl.detail || '')'', ''; '')\n'
    || E'                               from erp.tax_outside_the_ledger_report() tl), ''''),\n'
    || E'                   erp.document_tax_minor(v_inv2),\n'
    || E'                   (select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)\n'
    || E'                      from erp.journal j\n'
    || E'                      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id\n'
    || E'                      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id\n'
    || E'                     where j.tenant_id = v_tenant and j.document_id = v_inv2\n'
    || E'                       and a.control_kind = ''tax''));\n';
  v_hits integer;
begin
  if position('of a posted document' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already names what it found', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % writes its ninth case''s detail % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$detail$;

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
