-- =============================================================================
-- Part 14: the way in
--
-- The open decision device_client_not_built says the warehouse application is
-- not built, and gives a good reason: forty-eight pixel touch targets, haptics
-- and a three-hundred-millisecond budget are properties of a client, and
-- claiming them from a schema would read as done and not be.
--
-- That reason still stands. What it was hiding is that Part 14 could not be
-- reached at all, and would not have worked if it had been:
--
--   1. NO PUBLIC DOOR. erp.open_device_session(), erp.record_device_action()
--      and erp.parse_gs1() all live in schema erp. PostgREST exposes public.
--      Nothing outside the database could call any of them, so "the client is
--      not built" was not a scheduling choice — there was nothing to build
--      against.
--
--   2. erp.scan_rule WAS READ BY NOTHING. §14.4 promises "which symbologies
--      are accepted at which step, which application identifiers are mandatory
--      for which product class, and what happens when a required identifier is
--      absent" as configuration. All three are columns on erp.scan_rule, and
--      the only function that touched the table was the report checking the
--      table's own integrity. Configuration nothing consults is a promise in a
--      column.
--
--   3. NO WAY TO REGISTER A DEVICE, and no way to close a session. §14.6's
--      "devices are registered and bound to a site" had no registration
--      function; a row had to be inserted by hand.
--
--   4. NEITHER DOOR AUTHORISED. Both checked that the DEVICE was registered
--      and active, which is §14.6's sentence, and neither asked whether the
--      PERSON could do the work. Any authenticated member of the tenant could
--      open a session on any device and queue actions on it.
--
-- All four are fixed here. What is deliberately NOT fixed is the fifth, which
-- needs its own decision and gets one: nothing drains erp.device_action.
-- Actions queue, and no function ever moves one to applied or conflicted, so
-- §14.5's "never posts silently or silently disappears" currently holds by
-- never posting at all. Draining it means mapping twenty-two device tasks onto
-- the module functions that already do the work, which is per-module design
-- rather than plumbing, and guessing at it here would be worse than naming it.
--
-- A device is not made promotable. Registering one binds it to physical
-- hardware at a physical site, so promoting devices from a sandbox into
-- production would describe scanners that are not there — the same reason
-- email suppression stays out.
-- =============================================================================

-- ── §14.6 registering a device, and closing what a session opened ───────────

