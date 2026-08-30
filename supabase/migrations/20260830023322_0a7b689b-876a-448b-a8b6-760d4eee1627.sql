CREATE OR REPLACE FUNCTION public.erp_change_requests(p_object_type text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO ''
AS $function$
declare v_tenant uuid;
begin
  perform erp.authorise('master_data.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x_created_at desc) from (
      select jsonb_build_object(
        'change_request_id', cr.id, 'object_type', cr.object_type, 'object_id', cr.object_id,
        'status', cr.status, 'reason', cr.reason, 'proposed', cr.proposed,
        'before', cr.before_snapshot, 'requested_by', a.display_name,
        'created_at', cr.created_at, 'applied_at', cr.applied_at,
        'governance', coalesce((select jsonb_agg(to_jsonb(g)) from erp.change_request_governance(cr.id) g), '[]'::jsonb)
      ) as x, cr.created_at as x_created_at
        from erp.change_request cr
        left join erp.app_user a on a.tenant_id = cr.tenant_id and a.id = cr.created_by
       where cr.tenant_id = v_tenant
         and (p_object_type is null or cr.object_type = p_object_type)) t), '[]'::jsonb);
end;
$function$;

ALTER FUNCTION erp.data_quality_report(text) SECURITY DEFINER;
ALTER FUNCTION erp.score_master_record(text, uuid) SECURITY DEFINER;
ALTER FUNCTION erp.data_quality_score(text, uuid) SECURITY DEFINER;