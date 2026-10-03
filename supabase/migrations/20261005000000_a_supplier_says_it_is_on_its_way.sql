set lock_timeout = '30s';

-- =============================================================================
-- 20261005000000  A supplier says it is on its way
-- -----------------------------------------------------------------------------
-- Owner, 3 October 2026: the advance shipping notice. A supplier confirmed the
-- order (20261004990000) and then nothing said the goods had left: what is in
-- the delivery, in which cartons, when it arrives and with whom.
--
-- Owner decisions:
--   * The supplier sends the notice from the same link, once the order is
--     confirmed; the buyer can record one.
--   * Lines are required; cartons, with their SSCC and contents, optional.
--   * Goods-in receives a notice as notified in one press, any line changed
--     for what arrived, or a carton at a time by scanning its SSCC.
--   * Differences are recorded against the notice and the buyer is told.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.shipping_notice, its lines and its cartons: one notice per
--      dispatch against a sent order, several to an order, never more than is
--      still open on a line.
--   B. erp_supplier_notify_shipment (the link, service role) and
--      erp_record_shipping_notice (the buyer); erp_cancel_shipping_notice.
--   C. erp_receive_as_notified: a goods receipt at the notified quantities,
--      or what arrived, posted; the differences kept on the notice and the
--      buyer told. erp_receive_notified_carton: one carton by its SSCC, from
--      the desk or the scanner (device task carton_receipt).
--   D. Planning expects a notified line when the notice says it arrives.
--   E. The daily look procurement.notice_overdue tells the buyer of a notice
--      past its arrival with nothing received.
--   F. The supplier's page reads the notices and what is still open.
--
-- Proved by erp_test.shipping_notice_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_ORDER_NOT_OPEN_FOR_NOTICE',
  'Notifying a shipment for an order that is not sent and open, or, from the supplier''s link, not yet confirmed.',
  'A shipment is notified against an order the supplier has agreed to; one received in full, closed or cancelled has nothing left to send.',
  'Confirm the order first, or ask the buyer, who can send it again.');

select erp.register_refusal('CLOVEERP_NOTICE_LINE_INVALID',
  'Notifying a line that is not on the order, a quantity of nothing, or more than is still open on the line.',
  'A notice says what is in one delivery; more than is still owed would be received against nothing.',
  'Give each line a quantity no more than what is still open on it, counting earlier notices.');

select erp.register_refusal('CLOVEERP_NOTICE_DATES_INVALID',
  'Notifying a shipment that arrives before it leaves, or leaves before the order was placed.',
  'A delivery cannot arrive before it is sent, nor be sent before it was ordered.',
  'Give a ship date on or after the order date and an arrival on or after the ship date.');

select erp.register_refusal('CLOVEERP_CARTON_INVALID',
  'Notifying a carton without an 18-digit SSCC with its check digit, one already notified, or contents that do not add up to the notice''s lines.',
  'A carton is received by scanning its SSCC, so a wrong or repeated one receives the wrong goods.',
  'Give each carton the SSCC printed on its label and list what is in it; the cartons together hold what the lines say.');

select erp.register_refusal('CLOVEERP_NOTICE_NOT_OPEN',
  'Receiving or cancelling a notice that has been received or cancelled already.',
  'A notice is received once; what arrives afterwards is received against the order.',
  'Receive what else arrived against the order with Receive an order.');

select erp.register_refusal('CLOVEERP_CARTON_UNKNOWN',
  'Scanning a carton no open notice of this organisation lists.',
  'Only a notified carton can be received by its label; anything else is received against its order.',
  'Check the label is the carton''s SSCC, or receive the goods against the order.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.purchase_order.shipment_notified', 'en', 'Shipment notified', 'procurement',
   'Event raised when a supplier, or the buyer for them, notifies a shipment against an order.'),
  ('event.purchase_order.shipment_notified', 'de', 'Lieferavis erhalten', 'procurement',
   'Ereignis, wenn ein Lieferant oder der Einkäufer für ihn eine Lieferung zu einer Bestellung avisiert.'),
  ('event.purchase_order.notice_received', 'en', 'Notified shipment received', 'procurement',
   'Event raised when a notified shipment, or one of its cartons, is received.'),
  ('event.purchase_order.notice_received', 'de', 'Avisierte Lieferung empfangen', 'procurement',
   'Ereignis, wenn eine avisierte Lieferung oder einer ihrer Kartons empfangen wird.'),
  ('job_handler.notice_overdue.name', 'en', 'Notified shipments overdue', 'procurement', 'Job handler name (20261005000000).'),
  ('job_handler.notice_overdue.name', 'de', 'Überfällige avisierte Lieferungen', 'procurement', null)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('purchase_order.shipment_notified', 1, 'document', 'procurement', 'event.purchase_order.shipment_notified',
   'A supplier, or the buyer for them, notified a shipment against an order.',
   '{"type":"object","required":["reference","notice","via"],"properties":{"reference":{"type":"string"},"notice":{"type":"string"},"via":{"type":"string"},"lines":{"type":"integer"},"cartons":{"type":"integer"}}}'::jsonb, true),
  ('purchase_order.notice_received', 1, 'document', 'procurement', 'event.purchase_order.notice_received',
   'A notified shipment, or one of its cartons, was received.',
   '{"type":"object","required":["reference","notice","receipt"],"properties":{"reference":{"type":"string"},"notice":{"type":"string"},"receipt":{"type":"string"},"differences":{"type":"integer"},"carton":{"type":["string","null"]}}}'::jsonb, true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code in ('purchase_order.shipment_notified', 'purchase_order.notice_received')
         and et.is_current and et.version = 1 and et.name_key = 'event.' || et.code) <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a shipping notice event is declared already, and not as 20261005000000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The tables
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.shipping_notice (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  order_id           uuid not null,
  notice_number      text not null,
  status             text not null default 'notified',
  ship_date          date,
  expected_arrival   date not null,
  carrier            text,
  tracking_reference text,
  supplier_reference text,
  note               text,
  sent_via           text not null,
  sent_by            uuid,
  receipt_id         uuid,
  received_at        timestamptz,
  differences        jsonb not null default '[]'::jsonb,
  cancelled_reason   text,
  late_notified_at   timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint shipping_notice_tenant_id_id_key unique (tenant_id, id),
  constraint shipping_notice_number_once unique (tenant_id, notice_number),
  constraint shipping_notice_order_fk foreign key (tenant_id, order_id) references erp.document(tenant_id, id) on delete restrict,
  constraint shipping_notice_receipt_fk foreign key (tenant_id, receipt_id) references erp.document(tenant_id, id) on delete restrict,
  constraint shipping_notice_status_known check (status in ('notified', 'part_received', 'received', 'cancelled')),
  constraint shipping_notice_via_known check (sent_via in ('supplier', 'buyer')),
  constraint shipping_notice_dates_in_order check (ship_date is null or expected_arrival >= ship_date),
  constraint shipping_notice_differences_is_a_list check (jsonb_typeof(differences) = 'array')
);

create index if not exists shipping_notice_open on erp.shipping_notice (tenant_id, expected_arrival)
  where status in ('notified', 'part_received');
create index if not exists shipping_notice_order on erp.shipping_notice (tenant_id, order_id);

comment on table erp.shipping_notice is
  'An advance shipping notice (20261005000000): one dispatch against a sent purchase order, when it left '
  'and arrives, with whom, what it holds and, once received, how what arrived differed.';

create table if not exists erp.shipping_notice_line (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  notice_id         uuid not null,
  order_line_id     uuid not null,
  quantity          numeric(20,6) not null,
  received_quantity numeric(20,6),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint shipping_notice_line_tenant_id_id_key unique (tenant_id, id),
  constraint shipping_notice_line_once unique (tenant_id, notice_id, order_line_id),
  constraint shipping_notice_line_notice_fk foreign key (tenant_id, notice_id) references erp.shipping_notice(tenant_id, id) on delete cascade,
  constraint shipping_notice_line_order_line_fk foreign key (tenant_id, order_line_id) references erp.document_line(tenant_id, id) on delete restrict,
  constraint shipping_notice_line_quantity_positive check (quantity > 0)
);

