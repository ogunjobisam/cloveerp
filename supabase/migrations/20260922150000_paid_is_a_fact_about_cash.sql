set lock_timeout = '30s';

-- =============================================================================
-- 20260922150000  Paid is a fact about cash, not a button
-- -----------------------------------------------------------------------------
-- `settle` on sales_invoice (20260829220000_finance_posting.sql:1577) and `pay`
-- on purchase_invoice (20260910094351:119) were written when somebody marked a
-- document paid by hand. 20260919200000 made settlement derived:
-- erp.apply_cash() and erp.pay_payment_run() both call
-- erp.settle_paid_document(), which reads what is owed from erp.ageing_balance
-- and moves the document only when that is nil.
--
-- The transitions survived. erp.available_transitions() still offers them, so
-- the desk still draws the button, and erp.transition_document() still performs
-- it — on a document owing nine hundred pounds as readily as on one owing
-- nothing. A screen that says Paid about an invoice nobody has paid is worse
-- than a screen that says nothing: the ageing still carries it, the receivables
-- report still carries it, and the only thing that has changed is that the
-- person reading the document believes otherwise.
--
-- ── WHY NOT REMOVE THEM ──────────────────────────────────────────────────────
--
-- The node as planned said remove both from the machines. They cannot be
-- removed. erp.settle_paid_document() does not name the move; it reads it out
-- of the lifecycle (20260919200000:280):
--
--   select t.transition_code, t.permitted, t.guard_passes
--     into v_code, v_permitted, v_guard
--     from erp.available_transitions('document', p_document_id) t
--    where t.transition_code in ('settle', 'pay')
--
-- deliberately, so that an organisation which promoted its own lifecycle is
-- answered by its own. Take `settle` out of the machine and settlement stops
-- working altogether — the derived path loses the move it performs, and every
-- invoice stays issued for ever. That is the defect 20260919200000 fixed,
-- reintroduced by the migration meant to tidy up after it.
--
-- So the transition stays declared and what is removed is the ability to assert
-- it by hand. The guard is in erp.transition_document(), which is the one place
-- every route to a state change passes through — the desk, the doors and the
-- seeder alike. Hiding the button would have been convenience; this is the
-- enforcement.
--
-- ── WHAT IS AND IS NOT REFUSED ───────────────────────────────────────────────
--
-- Refused: a settle or a pay on a document that has receivable or payable
-- detail and still carries a row on erp.ageing_balance. That is the same pair
-- of tests erp.settle_paid_document() makes before it moves anything, asked in
-- the same order and of the same two tables, so the derived path and the guard
-- cannot disagree about what "owes nothing" means.
--
-- Not refused: a document with no subledger detail at all. It owes nothing
-- because nothing was ever posted for it, which is not the same as having been
-- paid — erp.settle_paid_document() says so in those words and declines to move
-- it. Whether such a document should be settleable by hand is a separate
-- question about documents that never reached a ledger, and this node does not
-- answer it.
--
-- erp.ageing_balance carries a row only where what is owed is not zero, so a
-- row is a penny still outstanding and there is no tolerance in the test.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The guard
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Before the guard context is built and before the move is attempted, so the
-- answer is the money rather than a permission or a missing transition.

do $guard$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_new constant text :=
       E'  -- Paid is a fact about cash, not a button (20260922150000). settle and\n'
    || E'  -- pay stay declared by the lifecycle, because erp.settle_paid_document()\n'
    || E'  -- reads the move out of the machine rather than naming it, and performs\n'
    || E'  -- it when the cash has left nothing owing. What cannot be done is to\n'
    || E'  -- assert it by hand over a document that still owes money.\n'
    || E'  --\n'
    || E'  -- The same two tests erp.settle_paid_document() makes, of the same two\n'
    || E'  -- tables, in the same order, so the derived route and this guard cannot\n'
    || E'  -- disagree about what owing nothing means. A document with no subledger\n'
    || E'  -- detail is left alone: it owes nothing because nothing was posted for\n'
    || E'  -- it, which is not the same as having been paid.\n'
    || E'  if p_transition_code in (''settle'', ''pay'')\n'
    || E'     and exists (select 1 from erp.subledger_item si\n'
    || E'                  where si.tenant_id = v_tenant and si.document_id = p_document_id\n'
    || E'                    and si.control_kind in (''receivable'', ''payable''))\n'
    || E'     and exists (select 1 from erp.ageing_balance b\n'
    || E'                  where b.tenant_id = v_tenant and b.document_id = p_document_id)\n'
    || E'  then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_DOCUMENT_STILL_OWES: % still owes %, so it cannot be marked paid (%)'',\n'
    || E'      coalesce(d.document_number, p_document_id::text),\n'
    || E'      (select sum(b.outstanding_minor) from erp.ageing_balance b\n'
    || E'        where b.tenant_id = v_tenant and b.document_id = p_document_id),\n'
    || E'      p_transition_code\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Apply the cash against it. A document is settled by the '' ||\n'
    || E'                   ''money reaching it, and moves itself when nothing is left owing.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_hits integer;
