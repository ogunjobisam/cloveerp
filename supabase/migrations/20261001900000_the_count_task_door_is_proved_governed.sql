-- ═════════════════════════════════════════════════════════════════════════════
-- The count task door is proved governed
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20260927220223 (Lovable, 41be47fb) restated public.erp_count_tasks so open
-- counts come first, and did not call erp.assert_public_api_safe() in the same
-- migration. Specification v1.2 §16.2 asks for the door and the proof that it
-- is governed in one transaction; supabase/ci/boundary_in_migration.sh refuses
-- a migration without it, and has refused every build of main since 2ac3961b.
--
-- The door was governed: a plain sql read, empty search path, execute revoked
-- from public and anon, the tenant filter and row security scoping it, and the
-- assertion passes over it. What was missing is the proof. A migration is
-- written once, so the proof lands here, and boundary_repaired.txt pairs the
-- two files. Nothing is redefined.

-- The door as 20260927220223 left it, or stop: this migration proves that
-- definition and no other.
do $door$
declare
  v_def text := pg_get_functiondef('public.erp_count_tasks(integer)'::regprocedure);
begin
  if position('order by (c.status = ''open'') desc, c.created_at desc' in v_def) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_count_tasks is not the open-first door '
                    '20260927220223 wrote, so this migration is not proving what it names';
  end if;
end
$door$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