-- Planning and the open quantity look a line's notices up by the line.
create index if not exists shipping_notice_line_order_line on erp.shipping_notice_line (tenant_id, order_line_id);

create table if not exists erp.shipping_notice_carton (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  notice_id   uuid not null,
  sscc        text not null,
  contents    jsonb not null default '[]'::jsonb,
  receipt_id  uuid,
  received_at timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint shipping_notice_carton_tenant_id_id_key unique (tenant_id, id),
  constraint shipping_notice_carton_notice_fk foreign key (tenant_id, notice_id) references erp.shipping_notice(tenant_id, id) on delete cascade,
  constraint shipping_notice_carton_receipt_fk foreign key (tenant_id, receipt_id) references erp.document(tenant_id, id) on delete restrict,
  constraint shipping_notice_carton_sscc_shape check (sscc ~ '^[0-9]{18}$'),
  constraint shipping_notice_carton_contents_is_a_list check (jsonb_typeof(contents) = 'array')
);

-- A carton is notified once while it is coming: the label is how it is found.
create unique index if not exists shipping_notice_carton_open_sscc on erp.shipping_notice_carton (tenant_id, sscc)
  where received_at is null;

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'shipping_notice', 'tenant_scoped', 'An advance shipping notice; its state moves as it is received or cancelled, so not append-only.'),
  ('erp', 'shipping_notice_line', 'tenant_scoped', 'A notice''s quantity of one order line, and what of it was received.'),
  ('erp', 'shipping_notice_carton', 'tenant_scoped', 'A notified carton by its SSCC and contents, and when it was received.')
on conflict (schema_name, table_name) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. Notifying
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.sscc_is_valid(p_sscc text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- An SSCC: eighteen digits whose last is the GS1 check digit of the
  -- seventeen before it (20261005000000).
  select coalesce(p_sscc ~ '^[0-9]{18}$'
     and (10 - (select sum(substr(p_sscc, i, 1)::integer * case when i % 2 = 1 then 3 else 1 end)
                  from generate_series(1, 17) i) % 10) % 10 = substr(p_sscc, 18, 1)::integer, false)
$$;

create or replace function erp.sscc_of(p_scan text)
returns text
language sql
immutable
set search_path = ''
as $$
  -- The SSCC a scan carries (20261005000000): eighteen digits bare, or after
  -- the application identifier (00), as a wedge scanner types a GS1-128
  -- label or as it is printed under the bars. Null for anything else.
  with s as (select regexp_replace(regexp_replace(coalesce(p_scan, ''), '^\][A-Za-z][0-9]', ''),
                                   '[()[:space:]' || chr(29) || ']', '', 'g') as digits)
  select case when s.digits ~ '^[0-9]{18}$' then s.digits
              when s.digits ~ '^00[0-9]{18}$' then substr(s.digits, 3) end
    from s
$$;

create or replace function erp.order_line_open_for_notice(p_line uuid, p_except uuid default null)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- What of an order line no notice still coming holds (20261005000000): its
  -- quantity, less what was received, less what open notices say is coming.
  select greatest(0, l.quantity - coalesce(l.quantity_fulfilled, 0)
           - coalesce((select sum(nl.quantity - coalesce(nl.received_quantity, 0))
                         from erp.shipping_notice_line nl
                         join erp.shipping_notice n on n.tenant_id = nl.tenant_id and n.id = nl.notice_id
                        where nl.tenant_id = l.tenant_id and nl.order_line_id = l.id
                          and n.status in ('notified', 'part_received')
                          and n.id is distinct from p_except), 0))
    from erp.document_line l
   where l.tenant_id = erp.current_tenant_id() and l.id = p_line
$$;

create or replace function erp.record_shipping_notice(p_order uuid, p_notice jsonb, p_via text, p_by uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  v_ship    date := nullif(p_notice ->> 'ship_date', '')::date;
  v_arrive  date := nullif(p_notice ->> 'expected_arrival', '')::date;
  v_lines   jsonb := coalesce(p_notice -> 'lines', '[]'::jsonb);
  v_cartons jsonb := coalesce(p_notice -> 'cartons', '[]'::jsonb);
  v_id      uuid;
  v_number  text;
  x         jsonb;
  y         jsonb;
  l         erp.document_line%rowtype;
  v_qty     numeric;
  v_sscc    text;
  v_sum     numeric;
begin
  -- A shipment notified against an order (20261005000000): its dates, its
  -- carrier and tracking, what of each line it holds and, if the supplier
  -- labels them, its cartons. Never more than is still open on a line.
  select x2.* into d from erp.document x2 where x2.tenant_id = v_tenant and x2.id = p_order for update;
  if d.id is null or erp.object_current_state('document', p_order) not in ('sent', 'partially_received')
     or (p_via = 'supplier' and not exists (select 1 from erp.purchase_order_confirmation c
                                              where c.tenant_id = v_tenant and c.order_id = p_order and c.status = 'confirmed')) then
    raise exception 'CLOVEERP_ORDER_NOT_OPEN_FOR_NOTICE: % is not an order open for a shipment notice', coalesce(d.document_number, 'the order')
      using errcode = '23514', hint = 'Confirm the order first, or ask the buyer, who can send it again.';
  end if;
  if v_arrive is null or (v_ship is not null and (v_arrive < v_ship or v_ship < d.document_date)) then
    raise exception 'CLOVEERP_NOTICE_DATES_INVALID: % cannot leave on % and arrive on %', d.document_number,
      coalesce(v_ship::text, 'an unknown day'), coalesce(v_arrive::text, 'no day')
      using errcode = '22023', hint = 'Give a ship date on or after the order date and an arrival on or after the ship date.';
  end if;
  if jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) = 0 then
    raise exception 'CLOVEERP_NOTICE_LINE_INVALID: a notice for % holds no lines', d.document_number
      using errcode = '22023', hint = 'Give each line a quantity no more than what is still open on it, counting earlier notices.';
  end if;

  v_number := 'ASN-' || d.document_number || '-' ||
              (select count(*) + 1 from erp.shipping_notice n where n.tenant_id = v_tenant and n.order_id = p_order);
  insert into erp.shipping_notice (tenant_id, order_id, notice_number, ship_date, expected_arrival, carrier,
                                   tracking_reference, supplier_reference, note, sent_via, sent_by)
  values (v_tenant, p_order, v_number, v_ship, v_arrive,
          nullif(btrim(coalesce(p_notice ->> 'carrier', '')), ''),
          nullif(btrim(coalesce(p_notice ->> 'tracking_reference', '')), ''),
          nullif(btrim(coalesce(p_notice ->> 'supplier_reference', '')), ''),
          nullif(btrim(coalesce(p_notice ->> 'note', '')), ''), p_via, p_by)
  returning id into v_id;

  for x in select value from jsonb_array_elements(v_lines) loop
    select x2.* into l from erp.document_line x2
     where x2.tenant_id = v_tenant and x2.document_id = p_order and not x2.is_cancelled
       and x2.id::text = (x ->> 'order_line_id');
    v_qty := nullif(x ->> 'quantity', '')::numeric;
    if l.id is null or v_qty is null or v_qty <= 0 or v_qty > erp.order_line_open_for_notice(l.id, v_id) then
      raise exception 'CLOVEERP_NOTICE_LINE_INVALID: line % of % cannot be notified at %',
        coalesce(l.line_no::text, x ->> 'order_line_id', '?'), d.document_number, coalesce(x ->> 'quantity', 'nothing')
        using errcode = '22023', hint = 'Give each line a quantity no more than what is still open on it, counting earlier notices.';
    end if;
    insert into erp.shipping_notice_line (tenant_id, notice_id, order_line_id, quantity)
    values (v_tenant, v_id, l.id, v_qty)
    on conflict (tenant_id, notice_id, order_line_id) do update set quantity = erp.shipping_notice_line.quantity + excluded.quantity;
  end loop;

  -- The cartons, where the supplier labels them: each SSCC sound and new,
  -- and together holding exactly what the lines say.
  if jsonb_typeof(v_cartons) = 'array' and jsonb_array_length(v_cartons) > 0 then
    for x in select value from jsonb_array_elements(v_cartons) loop
      v_sscc := erp.sscc_of(x ->> 'sscc');
      if v_sscc is null or not erp.sscc_is_valid(v_sscc)
         or exists (select 1 from erp.shipping_notice_carton c where c.tenant_id = v_tenant and c.sscc = v_sscc and c.received_at is null)
         or jsonb_typeof(coalesce(x -> 'contents', 'null'::jsonb)) <> 'array' then
        raise exception 'CLOVEERP_CARTON_INVALID: % is not a carton this notice can hold', coalesce(x ->> 'sscc', 'nothing')
          using errcode = '22023',
                hint = 'Give each carton the SSCC printed on its label and list what is in it; the cartons together hold what the lines say.';
      end if;
      for y in select value from jsonb_array_elements(x -> 'contents') loop
        if not exists (select 1 from erp.shipping_notice_line nl
                        where nl.tenant_id = v_tenant and nl.notice_id = v_id and nl.order_line_id::text = (y ->> 'order_line_id'))
           or coalesce(nullif(y ->> 'quantity', '')::numeric, 0) <= 0 then
          raise exception 'CLOVEERP_CARTON_INVALID: carton % holds a line the notice does not', v_sscc
            using errcode = '22023',
                  hint = 'Give each carton the SSCC printed on its label and list what is in it; the cartons together hold what the lines say.';
        end if;
      end loop;
      insert into erp.shipping_notice_carton (tenant_id, notice_id, sscc, contents)
      values (v_tenant, v_id, v_sscc, x -> 'contents');
    end loop;
    for l in select x2.* from erp.document_line x2
              join erp.shipping_notice_line nl on nl.tenant_id = x2.tenant_id and nl.order_line_id = x2.id
             where nl.tenant_id = v_tenant and nl.notice_id = v_id loop
      select coalesce(sum((y2 ->> 'quantity')::numeric), 0) into v_sum
        from erp.shipping_notice_carton c, jsonb_array_elements(c.contents) y2
       where c.tenant_id = v_tenant and c.notice_id = v_id and y2 ->> 'order_line_id' = l.id::text;
      if v_sum <> (select nl.quantity from erp.shipping_notice_line nl
                    where nl.tenant_id = v_tenant and nl.notice_id = v_id and nl.order_line_id = l.id) then
        raise exception 'CLOVEERP_CARTON_INVALID: the cartons hold % of line %, the notice says otherwise', v_sum, l.line_no
          using errcode = '22023',
                hint = 'Give each carton the SSCC printed on its label and list what is in it; the cartons together hold what the lines say.';
      end if;
    end loop;
  end if;

  perform erp.append_event('purchase_order.shipment_notified', 'document', p_order,
    jsonb_build_object('reference', d.document_number, 'notice', v_number, 'via', p_via,
                       'lines', jsonb_array_length(v_lines), 'cartons', jsonb_array_length(coalesce(v_cartons, '[]'::jsonb))),
    d.entity_id, d.site_id);

  -- The buyer hears of a notice the supplier sent.
  if p_via = 'supplier' and d.created_by is not null then
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at)
    values (v_tenant, 'low'::erp.notification_severity, d.created_by, 'in_app',
            format('Order %s is on its way', d.document_number),
            format('%s arrives %s%s.', v_number, v_arrive,
                   coalesce(' with ' || nullif(btrim(coalesce(p_notice ->> 'carrier', '')), ''), '')),
            'delivered', now(), now());
  end if;

  -- The daily look for notices past their arrival, installed with the first.
  if not exists (select 1 from erp.job j where j.tenant_id = v_tenant and j.handler_code = 'procurement.notice_overdue') then
    perform erp.upsert_job('notice_overdue', 'Notified shipments overdue', 'procurement.notice_overdue',
                           'daily', null, time '07:05', null, null, 'UTC', '{}'::jsonb, 120, null, true);
  end if;

  return erp.shipping_notice(v_id);
