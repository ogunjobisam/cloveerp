-- =============================================================================
-- The suite for a door that existed and a rule that was never asked
--
-- Two different failures are worth attacking here, and neither is an error
-- anybody would have seen.
--
-- The first is a check that looks like authorisation and is not.
-- erp.open_device_session() refused an unregistered device from the day it was
-- written, which is exactly what §14.6 asks for and reads, at a glance, like a
-- guarded door. It is a check on the HARDWARE. Nothing asked whether the person
-- holding it could move stock, so any authenticated member of the organisation
-- could take a session on any scanner and queue work on it. The suite puts a
-- principal with no warehouse rights in front of a device that is registered,
-- active and faultless, and requires the refusal.
--
-- The second is configuration nothing consults. erp.scan_rule carried the
-- symbologies, the mandatory identifiers and what happens when one is absent —
-- all three of §14.4's promises, as columns — and the only function that read
-- the table was the report checking the table's own integrity. A rule that
-- decides nothing is indistinguishable from a rule being obeyed until somebody
-- scans the wrong thing and it is accepted. So every branch of when_absent is
-- exercised, and the specific rule is required to beat the general one.
-- =============================================================================

create or replace function erp_test.device_boundary_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  v_code   text := 'zzdb-' || substr(md5(random()::text), 1, 6);
  v_tenant uuid;
  ad       uuid := gen_random_uuid();   -- administrator
  op       uuid := gen_random_uuid();   -- an operator with no warehouse rights
  v_op     uuid; v_tok text;
  v_site   uuid; v_dev uuid; v_role uuid;
  v_ok     boolean; v_msg text; res jsonb; scan jsonb; v_n integer;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Device Boundary', 'admin@zzdb.test', 'Boundary Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ad, 'admin@zzdb.test'), (op, 'op@zzdb.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  select v_tenant, e.id, 'DC1', 'Distribution centre', 'warehouse', 'active'
    from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1
  returning id into v_site;
  perform erp_test.close_bootstrap_window(v_tenant);

  -- ── §14.6 registration, which had no function until now ───────────────────

  v_dev := erp.register_device('SCAN-01', 'DC1', 'Aisle scanner', 'handheld', 'SN-001');
  return query select 'a device can be registered against a site',
    v_dev is not null
      and (select d.site_id from erp.device d where d.id = v_dev) = v_site,
    '§14.6 refused an unregistered device from the start; nothing registered one';

  begin
    perform erp.register_device('SCAN-99', 'NOWHERE', 'Scanner at no site', 'handheld');
    v_ok := false; v_msg := 'a device was bound to a site that does not exist';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_SITE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and not to a site this organisation does not have', v_ok, v_msg;

  begin
    perform erp.register_device('SCAN-98', 'DC1', 'Imaginary hardware', 'hovercraft');
    v_ok := false; v_msg := 'an unknown device class was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_DEVICE_CLASS%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor with a device class §14.1 does not name', v_ok, v_msg;

  -- ── The check that looked like authorisation ──────────────────────────────

  res := public.erp_invite_principal('op@zzdb.test', 'Operator');
  v_op := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);

  begin
    perform erp.open_device_session('SCAN-01');
    v_ok := false;
    v_msg := 'an operator with no warehouse rights opened a session';
  exception when others then
    v_ok := sqlerrm not like 'ERPWARE_DEVICE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a person who may not move stock is refused the device',
    v_ok, v_msg;

  return query select 'and the refusal is about the person, not the hardware',
    v_ok and (select d.status from erp.device d where d.id = v_dev) = 'active',
    'the device is registered and active; §14.6''s check would have let this through';

  begin
    perform erp.record_device_action('SCAN-01', 'putaway', 'k-unauthorised');
    v_ok := false; v_msg := 'an unauthorised operator queued an action';
  exception when others then
    v_ok := sqlerrm not like 'ERPWARE_DEVICE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor may they queue work on it', v_ok, v_msg;

  -- A provisioned organisation carries one role, administrator. The operator
  -- needs a role that can move stock and nothing else, which is the whole point
  -- of the case above: rights, not hardware.
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_tenant);

  insert into erp.role (tenant_id, code, name, description, status)
  values (v_tenant, 'warehouse_operative', 'Warehouse operative',
          'Moves and counts stock on a device.', 'active')
  returning id into v_role;
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  values (v_tenant, v_role, 'inventory.move'),
         (v_tenant, v_role, 'inventory.read');

  perform erp_test.close_bootstrap_window(v_tenant);
  perform erp.grant_role(v_op, 'warehouse_operative', null, null, 'suite operator');

  -- ── §14.4 the rules nothing read ──────────────────────────────────────────

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.scan_rule
    (tenant_id, device_task_code, item_class, accepted_symbologies,
     mandatory_identifiers, when_absent)
  values (v_tenant, 'putaway', null, '{gs1_128,gs1_datamatrix}', '{01}', 'refuse'),
         (v_tenant, 'pick', null, '{gs1_128}', '{01,10}', 'exception_with_reason'),
         (v_tenant, 'count', null, '{gs1_128}', '{01,10}', 'accept'),
         (v_tenant, 'pick', 'pharma', '{gs1_datamatrix}', '{01,10,17}', 'refuse');
  perform erp_test.close_bootstrap_window(v_tenant);

  scan := erp.evaluate_scan('SCAN-01', 'putaway', '0105412345000013', 'gs1_128');
  return query select 'a scan carrying what the step demands is accepted',
    (scan ->> 'outcome') = 'accepted' and (scan -> 'fields' ->> 'gtin') = '05412345000013',
    coalesce(scan ->> 'outcome', '(null)');

  scan := erp.evaluate_scan('SCAN-01', 'putaway', '0105412345000013', 'code_39');
  return query select 'a symbology the step does not accept is refused',
    (scan ->> 'outcome') = 'refused',
    coalesce(scan ->> 'reason', '(none)');

  scan := erp.evaluate_scan('SCAN-01', 'putaway', '10LOT4711', 'gs1_128');
  return query select 'a mandatory identifier absent, when_absent refuse, refuses',
    (scan ->> 'outcome') = 'refused'
      and (scan -> 'missing_identifiers' ->> 0) = 'gtin',
    coalesce(scan ->> 'reason', '(none)');

  scan := erp.evaluate_scan('SCAN-01', 'pick', '0105412345000013', 'gs1_128');
  return query select 'the same absence, when_absent exception, is an exception',
    (scan ->> 'outcome') = 'exception'
      and (scan -> 'missing_identifiers' ->> 0) = 'batch',
    coalesce(scan ->> 'reason', '(none)');

  scan := erp.evaluate_scan('SCAN-01', 'count', '0105412345000013', 'gs1_128');
  return query select 'and when_absent accept accepts, and says what was missing',
    (scan ->> 'outcome') = 'accepted'
      and (scan -> 'missing_identifiers' ->> 0) = 'batch',
    'three branches, three behaviours — which is what made the column worth having';

  scan := erp.evaluate_scan('SCAN-01', 'pick', '0105412345000013', 'gs1_128', 'pharma');
  return query select 'a rule naming the item class beats the rule naming none',
    (scan ->> 'outcome') = 'refused',
    '§14.4 makes the rules per step AND per product class';

  scan := erp.evaluate_scan('SCAN-01', 'putaway', 'NOT-A-BARCODE', 'gs1_128');
  return query select 'an unrecognised barcode is rejected with the value shown',
    (scan ->> 'outcome') = 'rejected'
      and (scan ->> 'scanned_value') = 'NOT-A-BARCODE',
    '§14.4: never silently ignored — the operator is holding the label';

  return query select 'and rejecting one does not end the transaction',
    (erp.evaluate_scan('SCAN-01', 'putaway', '0105412345000013', 'gs1_128')
       ->> 'outcome') = 'accepted',
    'an operator scans a hundred labels an hour; a bad one must not need a retry';

  scan := erp.evaluate_scan('SCAN-01', 'despatch', '0105412345000013', 'gs1_128');
  return query select 'a step with no rule accepts, and says no rule is configured',
    (scan ->> 'outcome') = 'accepted' and (scan -> 'rule') = 'null'::jsonb,
    'a client that cannot tell allowed from unconfigured shows the wrong thing';

  begin
    perform erp.evaluate_scan('SCAN-01', 'putaway', '0105412345000013', 'telepathy');
    v_ok := false; v_msg := 'an unknown symbology was treated as a scan outcome';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_SYMBOLOGY%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a symbology the product does not know is a caller error',
    v_ok, v_msg;

  -- ── §14.6 sessions, and what closing one may reach ────────────────────────

  res := erp.open_device_session('SCAN-01');
  return query select 'an authorised operator opens a session',
    (res ->> 'session_id') is not null, 'attributed to the person, not the device';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  res := erp.close_device_session('shift over');
  return query select 'signing out closes only your own sessions',
    (res ->> 'closed')::integer = 0
      and exists (select 1 from erp.device_session s
                   where s.tenant_id = v_tenant and s.ended_at is null),
    'the administrator''s session survives; ending it is what switching users does';

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  res := erp.close_device_session('shift over');
  return query select 'and closes them when they are yours',
    (res ->> 'closed')::integer = 1
      and not exists (select 1 from erp.device_session s
                       where s.tenant_id = v_tenant and s.ended_at is null),
    coalesce(res ->> 'closed', '(none)');

  -- ── §14.5 the queue, and what the operator is owed sight of ───────────────

  perform erp.open_device_session('SCAN-01');
  res := erp.record_device_action('SCAN-01', 'putaway', 'k-1',
           '{"sscc":"012345678901234560"}'::jsonb);
  return query select 'an action queues through the door',
    (res ->> 'status') = 'queued' and (res ->> 'duplicate') = 'false',
    coalesce(res ->> 'action_id', '(none)');

  res := erp.record_device_action('SCAN-01', 'putaway', 'k-1',
           '{"sscc":"012345678901234560"}'::jsonb);
  return query select 'and resending it is told already done, not failed',
    (res ->> 'duplicate') = 'true',
    '§14.5: reconnection never duplicates, and never reads as an error';

  return query select 'the queue surfaces to the operator',
    (select count(*) from erp.device_queue('SCAN-01')) = 1,
    '§14.5: an action no longer valid surfaces with the reason, so it needs a surface';

  update erp.device_action set status = 'applied', applied_at = now()
   where tenant_id = v_tenant and idempotency_key = 'k-1';
  return query select 'and drops what is settled',
    (select count(*) from erp.device_queue('SCAN-01')) = 0,
    'an applied action is not something the operator still has to deal with';

  -- ── The doors, and who may reach them ─────────────────────────────────────

  return query select 'every Part 14 door is reachable from outside the database',
    (select count(*) from pg_catalog.pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('erp_register_device','erp_open_device_session',
                          'erp_close_device_session','erp_record_device_action',
                          'erp_scan','erp_devices','erp_device_queue',
                          'erp_device_tasks')) = 8,
    'every Part 14 function lived in schema erp, which PostgREST does not expose';

  return query select 'and none of them is callable without signing in',
    not exists (select 1 from pg_catalog.pg_proc p
                 where p.pronamespace = 'public'::regnamespace
                   and p.proname in ('erp_register_device','erp_open_device_session',
                                     'erp_close_device_session','erp_record_device_action',
                                     'erp_scan','erp_devices','erp_device_queue',
                                     'erp_device_tasks')
                   and pg_catalog.has_function_privilege('anon', p.oid, 'execute')),
    'on this project a new public function is granted to anon until revoked';

  return query select 'and every door that writes declares what gates it',
    (select count(*) from erp_meta.public_write_allowance w
      where w.function_name in ('erp_register_device','erp_open_device_session',
                                'erp_close_device_session','erp_record_device_action')) = 4
      and erp.assert_public_api_safe() is not null,
    'registration excuses nothing; it records what the gate is';

  return query select 'the device model still reads as sound',
    erp.assert_device_operations_sound() is not null, 'no findings';

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (ad, op);

  select count(*) into v_n from erp.tenant t where t.code like 'zzdb-%';
  return query select 'the suite leaves nothing behind',
    v_n = 0 and erp.assert_device_operations_sound() is not null,
    'and the shipped task register is untouched';
end;
$$;

comment on function erp_test.device_boundary_suite is
  'Specification v1.2 §14.4 and §14.6. Two attacks: a check that looks like '
  'authorisation and only inspects the hardware, and configuration that decides '
  'nothing. Both were live — erp.open_device_session() never asked whether the '
  'operator could move stock, and erp.scan_rule was read by no function that '
  'acted on it.';

create or replace function erp_test.assert_device_boundary_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _device_boundary_result on commit drop as
    select * from erp_test.device_boundary_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _device_boundary_result;

  if v_total <> 28 then
    raise exception 'ERPWARE_DEVICE_BOUNDARY_SUITE_SHRANK: % case(s), expected 28', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_DEVICE_BOUNDARY_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('device boundary: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_device_boundary_suite();
