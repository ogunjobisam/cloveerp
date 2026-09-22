set lock_timeout = '30s';

-- =============================================================================
-- 20260922202000  A credit note reverses its tax too
-- -----------------------------------------------------------------------------
-- 20260922180000 read the direction of a document's tax from its trade side and
-- was half right. The build then failed on this, which is the same check with
-- its new detail line doing exactly what that detail line was added for:
--
--   the tax determined on an issued invoice reaches a tax control account, and
--   none is left outside the ledger — 1 finding(s) of a posted document's tax
--   not being its journal's: CN-000001 (5310 was determined and -5310 reached a
--   tax control account on journal none)
--
-- A customer credit note is on the sale side, so the report read its tax
-- control movement as credit less debit. But a credit note debits tax control:
-- it is giving back tax that was charged. So the report saw minus the number it
-- was looking for and called it a disagreement of exactly twice the tax — the
-- same arithmetic the supplier bill produced before 20260922180000, one level
-- down.
--
-- ── WHY IT WAS NOT SEEN ──────────────────────────────────────────────────────
--
-- erp_test.invoice_tax_suite() case 8 seeds a slice of demonstration trading
-- and case 9 runs the report across everything the fixture holds. Whether that
-- slice contains a customer credit note is a property of what the seeder
-- happened to produce on the day, so the defect surfaced on some builds and not
-- others — which is exactly the shape that gets called a flake and re-run.
--
-- So the credit note goes into the fixture deliberately, before the report is
-- read, and it is asserted in its own right. A content-dependent check is not a
-- check.
--
-- ── THE RULE ─────────────────────────────────────────────────────────────────
--
-- Which way tax control moves is two facts, not one:
--
--   the side — a sale charges tax and credits the control account, a purchase
--   suffers it and debits;
--
--   and whether the document is itself a reversal, which flips that.
--
-- The second fact is not guessed here. erp.document_reversal_route() already
-- names the base types that are their own reversal — credit_reference and
-- return_to_supplier — and it is the register erp.assert_every_posting_can_be_
-- undone() holds to what the product does. Reading it means a base type that
-- becomes a reversal later moves this report with it.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The report reads the side and the reversal
-- ═════════════════════════════════════════════════════════════════════════════

do $report$
declare
  v_sig constant text := 'erp.tax_outside_the_ledger_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_note constant text :=
    E'-- months on whichever runs happened to contain a supplier bill with VAT.';
  v_new_note constant text :=
       E'-- months on whichever runs happened to contain a supplier bill with VAT.\n'
    || E'  --\n'
    || E'  -- And the side alone is only half of it (20260922202000). A document that is\n'
    || E'  -- itself a reversal moves tax control the other way: a customer credit note\n'
    || E'  -- is on the sale side and debits the control account, because it is giving\n'
    || E'  -- back tax that was charged. erp.document_reversal_route() is where the\n'
    || E'  -- product already says which base types are their own reversal, so it is\n'
    || E'  -- asked rather than a list being kept here to go stale.';
  v_old_sum constant text :=
       E'coalesce((select sum(case when erp.document_trade_side(doc.id) = ''purchase''\n'
    || E'                                    then jl.debit_minor - jl.credit_minor\n'
    || E'                                    else jl.credit_minor - jl.debit_minor end)';
  v_new_sum constant text :=
       E'coalesce((select sum(case when (erp.document_trade_side(doc.id) = ''purchase'')\n'
    || E'                                      <> exists (select 1\n'
    || E'                                                   from erp.document_type dt\n'
    || E'                                                   join erp.document_reversal_route() r\n'
    || E'                                                     on r.base_type_code = dt.base_type_code\n'
    || E'                                                  where dt.tenant_id = t.tenant_id\n'
    || E'                                                    and dt.id = doc.document_type_id\n'
    || E'                                                    and r.route = ''is_itself_a_reversal'')\n'
    || E'                                    then jl.debit_minor - jl.credit_minor\n'
    || E'                                    else jl.credit_minor - jl.debit_minor end)';
  v_hits integer;
begin
  if position('20260922202000' in v_def) > 0 then
    raise exception 'CLOVEERP_REPORT_UNRECOGNISED: % already reads the reversal', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_note, ''))) / length(v_old_note);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_REPORT_UNRECOGNISED: % carries its direction note % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_sum, ''))) / length(v_old_sum);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_REPORT_UNRECOGNISED: % takes its tax control sum % time(s) by side alone, not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(replace(v_def, v_old_note, v_new_note), v_old_sum, v_new_sum);
end
$report$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the credit note is in the fixture the report is read across
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The new case sits before the report case, so the credit note is part of what
-- the report is asked about rather than a separate reading of it. It asserts
-- the direction in its own right as well: a debit of the tax the credit note
-- determined, not a credit and not nothing.

