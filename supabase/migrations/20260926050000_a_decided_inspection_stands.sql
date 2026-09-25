set lock_timeout = '30s';

-- =============================================================================
-- 20260926050000  A decided inspection stands
-- -----------------------------------------------------------------------------
-- Found on the review of PR8 M6b (20260925400000). A reject on the floor stops
-- every batch the works order made, and the only way round it was to decide
-- the rejected inspection again.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * erp.disposition_inspection() never read the inspection's status. An
--     inspection already decided, or cancelled, could be decided again by
--     anybody holding quality.disposition: a reject became an accept, and
--     erp.release_batch(), which reads the decision as it stands, released
--     the batch the reject had stopped. The first decision, who made it and
--     when, was overwritten.
--   * Deciding 'pending' marked the inspection complete with nothing decided.
--     While a decision could be changed that was recoverable; once it cannot,
--     the batch would wait for ever on an inspection nobody could decide.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * An inspection is decided while it is open (planned, sampling or
--     testing), and once. Complete or cancelled, a decision is refused with
--     CLOVEERP_INSPECTION_CLOSED, whose next action is a new inspection
--     (erp_raise_inspection), decided on its own record.
--   * Pending is not a decision: it is refused with
--     CLOVEERP_INSPECTION_NEEDS_A_DECISION, and the inspection stays open.
--   * No seed, demonstration or suite decides an inspection twice on purpose.
--     The quality, quality_logistics, controls, wiring, second organisation
--     and production_inspection suites each decide an inspection once, and
--     the ones they refuse (a partial record, an unreasoned concession) are
--     refused before anything is written; M6b's rework is decided anew on a
--     new inspection. None of them changes.
--   * erp_test.quality_suite proves both refusals; its count is re-pinned
--     from 12 to 14.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_INSPECTION_CLOSED',
  'Deciding an inspection that has already been decided, or was cancelled.',
  'The release of a batch reads the decision on its inspections. Decided again, a reject becomes an accept, the batch it stopped is released on it, and the first decision is lost.',
  'Leave this inspection as it stands. If the goods need checking again, raise a new inspection and decide that one.');
select erp.register_refusal('CLOVEERP_INSPECTION_NEEDS_A_DECISION',
  'Deciding an inspection as still pending.',
  'Deciding closes the inspection for good. Pending is no decision, so the batch would wait on an inspection nobody could then decide.',
  'Choose accept, accept with concession, rework, reject, quarantine or destroy, or leave the inspection open until you can.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. An inspection is decided while it is open, and once
-- ─────────────────────────────────────────────────────────────────────────────

do $decide$
declare
  v_sig constant text := 'erp.disposition_inspection(uuid,erp.disposition,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  perform erp.authorise('quality.disposition', insp.entity_id, insp.site_id, null,
                        'inspection', p_inspection_id);
$o$,
    $n$  perform erp.authorise('quality.disposition', insp.entity_id, insp.site_id, null,
                        'inspection', p_inspection_id);

  -- An inspection is decided while it is open, and once (20260926050000).
  -- Decided again, a reject became an accept and the release read the new
  -- decision. A question asked again is a new inspection, on its own record.
  if insp.status not in ('planned', 'sampling', 'testing') then
    raise exception 'CLOVEERP_INSPECTION_CLOSED: %',
      case when insp.status = 'cancelled'
           then 'the inspection was cancelled, and is not decided'
           else format('the inspection was decided %s, and the decision stands', insp.disposition) end
      using errcode = '23514',
            hint = 'Leave this inspection as it stands. If the goods need checking again, raise a new inspection and decide that one.';
  end if;

  -- Pending is no decision, and deciding closes the inspection for good.
  if p_disposition = 'pending' then
    raise exception 'CLOVEERP_INSPECTION_NEEDS_A_DECISION: pending is not a decision, and would close the inspection with nothing decided'
      using errcode = '22023',
            hint = 'Choose accept, accept with concession, rework, reject, quarantine or destroy, or leave the inspection open until you can.';
  end if;
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$decide$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: two cases in erp_test.quality_suite, after the rejected
-- batch that is not inspected again (6b)
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig constant text := 'erp_test.quality_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$      v_err like 'CLOVEERP_BATCH_REJECTED:%', v_err;
$o$,
    $n$      v_err like 'CLOVEERP_BATCH_REJECTED:%', v_err;

    -- 6d. Nor is the rejected inspection decided again to overturn it, even
    -- with the reason a concession would need (20260926050000).
    begin perform erp.disposition_inspection(v_insp3, 'accept', 'Chilled again and within limits'); v_err := 'accepted';
    exception when others then v_err := left(sqlerrm, 120); end;
    return query select 'a rejected inspection is not decided again, so a reject cannot be turned into an accept',
      v_err like 'CLOVEERP_INSPECTION_CLOSED:%'
      and (select ins.status = 'complete' and ins.disposition = 'reject' and ins.disposition_note = 'Arrived warm'
             from erp.inspection ins where ins.id = v_insp3),
      v_err;

    -- 6e. Pending is no decision: a complete record is not closed on it, and
    -- stays open to be decided.
    perform erp.record_inspection_result(v_mine, 'temperature', 3);
    perform erp.record_inspection_result(v_mine, 'packaging', null, 'intact');
    begin perform erp.disposition_inspection(v_mine, 'pending', null); v_err := 'closed';
    exception when others then v_err := left(sqlerrm, 120); end;
    return query select 'an inspection is not closed as still pending, where nobody could then decide it',
      v_err like 'CLOVEERP_INSPECTION_NEEDS_A_DECISION:%'
      and (select ins.status = 'planned' and ins.disposition = 'pending' from erp.inspection ins where ins.id = v_mine),
      v_err;
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$suite$;

create or replace function erp_test.assert_quality_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.quality_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_QUALITY_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An inspection nobody can ask for, a plan that cannot name its product, a release that asks a clean batch for a signature, or an inspection decided twice, is the case that failed. Read it.';
  end if;
  if v_total <> 14 then
    raise exception 'CLOVEERP_QUALITY_SUITE_SHRANK: % case(s), expected 14', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_quality_suite() from public, anon;

comment on function erp_test.assert_quality_suite() is
  'An inspection is asked for by somebody who inspects, against a plan that covers the product; a '
  'promoted plan names its product; a batch is released on a signed statement only where a plan '
  'sampled it (20260925300000); and an inspection is decided while it is open, once, and never as '
  'pending (20260926050000).';

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
