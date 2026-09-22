set lock_timeout = '30s';

-- =============================================================================
-- 20260922350000  The catch-up acts as somebody who may release a hold
-- -----------------------------------------------------------------------------
-- A review of PR3 found that 20260922290000 made erp.seed_demo_history() release
-- a credit hold through erp.release_credit_hold(), which is authorised against
-- sales.credit_release, and that erp.catch_up_demonstrations() was not told.
-- It chooses the person it acts as by the permissions in v_needs, and
-- sales.credit_release was not one of them.
--
-- In the demonstrations that exist the gap is latent: the administrator role
-- holds sales.credit_release, and the catch-up's first choice is always somebody
-- holding everything. But a demonstration whose only fully-empowered person had
-- a role without it would have been caught up by somebody who could not do what
-- the catch-up now does. The first time a held customer came up on the
-- half-order path the whole day would have been refused — and the deploy step
-- that runs the catch-up continues on error, so every later deploy would have
-- stopped on that same day while the build stayed green.
--
-- So the permission joins the list. Where nobody holds all of them the catch-up
-- already says so and leaves that organisation as it was, which is the right
-- answer: it names what is missing rather than failing half way through a day.
-- =============================================================================

do $needs$
declare
  v_sig constant text := 'erp.catch_up_demonstrations(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'    ''procurement.match''];\n';
  v_new constant text :=
       E'    ''procurement.match'',\n'
    || E'    -- The seeder releases credit holds through erp.release_credit_hold()\n'
    || E'    -- (20260922290000), which asks for this (20260922350000).\n'
    || E'    ''sales.credit_release''];\n';
  v_hits integer;
begin
  if position('sales.credit_release' in v_def) > 0 then
    raise exception 'CLOVEERP_CATCH_UP_UNRECOGNISED: % already asks for sales.credit_release', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_CATCH_UP_UNRECOGNISED: % ends its list of needs % time(s) where this expects, not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$needs$;

-- The seeder asks for the permission, and the catch-up now asks for it before
-- it chooses whom to act as.

do $held$
begin
  if position('release_credit_hold' in pg_get_functiondef('erp.seed_demo_history(date, date, numeric)'::regprocedure)) > 0
     and position('sales.credit_release' in pg_get_functiondef('erp.catch_up_demonstrations(text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_CATCH_UP_UNDERPOWERED: the seeder releases credit holds and the catch-up does not choose somebody who may'
      using hint = 'Add sales.credit_release to the permissions erp.catch_up_demonstrations() requires of the person it acts as.';
  end if;
end
$held$;

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
