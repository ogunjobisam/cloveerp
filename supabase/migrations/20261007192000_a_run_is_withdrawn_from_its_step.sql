set lock_timeout = '30s';

-- =============================================================================
-- 20261007192000  A run is withdrawn from its step
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-106). Withdrawing a
-- payment run nobody has approved yet arrived on 6 October
-- (20261006041000), behind the Finance screen's Actions, so that the money
-- strip's verbs did not change. Now that a run is proposed, approved and paid
-- on one step (20261007190000), the run being withdrawn is the one chosen on
-- that step, and asking for it again from a list behind Actions is a second
-- way to the same press that knows less.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The money cycle's register row: ten actions, not nine. Withdraw a
--      payment run is the tenth, on the Payment run step, offered on a run
--      being put together or proposed and on nothing else.
--   B. erp_test.cash_documents_screens_suite's first case, which pins that
--      row, reads ten actions.
--
-- The screen's half is in src/lib/modules.tsx: the Payment run step carries
-- Withdraw a payment run, and the Finance screen's Actions no longer list it.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- The door, its permission (finance.approve_payment) and its refusals are as
-- 20261006041000 made them: an approved or paid run cannot be withdrawn, and a
-- withdrawal needs a reason. Its words are already screen strings.
--
-- On production: one row of erp_meta.flow_budget is rewritten (budget,
-- decision steps and rationale) and a test function is replaced. No table is
-- altered and no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Money is ten actions
-- ─────────────────────────────────────────────────────────────────────────────

do $budget$
declare
  c_rationale constant text :=
    'The ten actions over five steps are what the Finance screen''s strip draws. Proposing, approving and '
    'paying a run are one step, Payment run, which offers each verb only in the state it takes '
    '(20261007190000); withdrawing a run nobody has approved yet is the tenth, on the same step '
    '(20261007192000). The period close is not on the strip, and is walked by erp_test.step_budget_suite at '
    'two presses a month, open and close, for every ledger of the company together: opening runs every check '
    'and completes the checklist, closing asks the checks again and closes GL and COMMIT at one moment. A task '
    'that fails its check is one press more, to waive it with a reason (20260929200000). Cash in lists the '
    'receipts Apply cash opens, and adds no verb; Journals is a screen of its own and keeps no list '
    '(20260930300000).';
  v_row record;
begin
  select b.budget, b.decision_steps, b.stages, b.stages_without_a_list, b.rationale into v_row
    from erp_meta.flow_budget b where b.flow_code = 'money';
  if not found then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the money cycle has no budget; 20261007192000 rewrites it';
  end if;
  if strpos(v_row.rationale, '20261007192000') > 0 then
    raise notice 'the money cycle already reads ten actions; left as it is';
    return;
  end if;
  if (v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list) <> (9, 9, 5, 1)
     or md5(v_row.rationale) <> '4b6eb998250980c040d77a8c92c27ec9' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the money cycle''s budget is not the one 20261007192000 expects (%/%/%/%, md5 %)',
      v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list, md5(v_row.rationale);
  end if;

  update erp_meta.flow_budget
     set budget = 10, decision_steps = 10, rationale = c_rationale
   where flow_code = 'money';
end
$budget$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The suite that pins it
-- ─────────────────────────────────────────────────────────────────────────────

do $cash_screens$
declare
  v_sig  constant text := 'erp_test.cash_documents_screens_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    case_name := 'the money cycle is nine actions over five steps with one keeping no list, and the remittance advice waits for no screen';
    passed := v_state is null
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'money' and b.budget = 9 and b.decision_steps = 9
$o$;
  v_new  constant text := $n$    -- Withdrawing a run is the tenth action, on the same step (20261007192000).
    case_name := 'the money cycle is ten actions over five steps with one keeping no list, and the remittance advice waits for no screen';
    passed := v_state is null
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'money' and b.budget = 10 and b.decision_steps = 10
$n$;
begin
  if strpos(v_src, '20261007192000') > 0 then
    raise notice '% already reads ten actions; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a7ea8cc8ca943bcfd8207475e8052e21' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007192000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cash_screens$;

revoke all on function erp_test.cash_documents_screens_suite() from public, anon;

comment on function erp_test.cash_documents_screens_suite() is
  'What the cash documents'' screens read (20260930300000). Apply cash''s rows name the receipt it made, which the '
  'Cash in step lists and whose page reads its number, customer and Posted; paying a run names each supplier''s '
  'payment; a cash document offers no move, and New, Add line and Post are refused by name; the remittance advice '
  'renders for whoever may pay and is refused, and not offered, to somebody who may only read; the strip''s budget '
  'and the door register follow. The strip is five steps since a payment run is proposed, approved and paid on one '
  '(20261007190000), and ten actions since a run is withdrawn there too (20261007192000).';

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
