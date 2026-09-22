set lock_timeout = '30s';

-- =============================================================================
-- 20260922140000  The scrap reaches the works order
-- -----------------------------------------------------------------------------
-- erp.works_order.quantity_scrapped exists, is constrained
-- (20260829270000_production.sql:128), is read by the batch record at :1073, by
-- the works order list door that 20260830014600 built, and by the works order
-- report version 20260904430000 names as a column. Nothing has ever written it.
--
-- The only write to any scrap figure is at :709, into
-- erp.works_order_operation.quantity_scrapped, when somebody books time on an
-- operation. So a shop floor that has scrapped a hundred units reads zero on
-- the order, zero on the batch record it hands the auditor, and zero on the
-- report. The number is not missing on those screens — it is there, and it is
-- wrong, which is the worse of the two.
--
-- ── SUM, AND WHY ─────────────────────────────────────────────────────────────
--
-- The header figure is the sum of its operations', not the largest of them and
-- not the last one booked. A unit scrapped at assembly and a unit scrapped at
-- test are two units that will never be output, however far apart in the
-- routing they were lost. That is also what the batch record's own operation
-- breakdown at :1096 already shows line by line, so the header agreeing with
-- the sum is the header agreeing with the lines beneath it.
--
-- ── RECOMPUTED, NOT INCREMENTED ──────────────────────────────────────────────
--
-- The update reads the operations and writes the total, rather than adding
-- p_scrapped to whatever the header held. Two reasons, and the second is the
-- one that matters:
--
--   * it is idempotent, so a booking replayed against a header that already
--     counted it does not count it twice;
--   * every works order in every environment is carrying a header of zero
--     against operations that may not be, and an incrementing write would
--     leave that gap open for ever — each order would be wrong by exactly the
--     scrap booked before today. A recomputing write closes it on the next
--     booking, and section 3 closes it for orders that get no further booking.
--
-- ── PATCHED, NOT RESTATED ────────────────────────────────────────────────────
--
-- erp.book_operation_time() has been redefined since 20260829270000 — the
-- refusal codes were renamed by the CLOVEERP prefix change, among others — so
-- the body the database carries is not the body in that file. Anchored on the
-- deployed text with a counted occurrence, like every other patch of a function
-- that has accumulated history.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Booking rolls the operation figure to the header
-- ═════════════════════════════════════════════════════════════════════════════

do $roll$
declare
  v_sig constant text :=
    'erp.book_operation_time(uuid, integer, numeric, numeric, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  insert into erp.production_event (\n'
    || E'    tenant_id, works_order_id, operation_seq, event_kind, quantity, minutes,\n'
    || E'    actor_id)\n';
  v_new constant text :=
       E'  -- The header is the sum of its operations (20260922140000). Read and\n'
    || E'  -- written rather than incremented: it is idempotent, and it repairs a\n'
    || E'  -- header that was never written in the first place.\n'
    || E'  update erp.works_order w\n'
    || E'     set quantity_scrapped = (select coalesce(sum(o.quantity_scrapped), 0)\n'
    || E'                                from erp.works_order_operation o\n'
    || E'                               where o.tenant_id = v_tenant\n'
    || E'                                 and o.works_order_id = p_works_order_id),\n'
    || E'         updated_at = now()\n'
    || E'   where w.tenant_id = v_tenant and w.id = p_works_order_id;\n'
    || E'\n'
    || E'  insert into erp.production_event (\n'
    || E'    tenant_id, works_order_id, operation_seq, event_kind, quantity, minutes,\n'
    || E'    actor_id)\n';
  v_hits integer;
