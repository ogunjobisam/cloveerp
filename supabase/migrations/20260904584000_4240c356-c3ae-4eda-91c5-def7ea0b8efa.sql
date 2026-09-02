-- 1. Read wrappers that also write (audit trail) must not be STABLE.
ALTER FUNCTION public.erp_adoption_signals() VOLATILE;
ALTER FUNCTION public.erp_commercial_summary() VOLATILE;
ALTER FUNCTION public.erp_determination_coverage_report() VOLATILE;
ALTER FUNCTION public.erp_domain_cutovers() VOLATILE;
ALTER FUNCTION public.erp_erasure_requests() VOLATILE;
ALTER FUNCTION public.erp_erasure_subjects() VOLATILE;
ALTER FUNCTION public.erp_help_topics() VOLATILE;
ALTER FUNCTION public.erp_migration_domains() VOLATILE;
ALTER FUNCTION public.erp_opening_batches() VOLATILE;
ALTER FUNCTION public.erp_parallel_run_figures() VOLATILE;
ALTER FUNCTION public.erp_personal_data_register() VOLATILE;
ALTER FUNCTION public.erp_proposals(text) VOLATILE;

-- 2. Platform-staff reads over erp_meta: definer rights, explicit staff gate.
CREATE OR REPLACE FUNCTION public.erp_platform_incidents()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.declared_at desc)
                     from erp.incident_report() r), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_platform_disclosures()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(to_jsonb(r)) from erp.disclosure_report() r), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_platform_maintenance_windows()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.starts_at desc)
                     from erp.maintenance_report() r), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_platform_incident_organisations(p_incident_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  perform erp_meta.require_platform('support');
  return coalesce((
    select jsonb_agg(jsonb_build_object('tenant_code', t.tenant_code, 'named_at', t.named_at,
                                        'named_by', t.named_by) order by t.tenant_code)
      from erp_meta.incident_tenant t
      join erp_meta.incident i on i.id = t.incident_id
     where i.code = p_incident_code), '[]'::jsonb);
end;
$function$;

-- 3. Platform-staff writes: definer rights. The erp.* routine each one calls
--    performs its own erp_meta.require_platform(...) check first.
ALTER FUNCTION erp.declare_incident(text, text, text, text, text, text, boolean, text, boolean) SECURITY DEFINER;
ALTER FUNCTION erp.contain_incident(text, text, boolean) SECURITY DEFINER;
ALTER FUNCTION erp.resolve_incident(text, text) SECURITY DEFINER;
ALTER FUNCTION erp.post_incident_update(text, text, boolean) SECURITY DEFINER;
ALTER FUNCTION erp.name_affected_organisations(text, text[]) SECURITY DEFINER;
ALTER FUNCTION erp.flag_security_incident(text) SECURITY DEFINER;
ALTER FUNCTION erp.record_disclosure(text, text, text) SECURITY DEFINER;
ALTER FUNCTION erp.announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text) SECURITY DEFINER;
ALTER FUNCTION erp.cancel_maintenance(text, text) SECURITY DEFINER;