-- ---------------------------------------------------------------------------
-- Per-tenant encryption keys, crypto-shredding, and end-to-end billing demo.
-- ---------------------------------------------------------------------------

create table if not exists erp.tenant_secret (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  ciphertext   bytea not null,
  key_version  integer not null,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  unique (tenant_id, code)
);

grant select, insert, update, delete on erp.tenant_secret to service_role;
alter table erp.tenant_secret enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='erp'
                   and tablename='tenant_secret' and policyname='tenant_isolation') then
    create policy tenant_isolation on erp.tenant_secret
      using (tenant_id = erp.current_tenant_id())
      with check (tenant_id = erp.current_tenant_id());
  end if;
end $$;

insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
values ('erp', 'tenant_secret', 'tenant_scoped',
        'Ciphertext only; readable solely through the tenant key.')
on conflict do nothing;

-- --- key lifecycle -------------------------------------------------------

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

create or replace function erp.tenant_key_material(p_purpose text default 'tenant_data')
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_ref text;
  v_material text;
begin
  select k.kms_key_ref into v_ref from erp.tenant_key k
   where k.tenant_id = v_tenant and k.purpose = p_purpose and k.destroyed_at is null
   order by k.key_version desc limit 1;

  if v_ref is null then
    raise exception 'ERPWARE_KEY_DESTROYED: this company has no live % key, so protected values cannot be read', p_purpose
      using errcode = '42501',
      hint = 'Key destruction is irreversible by design; anything encrypted under it is unrecoverable.';
  end if;

  select s.decrypted_secret into v_material
    from vault.decrypted_secrets s where s.id = v_ref::uuid;

  if v_material is null then
    raise exception 'ERPWARE_KEY_DESTROYED: the key material for % is gone', p_purpose
      using errcode = '42501';
  end if;
  return v_material;
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

create or replace function erp.destroy_tenant_keys(p_witness text)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r record;
  v_n integer := 0;
