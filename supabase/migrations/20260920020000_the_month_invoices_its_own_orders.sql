-- =============================================================================
-- The month invoices its own orders
--
-- 20260919900000 took the hand-driven move out of erp.seed_demo_history():
--
--     perform erp.transition_document(v_inv, 'issue', 'demonstration');
--     perform erp.transition_document(v_doc, 'invoice', 'demonstration');   ← gone
--
-- because issuing the invoice now moves the order itself, the way the product
-- does it. That is the right change and it leaves a hole behind it. Nothing in
-- the build can tell the difference between "the mechanism fired" and "the
-- mechanism did nothing and the order stayed in Despatched", because
-- erp_test.demo_history_suite() has always allowed a demonstration sales order
-- to read any of
--
--     cancelled, pending_approval, confirmed, despatched, invoiced, closed
--
-- and Despatched is on that list. So a silent regression in
-- erp.advance_orders_for_invoice() — a permission, a guard, a relation written
-- the other way round, anything its exception handler swallows into an event —
-- would leave every order in the demonstration month sitting one move short of
-- where it belongs, and every build would stay green. That is the shape of the
-- defect the whole of 20260919900000 exists to remove, so leaving one behind in
-- the same file's wake is not on.
--
-- One conjunct on the case that already reads the month: a demonstration sales
-- order whose history carries the `invoice` move, made for the reason the
-- mechanism gives it. The reason is the point. A state could have been reached
-- by anything, including another hand-driven call somebody adds later; only
-- "Invoiced in full by INV-000123" says that erp.advance_orders_for_invoice()
-- is what moved it.
--
-- The history rather than the state, too, because the month closes about seven
-- in ten of the orders whose invoice is paid, and a closed order does not read
-- Invoiced any more. erp.state_transition_log is append-only, so the move is
-- still there after the order moves on.
--
-- No case is added, so the suite's count is untouched and its two pinned
-- figures stay where they are. This widens one verdict that is already counted.
-- =============================================================================

do $cases$
declare
  v_sig  constant text := 'erp_test.demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.demo_history_suite()'::regprocedure);
  v_n    constant text := $p$    and exists (select 1 from erp.document x join erp.document_type dt on dt.id = x.document_type_id
                 where x.tenant_id = v_tenant and dt.code = 'sales_invoice'
                   and erp.object_current_state('document', x.id) = 'paid')
$p$;
  v_r    constant text := $q$    and exists (select 1 from erp.document x join erp.document_type dt on dt.id = x.document_type_id
                 where x.tenant_id = v_tenant and dt.code = 'sales_invoice'
                   and erp.object_current_state('document', x.id) = 'paid')
    -- The order the month invoiced, and what moved it (20260919950000). The
    -- seeder stopped driving this by hand in 20260919900000; without this the
    -- mechanism could stop firing and every build would stay green, because
    -- Despatched is on the list of states a demonstration order may read.
    and exists (select 1 from erp.document x
                  join erp.document_type dt on dt.id = x.document_type_id
                  join erp.state_transition_log l
                    on l.tenant_id = x.tenant_id and l.object_type = 'document'
                   and l.object_id = x.id and l.transition_code = 'invoice'
                 where x.tenant_id = v_tenant and dt.code = 'sales_order'
                   and x.their_reference like 'DEMO-%'
                   and l.reason like 'Invoiced in full by %')
$q$;
  v_hits integer;
begin
  if position('Invoiced in full by ' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_SUITE_UNRECOGNISED: % already reads the move the invoice '
      'makes; this migration would widen the same verdict twice', v_sig
      using hint = 'The migration has already been applied to this database. Nothing to do.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_SUITE_UNRECOGNISED: expected the paid-invoice conjunct once in %, found %',
      v_sig, v_hits
      using hint = 'Read pg_get_functiondef(''erp_test.demo_history_suite()'') and re-cut the needle before re-running.';
  end if;

  execute replace(v_def, v_n, v_r);

  -- The patches this body already carried are still in it. A re-emission from
  -- any file would have dropped every one of them.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('Invoiced in full by ' in v_def) = 0
     or position('erp_test.approve_document(' in v_def) = 0                                  -- 20260914062000
     or position('DAMAGED_TRANSIT' in v_def) = 0                                             -- 20260918220000
     or position('partially_received' in v_def) = 0                                 -- 20260918600000
     or position('stock.adjusted' in v_def) = 0 then                                -- 20260918810000
    raise exception
      'CLOVEERP_DEMO_SUITE_UNRECOGNISED: % dropped a patch it already had, or did not take',
      v_sig
      using hint = 'Compare pg_get_functiondef with the markers listed in 20260919950000 before re-running.';
  end if;
end
$cases$;

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- The month itself, which is the whole point: five days of demonstration
-- trading that now reach Invoiced because the invoice moved the order.
select erp_test.assert_demo_history_suite();
