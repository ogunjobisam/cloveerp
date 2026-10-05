set lock_timeout = '30s';

-- =============================================================================
-- 20261009010000  Order to cash is four steps
-- -----------------------------------------------------------------------------
-- Found designing the folded rail, 4 October (design "rail", change 6). The
-- Sales screen's strip drew six steps for five verbs. Two of the steps kept no
-- list of their own: Pick, which carried Pick the order and made the reader
-- choose again the order already chosen on the Sales order step, and Cash,
-- which only said that money is applied in Financials. Quotation carried Find a
-- price as its raising verb, though finding a price raises nothing.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The order to cash cycle's register row: four actions over four steps,
--      every one of them keeping a list. Pick the order moves onto the Sales
--      order step, which offers it with the order already chosen and only in
--      the states an order is picked in (confirmed, being picked, part
--      despatched). The Pick and Cash steps are gone. Find a price leaves the
--      strip for the Sales screen's Actions sheet, where it is offered as it
--      was, behind sales.price.
--
-- The screen's half is in src/routes/sales/index.tsx and e2e/demo-path.ts.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No door, permission or verb is removed, and nothing that was reachable stops
-- being reachable: Pick the order is on the Sales order step (sales.despatch,
-- as before), Find a price is in the Actions sheet (sales.price, as before),
-- and a quotation's own lines still price themselves through
-- erp_resolve_price. Applying cash stays on Financials' Cash in step, which
-- the Invoice step's Open finance reaches.
--
-- On production: one row of erp_meta.flow_budget is rewritten (budget,
-- decision_steps, stages, stages_without_a_list and rationale). No table is
-- altered and no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Order to cash is four steps
-- ─────────────────────────────────────────────────────────────────────────────

do $budget$
declare
  c_rationale constant text :=
    'The four actions over four steps are what the Sales screen''s strip draws: converting a quotation, '
    'promising a date, picking the order and creating its delivery, the last three on the Sales order step '
    'with the order already chosen (20261009010000). Find a price is in the screen''s Actions sheet, and '
    'applying cash is Financials'' Cash in step. Most of order to cash is reached from the document screen '
    'rather than the strip. The cycle itself is walked by erp_test.step_budget_suite at seven presses by four '
    'people, from a quotation to a filed invoice paid and a closed order, with the six moves nobody pressed '
    'made by what happened (20260924100000).';
  v_row record;
begin
  select b.budget, b.decision_steps, b.stages, b.stages_without_a_list, b.rationale into v_row
    from erp_meta.flow_budget b where b.flow_code = 'o2c';
  if not found then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the order to cash cycle has no budget; 20261009010000 rewrites it';
  end if;
  if strpos(v_row.rationale, '20261009010000') > 0 then
    raise notice 'the order to cash cycle already reads four steps; left as it is';
    return;
  end if;
  if (v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list) <> (5, 5, 6, 2)
     or md5(v_row.rationale) <> 'ae2a970c1cb49404eefd76d3d7f2ccb5' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the order to cash cycle''s budget is not the one 20261009010000 expects (%/%/%/%, md5 %)',
      v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list, md5(v_row.rationale);
  end if;

  -- The budget only goes down.
  update erp_meta.flow_budget
     set budget = 4, decision_steps = 4, stages = 4, stages_without_a_list = 0, rationale = c_rationale
   where flow_code = 'o2c';
end
$budget$;

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
