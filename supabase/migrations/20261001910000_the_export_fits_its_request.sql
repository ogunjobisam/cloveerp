set lock_timeout = '30s';

-- ═════════════════════════════════════════════════════════════════════════════
-- The export fits its request
-- ═════════════════════════════════════════════════════════════════════════════
--
-- On 29 September at 14:53 UTC, "Download as JSON" on Settings → Organisation
-- ran 9.2 s and was cancelled at the authenticated role's statement_timeout,
-- inside the single statement that builds the export. The screen then said
-- "Try a narrower selection", and the export has no selection to narrow.
--
-- public.erp_export_tenant() is one jsonb_build_object over twenty-one tables:
-- every row the organisation holds, including every audit entry with its
-- before and after state. It ran as the caller, so every one of those rows
-- also passed row security, and the policy is
--
--   tenant_id = erp.current_tenant_id()
--
-- where current_tenant_id() is never inlined, so erp.principal_context() ran
-- once per row. 20261001900000 found the same cost cancelling
-- erp_accept_interview a quarter of an hour later.
--
-- Two changes, and no change to the body:
--
--   * The door runs as its owner. Every subquery in it already reads
--     `where x.tenant_id = v_tenant`, and v_tenant is erp.require_tenant_id(),
--     resolved before anything is read and after the gate on the first line,
--     erp.authorise('administration.configure'). The policy was asking the same
--     question again for every row. Registered in
--     erp_meta.security_definer_allowance, as every definer door is.
--   * The door gets the fifty-five seconds erp_platform_assurance, both purge
--     doors and erp_accept_interview have. PostgREST applies a function's own
--     statement_timeout to the call, and sixty seconds is the most a request
--     through the API is given.
--
-- Not done: an export built in parts, or in the background and collected
-- later. An organisation whose data does not fit in fifty-five seconds still
-- cannot export through the screen, and the screen still words that as a
-- timeout. That is the next step if it happens, not a guess to make now.
-- ═════════════════════════════════════════════════════════════════════════════

alter function public.erp_export_tenant() security definer;
alter function public.erp_export_tenant() set statement_timeout = '55s';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_export_tenant',
   'Reads every table the organisation owns into one export. Gated on its first '
   'line by erp.authorise(''administration.configure''), and every read is '
   'filtered to the organisation erp.require_tenant_id() resolves, so running as '
   'the owner skips only the per-row policy check that asked the same question '
   'again for every row and took the export past its request limit.')
on conflict (schema_name, function_name) do update
  set rationale = excluded.rationale;

-- Proved here rather than trusted: the door runs as its owner, has its time,
-- still gates, and still reads only through the resolved organisation.
do $$
declare
  p pg_catalog.pg_proc%rowtype;
begin
  select * into p from pg_catalog.pg_proc
   where oid = 'public.erp_export_tenant()'::regprocedure;

  if not p.prosecdef then
    raise exception 'CLOVEERP_EXPORT_NOT_DEFINER: public.erp_export_tenant still runs as the caller';
  end if;
  if not ('statement_timeout=55s' = any (coalesce(p.proconfig, '{}'))
          and 'search_path=""' = any (coalesce(p.proconfig, '{}'))) then
    raise exception 'CLOVEERP_EXPORT_CONFIG_MISSING: public.erp_export_tenant needs statement_timeout=55s and an empty search_path, has %', p.proconfig;
  end if;
  if p.prosrc !~ 'perform\s+erp\.authorise\(''administration\.configure''\)'
     or p.prosrc !~ 'v_tenant\s+uuid\s*:=\s*erp\.require_tenant_id\(\)' then
    raise exception 'CLOVEERP_EXPORT_UNGATED: public.erp_export_tenant no longer gates or no longer resolves its organisation first';
  end if;
  -- Every table read is followed by its tenant filter; the tenant row itself
  -- is read by id.
  if (select count(*) from regexp_matches(p.prosrc, 'from\s+erp\.\w+\s+\w+\s+where', 'g'))
     <> (select count(*) from regexp_matches(p.prosrc, 'where\s+\w+\.(tenant_id|id)\s*=\s*v_tenant', 'g')) then
    raise exception 'CLOVEERP_EXPORT_UNSCOPED_READ: a read in public.erp_export_tenant is not filtered to v_tenant';
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