end;
$$;

revoke all on function erp.record_shipping_notice(uuid, jsonb, text, uuid) from public, anon;

comment on function erp.record_shipping_notice(uuid, jsonb, text, uuid) is
  'Records a shipment notified against a sent order: dates, carrier, lines and optional cartons '
  '(20261005000000). Called by erp.supplier_notify_shipment and erp.record_buyer_shipping_notice, which authorise.';

create or replace function erp.shipping_notice(p_notice uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A notice as a page reads it (20261005000000).
  select jsonb_build_object(
           'notice_id', n.id, 'notice', n.notice_number, 'order_id', n.order_id, 'order', d.document_number,
           'supplier', p.name, 'status', n.status, 'ship_date', n.ship_date, 'expected_arrival', n.expected_arrival,
           'late', n.status in ('notified', 'part_received') and n.expected_arrival < current_date,
           'carrier', n.carrier, 'tracking_reference', n.tracking_reference,
           'supplier_reference', n.supplier_reference, 'note', n.note, 'sent_via', n.sent_via,
           'receipt', r.document_number, 'receipt_id', n.receipt_id, 'received_at', n.received_at,
           'differences', n.differences,
           'lines', coalesce((select jsonb_agg(jsonb_build_object(
                       'order_line_id', nl.order_line_id, 'line_no', l.line_no,
                       'description', coalesce(l.description, i.name), 'quantity', nl.quantity,
                       'received_quantity', nl.received_quantity) order by l.line_no)
                        from erp.shipping_notice_line nl
                        join erp.document_line l on l.tenant_id = nl.tenant_id and l.id = nl.order_line_id
                        left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
                       where nl.tenant_id = n.tenant_id and nl.notice_id = n.id), '[]'::jsonb),
           'cartons', coalesce((select jsonb_agg(jsonb_build_object('sscc', c.sscc, 'contents', c.contents,
                                                                     'received_at', c.received_at) order by c.sscc)
                          from erp.shipping_notice_carton c
                         where c.tenant_id = n.tenant_id and c.notice_id = n.id), '[]'::jsonb))
    from erp.shipping_notice n
    join erp.document d on d.tenant_id = n.tenant_id and d.id = n.order_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
    left join erp.document r on r.tenant_id = n.tenant_id and r.id = n.receipt_id
   where n.tenant_id = erp.current_tenant_id() and n.id = p_notice
$$;

revoke all on function erp.shipping_notice(uuid) from public, anon;

create or replace function erp.supplier_notify_shipment(p_token text, p_notice jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  lk erp.supplier_response_link%rowtype;
begin
  -- A supplier's notice through its link (20261005000000): the link is the
  -- authority, as for its answer, and the work is done in the link's
  -- organisation as nobody.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not notify for a supplier', current_user
      using errcode = '42501', hint = 'The supplier''s page notifies through the server, never from the browser.';
  end if;
  select (erp.supplier_link(p_token)).* into lk;
  if lk.id is null then
    raise exception 'CLOVEERP_SUPPLIER_LINK_UNKNOWN: that link answers no order'
      using errcode = '42501', hint = 'Use the link in the most recent email of the order, or reply to the buyer.';
  end if;
  perform erp.set_job_tenant(lk.tenant_id);
  perform set_config('erp.job_principal_id', '', true);
  return erp.record_shipping_notice(lk.order_id, p_notice, 'supplier', null);
end;
$$;

revoke all on function erp.supplier_notify_shipment(text, jsonb) from public, anon;

create or replace function public.erp_supplier_notify_shipment(p_token text, p_notice jsonb)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select erp.supplier_notify_shipment(p_token, p_notice) $$;

revoke all on function public.erp_supplier_notify_shipment(text, jsonb) from public, anon, authenticated;
grant execute on function public.erp_supplier_notify_shipment(text, jsonb) to service_role;

comment on function public.erp_supplier_notify_shipment(text, jsonb) is
  'A supplier''s shipping notice through the link in its order''s email (20261005000000). Executed by '
  'service_role alone, from src/lib/supplier-response.functions.ts.';

create or replace function erp.record_buyer_shipping_notice(p_order uuid, p_notice jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d erp.document%rowtype;
begin
  -- A notice the supplier sent by email or gave by phone, recorded by the
  -- buyer (20261005000000).
  select x.* into d from erp.document x where x.tenant_id = erp.require_tenant_id() and x.id = p_order;
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', p_order);
  return erp.record_shipping_notice(p_order, p_notice, 'buyer', erp.current_principal_id());
end;
$$;

revoke all on function erp.record_buyer_shipping_notice(uuid, jsonb) from public, anon;

create or replace function public.erp_record_shipping_notice(p_order uuid, p_notice jsonb)
returns jsonb
language sql
set search_path = ''
as $$ select erp.record_buyer_shipping_notice(p_order, p_notice) $$;

revoke all on function public.erp_record_shipping_notice(uuid, jsonb) from public, anon;
grant execute on function public.erp_record_shipping_notice(uuid, jsonb) to authenticated, service_role;

comment on function public.erp_record_shipping_notice(uuid, jsonb) is
  'Records a supplier''s shipping notice on their behalf (20261005000000). Authorises procurement.order.';

create or replace function erp.cancel_shipping_notice(p_notice uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  n        erp.shipping_notice%rowtype;
  d        erp.document%rowtype;
begin
  -- A notice that will not come as said, withdrawn (20261005000000). Its
  -- quantities are open again for another.
  select x.* into n from erp.shipping_notice x where x.tenant_id = v_tenant and x.id = p_notice for update;
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = n.order_id;
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', n.order_id);
  if n.id is null or n.status <> 'notified' then
    raise exception 'CLOVEERP_NOTICE_NOT_OPEN: % is not open', coalesce(n.notice_number, 'the notice')
      using errcode = '23514', hint = 'Receive what else arrived against the order with Receive an order.';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_REASON_REQUIRED: cancelling a notice needs a reason'
      using errcode = '23514', hint = 'Say why the notice is withdrawn, so goods-in knows.';
  end if;
  update erp.shipping_notice set status = 'cancelled', cancelled_reason = btrim(p_reason), updated_at = now()
   where id = n.id;
  return erp.shipping_notice(n.id);
end;
$$;

revoke all on function erp.cancel_shipping_notice(uuid, text) from public, anon;

create or replace function public.erp_cancel_shipping_notice(p_notice uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.cancel_shipping_notice(p_notice, p_reason) $$;

revoke all on function public.erp_cancel_shipping_notice(uuid, text) from public, anon;
grant execute on function public.erp_cancel_shipping_notice(uuid, text) to authenticated, service_role;

comment on function public.erp_cancel_shipping_notice(uuid, text) is
  'Withdraws a shipping notice nothing was received against (20261005000000). Authorises procurement.order.';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Receiving
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.receive_notice_lines(p_notice uuid, p_lines jsonb, p_carton uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  n        erp.shipping_notice%rowtype;
  d        erp.document%rowtype;
  v_grn    uuid;
  x        jsonb;
  v_qty    numeric;
  v_diff   jsonb := '[]'::jsonb;
  v_number text;
  r        record;
begin
  -- What arrived of a notice, received against its order in one receipt and
  -- posted (20261005000000). p_lines is what arrived, by order line; a line
  -- the notice held and p_lines does not is taken as notified. Where it
  -- differs, short, over or not notified, the difference is kept and the
  -- buyer told. For a carton (p_carton), p_lines is its contents and only
  -- they are received. erp.receive_against authorises each line.
  select x2.* into n from erp.shipping_notice x2 where x2.tenant_id = v_tenant and x2.id = p_notice for update;
  select x2.* into d from erp.document x2 where x2.tenant_id = v_tenant and x2.id = n.order_id;
  if n.id is null or n.status not in ('notified', 'part_received') then
    raise exception 'CLOVEERP_NOTICE_NOT_OPEN: % is not open', coalesce(n.notice_number, 'the notice')
      using errcode = '23514', hint = 'Receive what else arrived against the order with Receive an order.';
  end if;

  v_grn := erp.open_document('goods_receipt', d.party_id, d.entity_id, d.site_id,
                             coalesce(n.supplier_reference, n.notice_number));
  update erp.document set attributes = coalesce(attributes, '{}'::jsonb) || jsonb_build_object('shipping_notice_id', n.id),
         notes = coalesce(notes, 'Received as notified: ' || n.notice_number), updated_at = now()
   where id = v_grn;

  for r in
    select coalesce(nl.order_line_id, (y ->> 'order_line_id')::uuid) as order_line_id,
           nl.quantity - coalesce(nl.received_quantity, 0) as notified,
           y ->> 'quantity' as typed
      from (select * from erp.shipping_notice_line where tenant_id = v_tenant and notice_id = n.id) nl
      full join (select value as y from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))) given
        on (given.y ->> 'order_line_id') = nl.order_line_id::text
     -- A carton receives what it holds and nothing else of its notice.
     where p_carton is null or given.y is not null
  loop
    v_qty := coalesce(nullif(r.typed, '')::numeric, r.notified, 0);
    if v_qty > 0 then
      perform erp.receive_against(v_grn, r.order_line_id, v_qty, null);
    end if;
    if r.notified is null or v_qty <> r.notified then
      v_diff := v_diff || jsonb_build_object(
        'order_line_id', r.order_line_id,
        'line_no', (select l.line_no from erp.document_line l where l.tenant_id = v_tenant and l.id = r.order_line_id),
        'notified', coalesce(r.notified, 0), 'received', v_qty,
        'kind', case when r.notified is null then 'not_notified' when v_qty < r.notified then 'short' else 'over' end);
    end if;
    update erp.shipping_notice_line
       set received_quantity = coalesce(received_quantity, 0) + v_qty, updated_at = now()
     where tenant_id = v_tenant and notice_id = n.id and order_line_id = r.order_line_id;
  end loop;

  if not exists (select 1 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = v_grn) then
    raise exception 'CLOVEERP_NOTICE_LINE_INVALID: nothing of % arrived to receive', n.notice_number
      using errcode = '22023', hint = 'Give each line a quantity no more than what is still open on it, counting earlier notices.';
  end if;
  perform erp.transition_document(v_grn, 'post', 'received as notified: ' || n.notice_number);
  select x2.document_number into v_number from erp.document x2 where x2.id = v_grn;

  if p_carton is not null then
    update erp.shipping_notice_carton set receipt_id = v_grn, received_at = now(), updated_at = now() where id = p_carton;
  else
    update erp.shipping_notice_carton set receipt_id = coalesce(receipt_id, v_grn), received_at = coalesce(received_at, now()),
           updated_at = now()
     where tenant_id = v_tenant and notice_id = n.id;
  end if;
  update erp.shipping_notice
     set status = case when p_carton is not null
                        and exists (select 1 from erp.shipping_notice_carton c
                                     where c.tenant_id = v_tenant and c.notice_id = n.id and c.received_at is null)
                       then 'part_received' else 'received' end,
         receipt_id = v_grn, received_at = now(), differences = differences || v_diff, updated_at = now()
   where id = n.id;

  perform erp.append_event('purchase_order.notice_received', 'document', n.order_id,
    jsonb_build_object('reference', d.document_number, 'notice', n.notice_number, 'receipt', v_number,
                       'differences', jsonb_array_length(v_diff),
                       'carton', (select c.sscc from erp.shipping_notice_carton c where c.id = p_carton)),
    d.entity_id, d.site_id);

  if jsonb_array_length(v_diff) > 0 and d.created_by is not null then
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at)
    values (v_tenant, 'medium'::erp.notification_severity, d.created_by, 'in_app',
            format('%s arrived different from its notice', n.notice_number),
            format('%s line(s) of order %s arrived short, over or not notified; %s holds what came. The order stays open for the rest.',
                   jsonb_array_length(v_diff), d.document_number, v_number),
            'delivered', now(), now());
  end if;
  return erp.shipping_notice(n.id) || jsonb_build_object('receipt', v_number, 'receipt_id', v_grn);
end;
$$;

revoke all on function erp.receive_notice_lines(uuid, jsonb, uuid) from public, anon;

create or replace function erp.receive_as_notified(p_notice uuid, p_lines jsonb default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  n erp.shipping_notice%rowtype;
  d erp.document%rowtype;
begin
  -- Goods-in's one press (20261005000000).
  select x.* into n from erp.shipping_notice x where x.tenant_id = erp.require_tenant_id() and x.id = p_notice;
  select x.* into d from erp.document x where x.tenant_id = n.tenant_id and x.id = n.order_id;
  perform erp.authorise('procurement.receive', d.entity_id, d.site_id, null, 'document', n.order_id);
  return erp.receive_notice_lines(p_notice, p_lines, null);
end;
$$;

revoke all on function erp.receive_as_notified(uuid, jsonb) from public, anon;

create or replace function public.erp_receive_as_notified(p_notice uuid, p_lines jsonb default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.receive_as_notified(p_notice, p_lines) $$;

revoke all on function public.erp_receive_as_notified(uuid, jsonb) from public, anon;
grant execute on function public.erp_receive_as_notified(uuid, jsonb) to authenticated, service_role;

comment on function public.erp_receive_as_notified(uuid, jsonb) is
  'Receives a notified shipment as notified, or as it arrived, in one posted receipt; keeps the differences '
  'and tells the buyer (20261005000000). Authorises procurement.receive.';

create or replace function erp.receive_notified_carton(p_sscc text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  c        erp.shipping_notice_carton%rowtype;
  d        erp.document%rowtype;
  v_sscc   text := erp.sscc_of(p_sscc);
begin
  -- One notified carton by the SSCC on its label (20261005000000): what the
  -- notice says it holds, received in a receipt of its own. From the desk, or
  -- the scanner (device task carton_receipt).
  select x.* into c from erp.shipping_notice_carton x
   where x.tenant_id = v_tenant and x.sscc = v_sscc and x.received_at is null for update;
  if c.id is null then
    raise exception 'CLOVEERP_CARTON_UNKNOWN: % is no carton an open notice lists', coalesce(v_sscc, nullif(btrim(coalesce(p_sscc, '')), ''), 'that label')
      using errcode = '23503', hint = 'Check the label is the carton''s SSCC, or receive the goods against the order.';
  end if;
  select x.* into d from erp.document x
    join erp.shipping_notice n on n.tenant_id = x.tenant_id and n.order_id = x.id
   where n.tenant_id = v_tenant and n.id = c.notice_id;
  -- The receipt it makes is opened, filled and posted by somebody who may
  -- receive: a scan-only operator confirms receipt lines, not whole receipts.
  perform erp.authorise('procurement.receive', d.entity_id, d.site_id, null, 'document', d.id);
  return erp.receive_notice_lines(c.notice_id, c.contents, c.id);
end;
$$;

revoke all on function erp.receive_notified_carton(text) from public, anon;

create or replace function public.erp_receive_notified_carton(p_sscc text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.receive_notified_carton(p_sscc) $$;

revoke all on function public.erp_receive_notified_carton(text) from public, anon;
grant execute on function public.erp_receive_notified_carton(text) to authenticated, service_role;

comment on function public.erp_receive_notified_carton(text) is
  'Receives one notified carton by its SSCC (20261005000000). Authorises procurement.receive.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale, ungated_because) values
  ('erp_supplier_notify_shipment', 'erp.supplier_notify_shipment',
   'Records a supplier''s shipping notice through the link in its order''s email. The link''s token is the '
   'authority; service_role only, from the server function behind /respond.', 'bearer_token')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale,
  ungated_because = excluded.ungated_because;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_record_shipping_notice', 'erp.record_buyer_shipping_notice',
   'Records a supplier''s shipping notice on their behalf: dates, carrier, lines and cartons; authorises procurement.order.'),
  ('erp_cancel_shipping_notice', 'erp.cancel_shipping_notice',
   'Withdraws an open shipping notice; authorises procurement.order.'),
  ('erp_receive_as_notified', 'erp.receive_as_notified',
   'Receives a notified shipment in one posted receipt and keeps its differences; authorises procurement.receive.'),
  ('erp_receive_notified_carton', 'erp.receive_notified_carton',
   'Receives one notified carton by its SSCC in a posted receipt; authorises procurement.receive.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_supplier_notify_shipment',
   'UNGATED BY DESIGN: as erp_supplier_respond, the supplier''s link token is the authority. Executable by '
   'service_role alone; erp.supplier_notify_shipment refuses an untrusted session and a link that does not '
   'hold, then works in the link''s organisation as nobody.')
on conflict do nothing;

select erp_meta.add_help_actions('/procurement',
  array['erp_record_shipping_notice', 'erp_cancel_shipping_notice', 'erp_receive_as_notified', 'erp_receive_notified_carton']);

-- The scanner: a carton by its label, for somebody who may receive.

insert into erp_ref.device_task (code, name, task_group, starts_when, completes_when, abandons_when, works_offline, seq)
values ('carton_receipt', 'Receive a notified carton', 'inbound',
        'A carton whose supplier notified it arrives at goods in.',
        'Its SSCC is scanned and what the notice says it holds is received.',
        'The operator leaves it; the carton waits, still notified.', false, 21)
on conflict (code) do nothing;

insert into erp_ref.device_task_handler (device_task_code, module_code, sql_function, arguments, writes_nothing, note)
values ('carton_receipt', 'procurement', 'receive_notified_carton',
        '[{"arg": "p_sscc", "key": "sscc", "type": "text", "required": true}]'::jsonb, false,
        'A notified carton by the SSCC on its label: what its notice says it holds, received (20261005000000).')
on conflict (device_task_code) do update set sql_function = excluded.sql_function, arguments = excluded.arguments,
  note = excluded.note;


-- ═════════════════════════════════════════════════════════════════════════════
-- E. Reads
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_shipping_notices(p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What is on its way to goods in (20261005000000): the open notices, the
  -- late first, then by arrival.
  select coalesce(jsonb_agg(erp.shipping_notice(n.id)
                            order by (n.expected_arrival < current_date) desc, n.expected_arrival, n.notice_number), '[]'::jsonb)
    from erp.shipping_notice n
    join erp.document d on d.tenant_id = n.tenant_id and d.id = n.order_id
   where n.tenant_id = erp.current_tenant_id()
     and n.status in ('notified', 'part_received')
     and (p_site_id is null or d.site_id = p_site_id)
$$;

revoke all on function public.erp_shipping_notices(uuid) from public, anon;
grant execute on function public.erp_shipping_notices(uuid) to authenticated, service_role;

comment on function public.erp_shipping_notices(uuid) is 'Open shipping notices for goods in, late first (20261005000000).';

create or replace function public.erp_order_shipping_notices(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- An order's notices, newest first, and what of each line is still open
  -- for another (20261005000000).
  select jsonb_build_object(
           'order_id', p_order,
           'notices', coalesce((select jsonb_agg(erp.shipping_notice(n.id) order by n.created_at desc)
                                  from erp.shipping_notice n
                                 where n.tenant_id = erp.current_tenant_id() and n.order_id = p_order), '[]'::jsonb),
           'open', coalesce((select jsonb_agg(jsonb_build_object('order_line_id', l.id, 'line_no', l.line_no,
                                    'open', erp.order_line_open_for_notice(l.id)) order by l.line_no)
                               from erp.document_line l
                              where l.tenant_id = erp.current_tenant_id() and l.document_id = p_order
                                and not l.is_cancelled), '[]'::jsonb))
$$;

revoke all on function public.erp_order_shipping_notices(uuid) from public, anon;
grant execute on function public.erp_order_shipping_notices(uuid) to authenticated, service_role;

comment on function public.erp_order_shipping_notices(uuid) is 'A purchase order''s shipping notices (20261005000000).';

-- The supplier's page reads the notices and what is still open. Restated
-- whole: the body 20261004990000 wrote (md5 2d8a13c8…), with both.

do $peek$
begin
  if strpos((select p.prosrc from pg_proc p where p.oid = 'public.erp_supplier_response_peek(text)'::regprocedure),
            '20261005000000') = 0
     and md5((select p.prosrc from pg_proc p where p.oid = 'public.erp_supplier_response_peek(text)'::regprocedure))
         <> '2d8a13c84df64d1cee002b5a2a35970b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_supplier_response_peek is not the body 20261005000000 restates';
  end if;
end
$peek$;

create or replace function public.erp_supplier_response_peek(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  -- The order a supplier's link names, as the supplier may see it
  -- (20261004990000): what the PDF already showed them, the lines as they
  -- stand, and where the answer is; and its shipping notices and what is
  -- still open to notify (20261005000000). Null for a token that is not one,
  -- so a wrong guess learns nothing. Runs as its owner because the caller is
  -- no organisation; every read is held to the link's own.
  with lk as (select * from erp.supplier_link(p_token))
  select case when lk.id is null then null else jsonb_build_object(
           'order', d.document_number,
           'organisation', coalesce(e.legal_name, e.name, t.name),
           'supplier', p.name,
           'currency', d.currency,
           'order_date', d.document_date,
           'required_date', d.required_date,
           'status', c.status,
           'supplier_reference', c.supplier_reference,
           'note', c.note,
           'decision_note', c.decision_note,
           'proposal', c.proposal,
           'can_respond', coalesce((select st.code in ('sent', 'partially_received')
                                      from erp.object_state os
                                      join erp.state st on st.id = os.current_state_id
                                     where os.tenant_id = lk.tenant_id and os.object_type = 'document'
                                       and os.object_id = d.id), false)
                          and c.status in ('awaiting', 'changes_proposed'),
           'can_notify', coalesce((select st.code in ('sent', 'partially_received')
                                     from erp.object_state os
                                     join erp.state st on st.id = os.current_state_id
                                    where os.tenant_id = lk.tenant_id and os.object_type = 'document'
                                      and os.object_id = d.id), false)
                         and c.status = 'confirmed',
           'expires_at', lk.expires_at,
           'notices', coalesce((select jsonb_agg(jsonb_build_object(
                         'notice', n.notice_number, 'status', n.status, 'ship_date', n.ship_date,
                         'expected_arrival', n.expected_arrival, 'carrier', n.carrier,
                         'tracking_reference', n.tracking_reference) order by n.created_at)
                          from erp.shipping_notice n
                         where n.tenant_id = lk.tenant_id and n.order_id = d.id and n.status <> 'cancelled'), '[]'::jsonb),
           'lines', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'line_id', l.id, 'line_no', l.line_no,
                      'description', coalesce(l.description, i.name),
                      'item_code', i.code, 'supplier_item_code', l.supplier_item_code,
                      'quantity', l.quantity, 'uom', u.code,
                      'unit_price_minor', l.unit_price_minor,
                      'required_date', coalesce(l.required_date, d.required_date),
                      'confirmed_quantity', l.confirmed_quantity, 'confirmed_date', l.confirmed_date,
                      'open_to_notify', greatest(0, l.quantity - coalesce(l.quantity_fulfilled, 0)
                        - coalesce((select sum(nl.quantity - coalesce(nl.received_quantity, 0))
                                      from erp.shipping_notice_line nl
                                      join erp.shipping_notice n on n.tenant_id = nl.tenant_id and n.id = nl.notice_id
                                     where nl.tenant_id = l.tenant_id and nl.order_line_id = l.id
                                       and n.status in ('notified', 'part_received')), 0)))
                      order by l.line_no)
               from erp.document_line l
               left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
               left join erp.uom u on u.tenant_id = l.tenant_id and u.id = l.uom_id
              where l.tenant_id = lk.tenant_id and l.document_id = d.id and not l.is_cancelled), '[]'::jsonb)) end
    from (select 1) one
    left join lk on true
    left join erp.document d on d.tenant_id = lk.tenant_id and d.id = lk.order_id
    left join erp.entity e on e.tenant_id = d.tenant_id and e.id = d.entity_id
    left join erp.tenant t on t.id = lk.tenant_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
    left join erp.purchase_order_confirmation c on c.tenant_id = d.tenant_id and c.order_id = d.id
$$;

revoke all on function public.erp_supplier_response_peek(text) from public, anon, authenticated;
grant execute on function public.erp_supplier_response_peek(text) to service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. Planning, and the daily look
-- ═════════════════════════════════════════════════════════════════════════════

do $supply$
declare
  v_sig  constant text := 'erp.scheduled_supply(uuid,uuid,date,date,boolean)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(dl.confirmed_date, dl.required_date, d.required_date, d.document_date),$o$;
  v_new  constant text := $n$  -- When an open notice says it arrives, before the confirmed date (20261005000000).
  select coalesce((select min(n.expected_arrival)
                     from erp.shipping_notice_line nl
                     join erp.shipping_notice n on n.tenant_id = nl.tenant_id and n.id = nl.notice_id
                    where nl.tenant_id = dl.tenant_id and nl.order_line_id = dl.id
                      and n.status in ('notified', 'part_received')),
                  dl.confirmed_date, dl.required_date, d.required_date, d.document_date),$n$;
begin
  if strpos(v_src, '20261005000000') > 0 then
    raise notice '% already reads a notice''s arrival; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '08e4d2bce33357c4d6835b111288b3d3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005000000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$supply$;

create or replace function erp.notify_overdue_notices()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_n      integer := 0;
begin
  -- Notices past their arrival with nothing received (20261005000000): the
  -- order's buyer is told once.
  for r in
    select n.id, n.notice_number, n.expected_arrival, d.document_number, d.created_by
      from erp.shipping_notice n
      join erp.document d on d.tenant_id = n.tenant_id and d.id = n.order_id
     where n.tenant_id = v_tenant and n.status = 'notified' and n.expected_arrival < current_date
       and n.late_notified_at is null and d.created_by is not null
       for update of n
  loop
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at)
    values (v_tenant, 'medium'::erp.notification_severity, r.created_by, 'in_app',
            format('%s has not arrived', r.notice_number),
            format('Order %s''s shipment was due on %s. Chase the supplier or the carrier, or cancel the notice.', r.document_number, r.expected_arrival),
            'delivered', now(), now());
    update erp.shipping_notice set late_notified_at = now(), updated_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function erp.notify_overdue_notices() from public, anon;

comment on function erp.notify_overdue_notices() is
  'The daily look for shipping notices past their arrival with nothing received: tells the order''s buyer '
  'once (20261005000000). Run by the job procurement.notice_overdue.';

insert into erp_ref.job_handler (code, name_key, description, module_code, parameter_schema,
                                 default_timeout_seconds, forbids_overlap, is_current, sql_function,
                                 default_max_silence_seconds)
values ('procurement.notice_overdue', 'job_handler.notice_overdue.name',
        'Tells an order''s buyer when a notified shipment is past its arrival with nothing received (20261005000000).',
        'procurement', '{"type":"object"}'::jsonb, 120, true, true, 'notify_overdue_notices', 172800)
on conflict (code) do update set name_key = excluded.name_key, description = excluded.description,
  sql_function = excluded.sql_function, is_current = true;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The suite
-- ═════════════════════════════════════════════════════════════════════════════

-- device_drain_suite pins the device tasks by count: a carton received by its
-- label is one more that applies through a module function.
do $drain_suite$
declare
  v_sig  constant text := 'erp_test.device_drain_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$'%22 task(s) — 18 apply%1 read only, 3 not yet handled%'$o$;
  v_new  constant text := $n$'%23 task(s) — 19 apply%1 read only, 3 not yet handled%'$n$;
begin
  if strpos(v_src, v_new) > 0 then
    raise notice '% already counts the carton; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '404212a5876ed083f26bb719bc839bd1' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005000000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$drain_suite$;

create or replace function erp_test.shipping_notice_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid;
  v_po uuid; v_l1 uuid; v_l2 uuid; v_tok text; v_n1 jsonb; v_n2 jsonb; v_r jsonb; v_supply date; v_peek jsonb;
  v_val0 numeric; v_k integer;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text;
  c1 constant text := '350123451234567894';
  c2 constant text := '350123451234567900';
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, a supplier, and an order confirmed through its link';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzasn-' || v_tag, 'Shipping Notice Suite',
      'admin@zzasn-' || v_tag || '.test', 'Notice Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzasn-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZNCOAT', 'Notified Coat', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZNSCARF', 'Notified Scarf', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZNBRAND');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZNO1', false);
    perform erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
    select l.id into v_l1 from erp.document_line l where l.document_id = v_po and l.item_id = v_item;
    select l.id into v_l2 from erp.document_line l where l.document_id = v_po and l.item_id = v_item2;
    res := public.erp_send_purchase_order(v_po, 'orders@znbrand-' || v_tag || '.test', null, null, null);
    select t.response_token into v_tok from erp.claim_document_email_batch(10, 'suite') t
     where t.document_kind = 'purchase_order' limit 1;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, the refusals, the events and the scanner task';
    v_cases := v_cases + 1;
    case_name := 'the four buyer and goods-in doors are on the allow-list under their gates and the supplier''s as a bearer token, the six refusals are registered, both events are current in English and German, and the scanner receives a carton by its label';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance a
                where (a.function_name, a.gate) in (('erp_record_shipping_notice', 'erp.record_buyer_shipping_notice'),
                                                    ('erp_cancel_shipping_notice', 'erp.cancel_shipping_notice'),
                                                    ('erp_receive_as_notified', 'erp.receive_as_notified'),
                                                    ('erp_receive_notified_carton', 'erp.receive_notified_carton'))) = 4
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_supplier_notify_shipment' and a.ungated_because = 'bearer_token')
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_ORDER_NOT_OPEN_FOR_NOTICE', 'CLOVEERP_NOTICE_LINE_INVALID', 'CLOVEERP_NOTICE_DATES_INVALID',
                                 'CLOVEERP_CARTON_INVALID', 'CLOVEERP_NOTICE_NOT_OPEN', 'CLOVEERP_CARTON_UNKNOWN')
                  and coalesce(f.next_action, '') <> '') = 6
          and (select count(*) from erp_ref.resource x
                where x.key in ('event.purchase_order.shipment_notified', 'event.purchase_order.notice_received')
                  and x.locale in ('en', 'de')) = 4
          and exists (select 1 from erp_ref.device_task_handler h
                       where h.device_task_code = 'carton_receipt' and h.sql_function = 'receive_notified_carton')
          and erp.sscc_is_valid(c1) and erp.sscc_is_valid(c2) and not erp.sscc_is_valid('350123451234567895');
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Not before the order is confirmed ────────────────────────────────
    v_step := 'a notice through the link before the supplier confirmed';
    perform set_config('request.jwt.claims', '', true);
    begin
      perform erp.supplier_notify_shipment(v_tok, jsonb_build_object('expected_arrival', (current_date + 5)::text,
        'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 4))));
      v_err := 'notified';
    exception when others then v_err := sqlerrm; end;
    perform erp.supplier_respond(v_tok, '{"decision": "confirm"}');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'the supplier''s link notifies nothing until the order is confirmed';
    passed := v_state is null and v_err like 'CLOVEERP_ORDER_NOT_OPEN_FOR_NOTICE:%';
    detail := coalesce(v_state, left(v_err, 300));
    return next;

    -- ── 3. The supplier notifies, with cartons ──────────────────────────────
    v_step := 'six coats and the ten scarves in two cartons, arriving in five days';
    perform set_config('request.jwt.claims', '', true);
    v_n1 := erp.supplier_notify_shipment(v_tok, jsonb_build_object(
      'ship_date', current_date::text, 'expected_arrival', (current_date + 5)::text,
      'carrier', 'DHL', 'tracking_reference', 'JD0001', 'supplier_reference', 'DN-77',
      'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 6),
                                 jsonb_build_object('order_line_id', v_l2, 'quantity', 10)),
      'cartons', jsonb_build_array(
        jsonb_build_object('sscc', '(00)' || c1, 'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 6))),
        jsonb_build_object('sscc', c2, 'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l2, 'quantity', 10))))));
    v_peek := public.erp_supplier_response_peek(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select s.due_on into v_supply from erp.scheduled_supply(v_item, v_site, current_date, current_date + 60, false) s
     where s.source = 'purchase_order' limit 1;
    v_cases := v_cases + 1;
    case_name := 'a confirmed order''s supplier notifies a shipment of two cartons through its link: the notice holds its lines and cartons, the buyer is told, the page shows it with what is still open, and planning expects the coats on the notice''s day';
    passed := v_state is null
          and v_n1 ->> 'status' = 'notified'
          and jsonb_array_length(v_n1 -> 'lines') = 2
          and jsonb_array_length(v_n1 -> 'cartons') = 2
          and v_n1 ->> 'tracking_reference' = 'JD0001'
          and exists (select 1 from erp.notification n where n.tenant_id = rb.tenant_id and n.subject like 'Order % is on its way')
          and jsonb_array_length(v_peek -> 'notices') = 1
          and (select (x ->> 'open_to_notify')::numeric from jsonb_array_elements(v_peek -> 'lines') x
                where x ->> 'line_id' = v_l1::text) = 4
          and v_supply = current_date + 5;
    detail := coalesce(v_state, left(format('%s | supply %s', v_n1, v_supply), 600));
    return next;

    -- ── 4. What may not be notified ─────────────────────────────────────────
    v_step := 'too much, a bad date, a bad SSCC, a repeated SSCC, cartons that do not add up';
    begin perform public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 3)::text,
            'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 5)))); v_err := 'notified';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_record_shipping_notice(v_po, jsonb_build_object('ship_date', current_date::text,
            'expected_arrival', (current_date - 1)::text,
            'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1)))); v_err2 := 'notified';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 3)::text,
            'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1)),
            'cartons', jsonb_build_array(jsonb_build_object('sscc', '350123451234567895',
              'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1)))))); v_err3 := 'notified';
    exception when others then v_err3 := sqlerrm; end;
    begin perform public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 3)::text,
            'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1)),
            'cartons', jsonb_build_array(jsonb_build_object('sscc', c1,
              'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1)))))); v_err4 := 'notified';
    exception when others then v_err4 := sqlerrm; end;
    begin perform public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 3)::text,
            'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 2)),
            'cartons', jsonb_build_array(jsonb_build_object('sscc', '000000000000000000',
              'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1)))))); v_err5 := 'notified';
    exception when others then v_err5 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'more than is still open, an arrival before the ship date, an SSCC with a wrong check digit, an SSCC already coming, and cartons that do not add up to their lines are each refused by name';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOTICE_LINE_INVALID:%'
          and v_err2 like 'CLOVEERP_NOTICE_DATES_INVALID:%'
          and v_err3 like 'CLOVEERP_CARTON_INVALID:%'
          and v_err4 like 'CLOVEERP_CARTON_INVALID:%'
          and v_err5 like 'CLOVEERP_CARTON_INVALID:%'
          and (select count(*) from erp.shipping_notice n where n.order_id = v_po) = 1;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 800));
    return next;

    -- ── 5. A carton, scanned ────────────────────────────────────────────────
    v_step := 'the coats'' carton received by its label';
    v_r := public.erp_receive_notified_carton('(00)' || c1);
    v_cases := v_cases + 1;
    case_name := 'scanning the first carton''s label receives the six coats in a posted receipt of its own; the notice is part received and the other carton still waits';
    passed := v_state is null
          and v_r ->> 'status' = 'part_received'
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_l1) = 6
          and erp.object_current_state('document', (v_r ->> 'receipt_id')::uuid) = 'posted'
          and exists (select 1 from erp.shipping_notice_carton c where c.sscc = c2 and c.received_at is null)
          and jsonb_array_length(v_r -> 'differences') = 0;
    detail := coalesce(v_state, left(coalesce(v_r::text, 'nothing'), 500));
    return next;

    -- ── 6. The rest, as notified ────────────────────────────────────────────
    v_step := 'the scarves'' carton received with the rest of the notice';
    v_r := public.erp_receive_notified_carton(c2);
    v_cases := v_cases + 1;
    case_name := 'the second carton completes the notice: received, with nothing different, and goods-in no longer lists it';
    passed := v_state is null
          and v_r ->> 'status' = 'received'
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_l2) = 10
          and not exists (select 1 from jsonb_array_elements(public.erp_shipping_notices(null)) x
                           where x ->> 'notice_id' = v_n1 ->> 'notice_id');
    detail := coalesce(v_state, left(coalesce(v_r::text, 'nothing'), 500));
    return next;

    -- ── 7. A notice without cartons, short ──────────────────────────────────
    v_step := 'the last four coats notified by the buyer, three arriving';
    v_n2 := public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 2)::text,
              'carrier', 'Own van', 'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 4))));
    v_r := public.erp_receive_as_notified((v_n2 ->> 'notice_id')::uuid,
              jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 3)));
    v_cases := v_cases + 1;
    case_name := 'a notice the buyer recorded, received as three of the four notified coats: received, the shortfall kept on the notice, the buyer told, and the order still open for the last coat';
    passed := v_state is null
          and v_n2 ->> 'sent_via' = 'buyer'
          and v_r ->> 'status' = 'received'
          and jsonb_array_length(v_r -> 'differences') = 1
          and v_r #>> '{differences,0,kind}' = 'short'
          and exists (select 1 from erp.notification n where n.tenant_id = rb.tenant_id and n.subject like '% arrived different from its notice')
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_l1) = 9
          and erp.object_current_state('document', v_po) = 'partially_received';
    detail := coalesce(v_state, left(coalesce(v_r::text, 'nothing'), 600));
    return next;

    -- ── 8. Settled is settled ───────────────────────────────────────────────
    v_step := 'receiving a received notice and a carton nobody notified';
    begin perform public.erp_receive_as_notified((v_n2 ->> 'notice_id')::uuid, null); v_err := 'received';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_receive_notified_carton(c1); v_err2 := 'received';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_cancel_shipping_notice((v_n2 ->> 'notice_id')::uuid, 'gone'); v_err3 := 'cancelled';
    exception when others then v_err3 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a received notice is not received or cancelled again, and a carton already in is no carton an open notice lists';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOTICE_NOT_OPEN:%'
          and v_err2 like 'CLOVEERP_CARTON_UNKNOWN:%'
          and v_err3 like 'CLOVEERP_NOTICE_NOT_OPEN:%';
    detail := coalesce(v_state, left(format('%s | %s | %s', v_err, v_err2, v_err3), 500));
    return next;

    -- ── 9. Cancelled, the quantity is open again ────────────────────────────
    v_step := 'the last coat notified, cancelled, notified again';
    v_n2 := public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 2)::text,
              'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1))));
    begin perform public.erp_cancel_shipping_notice((v_n2 ->> 'notice_id')::uuid, ''); v_err := 'cancelled';
    exception when others then v_err := sqlerrm; end;
    res := public.erp_cancel_shipping_notice((v_n2 ->> 'notice_id')::uuid, 'The van broke down');
    v_n2 := public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 4)::text,
              'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 1))));
    v_cases := v_cases + 1;
    case_name := 'a notice is cancelled with a reason, not without, and what it held is open to notify again';
    passed := v_state is null
          and v_err like 'CLOVEERP_REASON_REQUIRED:%'
          and res ->> 'status' = 'cancelled'
          and v_n2 ->> 'status' = 'notified';
    detail := coalesce(v_state, left(format('%s | %s', v_err, res), 400));
    return next;

    -- ── 10. Late, the buyer is told once ────────────────────────────────────
    v_step := 'the last notice past its day, looked at twice';
    update erp.shipping_notice set expected_arrival = current_date - 1 where id = (v_n2 ->> 'notice_id')::uuid;
    v_k := erp.notify_overdue_notices();
    v_cases := v_cases + 1;
    case_name := 'a notice past its arrival with nothing received is flagged to the buyer once, and goods-in lists it as late';
    passed := v_state is null
          and v_k = 1 and erp.notify_overdue_notices() = 0
          and exists (select 1 from jsonb_array_elements(public.erp_shipping_notices(null)) x
                       where x ->> 'notice_id' = v_n2 ->> 'notice_id' and (x ->> 'late')::boolean);
    detail := coalesce(v_state, format('first %s', v_k));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzasn-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzasn rolled back with its orders, notices and receipts');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SHIPPING_NOTICE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.shipping_notice_suite() from public, anon;

