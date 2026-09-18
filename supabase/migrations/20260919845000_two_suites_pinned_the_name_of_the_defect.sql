-- =============================================================================
-- Two suites pinned the name of the defect
--
-- 20260919840000 gave erp.configure_tax() the five treatments a United Kingdom
-- business needs and replaced its second rule — `supply_type == 'domestic'`,
-- a positive determination that read as a default — with a residual that is
-- named as one. The build refused at "Every check in the catalogue" with two
-- suites red and everything else green:
--
--   erp_test.finance_depth_suite   26/28
--     "tax rules install as promoted configuration"
--     "a determination records the rule that decided and what it saw"
--   erp_test.invoice_tax_suite      9/10
--     "every line of a newly issued invoice gets a determination, and the line
--      carries the code, the rate and the tax"
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHICH CASE MOVED, AND FROM WHAT TO WHAT
--
-- Not one rate and not one tax code. What moved is the NAME OF THE RULE that
-- produced the same answer, and those three cases pinned the name.
--
-- The proof is structural rather than a reading of the log, because a reading
-- of the log would only say these three cases and not why:
--
--   * erp.determine_tax() computes supply_type as exactly one of 'domestic' or
--     'export'. Under the old rule set every supply therefore matched rule 10
--     or rule 20 and nothing else could happen.
--
--   * Rule 10 is unchanged in its condition, its code and its rate: export,
--     'Z', nil. The only difference is a treatment key in its outcome, which
--     is written to a column that did not exist until yesterday.
--
--   * Rules 20 to 60 read tax_class. That column was added by 20260919840000
--     and is null on every row that existed before it, and erp.determine_tax()
--     supplies 'unstated' where it is null. None of those five conditions can
--     match anything that existed.
--
--   * Rule 99 therefore fires on exactly the supplies old rule 20 fired on —
--     every supply that is not an export — and emits the same code 'S' at the
--     same p_standard_rate.
--
-- So for every supply in existence at the moment that migration applies, the
-- tax code and the rate are arithmetically identical. erp.document_line
-- .tax_minor is identical, erp.document_tax_minor() is identical, and the
-- document_tax posting basis and therefore every journal are identical. The
-- seeded demonstration month does not move by a penny, which is also what the
-- build said: it seeded the demonstration and every reconciliation over it
-- passed, and the only three red cases in the catalogue are the three that
-- name a rule rather than a figure.
--
-- Each of the three keeps every figure it pinned. Not one is relaxed:
--
--   finance_depth  rate_pct = 20                     kept
--                  facts carry supply_type            kept
--                  rule_code 'domestic_standard'  →  'residual_standard_rated'
--                                                 +  treatment 'standard'
--                                                 +  the facts say the tax
--                                                    class was 'unstated'
--   finance_depth  two rules installed             →  seven
--   invoice_tax    net 130000, tax 26000            kept
--                  two lines at code S and 20%      kept
--                  two determinations               kept
--                  jurisdiction GB                  kept
--                  rule_code 'domestic_standard'  →  'residual_standard_rated'
--                                                 +  treatment 'standard'
--
-- Two of the three end up asserting strictly more than they did: that the
-- twenty per cent on a supply nobody classified was reached as a DEFAULT, and
-- that the determination records which. That is the distinction the old rule
-- code could not make and the whole reason the rule was replaced.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THE BEHAVIOUR CHANGE, WRITTEN DOWN RATHER THAN ABSORBED
--
-- A supply that nobody has classified for tax is charged the standard rate as
-- before. What changes, from the date this lands:
--
--   1. erp.tax_determination.rule_code says 'residual_standard_rated' where it
--      used to say 'domestic_standard', and the facts it recorded carry
--      "tax_class": "unstated". A person reading a determination can now tell
--      a default from a decision. Nothing reports on rule_code, so no figure
--      anybody has seen changes.
--
--   2. erp.tax_determination.treatment is 'standard' on those rows and null on
--      every row written before. erp.tax_report() groups by treatment, so on a
--      live organisation a period spanning this migration shows two rows at the
--      same code and the same rate — one with a treatment and one without —
--      whose TOTAL is unchanged. Nothing is restated to close that seam: the
--      historical rows are what they were when they were written, and the brief
--      for this work was explicit that posted history is not rewritten. A
--      period entirely before or entirely after shows one row as it always did.
--
-- Whether an organisation wants those two rows merged is a question about its
-- own past, and the answer is a decision for its accountant rather than a
-- silent update from a migration.
--
-- The suite bodies are needle-patched. erp_test.finance_depth_suite() has been
-- patched by 20260914062000 (twice) and 20260918400000 (twice); erp_test
-- .invoice_tax_suite() by 20260916090000. None of those touched the three
-- regions below, and each anchor is asserted to occur exactly once before
-- anything is replaced.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The installer no longer installs two rules
-- ═════════════════════════════════════════════════════════════════════════════

