-- =============================================================================
-- Part 14: the warehouse application, and the resolver it needed
--
-- The accepted decision device_client_not_built said the warehouse client was
-- deliberately not built, because forty-eight pixel targets, haptics and a
-- three-hundred-millisecond budget are properties of a client and claiming
-- them from a schema would read as done and not be. The client now exists, at
-- /device, and the properties are claimed from it: the targets are a constant
-- in the screen, the feedback is the browser's vibration and audio, the
-- validation runs against cached rules, and the queue holds an action with its
-- idempotency key from the moment of capture (src/lib/device-queue.ts, tested).
--
-- Building it found two things the database was missing.
--
--   1. NOTHING TURNED A SCAN INTO AN IDENTIFIER. The handler register says a
--      putaway needs a task_id and a receipt needs an item_id, and a scanner
--      produces a GTIN, a location code, an SSCC. Every screen would have had
--      to look those up itself — which is exactly §14.4's "the parser is
--      shared, not per-screen" one step along. erp.resolve_scan_reference()
--      is that step, once: given the key a task wants and what was scanned, it
--      names the row, scoped to the device's site so a location code that
--      exists at two sites resolves to the one the operator is standing in.
--
--   2. erp.evaluate_scan() PARSED EVERY BARCODE AS GS1. §14.4 accepts EAN-13,
--      UPC-A, Code 128 and Code 39 "for legacy and internal marking", and the
--      symbology register says which are GS1. A shelf label in Code 128 was
--      rejected as "not a barcode this product reads" — the rule said accept,
--      the parser said no, and the parser was asked first. Re-emitted: a
--      barcode in a non-GS1 symbology is one value, and a retail code is
--      offered as a fourteen-digit GTIN so a rule that requires 01 is met by
--      an EAN-13 on a consumer pack.
--
-- What is deliberately still not in the client: voice picking, and the
-- carrier-mandated label formats §15.3 stores rather than reproduces. Both are
-- recorded in the decision below rather than implied by silence.
-- =============================================================================

-- ── §14.4 a barcode that is not GS1 is one value ─────────────────────────────

