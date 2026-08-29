-- Membership is per-tenant: one principal per account within a tenant,
-- but an account may belong to several tenants. The only consumer of
-- auth_user_id lookups, erp.principal_context(), already resolves the
-- working tenant explicitly (newest principal wins).
ALTER TABLE erp.app_user DROP CONSTRAINT app_user_auth_user_id_key;
ALTER TABLE erp.app_user ADD CONSTRAINT app_user_tenant_id_auth_user_id_key UNIQUE (tenant_id, auth_user_id);