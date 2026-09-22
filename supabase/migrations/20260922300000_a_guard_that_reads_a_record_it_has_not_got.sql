set lock_timeout = '30s';

-- =============================================================================
-- 20260922300000  A guard that reads a record it has not got
-- -----------------------------------------------------------------------------
-- Running every check in the catalogue against a database built and seeded the
-- way the build does it found one failure in 334, and it is W2's:
--
--   FAIL erp_test.assert_purchase_pricing_suite
--   CLOVEERP_PURCHASE_PRICING_SUITE_SHRANK: 10 case(s), expected 13
--   ... the suite ran to its end — record "m" is not assigned yet
--
-- 20260922210000 appended this to erp.price_document_line():
--
--   if v_base not in (''purchase_order'', ''requisition'', ''return_to_supplier'')
--      and not m.within_policy then
--
-- and wrote a comment above it saying the guard was on v_base rather than on m
-- BECAUSE a record that was never selected into raises when a field is read.
-- The diagnosis was right and the remedy did not follow from it. PL/pgSQL does
-- not short-circuit that AND: the whole condition is one SQL expression, and
-- m.within_policy is read to bind it as a parameter before any of it is
-- evaluated. Two lines prove it:
--
--   do $$ declare m record; v text := ''a'';
--   begin if v not in (''a'') and not m.x then end if; end $$;
--   ERROR:  record "m" is not assigned yet
--   CONTEXT:  SQL expression "v not in (''a'') and not m.x"
--
-- erp.check_margin() is called only in the sales arm, so on a purchase line the
-- record is never assigned and the guard raised every time — which is to say
-- the node broke purchase pricing outright.
--
-- The remedy is the one the comment described: reach the record only when there
-- is one. Two nested IFs, because each IF condition is its own expression and
-- is evaluated only when reached. The comment is rewritten with it, since a
-- comment asserting something false about the language is worse than no comment.
--
-- ── AND THE CASE THAT DID NOT CATCH IT ──────────────────────────────────────
--
-- erp_test.margin_floor_suite() case 5 prices a purchase line and asserts that
-- nobody was asked about margin. Its whole claim was a count of nought — and
-- nought is also what a line taking the SALES arm produces, so the case could
-- not tell the two apart and would have passed either way.
--
-- It now asserts the price as well: 800, the supplier purchase list the fixture
-- seeds, which only the purchase arm resolves. The case now fails if the line
-- goes the other way, whatever the request count says.
--
-- One thing is deliberately not explained here, because it is not understood.
-- That case calls erp.price_document_line() on a purchase line, which is the
-- call that raised in erp_test.purchase_pricing_suite(), and it did NOT raise —
-- verified by putting the conjoined guard back and running it, where it passed
-- and reported the 800 that proves it took the purchase arm. So the two suites
-- reach the same arm of the same function through the same call and only one of
-- them raises, and this migration does not know why. What is established is
-- that the conjoined form raises on an unassigned record, that the purchase
-- suite hit it, that nesting fixes it, and that both suites pass afterwards. A
-- guess dressed as a reason would be worth less than saying so.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The guard reaches the record only when there is one
-- ═════════════════════════════════════════════════════════════════════════════

do $guard$
declare
  v_sig constant text := 'erp.price_document_line(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  -- Guarded on v_base, not on m. erp.check_margin() is not called on the\n'
    || E'  -- purchase branch, and a record that was never selected into raises when a\n'
    || E'  -- field is read rather than reading as null. There is no margin on a price\n'
    || E'  -- we pay.\n'
    || E'  if v_base not in (''purchase_order'', ''requisition'', ''return_to_supplier'')\n'
    || E'     and not m.within_policy then\n';
  v_new constant text :=
       E'  -- Nested, not conjoined (20260922300000). erp.check_margin() is called only\n'
    || E'  -- in the sales arm, so on a purchase line m was never selected into, and a\n'
    || E'  -- record in that state raises when a field is read. PL/pgSQL does not\n'
    || E'  -- short-circuit AND — the whole condition is one SQL expression and\n'
    || E'  -- m.within_policy is read to bind it before any of it runs — so the outer\n'
    || E'  -- test has to be its own IF. There is no margin on a price we pay.\n'
    || E'  if v_base not in (''purchase_order'', ''requisition'', ''return_to_supplier'') then\n'
    || E'  if not m.within_policy then\n';
  v_tail_old constant text :=
       E'      1, d.entity_id, d.site_id);\n'
    || E'  end if;\n';
  v_tail_new constant text :=
       E'      1, d.entity_id, d.site_id);\n'
    || E'  end if;\n'
    || E'  end if;\n';
  v_hits integer;
begin
  if position('20260922300000' in v_def) > 0 then
    raise exception 'CLOVEERP_MARGIN_GUARD_UNRECOGNISED: % already reaches the record only when there is one', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_MARGIN_GUARD_UNRECOGNISED: % conjoins its margin guard % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_tail_old, ''))) / length(v_tail_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_MARGIN_GUARD_UNRECOGNISED: % closes its approval request % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(replace(v_def, v_old, v_new), v_tail_old, v_tail_new);
end
$guard$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the case says which arm it took
-- ═════════════════════════════════════════════════════════════════════════════

do $case$
declare
  v_sig constant text := 'erp_test.margin_floor_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  case_name := ''a purchase line asks nobody about margin, because there is none on a price we pay'';\n'
    || E'  passed := v_n_buy = 0;\n'
    || E'  detail := format(''%s request(s) on a purchase line'', v_n_buy);\n';
  v_new constant text :=
       E'  case_name := ''a purchase line asks nobody about margin, because there is none on a price we pay'';\n'
    || E'  -- The price as well as the count (20260922300000). A count of nought is\n'
    || E'  -- what a line that took the SALES arm produces too, so this case passed\n'
    || E'  -- against a guard that was raising on every purchase line. 800 is the\n'
    || E'  -- supplier purchase list this fixture seeds, and only the purchase arm\n'
    || E'  -- resolves it.\n'
    || E'  passed := v_n_buy = 0\n'
    || E'        and (select l.unit_price_minor from erp.document_line l\n'
    || E'              where l.id = v_l_buy) = 800;\n'
    || E'  detail := format(''%s request(s) on a purchase line, priced at %s from the supplier list'',\n'
    || E'                   v_n_buy,\n'
    || E'                   (select l.unit_price_minor from erp.document_line l where l.id = v_l_buy));\n';
  v_hits integer;
begin
  if position('20260922300000' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already says which arm it took', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % asserts its purchase case % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$case$;

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
