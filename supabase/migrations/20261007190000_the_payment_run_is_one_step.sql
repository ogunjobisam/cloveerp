set lock_timeout = '30s';

-- =============================================================================
-- 20261007190000  The payment run is one step
-- -----------------------------------------------------------------------------
-- Found designing the folded rail, 4 October (design "rail", change 5). The
-- Finance screen's strip drew a payment run three times: Payment run listed
-- the runs being put together or proposed, Approve listed the proposed ones
-- again, and Pay the approved ones. One run walked across three steps, each a
-- list of the same read narrowed by its status, and the reader had to know
-- which step a run had reached to find it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The money cycle's register row: five steps, not seven. Its nine actions
--      are unchanged, because proposing, approving and paying are still three
--      verbs; they sit on one step, Payment run, which offers each only in the
--      state it takes (draft or proposed, proposed, approved). Journals is
--      still the one step that keeps no list.
--   B. erp_test.cash_documents_screens_suite's first case, which pins that
--      row, reads five steps.
--
-- The screen's half is in src/lib/modules.tsx: the Payment run step lists
-- runs being put together, proposed and approved, and carries Approve and Pay
-- with the states each is offered in; the Approve and Pay steps are gone.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Whoever proposed a run still may not approve it: erp.approve_payment_run
-- refuses them whatever the screen offers. No door, permission or verb is
-- removed, and nothing that was reachable stops being reachable.
--
-- On production: one row of erp_meta.flow_budget is rewritten (stages and
-- rationale) and a test function is replaced. No table is altered and no row
-- of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Money is five steps
-- ─────────────────────────────────────────────────────────────────────────────

do $budget$
declare
  c_rationale constant text :=
    'The nine actions over five steps are what the Finance screen''s strip draws. Proposing, approving and '
    'paying a run are one step, Payment run, which offers each verb only in the state it takes '
    '(20261007190000). The period close is not on the strip, and is walked by erp_test.step_budget_suite at '
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
    raise exception 'CLOVEERP_ANCHOR_MOVED: the money cycle has no budget; 20261007190000 rewrites it';
  end if;
  if strpos(v_row.rationale, '20261007190000') > 0 then
    raise notice 'the money cycle already reads five steps; left as it is';
    return;
  end if;
  if (v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list) <> (9, 9, 7, 1)
     or md5(v_row.rationale) <> '7fd2e66e8d032001712a8507778bc609' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the money cycle''s budget is not the one 20261007190000 expects (%/%/%/%, md5 %)',
      v_row.budget, v_row.decision_steps, v_row.stages, v_row.stages_without_a_list, md5(v_row.rationale);
  end if;

  update erp_meta.flow_budget
     set stages = 5, rationale = c_rationale
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
  v_old  constant text := $o$    case_name := 'the money cycle is nine actions over seven steps with one keeping no list, and the remittance advice waits for no screen';
    passed := v_state is null
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'money' and b.budget = 9 and b.decision_steps = 9
                         and b.stages = 7 and b.stages_without_a_list = 1
$o$;
  v_new  constant text := $n$    -- A payment run is proposed, approved and paid on one step (20261007190000).
    case_name := 'the money cycle is nine actions over five steps with one keeping no list, and the remittance advice waits for no screen';
    passed := v_state is null
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'money' and b.budget = 9 and b.decision_steps = 9
                         and b.stages = 5 and b.stages_without_a_list = 1
$n$;
begin
  if strpos(v_src, '20261007190000') > 0 then
    raise notice '% already reads five steps; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '079666b2f2db87025e1bf6c7c6df0950' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007190000 expects (md5 %)', v_sig, md5(v_src);
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
  '(20261007190000).';

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