do $suite$
declare
  v_sig constant text := 'erp_test.invoice_tax_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_dec constant text :=
    E'  v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_pinv uuid;\n';
  v_new_dec constant text :=
       E'  v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_pinv uuid;\n'
    || E'  -- The chain a credit note needs behind it (20260922202000).\n'
    || E'  v_po uuid; v_pol uuid; v_grn uuid;\n'
    || E'  v_so uuid; v_sol uuid; v_dn uuid; v_inv4 uuid; v_ccn uuid;\n'
    || E'  v_cncust uuid;\n';
  v_old_case constant text :=
       E'  v_cases := v_cases + 1;\n'
    || E'  case_name := ''the tax determined on an issued invoice reaches a tax control account, and none is left outside the ledger'';\n';
  v_new_case constant text :=
       E'  -- A credit note reverses the tax as well (20260922202000). Built here\n'
    || E'  -- rather than left to whatever the demonstration slice above happened to\n'
    || E'  -- produce, because a check that only sometimes has a credit note in front\n'
    || E'  -- of it only sometimes checks this.\n'
    || E'  --\n'
    || E'  -- A credit note is raised against a despatch or the invoice that billed one,\n'
    || E'  -- so the goods have to go out before they can come back: ten in on a\n'
    || E'  -- purchase order, ten out on a sales order, and the invoice that bills them.\n'
    || E'  --\n'
    || E'  -- The sale is to a customer of this case''s own, standard-rated because it is\n'
    || E'  -- in the country, and new because the demonstration''s customers carry the\n'
    || E'  -- slice of history seeded above and can be on credit hold for it.\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  insert into erp.party (tenant_id, code, name, country_code, status)\n'
    || E'  values (v_tenant, ''ZZITCN'', ''Invoice tax suite credit customer'', ''GB'', ''active'')\n'
    || E'  returning id into v_cncust;\n'
    || E'  insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)\n'
    || E'  values (v_tenant, v_cncust, ''customer'',\n'
    || E'          jsonb_build_object(''credit_limit_minor'', 100000000), ''active'');\n'
    || E'\n'
    || E'  v_po := erp.open_document(''purchase_order'', v_supplier, v_entity, v_site);\n'
    || E'  v_pol := erp.add_document_line(v_po, v_item, 10, 1000, ''ten for the credit note'');\n'
    || E'  perform erp.transition_document(v_po, ''submit'', ''invoice tax suite'');\n'
    || E'  perform erp_test.approve_document(v_po, ''invoice tax suite'');\n'
    || E'  perform erp.transition_document(v_po, ''send'', ''invoice tax suite'');\n'
    || E'  v_grn := erp.open_document(''goods_receipt'', v_supplier, v_entity, v_site);\n'
    || E'  perform erp.receive_against(v_grn, v_pol, 10, null);\n'
    || E'  perform erp.transition_document(v_grn, ''post'', ''invoice tax suite'');\n'
    || E'\n'
    || E'  v_so := erp.open_document(''sales_order'', v_cncust, v_entity, v_site);\n'
    || E'  v_sol := erp.add_document_line(v_so, v_item, 10, 2500, ''ten for the credit note'');\n'
    || E'  perform erp.transition_document(v_so, ''submit'', ''invoice tax suite'');\n'
    || E'  perform erp_test.approve_document(v_so, ''invoice tax suite'');\n'
    || E'  v_dn := (erp.create_delivery_from_order(v_so) ->> ''document_id'')::uuid;\n'
    || E'  perform erp.transition_document(v_dn, ''post'', ''invoice tax suite'');\n'
    || E'  v_inv4 := erp.invoice_from_delivery(v_dn, true);\n'
    || E'  perform erp.transition_document(v_inv4, ''issue'', ''invoice tax suite'');\n'
    || E'  v_ccn := erp.raise_customer_credit_note(v_inv4, ''damaged'', ''one case crushed in transit'');\n'
    || E'  perform erp.transition_document(v_ccn, ''issue'', ''invoice tax suite'');\n'
    || E'  case_name := ''a credit note gives the tax back, and the ledger is debited for it'';\n'
    || E'  passed := erp.document_tax_minor(v_ccn) > 0\n'
    || E'        and (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)\n'
    || E'               from erp.journal j\n'
    || E'               join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id\n'
    || E'               join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id\n'
    || E'              where j.tenant_id = v_tenant and j.document_id = v_ccn\n'
    || E'                and a.control_kind = ''tax'') = erp.document_tax_minor(v_ccn);\n'
    || E'  detail := format(''the credit note determined %s and its journal debits %s of tax control'',\n'
    || E'                   erp.document_tax_minor(v_ccn),\n'
    || E'                   (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)\n'
    || E'                      from erp.journal j\n'
    || E'                      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id\n'
    || E'                      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id\n'
    || E'                     where j.tenant_id = v_tenant and j.document_id = v_ccn\n'
    || E'                       and a.control_kind = ''tax''));\n'
    || E'  return next;\n'
    || E'\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  case_name := ''the tax determined on an issued invoice reaches a tax control account, and none is left outside the ledger'';\n';
  v_old_pin constant text :=
       E'  if v_cases <> 10 then\n'
    || E'    raise exception ''CLOVEERP_SUITE_SHRANK: invoice_tax_suite ran % cases, expected 10'', v_cases;\n';
  v_new_pin constant text :=
       E'  if v_cases <> 11 then\n'
    || E'    raise exception ''CLOVEERP_SUITE_SHRANK: invoice_tax_suite ran % cases, expected 11'', v_cases;\n';
  v_hits integer;
begin
  if position('20260922202000' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already holds the credit note case', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % declares its invoices % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_case, ''))) / length(v_old_case);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % opens its report case % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_pin, ''))) / length(v_old_pin);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % pins ten cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  execute replace(replace(replace(v_def, v_old_dec, v_new_dec),
                          v_old_case, v_new_case),
                  v_old_pin, v_new_pin);
end
$suite$;

-- The wrapper pins the count from outside, and one case was added.

do $pin$
declare
  v_sig constant text := 'erp_test.assert_invoice_tax_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  if v_all <> 10 then\n'
    || E'    raise exception ''CLOVEERP_SUITE_SHRANK: invoice_tax_suite ran % cases, expected 10'', v_all;\n';
  v_new constant text :=
       E'  if v_all <> 11 then\n'
    || E'    raise exception ''CLOVEERP_SUITE_SHRANK: invoice_tax_suite ran % cases, expected 11'', v_all;\n';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: % pins 10 cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$pin$;

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
