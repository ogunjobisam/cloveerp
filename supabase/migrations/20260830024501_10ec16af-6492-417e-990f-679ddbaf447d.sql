update erp_meta.public_write_allowance set gate = 'erp.decide_approval_task' where function_name = 'erp_decide_approval';
update erp_meta.public_write_allowance set gate = 'erp.change_request_governance' where function_name = 'erp_change_requests';
update erp_meta.public_write_allowance set gate = 'erp.authorise'
 where function_name in ('erp_add_party_role','erp_create_item','erp_create_party','erp_export_tenant','erp_import_batches','erp_request_tenant_deletion','erp_set_resource_override');