create or replace function erp.register_device(p_code text,
                                                p_site_code text,
                                                p_name text,
                                                p_device_class text,
                                                p_serial_number text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site   uuid;
  v_id     uuid;
begin
  perform erp.authorise('administration.configure');

  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = p_site_code and s.status = 'active';
  if v_site is null then
    raise exception 'ERPWARE_UNKNOWN_SITE: this organisation has no active site %',
      p_site_code using errcode = '23503';
  end if;

  if not exists (select 1 from erp_ref.device_class c where c.code = p_device_class) then
    raise exception 'ERPWARE_UNKNOWN_DEVICE_CLASS: % is not a device class', p_device_class
      using errcode = '23503',
            hint = 'erp_ref.device_class lists what §14.1 recognises.';
  end if;

  insert into erp.device (tenant_id, site_id, code, name, device_class, serial_number)
  values (v_tenant, v_site, p_code, p_name, p_device_class, p_serial_number)
  on conflict (tenant_id, code) do update set
    site_id = excluded.site_id, name = excluded.name,
    device_class = excluded.device_class,
    serial_number = excluded.serial_number,
    status = 'active', updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.register_device is
  'Specification v1.2 §14.6: "Devices are registered and bound to a site; an '
  'unregistered device cannot transact." The refusal existed from the start; '
  'the registration it refuses against had to be inserted by hand until now.';

create or replace function erp.close_device_session(p_end_reason text default 'signed out')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_user   uuid := erp.current_principal_id();
  v_count  integer;
begin
  perform erp.authorise('inventory.move');

  if v_user is null then
    raise exception 'ERPWARE_NO_PRINCIPAL: a device session belongs to a person'
      using errcode = '42501';
  end if;

  -- Only this operator's own open sessions. Ending somebody else's is what
  -- fast user switching does through erp.open_device_session(), deliberately
  -- and with a reason recorded; it is not something signing out should reach.
  update erp.device_session
     set ended_at = now(), end_reason = coalesce(nullif(btrim(p_end_reason), ''), 'signed out')
   where tenant_id = v_tenant and app_user_id = v_user and ended_at is null;
  get diagnostics v_count = row_count;

  return jsonb_build_object('closed', v_count);
end;
$$;

comment on function erp.close_device_session is
  'Specification v1.2 §14.6. erp.open_device_session() ends whatever session '
  'the DEVICE was carrying, which is fast user switching. This ends what this '
  'OPERATOR was carrying, which is signing out, and they are not the same act.';

-- ── §14.4 the rules the parser was never asked about ────────────────────────

create or replace function erp.evaluate_scan(p_device_code text,
                                              p_task_code text,
                                              p_barcode text,
                                              p_symbology text,
                                              p_item_class text default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_device  erp.device%rowtype;
  v_rule    erp.scan_rule%rowtype;
  v_fields  jsonb;
  v_missing text[] := '{}';
  v_ai      text;
  v_field   text;
begin
  perform erp.authorise('inventory.read');

  select * into v_device from erp.device d
   where d.tenant_id = v_tenant and d.code = p_device_code;
  if not found then
    raise exception
      'ERPWARE_DEVICE_NOT_REGISTERED: % is not a registered device', p_device_code
      using errcode = '42501';
  end if;
  if v_device.status <> 'active' then
    raise exception 'ERPWARE_DEVICE_NOT_ACTIVE: % is %', p_device_code, v_device.status
      using errcode = '42501';
  end if;

  if not exists (select 1 from erp_ref.device_task t where t.code = p_task_code) then
    raise exception 'ERPWARE_UNKNOWN_DEVICE_TASK: % is not a device task', p_task_code
      using errcode = '23503';
  end if;

  -- A symbology the product does not know is a client bug, not a scan outcome.
  if not exists (select 1 from erp_ref.symbology y where y.code = p_symbology) then
    raise exception 'ERPWARE_UNKNOWN_SYMBOLOGY: % is not a symbology this product reads',
      p_symbology using errcode = '23503';
  end if;

  -- Most specific rule wins: one naming this item class, else the one that
  -- names none. §14.4 makes the rules per step AND per product class.
  select * into v_rule from erp.scan_rule r
   where r.tenant_id = v_tenant and r.device_task_code = p_task_code
     and (r.item_class = p_item_class or r.item_class is null)
   order by (r.item_class is null)
   limit 1;

  -- §14.4: "Unrecognised barcodes are rejected with the scanned value shown,
  -- never silently ignored." Returned rather than raised, because an operator
  -- scanning a hundred labels an hour needs the value on the screen and the
  -- next scan to still work, not a transaction that failed.
  begin
    v_fields := erp.parse_gs1(p_barcode);
  exception when others then
    return jsonb_build_object(
      'outcome', 'rejected',
      'reason', left(sqlerrm, 200),
      'scanned_value', p_barcode,
      'symbology', p_symbology,
      'fields', '{}'::jsonb);
  end;

  if not found or v_rule.id is null then
    -- No rule configured for this step. Accept, and say so, rather than
    -- inventing a default: a client that cannot tell "allowed" from "nobody
    -- has configured this yet" will show the operator the wrong thing.
    return jsonb_build_object(
      'outcome', 'accepted', 'reason', 'no scan rule is configured for this step',
      'symbology', p_symbology, 'fields', v_fields, 'rule', null);
  end if;

  if not (p_symbology = any (v_rule.accepted_symbologies)) then
    return jsonb_build_object(
      'outcome', 'refused',
      'reason', format('%s is not accepted at %s; this step accepts %s',
                       p_symbology, p_task_code,
                       array_to_string(v_rule.accepted_symbologies, ', ')),
      'symbology', p_symbology, 'fields', v_fields,
      'rule', jsonb_build_object('device_task', v_rule.device_task_code,
                                 'item_class', v_rule.item_class,
                                 'when_absent', v_rule.when_absent));
  end if;

  foreach v_ai in array v_rule.mandatory_identifiers loop
    select a.field_name into v_field
      from erp_ref.gs1_application_identifier a where a.ai = v_ai;
    if v_field is null or not (v_fields ? v_field) then
      v_missing := v_missing || coalesce(v_field, v_ai);
    end if;
  end loop;

  return jsonb_build_object(
    'outcome', case
       when cardinality(v_missing) = 0 then 'accepted'
       when v_rule.when_absent = 'refuse' then 'refused'
       when v_rule.when_absent = 'accept' then 'accepted'
       else 'exception' end,
    'reason', case
       when cardinality(v_missing) = 0 then null
       when v_rule.when_absent = 'refuse'
         then format('%s is mandatory at %s and the barcode does not carry it',
                     array_to_string(v_missing, ', '), p_task_code)
       when v_rule.when_absent = 'accept'
         then format('%s absent, and this step accepts that',
                     array_to_string(v_missing, ', '))
       else format('%s absent; capture it with a reason or abandon the step',
                   array_to_string(v_missing, ', ')) end,
    'symbology', p_symbology,
    'fields', v_fields,
    'missing_identifiers', to_jsonb(v_missing),
    'rule', jsonb_build_object('device_task', v_rule.device_task_code,
                               'item_class', v_rule.item_class,
                               'when_absent', v_rule.when_absent));
end;
$$;

comment on function erp.evaluate_scan is
  'Specification v1.2 §14.4. erp.scan_rule held the symbologies, the mandatory '
  'identifiers and what happens when one is absent, and until now nothing read '
  'it except the report checking the table''s own integrity. This is the '
  'function that applies it, so the configuration decides the behaviour rather '
  'than describing behaviour nobody implemented.';

-- ── §14.5 what the operator is owed sight of ────────────────────────────────

create or replace function erp.device_queue(p_device_code text)
returns table(action_id uuid, task_code text, status text, input_method text,
              captured_at timestamptz, conflict_reason text, payload jsonb)
language sql
stable
set search_path = ''
as $$
  select a.id, a.device_task_code, a.status, a.input_method,
         a.captured_at, a.conflict_reason, a.payload
    from erp.device_action a
    join erp.device d on d.tenant_id = a.tenant_id and d.id = a.device_id
   where d.tenant_id = erp.require_tenant_id()
     and d.code = p_device_code
     and a.status in ('queued', 'conflicted')
   order by a.captured_at
$$;

comment on function erp.device_queue is
  'Specification v1.2 §14.5: an action that is no longer valid "surfaces to the '
  'operator as an exception with the reason". This is the surface. Queued and '
  'conflicted only — an applied action is not something the operator still has '
  'to deal with.';

-- ── The two doors that refused a device and never asked about the person ────

create or replace function erp.open_device_session(p_device_code text,
                                                   p_supervisor_user_id uuid default null,
                                                   p_supervisor_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_device erp.device%rowtype;
  v_user   uuid := erp.current_principal_id();
  v_id     uuid;
begin
  -- §14.6 refuses an unregistered DEVICE, which this always did. It says
  -- nothing about the person, and until now neither did this: any authenticated
  -- member of the organisation could open a session on any scanner.
  perform erp.authorise('inventory.move');

  if v_user is null then
    raise exception 'ERPWARE_NO_PRINCIPAL: a device session belongs to a person'
      using errcode = '42501';
  end if;

  select * into v_device from erp.device d
   where d.tenant_id = v_tenant and d.code = p_device_code;

  -- §14.6: "an unregistered device cannot transact."
  if not found then
    raise exception
      'ERPWARE_DEVICE_NOT_REGISTERED: % is not a registered device', p_device_code
      using errcode = '42501',
            hint = 'Register the device against a site before it transacts.';
  end if;

  if v_device.status <> 'active' then
    raise exception
      'ERPWARE_DEVICE_NOT_ACTIVE: % is %', p_device_code, v_device.status
      using errcode = '42501';
  end if;

  -- §14.6: "Fast user switching ... a shared terminal changes hands many times
  -- per shift." The previous session ends rather than lingering, so an action
  -- can never attribute to whoever held the device last.
  update erp.device_session
     set ended_at = now(), end_reason = 'superseded by a new operator'
   where tenant_id = v_tenant and device_id = v_device.id and ended_at is null;

  insert into erp.device_session
    (tenant_id, device_id, app_user_id, supervisor_user_id, supervisor_reason)
  values (v_tenant, v_device.id, v_user, p_supervisor_user_id, p_supervisor_reason)
  returning id into v_id;

  update erp.device set last_seen_at = now() where id = v_device.id;

  return jsonb_build_object('session_id', v_id, 'device', p_device_code,
                            'app_user_id', v_user,
                            'supervised_by', p_supervisor_user_id);
end;
$$;

comment on function erp.open_device_session is
  'Specification v1.2 §14.6. Refuses an unregistered device, refuses a caller '
  'who may not move stock, ends whatever session the device was carrying, and '
  'records the supervisor against the session when one authorised it.';

create or replace function erp.record_device_action(p_device_code text,
                                                    p_task_code text,
                                                    p_idempotency_key text,
                                                    p_payload jsonb default '{}',
                                                    p_input_method text default 'scanned',
                                                    p_keyed_reason text default null,
                                                    p_captured_at timestamptz default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_device  erp.device%rowtype;
  v_session uuid;
  v_id      uuid;
  v_existing erp.device_action%rowtype;
begin
  perform erp.authorise('inventory.move');

  select * into v_device from erp.device d
   where d.tenant_id = v_tenant and d.code = p_device_code;
  if not found then
    raise exception
      'ERPWARE_DEVICE_NOT_REGISTERED: % is not a registered device', p_device_code
      using errcode = '42501';
  end if;
  if v_device.status <> 'active' then
    raise exception 'ERPWARE_DEVICE_NOT_ACTIVE: % is %', p_device_code, v_device.status
      using errcode = '42501';
  end if;

  -- §14.5: "reconnection never duplicates". A device that reconnects and
  -- resends must be told the action already landed — not given an error it
  -- cannot distinguish from a failure, and not given a second row.
  select * into v_existing from erp.device_action a
   where a.tenant_id = v_tenant and a.device_id = v_device.id
     and a.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('action_id', v_existing.id, 'status', v_existing.status,
                              'duplicate', true,
                              'conflict_reason', v_existing.conflict_reason);
  end if;

  select id into v_session from erp.device_session s
   where s.tenant_id = v_tenant and s.device_id = v_device.id and s.ended_at is null
   order by s.started_at desc limit 1;

  insert into erp.device_action
    (tenant_id, device_id, device_session_id, device_task_code, idempotency_key,
     payload, input_method, keyed_reason, captured_at)
  values (v_tenant, v_device.id, v_session, p_task_code, p_idempotency_key,
          p_payload, p_input_method, p_keyed_reason,
          coalesce(p_captured_at, now()))
  returning id into v_id;

  update erp.device set last_seen_at = now() where id = v_device.id;

  return jsonb_build_object('action_id', v_id, 'status', 'queued', 'duplicate', false);
end;
$$;

comment on function erp.record_device_action is
  'Specification v1.2 §14.5. Refuses an unregistered device and a caller who '
  'may not move stock, and returns the original action when a reconnecting '
  'device resends — the difference between "already done" and "failed" is what '
  'stops a store-and-forward queue either duplicating or dropping.';

-- ── The doors themselves ────────────────────────────────────────────────────
--
-- Everything above lives in schema erp, which PostgREST does not expose. These
-- are what a warehouse client actually calls.

create or replace function public.erp_register_device(p_code text,
                                                       p_site_code text,
                                                       p_name text,
                                                       p_device_class text,
                                                       p_serial_number text default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.register_device(p_code, p_site_code, p_name, p_device_class, p_serial_number);
$$;

create or replace function public.erp_open_device_session(p_device_code text,
                                                           p_supervisor_user_id uuid default null,
                                                           p_supervisor_reason text default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.open_device_session(p_device_code, p_supervisor_user_id, p_supervisor_reason);
$$;

create or replace function public.erp_close_device_session(p_end_reason text default 'signed out')
returns jsonb
language sql
set search_path = ''
as $$
  select erp.close_device_session(p_end_reason);
$$;

create or replace function public.erp_record_device_action(p_device_code text,
                                                            p_task_code text,
                                                            p_idempotency_key text,
                                                            p_payload jsonb default '{}',
                                                            p_input_method text default 'scanned',
                                                            p_keyed_reason text default null,
                                                            p_captured_at timestamptz default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.record_device_action(p_device_code, p_task_code, p_idempotency_key,
                                  p_payload, p_input_method, p_keyed_reason, p_captured_at);
$$;

create or replace function public.erp_scan(p_device_code text,
                                            p_task_code text,
                                            p_barcode text,
                                            p_symbology text,
                                            p_item_class text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select erp.evaluate_scan(p_device_code, p_task_code, p_barcode, p_symbology, p_item_class);
$$;

create or replace function public.erp_devices()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb) from (
    select jsonb_build_object(
             'code', d.code, 'name', d.name, 'device_class', d.device_class,
             'site', s.code, 'status', d.status,
             'serial_number', d.serial_number,
             'registered_at', d.registered_at, 'last_seen_at', d.last_seen_at,
             'open_session', exists (select 1 from erp.device_session ds
                                      where ds.tenant_id = d.tenant_id
                                        and ds.device_id = d.id and ds.ended_at is null)) as x
      from erp.device d
      join erp.site s on s.tenant_id = d.tenant_id and s.id = d.site_id) t;
$$;

create or replace function public.erp_device_queue(p_device_code text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'action_id', q.action_id, 'task_code', q.task_code, 'status', q.status,
           'input_method', q.input_method, 'captured_at', q.captured_at,
           'conflict_reason', q.conflict_reason, 'payload', q.payload)
         order by q.captured_at), '[]'::jsonb)
    from erp.device_queue(p_device_code) q;
$$;

create or replace function public.erp_device_tasks()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'seq'), '[]'::jsonb) from (
    select jsonb_build_object(
             'code', t.code, 'name', t.name, 'task_group', t.task_group,
             'starts_when', t.starts_when, 'completes_when', t.completes_when,
             'abandons_when', t.abandons_when, 'works_offline', t.works_offline,
             'seq', t.seq,
             'scan_rules', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'item_class', r.item_class,
                        'accepted_symbologies', to_jsonb(r.accepted_symbologies),
                        'mandatory_identifiers', to_jsonb(r.mandatory_identifiers),
                        'when_absent', r.when_absent)
                      order by r.item_class nulls last)
                 from erp.scan_rule r
                where r.tenant_id = erp.require_tenant_id()
                  and r.device_task_code = t.code), '[]'::jsonb)) as x
      from erp_ref.device_task t) s;
