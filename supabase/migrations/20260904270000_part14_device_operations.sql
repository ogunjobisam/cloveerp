-- =============================================================================
-- Part 14 — device operations: registration, scanning standards, offline queue
--
-- "The warehouse does not use the application described in Part 7. It uses a
-- different application against the same functions: one task at a time, driven
-- by scanning, operated with gloves on, in poor light, sometimes without a
-- network."
--
-- Much of Part 14 is a client specification and cannot live here: §14.1's device
-- classes describe hardware, §14.2's forty-eight pixel touch targets and
-- thumb-reachable layout are a screen, and §14.7's three-hundred-millisecond
-- scan response is measured in the application. What IS a database concern is
-- everything those screens would otherwise each reinvent, and it is exactly the
-- part the specification says must not be reinvented:
--
--   §14.4 "A single scan populates several fields, and THE PARSER IS SHARED,
--   NOT PER-SCREEN."  →  erp.parse_gs1(), one function, with the application
--   identifiers as reference data rather than as a case statement somebody has
--   to remember to extend.
--
--   §14.4 "Unrecognised barcodes are rejected with the scanned value shown,
--   never silently ignored."  →  the parser raises, and the message carries the
--   value. An operator holding a barcode that did nothing cannot act on
--   silence.
--
--   §14.5 "Store and forward with idempotency keys on every queued action, so
--   RECONNECTION NEVER DUPLICATES."  →  a unique key per device action, and a
--   resubmission returns the original rather than erroring. Erroring would be
--   almost as bad: a device that cannot tell "already done" from "failed" will
--   either duplicate or drop.
--
--   §14.5 "an action that is no longer valid ... surfaces to the operator as an
--   exception with the reason, and NEVER POSTS SILENTLY OR SILENTLY DISAPPEARS."
--   →  a conflicted action keeps its row and must carry a reason.
--
--   §14.6 "Devices are registered and bound to a site; AN UNREGISTERED DEVICE
--   CANNOT TRANSACT."  →  a refusal.
--
--   §14.2 "Scan first, type never. ... Keyboard entry exists as an exception
--   path, ALWAYS REQUIRING A REASON where it substitutes for a scan of something
--   that should have been scannable."  →  a constraint: keyed input with no
--   reason is a row the database will not hold.
--
-- §14.3's task inventory is a register, because "each task is a self-contained
-- flow with a defined start, a defined completion, and a defined abandon path"
-- is a claim that can be checked and otherwise will not be.
-- =============================================================================

-- ── §14.1 device classes, as reference data ─────────────────────────────────

create table if not exists erp_ref.device_class (
  code            text primary key,
  name            text not null,
  description     text not null,
  is_handsfree    boolean not null default false,
  seq             integer not null,
  registered_at   timestamptz not null default now()
);

comment on table erp_ref.device_class is
  'Specification v1.2 §14.1. "One codebase serves all of them. Layout adapts; '
  'the task flow does not change between devices" — so the class is data the '
  'client reads, not a fork of the application.';

insert into erp_ref.device_class (code, name, description, is_handsfree, seq) values
('handheld', 'Ruggedised handheld terminal',
 'The primary device. Android, physical scan trigger, four to six inch portrait screen, worn or holstered.', false, 10),
('wearable', 'Ring or wearable scanner with wrist display',
 'Hands-free picking; the display shows one instruction and the scanner confirms it.', true, 20),
('vehicle', 'Vehicle-mounted terminal',
 'Forklift work: putaway, bulk moves, replenishment. Larger screen, operated stationary, never while moving.', false, 30),
('tablet', 'Tablet',
 'Supervision, quality inspection, receiving desks, goods-in booking.', false, 40),
('fixed', 'Fixed station',
 'Packing benches and despatch desks, with a keyboard, a scanner and a label printer.', false, 50),
('voice', 'Voice',
 'Picking by spoken instruction and confirmation, where the operation justifies it.', true, 60)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  is_handsfree = excluded.is_handsfree, seq = excluded.seq;

-- ── §14.3 the task set, with its three defined paths ────────────────────────

create table if not exists erp_ref.device_task (
  code              text primary key,
  name              text not null,
  task_group        text not null,
  starts_when       text not null,
  completes_when    text not null,
  abandons_when     text not null,
  works_offline     boolean not null default false,
  seq               integer not null,
  registered_at     timestamptz not null default now(),
  constraint device_task_group_known
    check (task_group in ('inbound','stock','outbound','production','quality'))
);