do $rule_count$
declare
  v_sig constant text := 'erp_test.finance_depth_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'      where rs.tenant_id = r.tenant_id and rs.decision_point_code = ''tax.determination'') = 2,\n'
    || E'    ''export zero-rated first, domestic standard second'';';
  v_new constant text :=
       E'      where rs.tenant_id = r.tenant_id and rs.decision_point_code = ''tax.determination'') = 7,\n'
    || E'    ''export first, the five treatments a product can state, and the residual last'';';
begin
  if position(v_new in v_def) > 0 then
    raise exception
      'CLOVEERP_FINANCE_DEPTH_SUITE_ALREADY_RESTATED: % already counts seven rules', v_sig
      using hint = 'Nothing to do. Check what previously applied this and remove the duplicate migration.';
  end if;

  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_FINANCE_DEPTH_SUITE_UNRECOGNISED: the rule-count case in % is not the one this migration restates', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$rule_count$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the rule that decided a supply nobody classified is the residual
--
-- The rate it pinned stays at twenty. What is added is that the record now
-- distinguishes the default from the decision, which the old rule code could
-- not do and which is the reason it was replaced.
-- ═════════════════════════════════════════════════════════════════════════════

do $rule_code$
declare
  v_sig constant text := 'erp_test.finance_depth_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'      and (select td.rule_code from erp.tax_determination td where td.id = v_td)\n'
    || E'          = ''domestic_standard''\n'
    || E'      and (select td.determination_inputs ? ''supply_type''\n'
    || E'             from erp.tax_determination td where td.id = v_td),';
  v_new constant text :=
       E'      and (select td.rule_code from erp.tax_determination td where td.id = v_td)\n'
    || E'          = ''residual_standard_rated''\n'
    || E'      and (select td.treatment from erp.tax_determination td where td.id = v_td)\n'
    || E'          = ''standard''\n'
    || E'      and (select td.determination_inputs ->> ''tax_class''\n'
    || E'             from erp.tax_determination td where td.id = v_td) = ''unstated''\n'
    || E'      and (select td.determination_inputs ? ''supply_type''\n'
    || E'             from erp.tax_determination td where td.id = v_td),';
begin
  if position('residual_standard_rated' in v_def) > 0 then
    raise exception
      'CLOVEERP_FINANCE_DEPTH_SUITE_ALREADY_RESTATED: % already expects the residual', v_sig
      using hint = 'Nothing to do. Check what previously applied this and remove the duplicate migration.';
  end if;

  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_FINANCE_DEPTH_SUITE_UNRECOGNISED: the determination case in % is not the one this migration restates', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  execute replace(v_def, v_old, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('''residual_standard_rated''' in v_def) = 0
     or position('= 20' in v_def) = 0
  then
    raise exception
      'CLOVEERP_FINANCE_DEPTH_SUITE_LOST_ITS_CASE: % was re-emitted without the case this migration restates, or without the rate it still pins', v_sig
      using hint = 'Do not proceed: a suite that stopped checking the rate is a suite that would not notice one moving.';
  end if;
end
$rule_code$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The same, on the invoice the lifecycle determines
--
-- Every figure this case pinned is kept exactly: two determinations, net
-- 130000, tax 26000, two lines at code S and twenty per cent, jurisdiction GB.
-- Those are the numbers that prove the change moved no rate, so they are the
-- last thing that should be touched.
-- ═════════════════════════════════════════════════════════════════════════════

do $invoice_tax$
declare
  v_sig constant text := 'erp_test.invoice_tax_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'        and (select count(*) from erp.tax_determination td\n'
    || E'              where td.document_id = v_inv2 and td.rule_code = ''domestic_standard''\n'
    || E'                and td.jurisdiction = ''GB'') = 2;';
  v_new constant text :=
       E'        and (select count(*) from erp.tax_determination td\n'
    || E'              where td.document_id = v_inv2 and td.rule_code = ''residual_standard_rated''\n'
    || E'                and td.treatment = ''standard''\n'
    || E'                and td.jurisdiction = ''GB'') = 2;';
begin
  if position('residual_standard_rated' in v_def) > 0 then
    raise exception
      'CLOVEERP_INVOICE_TAX_SUITE_ALREADY_RESTATED: % already expects the residual', v_sig
      using hint = 'Nothing to do. Check what previously applied this and remove the duplicate migration.';
  end if;

  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_INVOICE_TAX_SUITE_UNRECOGNISED: the determination case in % is not the one this migration restates', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  execute replace(v_def, v_old, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('v_net = 130000 and v_tax = 26000' in v_def) = 0
     or position('l.tax_code = ''S'' and l.tax_rate_pct = 20' in v_def) = 0
     or position('''residual_standard_rated''' in v_def) = 0
  then
    raise exception
      'CLOVEERP_INVOICE_TAX_SUITE_LOST_ITS_FIGURES: % was re-emitted without the net, the tax, the code and the rate it pins', v_sig
      using hint = 'Do not proceed: those four figures are the evidence that replacing the rule moved no rate, and a case that stopped checking them proves nothing.';
  end if;
end
$invoice_tax$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
--
-- Both restated suites are run here rather than left to the catalogue, so a
-- restatement that does not hold refuses inside its own transaction.
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp_test.assert_finance_depth_suite();
select erp_test.assert_invoice_tax_suite();
