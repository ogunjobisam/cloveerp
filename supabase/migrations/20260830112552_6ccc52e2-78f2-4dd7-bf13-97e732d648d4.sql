insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema)
values
  ('tenant.key_created', 1, 'tenant_key', 'administration', 'event.tenant.key_created',
   'A per-tenant encryption key was created and stored in the platform key store.',
   jsonb_build_object('type', 'object')),
  ('tenant.key_rotated', 1, 'tenant_key', 'administration', 'event.tenant.key_rotated',
   'A tenant key was rotated; values were re-protected and the previous key destroyed.',
   jsonb_build_object('type', 'object')),
  ('tenant.key_destroyed', 1, 'tenant_key', 'administration', 'event.tenant.key_destroyed',
   'A tenant key was irreversibly destroyed.',
   jsonb_build_object('type', 'object'))
on conflict (code, version) do nothing;
select pg_notify('pgrst','reload schema');