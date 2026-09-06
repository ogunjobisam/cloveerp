-- =============================================================================
-- 20260906140000  A run can wait its turn
-- -----------------------------------------------------------------------------
-- Specification v1.6 §9.1. Phase 9 of the outstanding-work programme, the
-- first of seven files.
--
-- erp.trigger_job() records a run as 'running' with no worker, because the
-- outcome vocabulary had no word for "asked for and not yet picked up"; the
-- engines claim schedules, never runs, so a triggered run sat until its lease
-- expired and then read as timed out (deferred finding 50). The word is added
-- here, alone: a value added to an enumerated type cannot be used in the
-- transaction that adds it, so the behaviour follows in 20260906144000.
--
-- Proof: the standard assertions and the console; the value is exercised by
-- erp_test.queued_run_suite() four files on.
-- =============================================================================

alter type erp.job_run_outcome add value if not exists 'queued' before 'running';

comment on type erp.job_run_outcome is
  'What became of a job run. queued: asked for by erp.trigger_job() and not '
  'yet claimed by an engine — no worker, no lease, no start. running: claimed, '
  'under a lease. The rest are terminal.';

-- ═════════════════════════════════════════════════════════════════════════════
-- Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
