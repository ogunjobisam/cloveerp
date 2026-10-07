set lock_timeout = '30s';

-- =============================================================================
-- 20261011030000  The checklist refusal speaks plainly
-- -----------------------------------------------------------------------------
-- 20261011020000 registered CLOVEERP_CHECKLIST_ITEM_UNKNOWN with a next step
-- that named the checklist's items as the register spells them —
-- lovable_domain, dns, google_sign_in, resend_webhook — which
-- erp_test.plain_words_suite rightly refuses: a word with an underscore in it
-- is one only the people who build Clove ERP would follow, and the refusal
-- is shown to the operator who ticked the wrong thing. The register is
-- re-worded here, and the door that raises it says the same.
--
-- A new migration rather than a change to the last one: a migration is
-- written once (supabase/ci/preflight.sh, rule E), and erp.register_refusal
-- is an upsert made for this.
-- =============================================================================

select erp.register_refusal(
  'CLOVEERP_CHECKLIST_ITEM_UNKNOWN',
  'Ticking a step of a deployment''s checklist that the checklist does not have.',
  'The checklist holds the steps a person still does by hand after a build: the Lovable domain, the DNS '
  'records, Google sign-in if the client wants it, and the email provider''s webhook.',
  'Tick one of the four steps the Fleet view lists: the Lovable domain, the DNS records, Google sign-in, or '
  'the Resend webhook.');

create or replace function public.erp_platform_deployment_checklist(p_code text, p_item text, p_done boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  d      erp_meta.deployment;
  v_item text := lower(btrim(coalesce(p_item, '')));
  v_list jsonb;
begin
  v := erp_meta.require_platform('operator');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);
  if v_item not in ('lovable_domain', 'dns', 'google_sign_in', 'resend_webhook') then
    raise exception 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: "%" is not a step of the checklist', p_item
      using errcode = '22023',
            hint = 'Tick one of the four steps the Fleet view lists: the Lovable domain, the DNS records, '
                   'Google sign-in, or the Resend webhook.';
  end if;
  update erp_meta.deployment x
     set checklist = x.checklist || jsonb_build_object(v_item,
                       jsonb_build_object('done', coalesce(p_done, false), 'at', now(), 'by', v.email)),
         updated_at = now()
   where x.code = d.code
  returning x.checklist into v_list;
  perform erp_meta.record_deployment_event(d.code, 'checklist', 'note',
    format('%s %s by %s', v_item, case when coalesce(p_done, false) then 'done' else 'not done' end, v.email));
  perform erp_meta.platform_log(v, 'platform.deployment_checklist', null, d.code, null,
    jsonb_build_object('item', v_item, 'done', coalesce(p_done, false)));
  return jsonb_build_object('code', d.code, 'checklist', v_list);
end;
$$;

revoke all on function public.erp_platform_deployment_checklist(text, text, boolean) from public, anon;
grant execute on function public.erp_platform_deployment_checklist(text, text, boolean) to authenticated, service_role;

comment on function public.erp_platform_deployment_checklist(text, text, boolean) is
  'Ticks or unticks one of the steps a person does by hand after a client deployment''s build: the Lovable '
  'domain, the DNS records, Google sign-in, the email provider''s webhook. Platform operator and above, on the '
  'control plane (20261011020000, 20261011030000).';

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