begin
  if position('CLOVEERP_DOCUMENT_STILL_OWES' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % already refuses a settle over money owed; '
      'this migration would add the guard twice', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % builds its guard context % time(s), not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$guard$;

select erp.register_refusal('CLOVEERP_DOCUMENT_STILL_OWES',
  'Marking an invoice or a bill paid while money is still owed on it.',
  'Paid is what the ledger says after the money has arrived, not a label somebody puts on a document. An invoice still carrying a balance appears on the ageing, on the receivables screen and on the statement the customer is sent, and marking it paid changes none of those — it only means the person reading the document is told something the ledger contradicts.',
  'Apply the cash against it: receive it from the customer, or pay it in a payment run. A document settles itself the moment nothing is left owing on it. If the balance will never be collected, write it off rather than calling it paid.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the suite says so, where the penny short already lives
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.cash_settlement_suite() already raises an invoice and pays all but
-- one penny of it, and already asserts that it is still issued. Two cases are
-- appended at that exact point rather than in a fixture of their own: the
-- invoice this node is about is already standing there, one penny short, and a
-- second fixture would be a second place for it to drift.
--
-- The second of the two is the one that keeps this node honest. Removing the
-- transitions instead of guarding them would pass the first case — nothing
-- would settle the document, because nothing could — and fail the second.

do $suite$
declare
  v_sig constant text := 'erp_test.cash_settlement_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'    -- ── 5. And the penny pays it ────────────────────────────────────────────\n';
  v_new constant text :=
       E'    -- ── 4a. And it cannot be called paid by hand ────────────────────────────\n'
    || E'    -- The button the desk used to draw over a document owing money\n'
    || E'    -- (20260922150000). The refusal is asked for here as a refusal, not as a\n'
    || E'    -- missing transition, because the move has to stay in the machine.\n'
    || E'    v_step := ''settling an invoice a penny short, by hand'';\n'
    || E'    v_t1 := null;\n'
    || E'    begin\n'
    || E'      perform erp.transition_document(v_inv2, ''settle'', ''marked paid by hand'');\n'
    || E'    exception when others then v_t1 := sqlerrm; end;\n'
    || E'\n'
    || E'    v_cases := v_cases + 1;\n'
    || E'    case_name := ''and it cannot be marked paid by hand while the penny is owed'';\n'
    || E'    passed := v_state is null\n'
    || E'          and v_t1 like ''CLOVEERP_DOCUMENT_STILL_OWES%''\n'
    || E'          and erp.object_current_state(''document'', v_inv2) = ''issued'';\n'
    || E'    detail := coalesce(v_state, format(''%s; the invoice is %s'',\n'
    || E'      left(coalesce(v_t1, ''it was marked paid''), 90),\n'
    || E'      erp.object_current_state(''document'', v_inv2)));\n'
    || E'    return next;\n'
    || E'\n'
    || E'    -- ── 4b. And the move is still there for the cash to make ───────────────\n'
    || E'    -- erp.settle_paid_document() reads the move out of the lifecycle rather\n'
    || E'    -- than naming it, so removing settle from the machine would stop\n'
    || E'    -- settlement altogether. This is the case that refuses that fix.\n'
    || E'    v_cases := v_cases + 1;\n'
    || E'    case_name := ''and the move is still declared by the lifecycle, because the cash is what performs it'';\n'
    || E'    passed := v_state is null\n'
    || E'          and exists (select 1 from erp.available_transitions(''document'', v_inv2) t\n'
    || E'                       where t.transition_code = ''settle'');\n'
    || E'    detail := coalesce(v_state, format(''the lifecycle offers %s from issued'',\n'
    || E'      coalesce((select string_agg(t.transition_code, '', '' order by t.transition_code)\n'
    || E'                  from erp.available_transitions(''document'', v_inv2) t), ''nothing'')));\n'
    || E'    return next;\n'
    || E'\n'
    || E'    -- ── 5. And the penny pays it ────────────────────────────────────────────\n';
  v_hits integer;
begin
  if position('CLOVEERP_DOCUMENT_STILL_OWES' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already holds the by-hand cases', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % marks its fifth case % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_old, v_new);

  -- The suite pins its own count, in its own body. Two cases were added.
  v_hits := (length(v_def) - length(replace(v_def, 'c_expected constant integer := 10;', '')))
            / length('c_expected constant integer := 10;');
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % pins 10 cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  execute replace(v_def, 'c_expected constant integer := 10;',
                         'c_expected constant integer := 12;');
end
$suite$;

-- And the wrapper, which pins the same number from outside.

do $pin$
declare
  v_sig constant text := 'erp_test.assert_cash_settlement_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, 'c_expected constant integer := 10;', '')))
            / length('c_expected constant integer := 10;');
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: % pins 10 cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on what it says now.';
  end if;

  execute replace(v_def, 'c_expected constant integer := 10;',
                         'c_expected constant integer := 12;');
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
