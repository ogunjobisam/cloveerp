-- The warehouse suite promotes finance first.
--
-- erp_test.warehouse_and_finance_jobs_suite (20260914061500) failed once in the
-- build's catalogue (run 35152683802 on PR 163) and passed on an identical
-- re-run of the same commit:
--
--   at "the modules the base pack presupposes are installed and promoted":
--   CLOVEERP_PROMOTION_BREAKS_DETERMINATION: sales-lifecycle introduces a way
--   for a posting to fail
--
-- Organisation A installs seven modules inside the suite's one transaction and
-- then promotes every ready change set "order by cs.created_at". created_at
-- defaults to now(), the transaction's timestamp, so all seven carry the same
-- value and the sort has nothing to decide. It gives back rows with equal keys
-- in the order the scan found them, which follows where the row versions
-- written by erp.submit_change_set() happen to sit in erp.change_set's heap:
-- wherever free space was, after everything the build did to that table
-- before, and after however far vacuum had got. So the order moved between runs.
--
-- The promoter's determination check is a delta, and the delta does not make
-- the order free. finance-posting carries the posting rules sales_commitment,
-- delivery and sales_invoice; sales-lifecycle carries the document types
-- sales_order, delivery and sales_invoice, which reach the ledger and name those
-- rules. Promoted before finance-posting, sales-lifecycle adds three findings
-- erp.determination_coverage_report() did not return a moment earlier (a
-- document type names a posting rule with no version in force) and the whole
-- promotion is refused. Promoted after it, it adds none. Nothing else in the
-- seven depends on order that way: the accounts are written by
-- erp.configure_finance() directly and every rule's version starts on
-- current_date, which the report reads too. procurement-lifecycle names
-- purchase_commitment and goods_receipt the same way, so it fails the same way
-- whenever it comes before finance-posting, and inventory-operations restates
-- goods_receipt and delivery, so it belongs after finance-posting as well.
--
-- Two changes to the suite's body, each a counted replacement:
--
--   1. The loop promotes in the order the installers ran, named: finance-posting,
--      then the modules whose document types name its rules, then the rest. A
--      change set the list does not name goes after the named ones, by code, so
--      the order is decided either way.
--   2. Both organisations' exception handlers carry the refusal's DETAIL into the
--      case. The promoter puts the new findings in DETAIL, and left(sqlerrm, 240)
--      kept only the message, so the build log said that a promotion was refused
--      and not what it would have broken.
--
-- Twenty-one cases before and after.

do $suite$
declare
  v_sig  text := 'erp_test.warehouse_and_finance_jobs_suite()';
  v_def  text := pg_get_functiondef('erp_test.warehouse_and_finance_jobs_suite()'::regprocedure);
  v_after text;

  v_decl_old text := $n$  v_state_a  text;
$n$;
  v_decl_new text := $r$  v_state_a  text;
  v_why      text;   -- a refusal's DETAIL, carried into the case (20260916610000)
$r$;

  v_loop_old text := $n$    for c in select cs.id from erp.change_set cs
              where cs.tenant_id = ra.tenant_id and cs.status = 'ready'
              order by cs.created_at loop
$n$;
  v_loop_new text := $r$    -- The installers' own order, named (20260916610000). The seven share one
    -- created_at, and a module promoted before finance-posting names posting
    -- rules not yet in force, which the promoter refuses.
    for c in select cs.id from erp.change_set cs
              where cs.tenant_id = ra.tenant_id and cs.status = 'ready'
              order by array_position(array['finance-posting', 'procurement-lifecycle', 'sales-lifecycle',
                                            'inventory-operations', 'quality', 'logistics', 'period-close'],
                                      cs.code) nulls last,
                       cs.code loop
$r$;

  v_a_old text := $n$      v_state_a := format('at "%s": %s', v_step, left(sqlerrm, 240));
$n$;
  v_a_new text := $r$      get stacked diagnostics v_why = pg_exception_detail;
      v_state_a := format('at "%s": %s', v_step, left(sqlerrm, 240))
                   || coalesce(' — detail: ' || nullif(regexp_replace(btrim(v_why, E' \n'), '\s*\n\s*', '; ', 'g'), ''), '');
$r$;

  v_b_old text := $n$      v_state_b := format('at "%s": %s', v_step, left(sqlerrm, 240));
$n$;
  v_b_new text := $r$      get stacked diagnostics v_why = pg_exception_detail;
      v_state_b := format('at "%s": %s', v_step, left(sqlerrm, 240))
                   || coalesce(' — detail: ' || nullif(regexp_replace(btrim(v_why, E' \n'), '\s*\n\s*', '; ', 'g'), ''), '');
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_decl_old, ''))) / length(v_decl_old) <> 1
     or (length(v_def) - length(replace(v_def, v_loop_old, ''))) / length(v_loop_old) <> 1
     or (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1
     or position('pg_exception_detail' in v_def) > 0
     or position('array_position(' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body this migration patches', v_sig
      using hint = 'Each needle must occur exactly once. A later migration changed the suite: read its body with pg_get_functiondef and patch that.';
  end if;

  execute replace(replace(replace(replace(v_def,
    v_decl_old, v_decl_new),
    v_loop_old, v_loop_new),
    v_a_old, v_a_new),
    v_b_old, v_b_new);

  v_after := pg_get_functiondef(v_sig::regprocedure);
  if position(v_loop_old in v_after) > 0
     or (length(v_after) - length(replace(v_after, v_loop_new, ''))) / length(v_loop_new) <> 1
     or (length(v_after) - length(replace(v_after, 'get stacked diagnostics v_why = pg_exception_detail;', '')))
          / length('get stacked diagnostics v_why = pg_exception_detail;') <> 2 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without its named order and both handlers'' detail', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needles above.';
  end if;
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_warehouse_and_finance_jobs_suite();

select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