comment on table erp_ref.device_task is
  'Specification v1.2 §14.3: "Each task is a self-contained flow with a defined '
  'start, a defined completion, and a defined abandon path." All three are '
  'columns because all three are the claim; a task with no stated abandon path '
  'is one an operator gets stuck inside.';

insert into erp_ref.device_task
  (code, name, task_group, starts_when, completes_when, abandons_when, works_offline, seq) values
('goods_in_booking', 'Goods-in booking', 'inbound',
 'A vehicle arrives against an expected receipt.',
 'Arrival is confirmed against the expected receipt.',
 'The operator records that the arrival was not the expected one.', false, 10),
('receipt', 'Receipt against purchase order or advance shipping notice', 'inbound',
 'A booked arrival is selected.',
 'Every line is received, with batch, expiry and serial where controlled.',
 'The operator leaves the receipt part-received; what was received stands.', false, 20),
('receiving_discrepancy', 'Receiving discrepancy', 'inbound',
 'A receipt line does not match: short, over, damaged, wrong product, temperature excursion.',
 'A reason and a photograph are captured against the line.',
 'Not abandonable: a discrepancy noticed and not recorded is the defect this exists to prevent.', false, 30),
('handling_unit_build', 'Handling unit build', 'inbound',
 'The operator starts a new unit.',
 'The unit is closed, with contents and identity applied.',
 'The unit is discarded before it is closed; its contents return to where they came from.', true, 40),
('putaway', 'Putaway', 'inbound',
 'A putaway task is assigned, or the operator scans stock in a receiving location.',
 'The destination location is scanned to confirm.',
 'The operator releases the task; the stock stays where it is.', true, 50),
('stock_enquiry', 'Stock enquiry', 'stock',
 'A product, location or handling unit is scanned.',
 'The position is shown.',
 'The operator leaves the screen; nothing was written.', true, 60),
('internal_move', 'Internal move', 'stock',
 'A source is scanned.',
 'The destination is scanned.',
 'The operator cancels before the destination scan; nothing moved.', true, 70),
('replenishment', 'Replenishment', 'stock',
 'A directed task is assigned from bulk to a pick face or marshalling area.',
 'The destination is scanned to confirm.',
 'The operator releases the task back to the queue.', true, 80),
('count', 'Cycle count and stocktake', 'stock',
 'A count task is assigned, blind or informed.',
 'A counted quantity is recorded at a timestamp.',
 'The operator releases the count; nothing is posted.', true, 90),
('adjustment', 'Adjustment and write-off', 'stock',
 'The operator selects stock to adjust.',
 'A reason is given and, above threshold, approval is routed.',
 'The operator cancels before the reason is given.', false, 100),
('batch_action', 'Batch actions', 'stock',
 'A batch is scanned.',
 'Quarantine, release, block, split or merge is recorded under named authority.',
 'The operator cancels; the batch is unchanged.', false, 110),
('pick', 'Pick', 'outbound',
 'A pick task is assigned by order, batch, cluster, zone or wave.',
 'Location, then product, then quantity are scanned.',
 'The operator releases the task; picked lines stand.', true, 120),
('short_pick', 'Short pick', 'outbound',
 'A pick cannot be completed in full.',
 'A reason is captured, an exception raised, and replenishment triggered where stock exists elsewhere.',
 'Not abandonable: a short pick not recorded leaves an order nobody knows is short.', true, 130),
('pack', 'Pack', 'outbound',
 'A packing station selects a completed pick.',
 'Contents are scan-verified against the order, carton and weight captured, and a label printed.',
 'The operator returns the pick to the queue; nothing is packed.', false, 140),
('marshalling', 'Marshalling', 'outbound',
 'A completed unit is selected.',
 'The unit is scanned into the marshalling area.',
 'The operator cancels; the unit stays where it is.', true, 150),
('despatch', 'Despatch and loading', 'outbound',
 'A load is opened against a vehicle.',
 'Units are scanned onto the vehicle and carrier and consignment are captured.',
 'The load is closed short; what was loaded stands and the rest returns.', false, 160),
