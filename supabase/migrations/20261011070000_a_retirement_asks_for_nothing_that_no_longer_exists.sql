set lock_timeout = '30s';

-- =============================================================================
-- 20261011070000  A retirement asks for nothing that no longer exists
-- -----------------------------------------------------------------------------
-- On 8 October the application moved from Lovable's hosting to a Cloudflare
-- Worker that serves cloveerp.com and every subdomain through one wildcard
-- route (.github/workflows/app.yml, wrangler.production.jsonc). A client
-- needs no domain or DNS record of its own any more, so the note the retire
-- door records — which the Fleet view shows as the client's last step — no
-- longer tells the owner to remove a Lovable domain and DNS records. The
-- door is re-made with that one sentence changed; it still deletes nothing,
-- and a retired address already answers nothing (erp_deployment_for_host).
-- =============================================================================

create or replace function public.erp_platform_retire_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  d       erp_meta.deployment;
  -- The register's own word, a text column's value. Named rather than
  -- written inline: erp.record_status_literal_report() looks for that word
  -- written into a record_status column, which has no such value, and a
  -- register column is not one (20261011040000).
  c_retired constant text := 'retired';
  v_last  erp_meta.deployment_event;
  v_busy  text;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: retiring a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say why the deployment is retired and what becomes of its project. At least twenty characters.';
  end if;

  -- The row's lock, held to the end: a release asking whether it may start
  -- (erp_meta.begin_deployment_release) waits for this, and then sees the
  -- row retired (20261011050000).
  select * into d from erp_meta.deployment x where x.code = d.code for update;

  -- The newest step of a release or a build dispatch, if any.
  select * into v_last
    from erp_meta.deployment_event e
   where e.code = d.code and e.phase in ('release', 'dispatch', 'create', 'build')
   order by e.at desc, e.id desc
   limit 1;

  v_busy := case
    when d.status in ('creating', 'building') then 'its build is running'
    when d.status = c_retired then 'it is retired already'
    when v_last.phase = 'release' and v_last.status = 'started' and v_last.at > now() - interval '90 minutes'
      then 'a release to it has started and not finished'
    when d.status = 'requested' and v_last.phase = 'dispatch' and v_last.at > now() - interval '90 minutes'
      then 'its build has been started and has not yet begun'
  end;

  if v_busy is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE: % is not retired: %', d.code, v_busy
      using errcode = '55000',
            hint = 'Wait until the Fleet view shows no build or release running for it, then retire it. If it is '
                   'retired already, there is nothing left to do but delete its project in the Supabase dashboard.';
  end if;

  update erp_meta.deployment x
     set status = c_retired, owner_email = null, updated_at = now()
   where x.code = d.code;

  -- A build still waiting for the sweep would rebuild a deployment that is
  -- gone. A release waiting for it is left alone: it may name the control
  -- plane and other clients too, and the train itself releases nothing to a
  -- retired client (deploy.yml reads only built and live ones, and each
  -- client's release asks the register first) (20261011060000).
  update erp_meta.fleet_request r
     set status = 'cancelled', outcome = 'the deployment was retired', settled_at = now()
   where r.status = 'requested'
     and r.kind = 'build'
     and r.payload ->> 'code' = d.code;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('retired by %s (was %s): %s. Nothing runs for it now: delete project %s in the Supabase dashboard. Its address needs nothing removed: it answers nothing once retired.',
           v.email, d.status, btrim(p_reason), coalesce(d.project_ref, 'that was never made')));

  perform erp_meta.platform_log(v, 'platform.deployment_retired', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'project_ref', d.project_ref));

  return jsonb_build_object('code', d.code, 'status', c_retired, 'was', d.status, 'project_ref', d.project_ref);
end;
$$;

revoke all on function public.erp_platform_retire_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_retire_deployment(text, text) to authenticated, service_role;

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
select erp.assert_personal_data_register_sound();
