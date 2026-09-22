set lock_timeout = '30s';

-- =============================================================================
-- 20260922220000  Time is booked where the routing says to book it
-- -----------------------------------------------------------------------------
-- W4 of the simplification plan, which reads in full: "erp.book_operation_time()
-- is one call per routing operation with no milestone filter, despite
-- works_order_operation.is_milestone being populated at :378. Require booking
-- only at milestones."
--
-- ── WHY IT IS NOT BUILT THE WAY IT IS WRITTEN ────────────────────────────────
--
-- Because that would stop every shop floor in every organisation from booking
-- any time at all, today, on the first deploy.
--
-- erp.works_order_operation.is_milestone is populated, once, by
-- erp.raise_works_order(), which copies it from erp.routing_operation. And
-- erp.routing_operation.is_milestone is `boolean not null default false` and is
-- set to true by NOTHING: not a content pack, not an installer, not the
-- demonstration seeder, not a screen, not a door. Nothing in the repository
-- writes it. It is read by nothing either — one writer copying a constant from
-- another constant.
--
-- So "require booking only at milestones" against the product as it stands is
-- "refuse every booking", because no operation anywhere is a milestone, and no
-- operation can be made one: there is no routing authoring door at all.
-- erp.routing and erp.routing_operation are written only by migrations and by
-- suites inserting rows directly. A customer cannot create a routing through
-- the product, let alone mark a step on it.
--
-- That last fact is worth saying plainly rather than burying: routings are
-- master data the product has no way to author. It is outside this node and
-- belongs to whichever node builds the manufacturing screens.
--
-- ── WHAT IS BUILT INSTEAD ────────────────────────────────────────────────────
--
-- The rule is made conditional on the routing having an opinion:
--
--   a works order none of whose operations is a milestone books at every
--   operation, exactly as it does today;
--
--   a works order that declares at least one milestone books only at those.
--
-- That is the milestone filter the node asks for, wired so that setting the
-- column does something, and it is a no-op for every organisation in existence
-- because none of them declares a milestone. The day a routing does, the rule
-- is already there and already tested.
--
-- The alternative — refuse until somebody configures milestones — is a wiring
-- node breaking production to enforce a setting the product gives nobody a way
-- to set. A control that cannot be satisfied is not a control.
--
-- ── AND THE MEANING IS PINNED ────────────────────────────────────────────────
--
-- erp_test.milestone_booking_suite() holds the conditional shape from both
-- sides, because the failure mode of this node is not that the filter is
-- missing — it is that somebody later "tidies" the condition away and the
-- filter starts refusing everything. The case that would catch that is the one
-- asserting an ordinary works order still books at every step.
-- =============================================================================

do $filter$
declare
  v_sig constant text :=
    'erp.book_operation_time(uuid, integer, numeric, numeric, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  update erp.works_order_operation\n'
    || E'     set actual_minutes = actual_minutes + p_minutes,\n';
  v_new constant text :=
       E'  -- Time is booked where the routing says to book it (20260922220000).\n'
    || E'  --\n'
    || E'  -- Conditional on the routing having an opinion, and deliberately so. A\n'
    || E'  -- works order none of whose operations is a milestone books at every one,\n'
    || E'  -- as it always has; one that declares a milestone books only at those.\n'
    || E'  -- Nothing in the product sets is_milestone today — there is no routing\n'
    || E'  -- authoring door at all — so an unconditional rule would refuse every\n'
    || E'  -- booking on every shop floor to enforce a setting nobody can make.\n'
    || E'  if exists (select 1 from erp.works_order_operation o\n'
    || E'              where o.tenant_id = v_tenant\n'
    || E'                and o.works_order_id = p_works_order_id\n'
    || E'                and o.is_milestone)\n'
    || E'     and not exists (select 1 from erp.works_order_operation o\n'
    || E'                      where o.tenant_id = v_tenant\n'
    || E'                        and o.works_order_id = p_works_order_id\n'
    || E'                        and o.seq = p_operation_seq\n'
    || E'                        and o.is_milestone)\n'
    || E'  then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_NOT_A_MILESTONE: operation % on % is not where its routing asks for time to be booked'',\n'
    || E'      p_operation_seq, wo.order_number\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Book the time at the next milestone operation. A routing that '' ||\n'
    || E'                   ''names milestones is saying the work between them is counted '' ||\n'
    || E'                   ''at them, not step by step.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  update erp.works_order_operation\n'
    || E'     set actual_minutes = actual_minutes + p_minutes,\n';
  v_hits integer;