$$;

-- Supabase carries DEFAULT PRIVILEGES on schema public that grant EXECUTE to
-- anon, so a new door is callable without signing in until it is revoked.
-- Found the hard way reconciling live, where thirty-two doors landed open.
revoke all on function
  public.erp_register_device(text, text, text, text, text),
  public.erp_open_device_session(text, uuid, text),
  public.erp_close_device_session(text),
  public.erp_record_device_action(text, text, text, jsonb, text, text, timestamptz),
  public.erp_scan(text, text, text, text, text),
  public.erp_devices(),
  public.erp_device_queue(text),
  public.erp_device_tasks()
  from public, anon;

grant execute on function
  public.erp_register_device(text, text, text, text, text),
  public.erp_open_device_session(text, uuid, text),
  public.erp_close_device_session(text),
  public.erp_record_device_action(text, text, text, jsonb, text, text, timestamptz),
  public.erp_scan(text, text, text, text, text),
  public.erp_devices(),
  public.erp_device_queue(text),
  public.erp_device_tasks()
  to authenticated, service_role;

-- ── The register that says which door writes, and what gates it ─────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_register_device', 'erp.register_device',
   'Registers a scanner against a site. §14.6 makes registration the thing an unregistered device is refused for, so the act of registering is administrative configuration and gates on administration.configure.'),
  ('erp_open_device_session', 'erp.open_device_session',
   'Opens a shift on a scanner and ends whoever held it before. Gates on inventory.move: the session exists to do warehouse work, and somebody who may not move stock has no business holding a terminal.'),
  ('erp_close_device_session', 'erp.close_device_session',
   'Ends this operator''s own open sessions. Gated the same as opening one, because signing out of work you were never entitled to start is not a separate right.'),
  ('erp_record_device_action', 'erp.record_device_action',
   'Queues a store-and-forward action. This is the write a device makes all day, and it gates on inventory.move because that is what the action will eventually do.')
