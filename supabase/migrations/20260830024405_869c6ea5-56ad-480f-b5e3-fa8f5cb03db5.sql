-- 1. Register the security-definer helpers added for data quality and demo seeding
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
 ('erp','data_quality_report','Reads erp_meta.maintainable_field, which the product role cannot read directly, and returns only rows for the caller''s own tenant.'),
 ('erp','data_quality_score','Scores a single master record against erp_meta.maintainable_field within the caller''s tenant scope.'),
 ('erp','score_master_record','Shared scoring helper for data quality; reads catalogue metadata only and never crosses tenant scope.'),
 ('erp','seed_demo_master_data','Creates demonstration master data inside the caller''s own tenant through the same governed writers a user would use.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- 2. Put the remaining operational wrappers on the public write allow-list
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
 ('erp_add_party_role','erp.add_party_role','Adds a trading role to a party under master_data.write; roles are additive and never remove history.'),
 ('erp_create_party','erp.create_party','Creates a party under master_data.write through the canonical writer, with the same validation the governed path uses.'),
 ('erp_create_item','erp.create_item','Creates an item under master_data.write through the canonical writer, including its base unit of measure.'),
 ('erp_set_resource_override','erp.set_resource_override','Records a tenant terminology override under administration.configure; product resource text itself is never changed.'),
 ('erp_submit_change_request','erp.submit_change_request','Submits a drafted master-data change for approval under master_data.write; it proposes, it does not apply.'),
 ('erp_apply_change_request','erp.apply_change_request','Applies an approved master-data change under master_data.approve, and refuses a request that has not cleared approval.'),
 ('erp_decide_approval','erp.decide_approval','Records an approve or reject decision on a task assigned to the caller; the decision itself is the audited write.'),
 ('erp_preview_import','erp.preview_import','Previews a staged import batch; it writes only the preview verdict rows against the caller''s own batch.'),
 ('erp_validate_import','erp.validate_import','Validates a staged import batch and writes row-level validation findings against the caller''s own batch.'),
 ('erp_import_batches','erp.import_batches','Lists the caller''s import batches; it writes only the authorisation audit entry every gated read records.'),
 ('erp_change_requests','erp.change_requests','Lists governed change requests for the tenant; it writes only the authorisation audit entry every gated read records.'),
 ('erp_export_tenant','erp.export_tenant','Produces the tenant portability export under administration.export, and records the export as an audited event.'),
 ('erp_request_tenant_deletion','erp.request_tenant_deletion','Opens a tenant deletion request under administration.configure; deletion itself remains a separate, confirmed step.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 3. The product surface is for authenticated principals only
do $$
declare r record;
begin
  for r in select p.oid::regprocedure::text sig from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'erp\_%' loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end $$;

-- 4. Assurance runs as the caller, so it cannot see past row-level security
alter function public.erp_platform_assurance() security invoker;