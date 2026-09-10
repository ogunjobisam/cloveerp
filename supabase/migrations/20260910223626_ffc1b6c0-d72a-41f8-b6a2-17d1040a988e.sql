insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values
  ('erp', 'is_platform_owner', 'Resolves platform ownership from erp_meta without granting tenant users read access to the platform control plane; called by erp.has_permission and erp.authorise.'),
  ('erp_meta', 'is_platform_owner', 'Reads erp_meta.platform_principal for the calling auth user; the control plane is not readable by tenant roles.')
on conflict do nothing;

update erp.document_type
   set create_permission = 'procurement.match'
 where code = 'purchase_invoice'
   and create_permission is distinct from 'procurement.match';

select erp.apply_row_security();
select erp.apply_execute_grants();
select erp.assert_document_create_permissions();
select erp.assert_governed_views_are_safe();