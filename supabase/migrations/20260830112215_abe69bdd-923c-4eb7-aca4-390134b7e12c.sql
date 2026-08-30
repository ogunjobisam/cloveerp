create or replace function erp.rotate_tenant_key(p_purpose text default 'tenant_data',
                                                 p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_old_id uuid; v_old_ref text; v_old_material text; v_old_version integer;
  v_new_id uuid; v_new_material text; v_new_version integer;
  v_reencrypted integer := 0;
begin
  perform erp.authorise('administration.configure');

  perform erp.ensure_tenant_key(p_purpose);

  select k.id, k.kms_key_ref, k.key_version
    into v_old_id, v_old_ref, v_old_version
    from erp.tenant_key k
   where k.tenant_id = v_tenant and k.purpose = p_purpose and k.destroyed_at is null
   order by k.key_version desc limit 1;

  select s.decrypted_secret into v_old_material
    from vault.decrypted_secrets s where s.id = v_old_ref::uuid;

  v_new_version := v_old_version + 1;
  v_new_material := encode(extensions.gen_random_bytes(32), 'base64');

  insert into erp.tenant_key (tenant_id, purpose, kms_key_ref, key_version,
                              activated_at, created_by, updated_by)
  values (v_tenant, p_purpose,
          vault.create_secret(v_new_material,
            'erpware:' || v_tenant::text || ':' || p_purpose || ':v' || v_new_version,
            'ERPWare per-tenant data key')::text,
          v_new_version, now(), erp.current_principal_id(), erp.current_principal_id())
  returning id into v_new_id;

  -- Everything protected under the old key is re-protected under the new one
  -- before the old key stops existing. After this point the old key is of no
  -- use to anybody, which is the only honest moment to destroy it.
  update erp.tenant_secret s
     set ciphertext = public.pgp_sym_encrypt(
           public.pgp_sym_decrypt(s.ciphertext, v_old_material), v_new_material),
         key_version = v_new_version,
         updated_at = now(), updated_by = erp.current_principal_id()
   where s.tenant_id = v_tenant;
  get diagnostics v_reencrypted = row_count;

  delete from vault.secrets where id = v_old_ref::uuid;

  update erp.tenant_key k
     set rotated_at = now(), destroyed_at = now(),
         destruction_witness = coalesce(p_reason, 'rotation'),
         kms_key_ref = 'destroyed:' || k.kms_key_ref,
         updated_at = now(), updated_by = erp.current_principal_id()
   where k.id = v_old_id;

  perform erp.append_event('tenant.key_rotated', 'tenant_key', v_new_id,
    jsonb_build_object('purpose', p_purpose, 'from_version', v_old_version,
                       'to_version', v_new_version, 'reason', p_reason,
                       'values_reprotected', v_reencrypted));

  return jsonb_build_object('purpose', p_purpose, 'key_version', v_new_version,
                            'values_reprotected', v_reencrypted,
                            'previous_key_destroyed', true);
end $$;

select pg_notify('pgrst','reload schema');