comment on function erp_test.shipping_notice_suite() is
  'A supplier says it is on its way (20261005000000): notified through the link once confirmed, with lines '
  'and cartons; refused by name when wrong; received by carton label or as notified, differences kept and '
  'the buyer told; cancelled and notified again; the late ones flagged once.';

create or replace function erp_test.assert_shipping_notice_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.shipping_notice_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SHIPPING_NOTICE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A shipment would be notified wrongly, or received against the wrong carton. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_SHIPPING_NOTICE_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('shipping notice: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_shipping_notice_suite() from public, anon;

comment on function erp_test.assert_shipping_notice_suite() is
  'Shipments are notified against confirmed orders and received as notified or by carton, with their '
  'differences kept (20261005000000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). An advance shipping notice (20261005000000).'
  from (values
    ('A scanner types the label straight in.'),
    ('Arrives'),
    ('Cancel the notice'),
    ('For a delivery that differs from its notice. The differences are kept on the notice and the buyer is told; the order stays open for anything short.'),
    ('For a delivery the supplier told you about by email or phone. No more than is still open on each line.'),
    ('Nothing is on its way.'),
    ('Nothing notified yet.'),
    ('Notified'),
    ('Part received'),
    ('Receive a carton'),
    ('Receive as notified'),
    ('Receive what arrived'),
    ('Received'),
    ('Receives everything the notice says is coming, in one posted goods receipt.'),
    ('Record a shipping notice'),
    ('SSCC'),
    ('Scan or type the SSCC on the carton''s label. What its notice says it holds is received in a posted goods receipt.'),
    ('Shipping notices'),
    ('The shipment will not come as notified. What it held is open for another notice.'),
    ('cartons in'),
    ('notified'),
    ('received'),
    ('On its way'),
    ('Deliveries suppliers have told you are coming, the late ones first. Receive one as notified, or a carton by scanning its label.'),
    ('What the supplier said is on its way, from the link in the order''s email or recorded by you, and how it arrived.'),
    ('Short'),
    ('Over'),
    ('Not notified'),
    ('Cancelled'),
    ('Scan the carton')
  ) as v(text)
on conflict (key, locale) do nothing;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
