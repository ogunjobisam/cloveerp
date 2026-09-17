-- ─────────────────────────────────────────────────────────────────────────────
-- The caps removal is repaired
--
-- 20260919010000_a_limit_nobody_was_sold.sql was edited after it was pushed, and
-- this migration is the repair that supabase/ci/migrations_edited.txt names for
-- it. What changed there was one line: it no longer calls
-- erp_test.assert_commercial_renewal_suite().
--
-- WHY THE EDIT. That suite's fixture designates its own throwaway tenant as the
-- platform's organisation. A database built from empty has no platform
-- organisation, so the designation succeeds and the suite passes — it did, on
-- every build, along with all 280 catalogue checks. A live database already has
-- one, clove-erp, and refuses the second by design. So the statement was green
-- on every build and could never be green on a deploy. The deploy died on it
-- with CLOVEERP_PLATFORM_ORGANISATION_ALREADY_DESIGNATED and rolled the whole
-- migration back.
--
-- The rule it broke, which is worth stating once: a migration runs only what a
-- live database can answer. An assertion over the schema is fine. A suite that
-- stands up a fixture conflicting with a live singleton — the platform's
-- organisation, the primary ledger, a going-live environment — is not, however
-- green it is on an empty build. That suite is in erp.ci_check_catalogue() and
-- runs on every build already, which is where it belongs.
--
-- WHAT THIS REPAIRS. Nothing, on every database that exists today: the edited
-- migration rolled back whole, so no environment has ever carried the version
-- with that call in it. The register still requires the repair to exist and to
-- be real, so this makes the end state true again rather than asserting it is —
-- the deletes below are the same ones 20260919010000 makes, written to be safe
-- to run a second time. On a database that ran the original they finish the job;
-- on one that ran the edited version they find nothing and say so.
--
-- The two kinds, for the record: documents_per_month (2,000 Starter / 50,000
-- Standard) and movements_per_month (10,000 / 500,000). Neither appears on the
-- published price list, and nothing may refuse or report a customer against a
-- limit they were never sold.
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  v_kinds constant text[] := array['documents_per_month', 'movements_per_month'];
  v_left  integer := 0;
  v_gone  integer := 0;
begin
  delete from erp_meta.contract_entitlement ce where ce.entitlement_code = any(v_kinds);
  get diagnostics v_gone = row_count;  v_left := v_left + v_gone;

  delete from erp.price_item pi where pi.entitlement_code = any(v_kinds);
  get diagnostics v_gone = row_count;  v_left := v_left + v_gone;

  delete from erp_meta.plan_entitlement pe where pe.entitlement_code = any(v_kinds);
  get diagnostics v_gone = row_count;  v_left := v_left + v_gone;

  delete from erp_meta.entitlement_kind k where k.code = any(v_kinds);
  get diagnostics v_gone = row_count;  v_left := v_left + v_gone;

  if v_left > 0 then
    raise notice
      'The caps removal is repaired: % row(s) of documents_per_month or movements_per_month were still here and are gone.',
      v_left;
  else
    raise notice
      'The caps removal is repaired: nothing was left to remove, which is what a database that ran the edited migration looks like.';
  end if;
end
$repair$;

-- A kind nothing sells and nothing measures must not come back by the side door.
do $none$
declare v_n integer;
begin
  select count(*) into v_n from erp_meta.entitlement_kind k
   where k.code in ('documents_per_month', 'movements_per_month');
  if v_n <> 0 then
    raise exception
      'CLOVEERP_UNSOLD_LIMIT_PRESENT: % entitlement kind(s) nobody was sold are still registered', v_n
      using errcode = '23514',
            hint = 'Remove the kind and every plan, price item and contract band that names it. A customer is never refused or reported against a limit that is not on the price list.';
  end if;
end
$none$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the checks a live database can answer
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_entitlements_enforceable();
select erp.assert_commercial_sound();
select erp.assert_whole_database_reconciles();
