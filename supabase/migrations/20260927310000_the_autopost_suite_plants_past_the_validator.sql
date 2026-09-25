set lock_timeout = '30s';

-- =============================================================================
-- 20260927310000  The autopost suite plants its bad value past the validator
-- -----------------------------------------------------------------------------
-- erp_test.count_autopost_suite (20260927300000) proves that a count posting
-- policy value outside its shape holds the count rather than posting it: the
-- resolver fails closed on a value that reached the store some way other than
-- the door. It planted the value through erp.set_config_value(), which checks
-- it against the type's schema, and where extensions.jsonb_matches_schema is
-- the real validator (the build's database, found on CI) the plant itself was
-- refused, so the case never reached the resolver. The plant now goes past the
-- validating trigger, for the two writes only, inside the case's rolled-back
-- block, which is what "some way other than the door" means.
-- =============================================================================

do $suite$
declare
  v_sig constant text := 'erp_test.count_autopost_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    v_fixture := 'recording under a policy value the door would have refused';
$o$,
    $n$    v_fixture := 'recording under a policy value the door would have refused';
    -- Past the validator, as a value that reached the store without the door
    -- (20260927310000); put back inside the same rolled-back block.
    alter table erp.config_version disable trigger t_config_version_validate;
$n$,
    $o$      v_log := (select t.post_held_reason from erp.count_task t where t.id = j1);
$o$,
    $n$      alter table erp.config_version enable trigger t_config_version_validate;
      v_log := (select t.post_held_reason from erp.count_task t where t.id = j1);
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
