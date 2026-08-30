alter table erp.tenant_key drop constraint tenant_key_purpose_check;
alter table erp.tenant_key add constraint tenant_key_purpose_check
  check (purpose = any (array['data','storage','export','backup','tenant_data']));
select pg_notify('pgrst','reload schema');