begin
  if position('20260922140000' in v_def) > 0 then
    raise exception
      'CLOVEERP_BOOKING_UNRECOGNISED: % already rolls scrap to the header; this '
      'migration would insert the roll twice', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_BOOKING_UNRECOGNISED: % raises its time_booked event % time(s), not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$roll$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the suite says so
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two cases appended to erp_test.production_suite(), which already stands up a
-- works order with a bill, a routing, issued components and booked time. A
-- second fixture for two numbers agreeing would be a second place for the works
-- order fixture to drift from this one.
--
-- The second case is the sharper of the two: it puts a wrong figure on the
-- header by hand and books nothing, and the header has to come back to the
-- truth. An incrementing write passes the first case and fails that one.

do $suite$
declare
  v_sig constant text := 'erp_test.production_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  set constraints all immediate;\n'
    || E'  perform set_config(''request.jwt.claims'','''',true);\n';
  v_new constant text :=
       E'  -- Scrap booked on an operation reaches the order it was scrapped from\n'
    || E'  -- (20260922140000). Until then erp.works_order.quantity_scrapped was\n'
    || E'  -- read by the batch record, the order list and the report, and written\n'
    || E'  -- by nothing at all.\n'
    || E'  perform erp.book_operation_time(v_wo, 10, 0, 0, 7);\n'
    || E'  return query select ''scrap booked on an operation reaches the works order'',\n'
    || E'    (select wo.quantity_scrapped from erp.works_order wo where wo.id = v_wo) = 7,\n'
    || E'    format(''the operation lost 7 and the header says %s'',\n'
    || E'           (select wo.quantity_scrapped from erp.works_order wo where wo.id = v_wo));\n'
    || E'\n'
    || E'  -- And the header is read from the operations rather than added to, so a\n'
    || E'  -- figure that is already wrong is corrected rather than carried on from.\n'
    || E'  -- Every order in every environment starts today with a header of zero\n'
    || E'  -- against operations that are not, which is the same shape as this.\n'
    || E'  update erp.works_order set quantity_scrapped = 999 where id = v_wo;\n'
    || E'  perform erp.book_operation_time(v_wo, 10, 0, 0, 0);\n'
    || E'  return query select ''and the header is recomputed from them, not added to'',\n'
    || E'    (select wo.quantity_scrapped from erp.works_order wo where wo.id = v_wo) = 7,\n'
    || E'    format(''set to 999 by hand, and a booking of nothing brings it back to %s'',\n'
    || E'           (select wo.quantity_scrapped from erp.works_order wo where wo.id = v_wo));\n'
    || E'\n'
    || E'  set constraints all immediate;\n'
    || E'  perform set_config(''request.jwt.claims'','''',true);\n';
  v_hits integer;
begin
  if position('20260922140000' in v_def) > 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % already holds the scrap cases', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % tears its fixture down % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$suite$;

-- The wrapper pins the case count, and two cases were added. A suite that
-- loses a case reports success, so the two numbers move together or the build
-- refuses the file that moved one of them.

do $pin$
declare
  v_sig constant text := 'erp_test.assert_production_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := 'c_expected constant integer := 24;';
  v_new constant text := 'c_expected constant integer := 26;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: % pins 24 cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$pin$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The orders that were already wrong
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A forward fix corrects an order at its next booking, and an order that has
-- finished gets no next booking. Those are precisely the orders somebody reads
-- a batch record for. Every environment this migration reaches is carrying them,
-- so they are put right here rather than left as a silent floor of wrongness
-- under a correct rule.
--
-- Only rows that disagree are touched, and the figure written is the one the
-- rule above would write. Nothing is invented: an order whose operations were
-- never booked has nothing to roll and stays at zero.

with rolled as (
  select o.tenant_id, o.works_order_id, sum(o.quantity_scrapped) as scrapped
    from erp.works_order_operation o
   group by o.tenant_id, o.works_order_id
)
update erp.works_order w
   set quantity_scrapped = rolled.scrapped, updated_at = now()
  from rolled
 where rolled.tenant_id = w.tenant_id
   and rolled.works_order_id = w.id
   and w.quantity_scrapped is distinct from rolled.scrapped;

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