create or replace function erp.evaluate_scan(p_device_code text, p_task_code text, p_barcode text, p_symbology text, p_item_class text default null::text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_device  erp.device%rowtype;
  v_rule    erp.scan_rule%rowtype;
  v_sym     erp_ref.symbology%rowtype;
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
  select * into v_sym from erp_ref.symbology y where y.code = p_symbology;
  if not found then
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

  if v_sym.is_gs1 then
    -- §14.4: "Unrecognised barcodes are rejected with the scanned value shown,
    -- never silently ignored." Returned rather than raised, because an
    -- operator scanning a hundred labels an hour needs the value on the screen
    -- and the next scan to still work, not a transaction that failed.
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
  else
    -- §14.4's legacy and internal marking: one value, nothing to parse. A
    -- retail code is a GTIN, offered zero-padded to fourteen digits the way
    -- GS1 defines the comparison, so a rule requiring 01 is met by an EAN-13.
    if coalesce(btrim(p_barcode), '') = '' then
      return jsonb_build_object(
        'outcome', 'rejected', 'reason', 'ERPWARE_EMPTY_SCAN: nothing was scanned',
        'scanned_value', p_barcode, 'symbology', p_symbology, 'fields', '{}'::jsonb);
    end if;
    v_fields := jsonb_build_object('value', btrim(p_barcode));
    if p_symbology in ('ean_13', 'upc_a') and btrim(p_barcode) ~ '^[0-9]{8,14}$' then
      v_fields := v_fields || jsonb_build_object('gtin', lpad(btrim(p_barcode), 14, '0'));
    end if;
  end if;

  if v_rule.id is null then
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
$function$;

-- ── The resolver: a scan becomes the identifier a task wants ─────────────────

create or replace function erp.resolve_scan_reference(
  p_key text,
  p_scanned text,
  p_fields jsonb default '{}'::jsonb,
  p_device_code text default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site   uuid;
  v_raw    text := btrim(coalesce(p_scanned, ''));
  v_gtin   text := coalesce(p_fields ->> 'gtin',
                            case when v_raw ~ '^[0-9]{8,14}$' then v_raw end);
  v_id     uuid;
  v_label  text;
  v_n      integer;
  v_kind   text;
begin
  perform erp.authorise('inventory.read');

  if v_raw = '' then
    return jsonb_build_object('resolved', false, 'id', null, 'kind', null, 'label', null,
                              'reason', 'nothing was scanned');
  end if;

  -- The device's site scopes a location code, which is unique per site and
  -- not per organisation: the operator is standing at exactly one of them.
  if p_device_code is not null then
    select d.site_id into v_site from erp.device d
     where d.tenant_id = v_tenant and d.code = p_device_code;
  end if;

  v_kind := case
    when p_key in ('item_id', 'component_item_id') then 'item'
    when p_key in ('location_id', 'to_location_id', 'from_location_id') then 'location'
    when p_key = 'container_id' then 'container'
    when p_key = 'batch_id' then 'batch'
    when p_key = 'works_order_id' then 'works_order'
    when p_key in ('receipt_id', 'document_id', 'original_document_id') then 'document'
    when p_key = 'shipment_id' then 'shipment'
    when p_key = 'task_id' then 'warehouse_task'
    when p_key = 'inspection_id' then 'inspection'
    when p_key = 'allocation_id' then 'allocation'
    when p_key = 'order_line_id' then 'document_line'
    when p_key = 'any' then 'any'
    else 'uuid' end;

  -- An identifier the device already holds — a task chosen from its list, a
  -- pick line from an assigned order — arrives as the row's own id and is
  -- checked to exist where the key says it should.
  if v_raw ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id := v_raw::uuid;
    v_n := case v_kind
      when 'item' then (select count(*) from erp.item x where x.tenant_id = v_tenant and x.id = v_id)
      when 'location' then (select count(*) from erp.location x where x.tenant_id = v_tenant and x.id = v_id)
      when 'container' then (select count(*) from erp.container x where x.tenant_id = v_tenant and x.id = v_id)
      when 'batch' then (select count(*) from erp.batch x where x.tenant_id = v_tenant and x.id = v_id)
      when 'works_order' then (select count(*) from erp.works_order x where x.tenant_id = v_tenant and x.id = v_id)
      when 'document' then (select count(*) from erp.document x where x.tenant_id = v_tenant and x.id = v_id)
      when 'shipment' then (select count(*) from erp.shipment x where x.tenant_id = v_tenant and x.id = v_id)
      when 'warehouse_task' then (select count(*) from erp.warehouse_task x where x.tenant_id = v_tenant and x.id = v_id)
      when 'inspection' then (select count(*) from erp.inspection x where x.tenant_id = v_tenant and x.id = v_id)
      when 'allocation' then (select count(*) from erp.allocation x where x.tenant_id = v_tenant and x.id = v_id)
      when 'document_line' then (select count(*) from erp.document_line x where x.tenant_id = v_tenant and x.id = v_id)
      else 1 end;
    if v_n = 1 then
      return jsonb_build_object('resolved', true, 'id', v_id, 'kind', v_kind,
                                'label', v_raw, 'reason', null);
    end if;
    return jsonb_build_object('resolved', false, 'id', null, 'kind', v_kind, 'label', null,
                              'reason', format('%s is not a %s in this organisation', v_raw, replace(v_kind, '_', ' ')));
  end if;

  -- ── item: by GTIN on any of its barcodes, else by its own code ────────────
  if v_kind in ('item', 'any') then
    select i.id, i.code || ' ' || i.name into v_id, v_label
      from erp.item i
     where i.tenant_id = v_tenant and i.status = 'active'
       and (exists (select 1 from erp.item_barcode b
                     where b.tenant_id = v_tenant and b.item_id = i.id
                       and v_gtin is not null
                       and lpad(b.barcode, 14, '0') = lpad(v_gtin, 14, '0'))
            or i.code = v_raw)
     order by (i.code = v_raw) desc
     limit 1;
    if v_id is not null then
      return jsonb_build_object('resolved', true, 'id', v_id, 'kind', 'item',
                                'label', v_label, 'reason', null);
    end if;
    if v_kind = 'item' then
      return jsonb_build_object('resolved', false, 'id', null, 'kind', 'item', 'label', null,
        'reason', format('no product carries barcode %s or code %s', coalesce(v_gtin, '—'), v_raw));
    end if;
  end if;

  -- ── location: by code, at the device's site ───────────────────────────────
  if v_kind in ('location', 'any') then
    select count(*) into v_n from erp.location l
     where l.tenant_id = v_tenant and l.code = coalesce(p_fields ->> 'value', v_raw)
       and (v_site is null or l.site_id = v_site);
    if v_n = 1 then
      select l.id, l.code || ' · ' || s.code into v_id, v_label
        from erp.location l join erp.site s on s.tenant_id = l.tenant_id and s.id = l.site_id
       where l.tenant_id = v_tenant and l.code = coalesce(p_fields ->> 'value', v_raw)
         and (v_site is null or l.site_id = v_site);
      return jsonb_build_object('resolved', true, 'id', v_id, 'kind', 'location',
                                'label', v_label, 'reason', null);
    elsif v_n > 1 then
      return jsonb_build_object('resolved', false, 'id', null, 'kind', 'location', 'label', null,
        'reason', format('%s is a location at %s sites; a registered device says which', v_raw, v_n));
    elsif v_kind = 'location' then
      return jsonb_build_object('resolved', false, 'id', null, 'kind', 'location', 'label', null,
        'reason', format('no location is coded %s%s', v_raw,
                         case when v_site is null then '' else ' at this device''s site' end));
    end if;
  end if;

  -- ── handling unit: by SSCC, which is its code ─────────────────────────────
  if v_kind in ('container', 'any') then
    select c.id, c.code into v_id, v_label from erp.container c
     where c.tenant_id = v_tenant and c.code = coalesce(p_fields ->> 'sscc', v_raw)
     limit 1;
    if v_id is not null then
      return jsonb_build_object('resolved', true, 'id', v_id, 'kind', 'container',
                                'label', v_label, 'reason', null);
    end if;
    return jsonb_build_object('resolved', false, 'id', null,
      'kind', case when v_kind = 'any' then null else 'container' end, 'label', null,
      'reason', case when v_kind = 'any'
                     then format('%s is not a product, a location or a handling unit', v_raw)
                     else format('no handling unit carries %s', coalesce(p_fields ->> 'sscc', v_raw)) end);
  end if;

  -- ── batch: by number, narrowed by the product when the scan names one ─────
  if v_kind = 'batch' then
    select b.id, i.code || ' · ' || b.batch_number into v_id, v_label
      from erp.batch b join erp.item i on i.tenant_id = b.tenant_id and i.id = b.item_id
     where b.tenant_id = v_tenant
       and b.batch_number = coalesce(p_fields ->> 'batch', v_raw)
       and (v_gtin is null or exists (
             select 1 from erp.item_barcode x
              where x.tenant_id = v_tenant and x.item_id = i.id
                and lpad(x.barcode, 14, '0') = lpad(v_gtin, 14, '0')))
     order by b.created_at desc limit 1;
    if v_id is not null then
      return jsonb_build_object('resolved', true, 'id', v_id, 'kind', 'batch',
                                'label', v_label, 'reason', null);
    end if;
    return jsonb_build_object('resolved', false, 'id', null, 'kind', 'batch', 'label', null,
      'reason', format('no batch is numbered %s', coalesce(p_fields ->> 'batch', v_raw)));
  end if;

  -- ── the numbered things ───────────────────────────────────────────────────
  if v_kind = 'works_order' then
    select w.id, w.order_number into v_id, v_label from erp.works_order w
     where w.tenant_id = v_tenant and w.order_number = v_raw limit 1;
  elsif v_kind = 'document' then
    select d.id, d.document_number into v_id, v_label from erp.document d
     where d.tenant_id = v_tenant and d.document_number = v_raw and not d.is_cancelled limit 1;
  elsif v_kind = 'shipment' then
    select s.id, s.reference into v_id, v_label from erp.shipment s
     where s.tenant_id = v_tenant and s.reference = v_raw limit 1;
  end if;
  if v_id is not null then
    return jsonb_build_object('resolved', true, 'id', v_id, 'kind', v_kind,
                              'label', v_label, 'reason', null);
  end if;

  return jsonb_build_object('resolved', false, 'id', null, 'kind', v_kind, 'label', null,
    'reason', case when v_kind = 'uuid'
                   then format('%s expects an identifier and %s is not one', p_key, v_raw)
                   else format('no %s is numbered %s', replace(v_kind, '_', ' '), v_raw) end);
end;
$$;

comment on function erp.resolve_scan_reference is
  'Specification v1.2 §14.4, one step along from the parser: given the payload '
  'key a device task wants and what was scanned, names the row — a product by '
  'GTIN or code, a location by code at the device''s site, a handling unit by '
  'SSCC, a batch by number, a works order, document or shipment by number, and '
  'an id the device already held checked to exist. Shared, so no screen looks '
  'anything up itself.';

-- ── §14.3 stock enquiry: a position, read at the point of the scan ───────────

create or replace function erp.device_stock_position(p_reference_id uuid, p_device_code text default null)
returns table(item text, item_name text, location text, container text, batch text,
              expires_on date, stock_status text, quantity numeric)
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_site uuid;
begin
  perform erp.authorise('inventory.read');
  if p_device_code is not null then
    select d.site_id into v_site from erp.device d
     where d.tenant_id = v_tenant and d.code = p_device_code;
  end if;
  return query
  select i.code, i.name, l.code, c.code, b.batch_number, b.expires_on,
         p.stock_status::text, p.quantity
    from erp.stock_position p
    join erp.item i on i.tenant_id = p.tenant_id and i.id = p.item_id
    join erp.location l on l.tenant_id = p.tenant_id and l.id = p.location_id
    left join erp.container c on c.tenant_id = p.tenant_id and c.id = p.container_id
    left join erp.batch b on b.tenant_id = p.tenant_id and b.id = p.batch_id
   where p.tenant_id = v_tenant
     and p.quantity <> 0
     and (p.item_id = p_reference_id or p.location_id = p_reference_id
          or p.container_id = p_reference_id)
     and (v_site is null or p.site_id = v_site)
   order by l.code, i.code, b.batch_number
   limit 200;
end;
$$;

comment on function erp.device_stock_position is
  'Specification v1.2 §14.3 stock enquiry: "scan a product, location or handling '
  'unit and see position, batches, expiry, allocation state". Reads the ledger''s '
  'position at the device''s site and writes nothing.';

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_resolve_scan(
  p_key text, p_barcode text, p_fields jsonb default '{}'::jsonb, p_device_code text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select erp.resolve_scan_reference(p_key, p_barcode, p_fields, p_device_code);
$$;

create or replace function public.erp_device_stock_position(p_reference_id uuid, p_device_code text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'item', q.item, 'item_name', q.item_name, 'location', q.location,
           'container', q.container, 'batch', q.batch, 'expires_on', q.expires_on,
           'stock_status', q.stock_status, 'quantity', q.quantity)), '[]'::jsonb)
    from erp.device_stock_position(p_reference_id, p_device_code) q;
$$;

revoke all on function
  public.erp_resolve_scan(text, text, jsonb, text),
  public.erp_device_stock_position(uuid, text)
  from public, anon;

grant execute on function
  public.erp_resolve_scan(text, text, jsonb, text),
  public.erp_device_stock_position(uuid, text)
  to authenticated, service_role;

-- ── Wording and guidance ─────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description) values
('nav.device', 'en', 'Scanner',
 'Navigation label for the warehouse application: one task at a time, driven by scanning, with a queue that holds work until the network returns.')
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Scanner wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('A device is registered at a site; an unregistered one cannot transact.'),
    ('A session needs the network to open. Connect, then start.'),
    ('A supervisor is authorising this session'),
    ('Abandon this task'),
    ('An action could not be applied. The reason is in the queue.'),
    ('Another task'),
    ('Back'),
    ('Back to the desk'),
    ('Barcode type'),
    ('Cannot scan it — type it with a reason'),
    ('Captured'),
    ('Checking…'),
    ('Choose a person'),
    ('Confirm scan'),
    ('Conflicted'),
    ('Connected'),
    ('Could not be applied'),
    ('Enter the number'),
    ('Enter the value'),
    ('Every action you capture is recorded against you, never against the device. Whoever held it last is signed out.'),
    ('Everything you captured has landed.'),
    ('Held on this device until the network returns.'),
    ('Loading…'),
    ('Missing'),
    ('Needs the network'),
    ('Needs your attention'),
    ('Next'),
    ('No active device is registered. Ask an administrator to register one.'),
    ('No device chosen'),
    ('Not read'),
    ('Not yet — tap to see why'),
    ('Nothing is held here.'),
    ('Nothing matches that scan.'),
    ('Offline'),
    ('Offline with no cached rules. Connect once so the scanner can learn its steps.'),
    ('On this device'),
    ('Positions are read from the server. Reconnect to see them.'),
    ('Queue'),
    ('Refused'),
    ('Same task again'),
    ('Scan a product, location or handling unit'),
    ('Scan another'),
    ('Scan instead'),
    ('Scan now, or tap here to see the last scan'),
    ('Scanner'),
    ('Sent, not yet applied'),
    ('Sent. It applies in the order it was captured; a conflict shows in the queue with its reason.'),
    ('Sign out of this device'),
    ('Skip'),
    ('Skip to the task'),
    ('Start'),
    ('Start work on'),
    ('Starting…'),
    ('Supervisor'),
    ('Sync now'),
    ('Syncing…'),
    ('This step needs a decision only the server can make. Reconnect to do it.'),
    ('Type the identifier'),
    ('Typing an identifier needs a reason.'),
    ('Use what I typed'),
    ('Waiting to send'),
    ('What are you doing?'),
    ('Which device is this?'),
    ('Why'),
    ('Why is this typed rather than scanned?'),
    ('Works offline'),
    ('Your queue'),
    ('expires'),
    ('in use'),
    ('keyed'),
    ('last sync'),
    ('Inbound'),
    ('Stock'),
    ('Outbound'),
    ('Production'),
    ('Quality'),
    ('Scan the product'),
    ('Scan the component'),
    ('Scan the location'),
    ('Scan the destination location'),
    ('Scan the source location'),
    ('Scan the handling unit'),
    ('Scan the batch'),
    ('Scan the works order'),
    ('Scan the task'),
    ('Scan the pick'),
    ('Scan the receipt'),
    ('Scan the order line'),
    ('Scan the original document'),
    ('Scan the shipment'),
    ('Scan the inspection'),
    ('How many?'),
    ('How many minutes?'),
    ('Why?'),
    ('Note'),
    ('New status'),
    ('Carrier'),
    ('Service'),
    ('Reason code'),
    ('Severity'),
    ('Batch number'),
    ('Characteristic'),
    ('Measured value'),
    ('Operation number'),
    ('How many scrapped?'),
    ('Why scrapped?'),
    ('Disposition')
  ) t(text)
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/device', 'nav.device', 'inventory',
   'The warehouse application. Choose the device you are holding, start a session so every action is yours, pick one task, and scan. Work captured without a network is held on the device and sent, in order, when it returns.',
   '["Choose the device and start a session; whoever held it last is signed out.","Pick a task. A step marked not yet says why when tapped.","Scan what each step asks for. Typing is the exception and asks for a reason.","Watch the chip: Connected, Offline with a count, or Syncing. The queue shows what has not landed and why."]',
   'Open a session and scan your first location.',
   '{erp_open_device_session,erp_record_device_action,erp_drain_device_actions}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

