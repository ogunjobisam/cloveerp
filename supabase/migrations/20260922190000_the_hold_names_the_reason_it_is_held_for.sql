set lock_timeout = '30s';

-- =============================================================================
-- 20260922190000  A payment hold names the reason it is held for
-- -----------------------------------------------------------------------------
-- 20260922160000 made a bill that does not match what was received land in
-- `disputed` rather than `registered`. erp.propose_payment_run() already held
-- such a bill, twice over, and it asks the two questions in this order:
--
--   1. is the document disputed?           → held, reason 'disputed'
--   2. does it carry an unresolved match
--      exception?                          → held, reason 'unresolved match
--                                            exception'
--
-- The second is only asked when the first said nothing. Before 20260922160000
-- an unmatched bill answered no to the first and yes to the second, and the
-- line read "unresolved match exception". Now it answers yes to the first, and
-- the same bill, held for the same reason, reads "disputed" — which is true,
-- and is the less useful of the two true things, because it names the state
-- rather than the cause. The person reading the run learns that somebody
-- disputed it, not that the supplier billed more than was delivered.
--
-- erp_test.finance_depth_suite() said so within minutes of the change landing
-- locally, asserting that the hold reason names the match exception. It was
-- right to.
--
-- ── THE ORDER, REVERSED ──────────────────────────────────────────────────────
--
-- The more specific reason is asked first. A bill disputed because of a
-- difference nobody has accepted says so; a bill disputed for any other reason
-- — a supplier in a row about something the product cannot see — still reads
-- "disputed", because that is all there is to say about it.
--
-- Nothing about what is held changes. The same bills are held, for the same
-- reasons, listed on the run rather than omitted from it — which is the point
-- erp.propose_payment_run() makes in its own comment and which this leaves
-- exactly as it found it: "a payment run that silently omits an invoice is one
-- nobody can reconcile against the ledger".
-- =============================================================================

do $order$
declare
  v_sig constant text := 'erp.propose_payment_run(date, character, interval)';
  v_def text;
  v_old constant text :=
       E'    v_held := null;\n'
    || E'    if r.document_id is not null then\n'
    || E'      select s.code into v_held\n'
    || E'        from erp.object_state os\n'
    || E'        join erp.state s on s.id = os.current_state_id\n'
    || E'       where os.tenant_id = v_tenant and os.object_type = ''document''\n'
    || E'         and os.object_id = r.document_id and s.code = ''disputed'';\n'
    || E'    end if;\n'
    || E'\n'
    || E'    -- An unresolved match exception is a hold too: paying an invoice that does\n'
    || E'    -- not agree with the receipt is exactly what three-way matching is for.\n'
    || E'    if v_held is null and r.document_id is not null\n'
    || E'       and exists (select 1 from erp.match_exception me\n'
    || E'                   where me.tenant_id = v_tenant and me.resolved_at is null\n'
    || E'                     and me.invoice_document_id = r.document_id) then\n'
    || E'      v_held := ''unresolved match exception'';\n'
    || E'    end if;\n';
  v_new constant text :=
       E'    v_held := null;\n'
    || E'\n'
    || E'    -- The cause before the state (20260922190000). An unresolved match\n'
    || E'    -- exception is a hold in its own right: paying an invoice that does not\n'
    || E'    -- agree with the receipt is exactly what three-way matching is for. Since\n'
    || E'    -- 20260922160000 such a bill is also disputed, so asking the state first\n'
    || E'    -- would answer "disputed" to every one of them and never say why.\n'
    || E'    if r.document_id is not null\n'
    || E'       and exists (select 1 from erp.match_exception me\n'
    || E'                   where me.tenant_id = v_tenant and me.resolved_at is null\n'
    || E'                     and me.invoice_document_id = r.document_id) then\n'
    || E'      v_held := ''unresolved match exception'';\n'
    || E'    end if;\n'
    || E'\n'
    || E'    -- And a bill disputed for a reason the product cannot see still reads as\n'
    || E'    -- disputed, because that is all there is to say about it.\n'
    || E'    if v_held is null and r.document_id is not null then\n'
    || E'      select s.code into v_held\n'
    || E'        from erp.object_state os\n'
    || E'        join erp.state s on s.id = os.current_state_id\n'
    || E'       where os.tenant_id = v_tenant and os.object_type = ''document''\n'
    || E'         and os.object_id = r.document_id and s.code = ''disputed'';\n'
    || E'    end if;\n';
  v_hits integer;
begin
  v_def := pg_get_functiondef(v_sig::regprocedure);

  if position('20260922190000' in v_def) > 0 then
    raise exception
      'CLOVEERP_PAYMENT_RUN_UNRECOGNISED: % already asks the cause before the state', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_PAYMENT_RUN_UNRECOGNISED: % decides its hold % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$order$;

-- ═════════════════════════════════════════════════════════════════════════════
-- And the suite holds both answers apart
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.finance_depth_suite() already asserts that a bill with an unresolved
-- exception is held with that reason, and that the run lists it rather than
-- omitting it. Those two are what caught the regression and they are left
-- exactly as they are.
--
-- What is added is the other side: the bill is disputed as well, and being
-- disputed did not swallow the reason. A hold that reads "disputed" for every
-- unmatched bill would pass the first of those two assertions if the reason
-- text ever widened, and this is the case that would not.

do $case$
declare
  v_sig constant text := 'erp_test.finance_depth_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'    return query select ''and it is listed with its reason rather than omitted'',\n';
  v_new constant text :=
       E'    return query select ''and the bill is disputed as well, without that swallowing why'',\n'
    || E'      erp.object_current_state(''document'', v_pinv2) = ''disputed''\n'
    || E'      and (select pl.hold_reason from erp.payment_proposal_line pl\n'
    || E'            where pl.payment_proposal_id = v_prop2 and pl.document_id = v_pinv2)\n'
    || E'          = ''unresolved match exception'',\n'
    || E'      ''the state says it is questioned and the hold says what the question is'';\n'
    || E'\n'
    || E'    return query select ''and it is listed with its reason rather than omitted'',\n';
  v_hits integer;
begin
  if position('without that swallowing why' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already holds both answers apart', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % lists the held line % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$case$;

-- The wrapper pins the case count from outside, and a case was added.

do $pin$
declare
  v_sig constant text := 'erp_test.assert_finance_depth_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := 'c_expected constant integer := 28;';
  v_new constant text := 'c_expected constant integer := 29;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: % pins 28 cases % time(s), not once', v_sig, v_hits
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
