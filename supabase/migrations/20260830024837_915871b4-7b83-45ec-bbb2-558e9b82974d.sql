revoke select on erp_meta.security_definer_allowance, erp_meta.public_write_allowance,
  erp_meta.table_policy, erp_meta.sensitive_object, erp_meta.audit_exemption,
  erp_meta.attribution_exemption, erp_meta.maintainable_field,
  erp_meta.transaction_path_function, erp_meta.command_transition from authenticated;
revoke usage on schema erp_meta from authenticated;

create or replace function erp.platform_assurance()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare v_result jsonb := '[]'::jsonb; v_check text; v_error text;
begin
  foreach v_check in array array[
    'erp.assert_isolation','erp.assert_audit_coverage','erp.assert_attribution_coverage',
    'erp.assert_session_context_hygiene','erp.assert_gateway_integrity',
    'erp.assert_scheduler_integrity','erp.assert_governed_views_are_safe',
    'erp.assert_intelligence_boundary','erp.assert_public_api_safe'
  ] loop
    begin
      execute format('select %s()', v_check);
      v_error := null;
    exception when others then
      v_error := sqlerrm;
    end;
    v_result := v_result || jsonb_build_object('check', v_check, 'ok', v_error is null, 'detail', v_error);
  end loop;
  return v_result;
end;
$$;

create or replace function public.erp_platform_assurance()
returns jsonb
language sql
stable
security invoker
set search_path to ''
as $$ select erp.platform_assurance() $$;

grant execute on function erp.platform_assurance() to authenticated, service_role;
revoke all on function public.erp_platform_assurance() from public, anon;
grant execute on function public.erp_platform_assurance() to authenticated, service_role;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp','platform_assurance','Runs the platform self-checks, which read the product rule catalogue in erp_meta rather than any tenant data, and returns only pass or fail per check.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;