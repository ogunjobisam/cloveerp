grant usage on schema erp_meta to authenticated;
grant select on erp_meta.security_definer_allowance, erp_meta.public_write_allowance,
  erp_meta.table_policy, erp_meta.sensitive_object, erp_meta.audit_exemption,
  erp_meta.attribution_exemption, erp_meta.maintainable_field,
  erp_meta.transaction_path_function, erp_meta.command_transition to authenticated;