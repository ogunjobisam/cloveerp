set lock_timeout = '30s';

-- ═════════════════════════════════════════════════════════════════════════════
-- The export goes back to its limit
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20261001910000 gave public.erp_export_tenant() fifty-five seconds and ran it
-- as its owner, so that an organisation's export would finish instead of being
-- cancelled at the authenticated role's eight. On 30 September between 01:12
-- and 01:13 UTC four export calls ran at once (the screen has two buttons,
-- Build export and Download as JSON, that call the same door) for 40 to 70
-- seconds each, and the live database then stopped without a clean shutdown
-- and recovered at 01:14:10. Every organisation was without it for about a
-- minute. The log names no cause; memory is the likely one.
--
-- The door builds everything the organisation holds, every audit entry with
-- its before and after state included, as one jsonb value in one statement.
-- Eight seconds had been cancelling that harmlessly. Fifty-five seconds, and
-- no per-row policy check to slow it, let four copies grow until the host
-- gave way. More time was the wrong answer for a statement whose size nothing
-- bounds.
--
-- So this puts the door back exactly as it was before 20261001910000: run as
-- the caller, under the role's own statement_timeout, with its definer
-- registration removed. An export too large for eight seconds fails as it did
-- before, with "That took too long", and cannot take the database with it.
--
-- The body is not touched. The export that fits comes from building it a
-- section at a time, so that no single request holds the whole organisation,
-- and that is its own change.
-- ═════════════════════════════════════════════════════════════════════════════

alter function public.erp_export_tenant() security invoker;
alter function public.erp_export_tenant() reset statement_timeout;

-- The door no longer runs as its owner, so its row goes.
delete from erp_meta.security_definer_allowance
 where schema_name = 'public' and function_name = 'erp_export_tenant';

-- Proved here rather than trusted: the door runs as the caller, has no time of
-- its own, keeps its empty search path, still gates, and is no longer excused.
do $$
declare
  p pg_catalog.pg_proc%rowtype;
begin
  select * into p from pg_catalog.pg_proc
   where oid = 'public.erp_export_tenant()'::regprocedure;

  if p.prosecdef then
    raise exception 'CLOVEERP_EXPORT_STILL_DEFINER: public.erp_export_tenant still runs as its owner';
  end if;
  if exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'statement_timeout=%') then
    raise exception 'CLOVEERP_EXPORT_STILL_TIMED: public.erp_export_tenant still carries its own statement_timeout, %', p.proconfig;
  end if;
  if not ('search_path=""' = any (coalesce(p.proconfig, '{}'))) then
    raise exception 'CLOVEERP_EXPORT_SEARCH_PATH: public.erp_export_tenant lost its empty search path, %', p.proconfig;
  end if;
  if p.prosrc !~ 'perform\s+erp\.authorise\(''administration\.configure''\)' then
    raise exception 'CLOVEERP_EXPORT_UNGATED: public.erp_export_tenant no longer gates';
  end if;
  if exists (select 1 from erp_meta.security_definer_allowance
              where schema_name = 'public' and function_name = 'erp_export_tenant') then
    raise exception 'CLOVEERP_EXPORT_STILL_EXCUSED: public.erp_export_tenant is still registered as a definer door';
  end if;
end
$$;

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