begin
  for r in select k.id, k.kms_key_ref, k.purpose, k.key_version
             from erp.tenant_key k
            where k.tenant_id = v_tenant and k.destroyed_at is null
  loop
    begin
      delete from vault.secrets where id = r.kms_key_ref::uuid;
    exception when others then
      null; -- a reference that is already gone is the desired end state
    end;

    update erp.tenant_key k
       set destroyed_at = now(), destruction_witness = p_witness,
           kms_key_ref = 'destroyed:' || k.kms_key_ref,
           updated_at = now(), updated_by = erp.current_principal_id()
     where k.id = r.id;

    perform erp.append_event('tenant.key_destroyed', 'tenant_key', r.id,
      jsonb_build_object('purpose', r.purpose, 'key_version', r.key_version,
                         'witness', p_witness));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function erp.put_tenant_secret(p_code text, p_value text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_material text;
  v_version integer;
begin
  perform erp.authorise('administration.configure');
  perform erp.ensure_tenant_key('tenant_data');
  v_material := erp.tenant_key_material('tenant_data');
  select k.key_version into v_version from erp.tenant_key k
   where k.tenant_id = v_tenant and k.purpose = 'tenant_data' and k.destroyed_at is null
   order by k.key_version desc limit 1;

  insert into erp.tenant_secret (tenant_id, code, ciphertext, key_version, created_by, updated_by)
  values (v_tenant, p_code, public.pgp_sym_encrypt(p_value, v_material), v_version,
          erp.current_principal_id(), erp.current_principal_id())
  on conflict (tenant_id, code) do update
     set ciphertext = excluded.ciphertext, key_version = excluded.key_version,
         updated_at = now(), updated_by = erp.current_principal_id();
end $$;

create or replace function erp.get_tenant_secret(p_code text)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cipher bytea;
begin
  perform erp.authorise('administration.configure');
  select s.ciphertext into v_cipher from erp.tenant_secret s
   where s.tenant_id = v_tenant and s.code = p_code;
  if v_cipher is null then return null; end if;
  return public.pgp_sym_decrypt(v_cipher, erp.tenant_key_material('tenant_data'));
end $$;

-- --- public surface ------------------------------------------------------

create or replace function public.erp_tenant_keys()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_tenant uuid; v_rows jsonb;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.require_tenant_id();
  perform erp.ensure_tenant_key('tenant_data');

  select coalesce(jsonb_agg(x order by x ->> 'purpose', (x ->> 'key_version')::int desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'key_id', k.id,
               'purpose', k.purpose,
               'key_version', k.key_version,
               'state', case when k.destroyed_at is not null then 'destroyed' else 'active' end,
               'activated_at', k.activated_at,
               'rotated_at', k.rotated_at,
               'destroyed_at', k.destroyed_at,
               'witness', k.destruction_witness,
               'protected_values', (select count(*) from erp.tenant_secret s
                                     where s.tenant_id = k.tenant_id
                                       and s.key_version = k.key_version)) as x
        from erp.tenant_key k where k.tenant_id = v_tenant) t;
  return v_rows;
end $$;

create or replace function public.erp_rotate_tenant_key(p_purpose text default 'tenant_data',
                                                        p_reason text default null)
returns jsonb
language sql
security definer
set search_path to ''
as $$ select erp.rotate_tenant_key(coalesce(p_purpose, 'tenant_data'), p_reason) $$;

create or replace function public.erp_put_protected_value(p_code text, p_value text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
begin
  if p_code is null or btrim(p_code) = '' then
    raise exception 'ERPWARE_VALIDATION: a name is required for a protected value';
  end if;
  perform erp.put_tenant_secret(btrim(p_code), coalesce(p_value, ''));
  return jsonb_build_object('code', btrim(p_code), 'stored', true);
end $$;

create or replace function public.erp_read_protected_value(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
begin
  return jsonb_build_object('code', p_code, 'value', erp.get_tenant_secret(p_code));
end $$;

create or replace function public.erp_protected_values()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.require_tenant_id();
  return coalesce((select jsonb_agg(jsonb_build_object(
            'code', s.code, 'key_version', s.key_version, 'updated_at', s.updated_at)
            order by s.code)
          from erp.tenant_secret s where s.tenant_id = v_tenant), '[]'::jsonb);
end $$;

-- Deletion destroys the keys, which is what makes deletion mean something.
create or replace function public.erp_request_tenant_deletion(p_confirm_code text, p_reason text)
returns jsonb
language plpgsql
set search_path to ''
as $$
declare v_tenant uuid; v_code text; v_overrides integer; v_keys integer;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.current_tenant_id();

  select t.code into v_code from erp.tenant t where t.id = v_tenant;
  if v_code is distinct from btrim(coalesce(p_confirm_code, '')) then
    raise exception 'ERPWARE_VALIDATION: the tenant code must be typed exactly to confirm deletion';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'ERPWARE_VALIDATION: a reason is required';
  end if;

  update erp.tenant t
     set status = 'suspended'::erp.tenant_status,
         suspended_at = now(),
         deleted_at = now(),
         retention_policy = coalesce(t.retention_policy, '{}'::jsonb)
                            || jsonb_build_object('deletion_requested_by', erp.current_principal_id(),
                                                  'deletion_requested_at', now(),
                                                  'deletion_reason', p_reason),
         updated_at = now(), updated_by = erp.current_principal_id()
   where t.id = v_tenant;

  delete from erp.resource_override o where o.tenant_id = v_tenant;
  get diagnostics v_overrides = row_count;

  v_keys := erp.destroy_tenant_keys('tenant deletion: ' || btrim(p_reason));

  return jsonb_build_object('tenant_id', v_tenant, 'status', 'suspended',
                            'overrides_destroyed', v_overrides,
                            'keys_destroyed', v_keys,
                            'note', 'Encryption keys were destroyed immediately and irreversibly; remaining operational data is removed by the scheduled purge.');
end $$;

revoke all on function erp.ensure_tenant_key(text) from public, anon, authenticated;
revoke all on function erp.tenant_key_material(text) from public, anon, authenticated;
revoke all on function erp.rotate_tenant_key(text, text) from public, anon, authenticated;
revoke all on function erp.destroy_tenant_keys(text) from public, anon, authenticated;
revoke all on function erp.put_tenant_secret(text, text) from public, anon, authenticated;
revoke all on function erp.get_tenant_secret(text) from public, anon, authenticated;

revoke all on function public.erp_tenant_keys() from public, anon;
revoke all on function public.erp_rotate_tenant_key(text, text) from public, anon;
revoke all on function public.erp_put_protected_value(text, text) from public, anon;
revoke all on function public.erp_read_protected_value(text) from public, anon;
revoke all on function public.erp_protected_values() from public, anon;
revoke all on function public.erp_request_tenant_deletion(text, text) from public, anon;

grant execute on function public.erp_tenant_keys() to authenticated;
grant execute on function public.erp_rotate_tenant_key(text, text) to authenticated;
grant execute on function public.erp_put_protected_value(text, text) to authenticated;
grant execute on function public.erp_read_protected_value(text) to authenticated;
grant execute on function public.erp_protected_values() to authenticated;
grant execute on function public.erp_request_tenant_deletion(text, text) to authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'ensure_tenant_key', 'Creates key material in the platform key store, which tenants cannot reach directly.'),
  ('erp', 'tenant_key_material', 'Reads key material; internal only, never granted to a session role.'),
  ('erp', 'rotate_tenant_key', 'Re-protects ciphertext and destroys the superseded key; authorises administration.configure first.'),
  ('erp', 'destroy_tenant_keys', 'Crypto-shredding on deletion; internal only.'),
  ('erp', 'put_tenant_secret', 'Encrypts under the tenant key; authorises administration.configure first.'),
  ('erp', 'get_tenant_secret', 'Decrypts under the tenant key; authorises administration.configure first.'),
  ('public', 'erp_tenant_keys', 'Key register for the tenant, gated on administration.configure.'),
  ('public', 'erp_rotate_tenant_key', 'Rotation entry point, gated on administration.configure.'),
  ('public', 'erp_put_protected_value', 'Protected value write, gated on administration.configure.'),
  ('public', 'erp_read_protected_value', 'Protected value read, gated on administration.configure.'),
  ('public', 'erp_protected_values', 'Protected value register, gated on administration.configure.')
on conflict do nothing;

-- --- demonstration billing and settlement --------------------------------

create or replace function erp.seed_demo_billing()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_notes jsonb := '[]'::jsonb;
  v_site uuid; v_entity uuid; v_ccy char(3);
  v_customer uuid; v_fg uuid; v_del uuid; v_inv uuid; v_so uuid;
  v_value bigint; v_paid bigint; v_qty numeric;
begin
  select s.id, s.entity_id, l.currency into v_site, v_entity, v_ccy
    from erp.site s
    join erp.ledger l on l.tenant_id = s.tenant_id and l.entity_id = s.entity_id
   where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
   order by s.code limit 1;

  if v_site is null then
    return jsonb_build_array('No active site with a ledger, so billing history was skipped.');
  end if;

  select p.id into v_customer from erp.party p
    join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
   where p.tenant_id = v_tenant and r.role_kind = 'customer' order by p.code limit 1;

  -- Bill for something that is actually on the shelf.
  select b.item_id, sum(b.quantity) into v_fg, v_qty
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = v_site and b.quantity > 0
   group by b.item_id
   order by sum(b.quantity) desc limit 1;

  if v_customer is null or v_fg is null then
    return jsonb_build_array('No customer or no stock on hand, so billing history was skipped.');
  end if;

  v_qty := least(coalesce(v_qty, 0), 10);
  if v_qty <= 0 then
    return jsonb_build_array('There is nothing in stock to despatch, so billing history was skipped.');
  end if;

  begin
    v_del := erp.create_document('delivery', v_entity, v_site, v_customer, current_date, v_ccy, 'DEMO-SEED-BILL');
    perform erp.add_document_line(v_del, v_fg, v_qty, 9900, 'Demo despatch');
    perform erp.transition_document(v_del, 'post');
    v_notes := v_notes || to_jsonb(('Despatched ' || v_qty || ' unit(s) to the customer.')::text);
  exception when others then
    v_del := null;
    v_notes := v_notes || to_jsonb(('Despatch was skipped: ' || sqlerrm)::text);
  end;

  if v_del is null then
    return v_notes;
  end if;

  -- Move the demonstration sales order along with it, so the order history
  -- reads the way it would if a person had done this.
  begin
    select d.id into v_so from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant and dt.base_type_code = 'sales_order'
       and d.party_id = v_customer and not d.is_cancelled
     order by d.created_at desc limit 1;
    if v_so is not null then
      perform erp.transition_document(v_so, 'pick');
      perform erp.transition_document(v_so, 'despatch');
    end if;
  exception when others then
    null;
  end;

  begin
    v_inv := erp.invoice_from_delivery(v_del, true);
    perform erp.transition_document(v_inv, 'issue');
    v_value := erp.document_value_minor(v_inv);
    v_notes := v_notes || to_jsonb(('Issued a sales invoice for '
      || to_char(v_value / 100.0, 'FM999999990.00') || ' ' || v_ccy || '.')::text);
  exception when others then
    v_inv := null;
    v_notes := v_notes || to_jsonb(('Invoicing was skipped: ' || sqlerrm)::text);
  end;

  if v_inv is null then
    return v_notes;
  end if;

  -- A part payment, deliberately: a demonstration in which everything is
  -- settled shows no ageing, no dunning and no collections work at all.
  begin
    v_paid := greatest((v_value * 6) / 10, 1);
    perform erp.apply_cash(v_customer, v_paid, v_ccy, 'DEMO-SEED-PAYMENT');
    v_notes := v_notes || to_jsonb(('Received a customer payment of '
      || to_char(v_paid / 100.0, 'FM999999990.00') || ' ' || v_ccy
      || '; the balance stays outstanding so ageing and dunning have something to show.')::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Cash application was skipped: ' || sqlerrm)::text);
  end;

  return v_notes;
end $$;

revoke all on function erp.seed_demo_billing() from public, anon, authenticated;

create or replace function erp.seed_demo_operations()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_site uuid; v_entity uuid; v_ccy char(3); v_notes jsonb := '[]'::jsonb;
  v_supplier uuid; v_customer uuid; v_rm uuid; v_fg uuid;
  v_po uuid; v_receipt uuid; v_so uuid; v_line uuid; v_wo uuid;
  v_recv uuid; v_prog text; v_n integer; v_seeded boolean;
begin
  perform erp.authorise('master_data.write', null, null, null, 'tenant', v_tenant);

  select s.id, s.entity_id, l.currency into v_site, v_entity, v_ccy
    from erp.site s
    join erp.ledger l on l.tenant_id = s.tenant_id and l.entity_id = s.entity_id
   where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
   order by s.code limit 1;

  if v_site is null then
    select s.id, s.entity_id into v_site, v_entity from erp.site s
     where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
     order by s.code limit 1;
  end if;

  if v_site is null then
    return jsonb_build_object('ok', false, 'notes',
      jsonb_build_array('There is no active site yet, so no operational history could be built.'));
  end if;

  if exists (select 1 from erp.document d
              where d.tenant_id = v_tenant and d.their_reference = 'DEMO-SEED-BILL') then
    return jsonb_build_object('ok', true, 'site', v_site, 'notes',
      jsonb_build_array('Demonstration history already runs end to end for this company; nothing was duplicated.'));
  end if;

  v_seeded := exists (select 1 from erp.document d
                       where d.tenant_id = v_tenant and d.their_reference = 'DEMO-SEED');

  if not v_seeded then
    begin
      perform erp.seed_demo_master_data(v_tenant, v_actor);
      v_notes := v_notes || to_jsonb('Demo master data is in place.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Master data could not be seeded: ' || sqlerrm)::text);
    end;

    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, created_by, updated_by)
    select v_tenant, v_site, x.code, x.name, x.lt::erp.location_type, x.pickable, v_actor, v_actor
      from (values ('RECV','Goods in','receiving',false),('BULK','Bulk store','bulk',false),
                   ('PICK','Pick face','pick',true),('QC','Quarantine','quarantine',false),
                   ('DESP','Despatch bay','despatch',false)) as x(code,name,lt,pickable)
     where not exists (select 1 from erp.location l
                        where l.tenant_id = v_tenant and l.site_id = v_site and l.code = x.code);

    select id into v_recv from erp.location where tenant_id = v_tenant and site_id = v_site and code = 'RECV';

    select p.id into v_supplier from erp.party p
      join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
     where p.tenant_id = v_tenant and r.role_kind = 'supplier' order by p.code limit 1;
    select p.id into v_customer from erp.party p
      join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
     where p.tenant_id = v_tenant and r.role_kind = 'customer' order by p.code limit 1;

    select id into v_rm from erp.item
     where tenant_id = v_tenant and status = 'active'::erp.record_status
     order by (code not like 'RM-%'), code limit 1;
    select id into v_fg from erp.item
     where tenant_id = v_tenant and status = 'active'::erp.record_status
       and (v_rm is null or id <> v_rm)
     order by (code not like 'FG-%'), code limit 1;
    v_fg := coalesce(v_fg, v_rm);

    if v_supplier is null or v_customer is null or v_rm is null then
      return jsonb_build_object('ok', false, 'notes', v_notes
        || to_jsonb('A supplier, a customer and at least one item are needed before history can be built.'::text));
    end if;

    begin
      v_notes := v_notes || to_jsonb(erp.seed_demo_bom(v_fg, v_rm, v_site));
    exception when others then
      v_notes := v_notes || to_jsonb(('Bill of materials was skipped: ' || sqlerrm)::text);
    end;

    begin
      v_po := erp.create_document('purchase_order', v_entity, v_site, v_supplier, current_date, v_ccy, 'DEMO-SEED');
      perform erp.add_document_line(v_po, v_rm, 500, 1250, 'Demo raw material order');
      perform erp.transition_document(v_po, 'submit');
      perform erp.transition_document(v_po, 'approve');
      perform erp.transition_document(v_po, 'send');
      v_notes := v_notes || to_jsonb('Raised and sent a purchase order for 500 units.'::text);
    exception when others then
      v_po := null;
      v_notes := v_notes || to_jsonb(('Purchase order was skipped: ' || sqlerrm)::text);
    end;

    if v_po is not null then
      begin
        v_receipt := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'DEMO-SEED');
        select dl.id into v_line from erp.document_line dl where dl.document_id = v_po order by dl.line_no limit 1;
        perform erp.receive_against(v_receipt, v_line, 500);
        perform erp.transition_document(v_receipt, 'post');
        v_notes := v_notes || to_jsonb('Received 500 units into stock.'::text);
      exception when others then
        v_notes := v_notes || to_jsonb(('Receipt was skipped: ' || sqlerrm)::text);
      end;
    end if;

    begin
      v_n := erp.raise_putaway_tasks(v_site);
      v_notes := v_notes || to_jsonb((v_n || ' putaway task(s) raised.')::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Putaway was skipped: ' || sqlerrm)::text);
    end;

    begin
      v_wo := erp.raise_works_order(v_fg, v_site, 50, 'assembly'::erp.works_order_kind, current_date + 7);
      perform erp.release_works_order(v_wo, true);
      perform erp.issue_to_works_order(v_wo, v_rm, 100, null, v_recv);
      perform erp.receive_works_order_output(v_wo, 40, null, v_recv);
      v_notes := v_notes || to_jsonb('Ran a works order for 50, received 40 so far.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Production history was skipped: ' || sqlerrm)::text);
    end;

    begin
      v_so := erp.create_document('sales_order', v_entity, v_site, v_customer, current_date, v_ccy, 'DEMO-SEED');
      perform erp.add_document_line(v_so, v_fg, 20, 9900, 'Demo customer order', current_date + 5);
      perform erp.transition_document(v_so, 'submit');
      perform erp.transition_document(v_so, 'approve');
      v_notes := v_notes || to_jsonb('Confirmed a customer order for 20 units.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Sales history was skipped: ' || sqlerrm)::text);
    end;

    begin
      select code into v_prog from erp.count_programme
       where tenant_id = v_tenant and status = 'active'::erp.record_status order by code limit 1;
      if v_prog is null then
        v_notes := v_notes || to_jsonb('No counting programme is configured, so no counts were raised.'::text);
      else
        v_n := erp.raise_count_tasks(v_prog);
        v_notes := v_notes || to_jsonb((v_n || ' count task(s) raised from ' || v_prog || '.')::text);
      end if;
    exception when others then
      v_notes := v_notes || to_jsonb(('Counting was skipped: ' || sqlerrm)::text);
    end;

    begin
      perform erp.run_planning(v_site, 90);
      v_notes := v_notes || to_jsonb('Planning run completed for the next 90 days.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Planning was skipped: ' || sqlerrm)::text);
    end;
  else
    v_notes := v_notes || to_jsonb('Operating history already existed; adding billing and settlement to it.'::text);
  end if;

  -- Despatch, invoice, and a part payment, so finance has a full cycle to read.
  v_notes := v_notes || erp.seed_demo_billing();

  return jsonb_build_object('ok', true, 'site', v_site, 'notes', v_notes);
end $function$;

revoke all on function erp.seed_demo_operations() from public, anon, authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'seed_demo_billing', 'Demonstration billing history; internal only, called by the seeded operations builder.')
on conflict do nothing;