('returns_receipt', 'Returns receipt', 'outbound',
 'A return is scanned.',
 'Condition is captured and the return routed to disposition.',
 'Not abandonable: a return in the building and not recorded is stock nobody owns.', false, 170),
('component_issue', 'Component issue against a works order', 'production',
 'A works order is scanned.',
 'Batch-controlled components are scan-confirmed and issued.',
 'The operator cancels; nothing is issued.', false, 180),
('operation_booking', 'Operation booking', 'production',
 'An operation is selected.',
 'Quantity completed, quantity scrapped with reason, and time are captured.',
 'The operator cancels before booking; nothing is recorded.', false, 190),
('finished_goods_receipt', 'Finished goods receipt', 'production',
 'A works order output is declared.',
 'A batch is created and a label printed.',
 'The operator cancels; no batch is created.', false, 200),
('inspection', 'Inspection execution', 'quality',
 'An inspection is assigned.',
 'Sampling and results are captured, with a photograph.',
 'The operator releases the inspection; the stock stays in its current status.', false, 210),
('disposition', 'Disposition', 'quality',
 'A completed inspection is selected.',
 'Accept, accept under concession, reject, return or destroy is recorded.',
 'Not abandonable: an inspected batch with no disposition is stock nobody may use or discard.', false, 220)
on conflict (code) do update set
  name = excluded.name, task_group = excluded.task_group,
  starts_when = excluded.starts_when, completes_when = excluded.completes_when,
  abandons_when = excluded.abandons_when, works_offline = excluded.works_offline,
  seq = excluded.seq;

-- ── §14.4 scanning standards, as reference data ─────────────────────────────

create table if not exists erp_ref.symbology (
  code            text primary key,
  name            text not null,
  is_gs1          boolean not null default false,
  is_two_dimensional boolean not null default false,
  note            text not null,
  seq             integer not null,
  registered_at   timestamptz not null default now()
);

insert into erp_ref.symbology (code, name, is_gs1, is_two_dimensional, note, seq) values
('gs1_128', 'GS1-128', true, false,
 'The primary carrier of application identifiers on inbound goods.', 10),
('gs1_datamatrix', 'GS1 DataMatrix', true, true,
 'Two-dimensional marking, including pharmaceutical unit packs.', 20),
('ean_13', 'EAN-13', false, false, 'Legacy and retail marking.', 30),
('upc_a', 'UPC-A', false, false, 'Legacy and retail marking.', 40),
('code_128', 'Code 128', false, false, 'Internal marking.', 50),
('code_39', 'Code 39', false, false, 'Legacy internal marking.', 60)
on conflict (code) do update set
  name = excluded.name, is_gs1 = excluded.is_gs1,
  is_two_dimensional = excluded.is_two_dimensional, note = excluded.note, seq = excluded.seq;

create table if not exists erp_ref.gs1_application_identifier (
  ai              text primary key,
  name            text not null,
  field_name      text not null,
  data_length     integer,
  is_numeric      boolean not null default true,
  note            text not null,
  constraint gs1_ai_shape check (ai ~ '^[0-9]{2,4}$')
);

comment on table erp_ref.gs1_application_identifier is
  'Specification v1.2 §14.4. The identifiers erp.parse_gs1() understands, as '
  'data rather than as a CASE somebody has to remember to extend. A null '
  'data_length means variable, terminated by the group separator or the end of '
  'the barcode.';

insert into erp_ref.gs1_application_identifier
  (ai, name, field_name, data_length, is_numeric, note) values
('00', 'Serial shipping container code', 'sscc', 18, true,
 'The identity of a handling unit. §14.4 makes the platform generate these for units it creates.'),
('01', 'Global trade item number', 'gtin', 14, true,
 'The product. One scan of a GS1-128 label gives this and the batch together.'),
('10', 'Batch or lot', 'batch', null, false,
 'Variable length up to twenty characters, terminated by the group separator.'),
('17', 'Expiry', 'expiry', 6, true,
 'YYMMDD. A day of 00 means end of month, which the parser resolves rather than leaving to each screen.'),
('21', 'Serial', 'serial', null, false,
 'Variable length up to twenty characters.'),
('37', 'Count of trade items', 'count', null, true,
 'Variable length up to eight digits.')