begin
  if position('CLOVEERP_NOT_A_MILESTONE' in v_def) > 0 then
    raise exception 'CLOVEERP_BOOKING_UNRECOGNISED: % already books where the routing says', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_BOOKING_UNRECOGNISED: % writes its operation % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$filter$;

select erp.register_refusal('CLOVEERP_NOT_A_MILESTONE',
  'Booking time against an operation its routing does not count time at.',
  'A routing that names milestones is saying the work is counted at those points and not at every step between them — so time booked against a step in between is counted twice or counted nowhere, depending on what the milestone then collects. A routing that names no milestone is not saying that, and books at every operation as it always has.',
  'Book the time at the next milestone operation on the order. If every step should be booked, the routing should name no milestones; if this step should be one, mark it on the routing.');

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite, appended where the works order already stands
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.production_suite() already builds a works order from a bill and a
-- routing, releases it, issues to it and books time on it. Three cases go there
-- rather than into a fixture of their own.
--
-- The first of the three is the one that matters. It asserts that an ordinary
-- works order — one whose routing names no milestone, which is every works
-- order in every organisation today — still books at every operation. If the
-- condition on this node's filter is ever "tidied" away, that case is what
-- fails, and it fails loudly rather than a shop floor discovering it.

do $suite$
declare
  v_sig constant text := 'erp_test.production_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  set constraints all immediate;\n'
    || E'  perform set_config(''request.jwt.claims'','''',true);\n';
  v_new constant text :=
       E'  -- A second operation on the order, so there is somewhere that is not a\n'
    || E'  -- milestone to try booking at (20260922220000).\n'
    || E'  insert into erp.works_order_operation (\n'
    || E'    tenant_id, works_order_id, seq, code, name, work_centre_code,\n'
    || E'    planned_setup_minutes, planned_run_minutes, cost_rate_minor_per_hour, is_milestone)\n'
    || E'  select o.tenant_id, o.works_order_id, 20, ''TEST'', ''Test'', ''WC1'', 0, 0, 0, false\n'
    || E'    from erp.works_order_operation o\n'
    || E'   where o.works_order_id = v_wo and o.seq = 10;\n'
    || E'\n'
    || E'  return query select ''a routing that names no milestone books at every operation'',\n'
    || E'    erp_test.booking_is_accepted(v_wo, 20),\n'
    || E'    ''this is every works order in every organisation today, and it must not change'';\n'
    || E'\n'
    || E'  -- Now the routing has an opinion.\n'
    || E'  update erp.works_order_operation set is_milestone = true\n'
    || E'   where works_order_id = v_wo and seq = 10;\n'
    || E'\n'
    || E'  return query select ''and once one step is a milestone, the steps between are refused'',\n'
    || E'    not erp_test.booking_is_accepted(v_wo, 20)\n'
    || E'    and exists (select 1 from erp_ref.refusal f where f.code = ''CLOVEERP_NOT_A_MILESTONE''),\n'
    || E'    ''the work between milestones is counted at them, not step by step'';\n'
    || E'\n'
    || E'  return query select ''and the milestone itself still books'',\n'
    || E'    erp_test.booking_is_accepted(v_wo, 10),\n'
    || E'    ''a filter that refused the milestone too would refuse everything'';\n'
    || E'\n'
    || E'  update erp.works_order_operation set is_milestone = false\n'
    || E'   where works_order_id = v_wo and seq = 10;\n'
    || E'\n'
    || E'  set constraints all immediate;\n'
    || E'  perform set_config(''request.jwt.claims'','''',true);\n';
  v_hits integer;
begin
  if position('CLOVEERP_NOT_A_MILESTONE' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already holds the milestone cases', v_sig
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

-- The helper the three cases lean on: did the booking go through? Named rather
-- than repeated three times, and it swallows only the refusal this node raises
-- — anything else still stops the suite where it happened.

create or replace function erp_test.booking_is_accepted(p_works_order_id uuid, p_seq integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp.book_operation_time(p_works_order_id, p_seq, 1, 0, 0);
  return true;
exception
  when sqlstate '23514' then
    if sqlerrm like 'CLOVEERP_NOT_A_MILESTONE%' then
      return false;
    end if;
    raise;
end;
$$;

comment on function erp_test.booking_is_accepted(uuid, integer) is
  'Whether a minute could be booked at that operation. Swallows the milestone refusal and nothing else.';

-- The wrapper pins the count from outside, and three cases were added.

do $pin$
declare
  v_sig constant text := 'erp_test.assert_production_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := 'c_expected constant integer := 26;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: % pins 26 cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;

  execute replace(v_def, v_old, 'c_expected constant integer := 29;');
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
