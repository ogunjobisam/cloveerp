-- =============================================================================
-- Part 14 — the adversarial suite
--
-- Four sentences carry Part 14's database half, and each is attacked here:
--
--   §14.4 "A single scan populates several fields" — so the suite scans one
--         GS1-128 label and reads four fields out of it, including an expiry
--         with a day of 00, which means end of month and which every screen
--         would otherwise get wrong separately.
--
--   §14.4 "Unrecognised barcodes are rejected with the scanned value shown,
--         never silently ignored" — so the suite scans rubbish and checks the
--         value is IN the message. A refusal that does not show the value
--         leaves an operator holding a barcode that did nothing.
--
--   §14.5 "Store and forward with idempotency keys ... so reconnection never
--         duplicates" — so the suite sends the same action twice and checks
--         there is one row and that the second call SAYS it was a duplicate
--         rather than erroring, because a device cannot act on an error it
--         cannot distinguish from a failure.
--
--   §14.6 "an unregistered device cannot transact" — so the suite tries.
-- =============================================================================

create or replace function erp_test.device_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ad uuid := gen_random_uuid();
  sup uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzdev-a';
  v_site uuid; v_dev uuid; v_sup_user uuid;
  v_ok boolean; v_msg text; res jsonb; scan jsonb;
  v_a1 uuid; v_count integer;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Device A', 'admin-a@zzdev.test', 'Device A Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ad, 'admin-a@zzdev.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  perform erp_test.reopen_bootstrap_window(v_tenant);

  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  select v_tenant, e.id, 'DC1', 'Distribution centre', 'warehouse', 'active'
    from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1
  returning id into v_site;

  -- ── §14.4 one scan, several fields ────────────────────────────────────────
  -- A real GS1-128: SSCC, GTIN, batch (variable, terminated by the group
  -- separator), expiry. Four identifiers, one scan.

  scan := erp.parse_gs1('00012345678901234560' ||
                        '0105412345000013' ||
                        '10LOT4711' || chr(29) ||
                        '17260930');

  return query select 'one scan populates several fields',
    (scan ->> 'sscc') = '012345678901234560'
      and (scan ->> 'gtin') = '05412345000013'
      and (scan ->> 'batch') = 'LOT4711'
      and (scan ->> 'expiry') = '2026-09-30',
    coalesce(scan::text, '(null)');

  return query select 'and a variable-length field stops at the separator',
    (scan ->> 'batch') = 'LOT4711',
    'not LOT471117260930, which is what a parser without the separator gives';

  -- §14.4's expiry: a day of 00 means end of month. Resolved once in the
  -- parser rather than in each screen that reads an expiry.
  scan := erp.parse_gs1('17260200');
  return query select 'an expiry day of 00 resolves to the end of the month',
    (scan ->> 'expiry') = '2026-02-28',
    coalesce(scan ->> 'expiry', '(null)');

  -- ── §14.4 unrecognised is rejected, and shows the value ───────────────────

  begin
    perform erp.parse_gs1('99XXNOTABARCODE');
    v_ok := false; v_msg := 'rubbish was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNRECOGNISED_BARCODE%'
        and position('99XXNOTABARCODE' in sqlerrm) > 0;
    v_msg := left(sqlerrm, 80);
  end;
  return query select 'an unrecognised barcode is refused AND shows what was scanned',
    v_ok, v_msg;

  begin
    perform erp.parse_gs1('');
    v_ok := false; v_msg := 'an empty scan was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_EMPTY_SCAN%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and so is an empty one', v_ok, v_msg;

  begin
    perform erp.parse_gs1('0012345');
    v_ok := false; v_msg := 'a truncated SSCC was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_TRUNCATED_BARCODE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a fixed-length identifier that is short is refused', v_ok, v_msg;

  -- ── §14.6 an unregistered device cannot transact ──────────────────────────

  perform erp_test.close_bootstrap_window(v_tenant);

  begin
    perform erp.open_device_session('nosuchdevice');
    v_ok := false; v_msg := 'an unregistered device opened a session';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DEVICE_NOT_REGISTERED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an unregistered device cannot open a session', v_ok, v_msg;

  begin
    perform erp.record_device_action('nosuchdevice', 'pick', 'k1');
    v_ok := false; v_msg := 'an unregistered device recorded an action';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DEVICE_NOT_REGISTERED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'nor transact at all', v_ok, v_msg;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.device (tenant_id, site_id, code, name, device_class, status)
  values (v_tenant, v_site, 'hh-001', 'Handheld 1', 'handheld', 'active')
  returning id into v_dev;

  insert into erp.device (tenant_id, site_id, code, name, device_class, status)
  values (v_tenant, v_site, 'hh-retired', 'Retired handheld', 'handheld', 'retired');
  perform erp_test.close_bootstrap_window(v_tenant);

  begin
    perform erp.record_device_action('hh-retired', 'pick', 'k0');
    v_ok := false; v_msg := 'a retired device transacted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DEVICE_NOT_ACTIVE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and neither can a retired one', v_ok, v_msg;

  -- ── §14.6 the session attributes to a person ──────────────────────────────

  res := erp.open_device_session('hh-001');
  return query select 'a registered device opens a session against a person',
    (res ->> 'app_user_id') is not null,
    '§14.6: every action attributes to the user, never to the device';

  -- ── §14.5 reconnection never duplicates ───────────────────────────────────

  res := erp.record_device_action('hh-001', 'pick', 'pick-0001',
                                  '{"location":"A-01-01","quantity":5}'::jsonb);
  v_a1 := (res ->> 'action_id')::uuid;

  return query select 'an action is queued',
    (res ->> 'status') = 'queued' and not (res ->> 'duplicate')::boolean,
    res ->> 'status';

  res := erp.record_device_action('hh-001', 'pick', 'pick-0001',
                                  '{"location":"A-01-01","quantity":5}'::jsonb);

  return query select 'resending the same key returns the ORIGINAL, not an error',
    (res ->> 'action_id')::uuid = v_a1 and (res ->> 'duplicate')::boolean,
    'a device cannot act on an error it cannot tell from a failure';

  select count(*) into v_count from erp.device_action a
   where a.tenant_id = v_tenant and a.idempotency_key = 'pick-0001';
  return query select 'and there is exactly one row',
    v_count = 1, format('%s row(s)', v_count);

  -- ── §14.2 scan first, type never ──────────────────────────────────────────

  begin
    perform erp.record_device_action('hh-001', 'pick', 'pick-0002',
                                     '{}'::jsonb, 'keyed', null);
    v_ok := false; v_msg := 'keyed entry with no reason was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'keyed entry with no reason is refused', v_ok, v_msg;

  res := erp.record_device_action('hh-001', 'pick', 'pick-0003', '{}'::jsonb,
                                  'keyed', 'label torn, barcode unreadable');
  return query select 'while keyed entry WITH a reason is the exception path',
    (res ->> 'status') = 'queued',
    '§14.2: keyboard entry exists as an exception path, always requiring a reason';

  -- ── §14.5 a conflict surfaces, and never silently disappears ──────────────

  begin
    update erp.device_action set status = 'conflicted' where id = v_a1;
    v_ok := false; v_msg := 'a conflict with no reason was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'a conflicted action with no reason is refused', v_ok, v_msg;

  update erp.device_action
     set status = 'conflicted',
         conflict_reason = 'the stock had already moved when this reconnected'
   where id = v_a1;

  return query select 'while one with a reason survives to be shown to the operator',
    (select a.conflict_reason is not null from erp.device_action a where a.id = v_a1),
    '§14.5: never posts silently, never silently disappears';

  -- ── §14.6 supervisor override names both users ────────────────────────────

  insert into auth.users (id, email) values (sup, 'supervisor@zzdev.test');
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant, sup, 'person', 'active', 'Supervisor', 'supervisor@zzdev.test')
  returning id into v_sup_user;

  res := erp.open_device_session('hh-001', v_sup_user, 'above the operator''s adjustment threshold');
  return query select 'a supervisor override records BOTH users',
    (res ->> 'supervised_by')::uuid = v_sup_user
      and (res ->> 'app_user_id')::uuid is not null,
    '§14.6: recorded against both users';

  begin
    insert into erp.device_session (tenant_id, device_id, app_user_id, supervisor_user_id)
    values (v_tenant, v_dev, v_sup_user, v_sup_user);
    v_ok := false; v_msg := 'a supervisor overrode themselves';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'and a supervisor cannot override themselves', v_ok, v_msg;

  -- ── §14.6 fast user switching closes the previous session ─────────────────

  select count(*) into v_count from erp.device_session s
   where s.tenant_id = v_tenant and s.device_id = v_dev and s.ended_at is null;
  return query select 'a device carries exactly one open session',
    v_count = 1,
    'a shared terminal changes hands many times per shift, and the last holder must not inherit the next one''s work';

  -- ── §14.3 the register states all three paths ─────────────────────────────

  return query select 'every task defines a start, a completion and an abandon path',
    erp.assert_device_operations_sound() is not null,
    (select format('%s tasks', count(*)) from erp_ref.device_task);

  return query select 'and some of them work offline',
    (select count(*) from erp_ref.device_task t where t.works_offline) >= 8,
    (select format('%s offline-capable', count(*)) from erp_ref.device_task t where t.works_offline);

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (ad, sup);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzdev-%')
      and not exists (select 1 from auth.users u where u.id in (ad, sup)),
    'devices, sessions and queued actions go with the organisation';
end;
$$;

comment on function erp_test.device_suite is
  'Specification v1.2 Part 14, proven adversarially: one GS1-128 scan yields '
  'four fields including an end-of-month expiry, rubbish is refused with the '
  'value shown, a resent action returns the original rather than duplicating or '
  'erroring, an unregistered device cannot transact, and keyed entry without a '
  'reason is refused.';

create or replace function erp_test.assert_device_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _device_result on commit drop as
    select * from erp_test.device_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _device_result;

  if v_total <> 23 then
    raise exception 'ERPWARE_DEVICE_SUITE_SHRANK: % case(s), expected 23', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_DEVICE_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('device: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_device_suite();