on conflict (ai) do update set
  name = excluded.name, field_name = excluded.field_name,
  data_length = excluded.data_length, is_numeric = excluded.is_numeric,
  note = excluded.note;

-- ── §14.4 the shared parser ─────────────────────────────────────────────────

create or replace function erp.parse_gs1(p_barcode text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_in     text := p_barcode;
  v_pos    integer := 1;
  v_len    integer;
  v_ai     text;
  v_rec    erp_ref.gs1_application_identifier%rowtype;
  v_value  text;
  v_gs     integer;
  v_out    jsonb := '{}'::jsonb;
  v_found  boolean;
begin
  if coalesce(btrim(v_in), '') = '' then
    raise exception 'ERPWARE_EMPTY_SCAN: nothing was scanned' using errcode = '22023';
  end if;

  -- Some scanners emit a leading FNC1 as the group separator; drop it rather
  -- than failing on a barcode that is perfectly good.
  v_in := ltrim(v_in, chr(29));
  v_len := length(v_in);

  while v_pos <= v_len loop
    v_found := false;

    -- Application identifiers are two to four digits. Longest match first, so a
    -- four-digit identifier is not mistaken for a two-digit one and a stray
    -- pair of digits.
    for v_ai in
      select substr(v_in, v_pos, n) from generate_series(4, 2, -1) n
       where v_pos + n - 1 <= v_len
    loop
      select * into v_rec from erp_ref.gs1_application_identifier a where a.ai = v_ai;
      if found then
        v_found := true;
        exit;
      end if;
    end loop;

    if not v_found then
      -- §14.4: "Unrecognised barcodes are rejected with the scanned value
      -- shown, never silently ignored." The value is in the message because an
      -- operator holding a barcode that did nothing cannot act on silence.
      raise exception
        'ERPWARE_UNRECOGNISED_BARCODE: % is not a barcode this product reads', p_barcode
        using errcode = '22023',
              detail = format('Stopped at position %s of %s.', v_pos, v_len),
              hint = 'Where a supplier''s barcode does not carry a needed '
                     'field, the exception path captures it with a reason.';
    end if;

    v_pos := v_pos + length(v_ai);

    if v_rec.data_length is not null then
      v_value := substr(v_in, v_pos, v_rec.data_length);
      if length(v_value) < v_rec.data_length then
        raise exception
          'ERPWARE_TRUNCATED_BARCODE: identifier % needs % characters and % has fewer',
          v_rec.ai, v_rec.data_length, p_barcode
          using errcode = '22023';
      end if;
      v_pos := v_pos + v_rec.data_length;
    else
      -- Variable length: to the group separator, or to the end.
      v_gs := position(chr(29) in substr(v_in, v_pos));
      if v_gs = 0 then
        v_value := substr(v_in, v_pos);
        v_pos := v_len + 1;
      else
        v_value := substr(v_in, v_pos, v_gs - 1);
        v_pos := v_pos + v_gs;      -- step over the separator too
      end if;
    end if;

    if v_rec.is_numeric and v_value !~ '^[0-9]+$' then
      raise exception
        'ERPWARE_BARCODE_FIELD_NOT_NUMERIC: identifier % carried %', v_rec.ai, v_value
        using errcode = '22023';
    end if;

    -- §14.4's expiry: a day of 00 means end of month. Resolved once, here,
    -- rather than in each screen that reads an expiry.
    if v_rec.ai = '17' then
      v_out := v_out || jsonb_build_object('expiry',
        case when substr(v_value, 5, 2) = '00'
             then (to_date('20' || substr(v_value,1,4) || '01', 'YYYYMMDD')
                   + interval '1 month - 1 day')::date
             else to_date('20' || v_value, 'YYYYMMDD')
        end);
    else
      v_out := v_out || jsonb_build_object(v_rec.field_name, v_value);
    end if;
  end loop;

  return v_out;
end;
$$;

comment on function erp.parse_gs1 is
  'Specification v1.2 §14.4: "A single scan populates several fields, and the '
  'parser is shared, not per-screen." One function, reading '
  'erp_ref.gs1_application_identifier, so adding an identifier is a row rather '
  'than an edit to every screen that scans.';

-- ── §14.6 the device, and the session on it ─────────────────────────────────

create table if not exists erp.device (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  site_id         uuid not null,
  code            text not null,
  name            text not null,
  device_class    text not null references erp_ref.device_class(code),
  serial_number   text,
  status          text not null default 'active',
  registered_at   timestamptz not null default now(),
  last_seen_at    timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint device_status_known check (status in ('active','suspended','retired')),
  constraint device_unique_code unique (tenant_id, code),
  constraint device_tenant_id_key unique (tenant_id, id),
  constraint device_site_fk
    foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

comment on table erp.device is
  'Specification v1.2 §14.6: "Devices are registered and bound to a site; an '
  'unregistered device cannot transact." The site binding is what makes that '
  'more than a list — a device transacting at a site it is not bound to is the '
  'thing being prevented.';

create table if not exists erp.device_session (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  device_id           uuid not null,
  app_user_id         uuid not null,
  started_at          timestamptz not null default now(),
  last_active_at      timestamptz not null default now(),
  ended_at            timestamptz,
  end_reason          text,
  -- §14.6: "Supervisor override is a separate authenticated act recorded
  -- against BOTH users." Both, because an override recorded against only the
  -- supervisor loses who was actually working, and against only the operator
  -- loses who permitted it.
  supervisor_user_id  uuid,
  supervisor_reason   text,
  constraint device_session_override_names_both
    check ((supervisor_user_id is null and supervisor_reason is null)
           or (supervisor_user_id is not null and supervisor_reason is not null)),
  constraint device_session_supervisor_is_not_operator
    check (supervisor_user_id is distinct from app_user_id),
  constraint device_session_tenant_id_key unique (tenant_id, id),
  constraint device_session_device_fk
    foreign key (tenant_id, device_id) references erp.device (tenant_id, id) on delete cascade
);

create index if not exists device_session_open
  on erp.device_session (tenant_id, device_id) where ended_at is null;

comment on table erp.device_session is
  'Specification v1.2 §14.6. "Every action attributes to the user who performed '
  'it, never to the device", which is why the session carries a principal and '
  'the action below carries the session.';

-- ── §14.4 which symbologies and identifiers a step demands ──────────────────

create table if not exists erp.scan_rule (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references erp.tenant(id) on delete cascade,
  device_task_code      text not null references erp_ref.device_task(code),
  item_class            text,
  accepted_symbologies  text[] not null default '{}',
  mandatory_identifiers text[] not null default '{}',
  when_absent           text not null default 'exception_with_reason',
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint scan_rule_when_absent_known
    check (when_absent in ('refuse','exception_with_reason','accept')),
  constraint scan_rule_accepts_something
    check (cardinality(accepted_symbologies) > 0),
  constraint scan_rule_unique unique (tenant_id, device_task_code, item_class)
);

comment on table erp.scan_rule is
  'Specification v1.2 §14.4: "Symbology and identifier rules are configuration: '
  'which symbologies are accepted at which step, which application identifiers '
  'are mandatory for which product class, and what happens when a required '
  'identifier is absent." All three are columns here, including the third, '
  'which is the one usually left to whoever writes the screen.';

-- ── §14.5 store and forward ─────────────────────────────────────────────────

create table if not exists erp.device_action (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  device_id           uuid not null,
  device_session_id   uuid,
  device_task_code    text not null references erp_ref.device_task(code),
  idempotency_key     text not null,
  payload             jsonb not null default '{}',
  -- §14.2: "Scan first, type never." Keyed entry is an exception path and must
  -- say why it was taken.
  input_method        text not null default 'scanned',
  keyed_reason        text,
  captured_at         timestamptz not null,
  received_at         timestamptz not null default now(),
  status              text not null default 'queued',
  conflict_reason     text,
  applied_at          timestamptz,
  constraint device_action_input_known
    check (input_method in ('scanned','keyed','voice')),
  constraint device_action_keyed_has_reason
    check (input_method <> 'keyed' or coalesce(btrim(keyed_reason), '') <> ''),
  constraint device_action_status_known
    check (status in ('queued','applied','conflicted','abandoned')),
  -- §14.5: an action that is no longer valid "surfaces to the operator as an
  -- exception with the reason, and never posts silently or silently
  -- disappears". A conflicted row with no reason would be a silent
  -- disappearance wearing a status.
  constraint device_action_conflict_has_reason
    check (status <> 'conflicted' or coalesce(btrim(conflict_reason), '') <> ''),
  -- The whole of store-and-forward rests on this one index.
  constraint device_action_idempotent unique (tenant_id, device_id, idempotency_key),
  constraint device_action_tenant_id_key unique (tenant_id, id),
  constraint device_action_device_fk
    foreign key (tenant_id, device_id) references erp.device (tenant_id, id) on delete cascade,
  constraint device_action_session_fk
    foreign key (tenant_id, device_session_id)
      references erp.device_session (tenant_id, id) on delete set null
);

comment on table erp.device_action is
  'Specification v1.2 §14.5: "Store and forward with idempotency keys on every '
  'queued action, so reconnection never duplicates." The unique key is the '
  'mechanism; erp.record_device_action() returning the original rather than '
  'raising is what makes a reconnecting device able to tell "already done" from '
  '"failed".';

-- ── The doors ───────────────────────────────────────────────────────────────

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
  'Specification v1.2 §14.6. Refuses an unregistered device, ends whatever '
  'session the device was carrying, and records the supervisor against the '
  'session when one authorised it.';

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
  'Specification v1.2 §14.5. Refuses an unregistered device, and returns the '
  'original action when a reconnecting device resends — the difference between '
  '"already done" and "failed" is what stops a store-and-forward queue either '
  'duplicating or dropping.';

-- ── The assertion ───────────────────────────────────────────────────────────

create or replace function erp.device_operations_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- §14.3: all three paths, for every task. A task with no abandon path is one
  -- an operator gets stuck inside, and the register is where that shows.
  select 'a device task does not define all three of its paths', t.code,
         'start, completion and abandon are the claim §14.3 makes'
    from erp_ref.device_task t
   where coalesce(btrim(t.starts_when), '') = ''
      or coalesce(btrim(t.completes_when), '') = ''
      or coalesce(btrim(t.abandons_when), '') = ''

  union all

  -- §14.4: every identifier the parser could meet must be readable back to a
  -- field, or a scan populates something nothing can name.
  select 'an application identifier names no field', a.ai, a.name
    from erp_ref.gs1_application_identifier a
   where coalesce(btrim(a.field_name), '') = ''

  union all

  -- A scan rule naming a symbology the product does not read.
  select 'a scan rule accepts a symbology that does not exist',
         r.device_task_code, s.code
    from erp.scan_rule r
    cross join lateral unnest(r.accepted_symbologies) as s(code)
   where not exists (select 1 from erp_ref.symbology y where y.code = s.code)

  union all

  -- A scan rule demanding an identifier the parser cannot produce.
  select 'a scan rule requires an identifier the parser does not read',
         r.device_task_code, i.ai
    from erp.scan_rule r
    cross join lateral unnest(r.mandatory_identifiers) as i(ai)
   where not exists (select 1 from erp_ref.gs1_application_identifier a where a.ai = i.ai)

  union all

  -- §14.6: an action that attributes to no one. The device is not an actor.
  select 'a device action attributes to no session', a.id::text,
         '§14.6: every action attributes to the user who performed it, never to the device'
    from erp.device_action a
   where a.device_session_id is null and a.status = 'applied'

  union all

  -- §14.5: a conflicted action that says nothing is a silent disappearance
  -- wearing a status. Constrained too; checked here because a row that predates
  -- the constraint would still be here.
  select 'a conflicted action gives no reason', a.id::text, a.device_task_code
    from erp.device_action a
   where a.status = 'conflicted' and coalesce(btrim(a.conflict_reason), '') = ''

  union all

  -- §14.2: keyed entry is the exception path and must say why it was taken.
  select 'a keyed action gives no reason', a.id::text, a.device_task_code
    from erp.device_action a
   where a.input_method = 'keyed' and coalesce(btrim(a.keyed_reason), '') = ''

  union all

  -- §14.5 names the tasks that work offline; an offline task is only meaningful
  -- if the register says so, and a task nothing can do offline being marked as
  -- offline-capable would mislead the client into queueing it.
  select 'no device task works offline', 'device_task',
         '§14.5 requires task lists, scanning, and capture of counts, picks, moves and putaways to work offline'
    from (select 1) x
   where not exists (select 1 from erp_ref.device_task t where t.works_offline)

  order by 1, 2
$$;

comment on function erp.device_operations_report is
  'Specification v1.2 Part 14. Read by erp.assert_device_operations_sound().';

create or replace function erp.assert_device_operations_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_tasks integer; v_ais integer; v_classes integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.device_operations_report();

  if v_count > 0 then
    raise exception 'ERPWARE_DEVICE_OPERATIONS_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) into v_tasks from erp_ref.device_task;
  select count(*) into v_ais from erp_ref.gs1_application_identifier;
  select count(*) into v_classes from erp_ref.device_class;
  return format('device operations: %s task(s) across %s class(es), %s identifier(s) parsed',
                v_tasks, v_classes, v_ais);
end;
$$;

comment on function erp.assert_device_operations_sound is
  'Fails where a task does not define all three of its paths, where a scan rule '
  'names a symbology or identifier that does not exist, where an applied action '
  'attributes to no session, or where a conflicted or keyed action gives no '
  'reason.';

-- ── Registration ────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_ref','device_class','product_content','Part 14 §14.1. The device classes one codebase serves.'),
  ('erp_ref','device_task','product_content','Part 14 §14.3. The task inventory, each with its three defined paths.'),
  ('erp_ref','symbology','product_content','Part 14 §14.4. The symbologies the product reads.'),
  ('erp_ref','gs1_application_identifier','product_content','Part 14 §14.4. What the shared parser understands, as data.'),
  ('erp','device','tenant_scoped','Part 14 §14.6. Registered and bound to a site; an unregistered device cannot transact.'),
  ('erp','device_session','tenant_scoped','Part 14 §14.6. Every action attributes to the user, never to the device.'),
  ('erp','scan_rule','tenant_scoped','Part 14 §14.4. Symbology and identifier rules are configuration.'),
  ('erp','device_action','tenant_scoped','Part 14 §14.5. The store-and-forward queue, unique on its idempotency key.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('device_operations', 'Device operations sound', 'assertion', 'platform',
   'erp', 'assert_device_operations_sound', '',
   'device_operations_report', '',
   'Part 14''s warehouse application: every task defining a start, a completion '
   'and an abandon path; scan rules naming only symbologies and identifiers '
   'that exist; and no action that attributes to a device rather than a person, '
   'or conflicts without saying why.',
   true, 57)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- D1: a device is the one actor in the product that is not a person, and §14.6
-- is explicit that it must never become one.
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
('D1','erp','assert_device_operations_sound',
 '§14.6 requires every device action to attribute to the user who performed it and never to the device. An applied action with no session is an action attributed to hardware, which would put a tenant''s stock movements outside the identity D1 scopes everything by.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_ref.resource (key, locale, value, description) values
('device.unrecognised_barcode', 'en', 'This barcode was not recognised',
 '§14.4: rejected with the scanned value shown, never silently ignored.'),
('device.queued_offline', 'en', 'Saved — will send when back online',
 '§14.5: the device shows its own state plainly, so an operator can always see whether their work has landed.'),
('device.keyed_needs_reason', 'en', 'Say why this was typed rather than scanned',
 '§14.2: keyboard entry is an exception path and always requires a reason.')
on conflict (key, locale) do update set value = excluded.value;

-- Part 14 is largely a client specification, and the half that cannot live in a
-- database is recorded rather than quietly counted as done.
insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('device_client_not_built',
   'Part 14''s client application does not exist',
   'v1.2 §14.1, §14.2, §14.7',
   'This migration builds Part 14''s database surface: registration, the task '
   'register, the shared GS1 parser, scan rules and the store-and-forward '
   'queue. The warehouse application itself — one decision per screen, '
   'forty-eight pixel targets, portrait thumb-reachable layout, haptics, and '
   'the performance budgets in §14.7 — is not built.',
   'Those are properties of a client, measurable only in one, and claiming them '
   'from a schema would be the kind of coverage that reads as done and is not. '
   'The database half is what stops each screen inventing its own parser, its '
   'own idempotency scheme and its own idea of who performed an action, which '
   'is the part that cannot be retrofitted once several screens exist.',
   'open',
   'No client application in this repository targets a handheld; '
   'erp_ref.device_class describes hardware nothing here renders for.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_device_operations_sound();
select erp.assert_product_decisions_enforced();
