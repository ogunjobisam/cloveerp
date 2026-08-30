create or replace function erp.ensure_tenant_key(p_purpose text default 'tenant_data')
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
  v_ref uuid;
  v_version integer;
begin
  select k.id into v_id from erp.tenant_key k
   where k.tenant_id = v_tenant and k.purpose = p_purpose and k.destroyed_at is null
   order by k.key_version desc limit 1;
  if v_id is not null then
    return v_id;
  end if;

  select coalesce(max(k.key_version), 0) + 1 into v_version
    from erp.tenant_key k where k.tenant_id = v_tenant and k.purpose = p_purpose;

  v_ref := vault.create_secret(
    encode(extensions.gen_random_bytes(32), 'base64'),
    'erpware:' || v_tenant::text || ':' || p_purpose || ':v' || v_version,
    'ERPWare per-tenant data key');

  insert into erp.tenant_key (tenant_id, purpose, kms_key_ref, key_version,
                              activated_at, created_by, updated_by)
  values (v_tenant, p_purpose, v_ref::text, v_version, now(),
          erp.current_principal_id(), erp.current_principal_id())
  returning id into v_id;

  perform erp.append_event('tenant.key_created', 'tenant_key', v_id,
    jsonb_build_object('purpose', p_purpose, 'key_version', v_version));

  return v_id;
end $$;

create or replace function erp.rotate_tenant_key(p_purpose text default 'tenant_data',
                                                 p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_old record;
  v_new_version integer;
  v_new_ref uuid;
  v_new_material text;
  v_id uuid;
begin
  perform erp.authorise('administration.configure');

  select k.id, k.key_version, k.kms_key_ref into v_old
    from erp.tenant_key k
   where k.tenant_id = v_tenant and k.purpose = p_purpose and k.destroyed_at is null
   order by k.key_version desc limit 1;

  perform erp.ensure_tenant_key(p_purpose);

  select k.id, k.key_version, k.kms_key_ref into v_old
    from erp.tenant_key k
   where k.tenant_id = v_tenant and k.purpose = p_purpose and k.destroyed_at is null
   order by k.key_version desc limit 1;

  v_new_version := v_old.key_version + 1;
  v_new_material := encode(extensions.gen_random_bytes(32), 'base64');
  v_new_ref := vault.create_secret(
    v_new_material,
    'erpware:' || v_tenant::text || ':' || p_purpose || ':v' || v_new_version,
    'ERPWare per-tenant data key (rotated)');

  update erp.tenant_key
     set rotated_at = now(),
         destruction_witness = coalesce(p_reason, 'rotation'),
         destroyed_at = now(),
         updated_by = erp.current_principal_id()
   where id = v_old.id;

  perform erp.destroy_vault_secret(v_old.kms_key_ref);

  insert into erp.tenant_key (tenant_id, purpose, kms_key_ref, key_version,
                              activated_at, created_by, updated_by)
  values (v_tenant, p_purpose, v_new_ref::text, v_new_version, now(),
          erp.current_principal_id(), erp.current_principal_id())
  returning id into v_id;

  perform erp.append_event('tenant.key_rotated', 'tenant_key', v_id,
    jsonb_build_object('purpose', p_purpose, 'from_version', v_old.key_version,
                       'to_version', v_new_version, 'reason', p_reason));

  return jsonb_build_object('ok', true, 'key_version', v_new_version);
end $$;