insert into erp_ref.first_run_step (guide_code, seq, screen_path, permission_code, title, why) values
  ('warehouse', 5, '/device', 'inventory.move',
   'Open a session on a scanner',
   'The device is where you are; the session is who you are. Every action attributes to the person, never to the terminal.')
on conflict (guide_code, seq) do update set
  screen_path = excluded.screen_path, permission_code = excluded.permission_code,
  title = excluded.title, why = excluded.why;

-- ── The decision, revised ────────────────────────────────────────────────────

update erp_meta.policy_decision set
  title = 'Part 14''s client is the web client at /device',
  decision =
    'The warehouse application is built as a screen of this product, served to '
    'any device with a browser and a scanner: one decision per screen, scan '
    'first with typing as a reasoned exception, sixty-four pixel targets with '
    'forty-eight as the floor, verdicts carried in words and shapes as well as '
    'colour, primary actions at the bottom, haptic and audible feedback distinct '
    'for accepted, rejected and complete, validation against cached rules, and a '
    'store-and-forward queue keyed at capture that survives sleep and signal loss.',
  rationale =
    'The original reason stands: those are properties of a client and could '
    'only be claimed from one. So they are claimed from one. What the client '
    'does not do is decide anything about stock: it captures, validates against '
    'the same rules the database holds, resolves scans through the shared '
    'resolver, and queues; the module function the handler register names '
    'applies the action and its refusal is the conflict the operator reads. '
    'Two things are outside it by choice: voice picking (§14.1) needs a speech '
    'engine the browser does not carry, and carrier-mandated label formats '
    '(§15.3) are stored from the carrier rather than reproduced.',
  status = 'accepted',
  evidence =
    'src/routes/device.tsx is the client; src/lib/gs1.ts mirrors erp.parse_gs1 '
    'and erp.evaluate_scan for offline validation and src/lib/gs1.test.ts holds '
    'them to the same cases; src/lib/device-queue.ts is the queue and '
    'src/lib/device-queue.test.ts proves the idempotency key is kept through '
    'every resend; erp.resolve_scan_reference() is the shared resolver and '
    'erp_test.device_client_suite() attacks it.'
