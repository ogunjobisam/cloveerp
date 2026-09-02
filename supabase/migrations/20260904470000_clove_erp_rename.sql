-- =============================================================================
-- The product is Clove ERP
--
-- ERPWare was renamed Clove ERP: the domain, the repository and the Supabase
-- project all carry the new name. Migrations already on main are immutable,
-- so the four places the database itself said the old name are re-issued here
-- rather than edited in place — three comments and one table comment, and the
-- three functions that put the name into data a person reads: the display
-- name a platform staff principal gets when entering a company, and the
-- description on the vault secret that holds a company's data key.
--
-- What deliberately keeps the old spelling: the ERPWARE_ prefix on every
-- refusal code, the erp schemas, and the erpware: prefix on vault secret
-- names. Those are identifiers, not the product's name — six hundred refusal
-- codes are matched by the client and the suites, and a secret's name is how
-- an existing company's key is found. Renaming an identifier is not a rename
-- of the product; it is a migration of every reader, and there is no reader
-- who benefits.
-- =============================================================================

comment on schema erp is
  'Clove ERP product schema. Every operational table in here carries a tenant_id '
  'and is protected by a row-level security policy keyed on the session tenant.';

comment on table erp.external_ref is
  'Spec 4.9: a mapping between a Clove ERP object and its identifier in an '
  'external system, with sync state. The only home for an external identifier.';

comment on function erp.link_external_ref(text, text, uuid, text, text, erp.sync_authority) is
  'Records or refreshes the mapping between a Clove ERP object and its identity '
  'in an external system.';

comment on function erp.session_context_hygiene_report() is
  'Every GUC Clove ERP uses to carry security or transaction context must be '
  'written transaction-locally. This reports any function that does not.';

-- Re-emitted from 20260830112154 with the secret description changed. The
-- secret name keeps its erpware: prefix, because it is the key's identity.
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
    'Clove ERP per-tenant data key');

  insert into erp.tenant_key (tenant_id, purpose, kms_key_ref, key_version,
                              activated_at, created_by, updated_by)
  values (v_tenant, p_purpose, v_ref::text, v_version, now(),
          erp.current_principal_id(), erp.current_principal_id())
  returning id into v_id;

  perform erp.append_event('tenant.key_created', 'tenant_key', v_id,
    jsonb_build_object('purpose', p_purpose, 'key_version', v_version));

  return v_id;
end $$;

-- Re-emitted from 20260830112320 with the secret description changed.
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
            'Clove ERP per-tenant data key')::text,
          v_new_version, now(), erp.current_principal_id(), erp.current_principal_id())
  returning id into v_new_id;

  update erp.tenant_secret s
     set ciphertext = extensions.pgp_sym_encrypt(
           extensions.pgp_sym_decrypt(s.ciphertext, v_old_material), v_new_material),
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

-- Re-emitted from 20260830091046 with the principal's display name changed.
create or replace function public.erp_platform_enter_tenant(
  p_tenant_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  v_t    erp.tenant;
  v_user uuid;
  v_role uuid;
begin
  v := erp_meta.require_platform('support');

  if coalesce(trim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: entering a customer tenant needs a reason'
      using errcode = '22023';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                              email, user_locale)
    values (p_tenant_id, v.auth_user_id, 'person', 'active',
            v.display_name || ' (Clove ERP ' || v.staff_role || ')',
            v.email, 'en')
    returning id into v_user;
  else
    update erp.app_user set status = 'active' where id = v_user;
  end if;

  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'administrator' and r.status = 'active';

  if v_role is not null and not exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id and ur.app_user_id = v_user and ur.role_id = v_role)
  then
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (p_tenant_id, v_user, v_role,
            'Platform ' || v.staff_role || ' support access: ' || p_reason);
  end if;

  insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
  values (v.auth_user_id, p_tenant_id)
  on conflict (auth_user_id)
    do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason);

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user);
end;
$$;

-- Nothing here changes a signature or a grant, so the ACLs the three carry
-- are untouched; the assertions confirm it.
select erp.assert_public_api_safe();
select erp.assert_session_context_hygiene();
