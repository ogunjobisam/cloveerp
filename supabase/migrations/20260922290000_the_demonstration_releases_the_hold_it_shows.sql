set lock_timeout = '30s';

-- =============================================================================
-- 20260922290000  The demonstration releases the hold it shows
-- -----------------------------------------------------------------------------
-- 20260922280000 stopped the demonstration refusing its own orders when they
-- are taken. Seeding then got as far as despatching one and refused there:
--
--   CLOVEERP_CREDIT_HOLD: SO-000023 is held on credit, because the customer has
--   debt overdue beyond the organisation's credit policy
--   erp.check_release_to_fulfilment(uuid) line 34
--
-- There are two credit doors, not one, and only the first has a switch.
-- erp.create_document() asks sales.credit_control.check_at_capture before it
-- refuses; erp.check_release_to_fulfilment() asks nothing and always refuses,
-- and it guards erp.create_delivery_from_order(), erp.commit_allocation() and
-- erp.pick_document(). Its only way past is the one its hint names: somebody
-- with sales.credit_release releases that order, with a reason.
--
-- ── SO THE DEMONSTRATION DOES THAT, WHICH IS BETTER THAN A SWITCH ────────────
--
-- One place needs it. The demonstration raises its ordinary deliveries with
-- erp.create_document('delivery', ...), which no credit door guards; the
-- half-order path is the only one that goes through
-- erp.create_delivery_from_order(), and it is the only one that was refused.
--
-- It now releases the order first, when the customer is held, through
-- erp.release_credit_hold() with a reason — the product's own door, the one a
-- person would use. That is a better answer than another switch would have
-- been:
--
--   the hold is real and stays real. The order carries credit_released_by, the
--   release is authorised against sales.credit_release, and the reason is on
--   the record;
--
--   erp.release_credit_hold() notes that "B1's catalogue has carried
--   sales.credit_release since it was written and nothing has ever required
--   it". After this the demonstration exercises it, so the permission, the
--   reason and the released-by attribution are all things a prospect can see
--   rather than things the catalogue merely lists.
--
-- ── AND WHY THE CUSTOMER IS HELD AT ALL ──────────────────────────────────────
--
-- Because the demonstration leaves a fifth of a year's invoices unpaid on
-- purpose, so that it has ageing, dunning and collections work to show. Every
-- customer's oldest debt eventually passes any window worth setting. The data
-- is right and the control is right; what a demonstration cannot also do is
-- stop itself trading over it.
-- =============================================================================

do $release$
declare
  v_sig constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'        v_half_dn := (erp.create_delivery_from_order(\n';
  v_new constant text :=
       E'        -- Released first where the customer is held (20260922290000).\n'
    || E'        -- erp.check_release_to_fulfilment() has no switch and guards this\n'
    || E'        -- door; the way past is the one its hint names, and it is the way a\n'
    || E'        -- person would take. The hold stays real and the release is on the\n'
    || E'        -- record, against sales.credit_release, with its reason.\n'
    || E'        if coalesce((select cp.on_hold from erp.credit_position(v_customer) cp), false) then\n'
    || E'          perform erp.release_credit_hold(v_half_so,\n'
    || E'            ''released for despatch while the debt behind the hold is collected'');\n'
    || E'        end if;\n'
    || E'\n'
    || E'        v_half_dn := (erp.create_delivery_from_order(\n';
  v_hits integer;
begin
  if position('release_credit_hold' in v_def) > 0 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: % already releases the hold it shows', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SEEDER_UNRECOGNISED: % raises a delivery from an order % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it. Another such call is another door that will refuse.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$release$;

-- The other two doors erp.check_release_to_fulfilment() guards are
-- erp.commit_allocation() and erp.pick_document(). The seeder calls neither,
-- and this says so where it would stop being true.

do $doors$
declare
  v_def text := pg_get_functiondef('erp.seed_demo_history(date, date, numeric)'::regprocedure);
  v_n   integer := 0;
begin
  if position('erp.commit_allocation(' in v_def) > 0 then v_n := v_n + 1; end if;
  if position('erp.pick_document(' in v_def) > 0 then v_n := v_n + 1; end if;
  if v_n > 0 then
    raise exception
      'CLOVEERP_SEEDER_REACHES_ANOTHER_CREDIT_DOOR: the seeder now calls % routine(s) that erp.check_release_to_fulfilment() guards, and they will refuse a held customer the way erp.create_delivery_from_order() did',
      v_n
      using hint = 'Release the order before that call as the half-order path does, or the demonstration stops seeding the first time a customer ages past the window.';
  end if;
end
$doors$;

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