where code = 'device_client_not_built';

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.device_client_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  v_code   text := 'zzdc-' || substr(md5(random()::text), 1, 6);
  v_tenant uuid;
  ad       uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_site2 uuid; v_uom uuid; v_item uuid; v_loc uuid;
  v_cont uuid; v_batch uuid;
  res jsonb; v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Device Client', 'admin@zzdc.test', 'Client Admin');
  v_tenant := r.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzdc.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'DC1', 'Distribution centre', 'warehouse', 'active')
  returning id into v_site;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'DC2', 'Second centre', 'warehouse', 'active')
  returning id into v_site2;
  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (v_tenant, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'WID', 'Widget', v_uom, 'active') returning id into v_item;
  insert into erp.item_barcode (tenant_id, item_id, barcode, barcode_kind, uom_id, is_primary)
  values (v_tenant, v_item, '5012345678900', 'ean13', v_uom, true);
  -- The same location code at both sites: a scan of it is ambiguous until a
  -- device says where the operator is standing.
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (v_tenant, v_site, 'A-01-01', 'Aisle A bay 1', 'bulk', 'active') returning id into v_loc;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (v_tenant, v_site2, 'A-01-01', 'Aisle A bay 1', 'bulk', 'active');
  insert into erp.container (tenant_id, code, container_type, site_id, location_id, status)
  values (v_tenant, '350123456789012345', 'pallet', v_site, v_loc, 'active') returning id into v_cont;
  insert into erp.batch (tenant_id, item_id, batch_number, status)
  values (v_tenant, v_item, 'LOT42', 'released') returning id into v_batch;
  perform erp_test.close_bootstrap_window(v_tenant);

  perform erp.register_device('SCAN-01', 'DC1', 'Aisle scanner', 'handheld', 'SN-001');

  -- ── §14.4 legacy marking is read, not rejected ────────────────────────────

  res := erp.evaluate_scan('SCAN-01', 'putaway', 'A-01-01', 'code_128');
  return query select 'a Code 128 location label is one value, accepted',
    res ->> 'outcome' = 'accepted' and res -> 'fields' ->> 'value' = 'A-01-01', res::text;

  res := erp.evaluate_scan('SCAN-01', 'receipt', '5012345678900', 'ean_13');
  return query select 'an EAN-13 is offered as a fourteen-digit GTIN',
    res ->> 'outcome' = 'accepted' and res -> 'fields' ->> 'gtin' = '05012345678900',
    res -> 'fields' ->> 'gtin';

  perform erp.upsert_scan_rule('receipt', 'gs1_128,ean_13', '01', 'refuse', null);
  res := erp.evaluate_scan('SCAN-01', 'receipt', '5012345678900', 'ean_13');
  return query select 'so a rule requiring 01 is met by a consumer pack',
    res ->> 'outcome' = 'accepted', res ->> 'reason';

  res := erp.evaluate_scan('SCAN-01', 'receipt', '010501234567890010LOT42', 'gs1_128');
  return query select 'and a GS1-128 still parses into its fields',
    res ->> 'outcome' = 'accepted' and res -> 'fields' ->> 'batch' = 'LOT42', res::text;

  -- ── The resolver ──────────────────────────────────────────────────────────

  res := erp.resolve_scan_reference('item_id', '010501234567890010LOT42',
           '{"gtin": "05012345678900", "batch": "LOT42"}', 'SCAN-01');
  return query select 'a GTIN from a GS1 scan names the product through its barcode',
    (res ->> 'resolved')::boolean and (res ->> 'id')::uuid = v_item and res ->> 'kind' = 'item',
    res ->> 'label';

  res := erp.resolve_scan_reference('item_id', 'WID', '{}', 'SCAN-01');
  return query select 'a product code scanned as text names the product too',
    (res ->> 'resolved')::boolean and (res ->> 'id')::uuid = v_item, res ->> 'label';

  res := erp.resolve_scan_reference('item_id', '9999999999999', '{"gtin": "09999999999999"}', 'SCAN-01');
  return query select 'an unknown barcode is not resolved, and says what it looked for',
    not (res ->> 'resolved')::boolean and res ->> 'reason' like 'no product carries barcode%',
    res ->> 'reason';

  res := erp.resolve_scan_reference('to_location_id', 'A-01-01', '{"value": "A-01-01"}', null);
  return query select 'a location code at two sites is ambiguous without a device',
    not (res ->> 'resolved')::boolean and res ->> 'reason' like '%2 sites%', res ->> 'reason';

  res := erp.resolve_scan_reference('to_location_id', 'A-01-01', '{"value": "A-01-01"}', 'SCAN-01');
  return query select 'and resolves to the device''s own site with one',
    (res ->> 'resolved')::boolean and (res ->> 'id')::uuid = v_loc and res ->> 'label' like '%DC1',
    res ->> 'label';

  res := erp.resolve_scan_reference('container_id', '00350123456789012345',
           '{"sscc": "350123456789012345"}', 'SCAN-01');
  return query select 'an SSCC names the handling unit',
    (res ->> 'resolved')::boolean and (res ->> 'id')::uuid = v_cont, res ->> 'label';

  res := erp.resolve_scan_reference('batch_id', 'LOT42', '{"gtin": "05012345678900", "batch": "LOT42"}', 'SCAN-01');
  return query select 'a batch number narrowed by the product names the batch',
    (res ->> 'resolved')::boolean and (res ->> 'id')::uuid = v_batch, res ->> 'label';

  res := erp.resolve_scan_reference('task_id', v_item::text, '{}', 'SCAN-01');
  return query select 'an id the device holds is checked against the table the key names',
    not (res ->> 'resolved')::boolean and res ->> 'reason' like '%not a warehouse task%', res ->> 'reason';

  res := erp.resolve_scan_reference('any', '5012345678900', '{"gtin": "05012345678900", "value": "5012345678900"}', 'SCAN-01');
  return query select 'a stock enquiry scan is tried as product, location, then handling unit',
    (res ->> 'resolved')::boolean and res ->> 'kind' = 'item', res ->> 'kind';

  res := erp.resolve_scan_reference('any', 'NOPE', '{"value": "NOPE"}', 'SCAN-01');
  return query select 'and says so when it is none of them',
    not (res ->> 'resolved')::boolean and res ->> 'reason' like '%not a product, a location or a handling unit', res ->> 'reason';

  -- ── The position door ─────────────────────────────────────────────────────

  return query select 'a product with no stock has no position, rather than an error',
    public.erp_device_stock_position(v_item, 'SCAN-01') = '[]'::jsonb,
    'empty list';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id = ad;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant), 'organisation gone';
end;
$$;

create or replace function erp_test.assert_device_client_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _device_client_result on commit drop as
    select * from erp_test.device_client_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _device_client_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_DEVICE_CLIENT_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('device client: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_device_client_suite();

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_device_operations_sound();
select erp.assert_device_task_handlers_sound();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