on conflict (function_name) do nothing;

-- ── The build fails here if any of that is ungoverned ───────────────────────
--
-- §16.2: a migration that adds a callable function must register it and pass
-- the boundary assertion in the same migration, so an ungoverned entry point
-- cannot survive its own transaction.

select erp.assert_public_api_safe();
select erp.assert_device_operations_sound();
select erp.assert_isolation();
select erp.assert_session_context_hygiene();
select erp.assert_no_dead_configuration();

-- ── The decision this settles, and the one it opens ─────────────────────────

update erp_meta.policy_decision set
  status = 'accepted',
  decision = 'The warehouse client is deliberately not built. The database surface it calls is, including the public doors that were missing, the scan-rule evaluation that nothing performed, device registration, and authorisation on both existing doors.',
  rationale = 'The client properties §14.2 and §14.7 name — forty-eight pixel touch targets, thumb-reachable portrait layout, haptics, a three-hundred-millisecond scan-to-response budget — are measurable only in a client, and claiming them from a schema would read as done and not be. That reasoning was always right. What it concealed is that no client could have been written: every Part 14 function lived in schema erp, which PostgREST does not expose. The deferral is a scheduling choice now; before this it was a dead end.',
  evidence = 'public.erp_register_device, erp_open_device_session, erp_close_device_session, erp_record_device_action, erp_scan, erp_devices, erp_device_queue and erp_device_tasks, all registered in erp_meta.public_write_allowance where they write and all revoked from anon; erp.evaluate_scan() applies erp.scan_rule, which previously nothing read; and erp_test.device_boundary_suite() proves an operator without inventory.move is refused a session on a device that is registered and active.',
  decided_at = now()
 where code = 'device_client_not_built';

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'device_action_queue_is_not_drained',
  'Nothing applies a queued device action',
  'v1.2 §14.5',
  'erp.device_action rows are recorded and read back, and no function moves one to applied or conflicted. The queue is written and surfaced; it is not drained.',
  'Draining it means deciding, for each of the twenty-two tasks in erp_ref.device_task, which existing module function performs the work and what makes an action no longer valid — a putaway whose location has been re-slotted, a pick whose line has been cancelled. That is per-module design, not plumbing, and the shapes differ enough that a single generic applier would be wrong for most of them. Recorded rather than guessed at, because §14.5 promises an action "never posts silently or silently disappears", and today it holds that promise by never posting: honest, and not what was meant.',
  'open',
  'erp.device_queue() and public.erp_device_queue() surface queued and conflicted actions to the operator, so the gap is visible from the client rather than only from the table. erp.device_operations_report() already fails a conflicted action carrying no reason.');
