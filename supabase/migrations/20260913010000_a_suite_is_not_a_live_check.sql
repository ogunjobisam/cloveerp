-- A suite is not a live check.
--
-- deploy.yml proves a release with erp.platform_assurance(), and says why in
-- one line: the same checks the build runs, minus the suites, because a
-- suite creates and destroys organisations and does not belong on live.
-- 20260911130939 registered one anyway. erp_test.assert_document_archive_
-- authenticated_suite() went into erp_meta.diagnostic_check as an assertion,
-- and the assurance runner runs every assertion, so every deploy since — and
-- every press of the console's assurance button — has provisioned an
-- organisation called zzdocauth on production, run seven cases as it, and
-- torn it down. The deploys did not get that far. On 12 September the suite
-- died in the promoter bug 20260912260000 fixed; on 13 September, with that
-- gone, it died one step later:
--
--   document_archive_authenticated: cannot set parameter "role" within
--   security-definer function
--
-- because erp.platform_assurance() is security definer, and a suite that
-- proves the archive is invisible to authenticated callers does so by
-- `set local role authenticated`, which PostgreSQL refuses inside one. The
-- build never saw either failure: erp.ci_check_catalogue() calls the wrapper
-- directly, as psql, where the role switch is allowed. Nothing about the
-- suite is wrong. Its register row is.
--
-- The row goes. The suite stays in the build exactly as before, because the
-- catalogue reads pg_proc, not the register (20260906010000): every
-- erp_test.assert_* is in the build by existing. erp.assert_diagnostics_
-- registered() asks nothing of erp_test, so no exemption is needed, and the
-- guard below keeps the register from acquiring another suite by accident.
--
-- What ran on live rolled back: erp.run_diagnostic() runs each check inside
-- an exception block, so the organisation the suite provisioned was undone
-- with the error that reported it.

delete from erp_meta.diagnostic_check
 where code = 'document_archive_authenticated';

-- No suite in the live register, now or later. A suite is anything in
-- erp_test; the register is for assertions and reports the console and the
-- deploy may run against a live database.
do $register$
declare v_bad text;
begin
  select string_agg(d.code || ' -> ' || d.schema_name || '.' || d.function_name, ', ' order by d.code)
    into v_bad
    from erp_meta.diagnostic_check d
   where d.schema_name = 'erp_test';
  if v_bad is not null then
    raise exception 'CLOVEERP_SUITE_IN_LIVE_REGISTER: % — a suite provisions organisations and switches roles, which live assurance may not do',
      v_bad
      using errcode = 'P0001',
            hint = 'Leave suites to erp.ci_check_catalogue(), which finds them in pg_proc. Register only assertions and reports here.';
  end if;
end
$register$;

-- The register is still whole, and the build still covers the suite.
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
