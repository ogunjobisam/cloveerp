set lock_timeout = '30s';

-- =============================================================================
-- 20261004920000  A purchase order reaches its supplier
-- -----------------------------------------------------------------------------
-- The third procure-to-pay gap the owner named on 1 October 2026, on top of
-- goods going back to the supplier (20261004910000). docs/spec/p2p-target-flow.md
-- §3 Action 4: "Generates the document through the existing document pipeline
-- and writes erp.document_issue. Either emailed direct to the supplier or
-- downloaded and sent manually."
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Sending a purchase order was a state change. The order read Sent and nothing
-- had gone anywhere: no document, no email, no record of who it went to or
-- when. A buyer emailed a screenshot, or a supplier rang to ask where it was.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp_send_purchase_order(p_order, p_to, p_cc, p_message, p_reason): a
--     buyer (procurement.order) sends an approved or sent order to its
--     supplier. An approved order moves to Sent by the same press. Each send
--     reserves an issue of the order (erp.document_issue, kind
--     purchase_order), frozen as it read, and queues one email in
--     erp.document_email. The address defaults to the supplier's purchasing
--     contact, then their default contact; a send after the first names why,
--     and its issue replaces the last.
--   * erp.document_email: the organisation's outgoing documents, one row per
--     send (owner, 1 October 2026: a queue of its own is acceptable). Shaped as
--     erp_meta.commercial_email is: status, attempts, lease, the provider's id,
--     the archived copy and the delivery the provider reports.
--   * The sender (owner): the organisation's verified sending domain where it
--     has one, otherwise the platform's address under the organisation's name,
--     with replies to the buyer who sent it (erp.sender_for('transactional')).
--   * The dispatch worker drains it per organisation
--     (worker/src/core/document-email.ts): renders the purchase order PDF from
--     the frozen payload (src/lib/pdf/purchase-order-pdf.ts), sends it attached,
--     keeps a copy in the document-output bucket, and settles:
--     erp.complete_document_email() files the copy on the issue and marks it
--     sent; erp.fail_document_email() puts it back or fails it, and a failure
--     for good tells the buyer in the product. The kill switch, a
--     demonstration and a suppressed address send nothing.
--   * Resend's delivery events reach a purchase order's send as they reach a
--     notification's (erp.record_email_delivery_event()), and a hard bounce or
--     a complaint stops the organisation writing to that address.
--   * erp_purchase_order_sends(p_order): the order's sends, newest first, the
--     address a send would go to, and whether the reader may send; and
--     erp_purchase_order_document(p_order), the payload the order's page
--     renders a PDF from for sending by hand.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No EDI, and no acknowledgement from the supplier: follow-ups.
--   * No organisation-wide rule forcing email or forbidding it: the buyer
--     chooses on the order, Send to supplier or Download.
--   * The bare Send move stays, for an order sent some other way.
--
-- Proved by erp_test.purchase_order_send_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The queue
-- ═════════════════════════════════════════════════════════════════════════════

create table erp.document_email (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  document_id         uuid not null,
  document_issue_id   uuid not null,
  document_kind       text not null,
  to_address          text not null,
  to_name             text,
  cc_addresses        text[] not null default '{}',
  from_address        text not null,
  from_name           text,
  reply_to            text,
  message             text,
  status              text not null default 'queued',
  attempts            integer not null default 0,
  claimed_by          text,
  claimed_at          timestamptz,
  lease_expires_at    timestamptz,
  provider_message_id text,
  sent_at             timestamptz,
  failure_reason      text,
  idempotency_key     text not null default gen_random_uuid()::text,
  document_path       text,
  document_bytes      integer,
  document_sha256     text,
  document_problem    text,
  delivery_state      text,
  delivery_state_at   timestamptz,
  delivery_detail     text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint document_email_tenant_id_id_key unique (tenant_id, id),
  constraint document_email_document_fk foreign key (tenant_id, document_id)
    references erp.document(tenant_id, id) on delete restrict,
  constraint document_email_issue_fk foreign key (tenant_id, document_issue_id)
    references erp.document_issue(tenant_id, id) on delete restrict,
  constraint document_email_kind_known check (document_kind in ('purchase_order')),
  constraint document_email_status_known check (status in ('queued', 'sending', 'sent', 'failed', 'cancelled')),
  constraint document_email_sent_has_provider check (status <> 'sent' or provider_message_id is not null),
  constraint document_email_address_shape check (to_address ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint document_email_checksum_shape check (document_sha256 is null or document_sha256 ~ '^[0-9a-f]{64}$'),
  constraint document_email_delivery_known check (delivery_state is null or delivery_state in
    ('sent', 'delayed', 'delivered', 'opened', 'complained', 'bounced'))
);

create index document_email_queue on erp.document_email (tenant_id, status, created_at)
  where status in ('queued', 'sending');
create index document_email_document on erp.document_email (tenant_id, document_id, created_at desc);
create index document_email_provider on erp.document_email (provider_message_id)
  where provider_message_id is not null;

comment on table erp.document_email is
  'A document an organisation sends to someone outside it, one row per send (20261004920000): a '
  'purchase order to its supplier, its issue, the addresses, the state of the send and what the '
  'provider reported. Drained by the dispatch worker.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'document_email', 'tenant_scoped',
   'A document sent outside the organisation, one row per send; its state moves as it is claimed, sent and delivered, so not append-only.')
on conflict (schema_name, table_name) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_PURCHASE_ORDER_NOT_SENDABLE',
  'Sending to a supplier something that is not a purchase order the supplier may be given: one in draft or awaiting approval, closed, cancelled, or not an order.',
  'An order goes to its supplier once it is approved, and again while goods are still coming; before approval nothing has been agreed, and after it is closed or cancelled there is nothing to ask for.',
  'Approve the order first, or send it from the order''s own page while it is approved, sent or being received.');

select erp.register_refusal('CLOVEERP_SUPPLIER_HAS_NO_EMAIL',
  'Sending a purchase order with no address to send it to.',
  'An order emailed to nobody has not been sent; the supplier has no purchasing or default contact with an email address, and none was given.',
  'Type the supplier''s address on the form, or give the supplier a contact with an email address on their record.');

select erp.register_refusal('CLOVEERP_EMAIL_ADDRESS_INVALID',
  'Sending a document to something that is not an email address.',
  'A provider refuses an address that is not one, and a message refused is a document the supplier never had.',
  'Type the address as name@example.com, one to a box, and separate copies with commas.');

select erp.register_refusal('CLOVEERP_EMAIL_ADDRESS_SUPPRESSED',
  'Sending a document to an address the organisation has stopped writing to.',
  'The address bounced for good or complained before, and writing to it again harms every message the organisation sends.',
  'Ask the supplier for another address, or clear the suppression under Email on the Administration screen once they confirm it works.');

select erp.register_refusal('CLOVEERP_PURCHASE_ORDER_RESEND_NEEDS_REASON',
  'Sending a purchase order again without saying why.',
  'A second copy of an order can be read as a second order; the reason travels with it and stays on the record of what was sent.',
  'Say why it is going again: changed lines, a new address, the supplier lost it.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.purchase_order.emailed', 'en', 'Purchase order sent to the supplier', 'procurement',
   'Event raised when a buyer sends a purchase order to its supplier by email.'),
  ('event.purchase_order.emailed', 'de', 'Bestellung an den Lieferanten gesendet', 'procurement',
   'Ereignis, wenn ein Einkäufer eine Bestellung per E-Mail an den Lieferanten sendet.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('purchase_order.emailed', 1, 'document', 'procurement', 'event.purchase_order.emailed',
        'A buyer sent a purchase order to its supplier by email.',
        '{"type":"object","required":["reference","to_address","document_issue_id"],
          "properties":{"reference":{"type":"string"},"to_address":{"type":"string"},
                        "cc":{"type":"array"},"document_issue_id":{"type":"string"},
                        "document_email_id":{"type":"string"},"reason":{"type":["string","null"]}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'purchase_order.emailed' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.purchase_order.emailed') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: purchase_order.emailed is declared already, and not as 20261004920000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. What the supplier is sent
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.purchase_order_document(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A purchase order as its supplier reads it (20261004920000): the order's
  -- number, dates and references (never its internal notes), who is buying (the company, its registration
  -- and the buyer) and where the goods go (the site and its address), who it
  -- is to, the lines with the supplier's own codes, the tax by code and the
  -- totals. In the sections an issue's frozen contract carries. Nothing it
  -- prints is a cost, a margin or anything the supplier should not read.
  select jsonb_build_object(
           'kind', 'purchase_order',
           'header', jsonb_build_object(
             'number', d.document_number,
             'order_date', d.document_date,
             'required_date', d.required_date,
             'currency', d.currency,
             'our_reference', d.our_reference,
             'their_reference', d.their_reference),
           'company', jsonb_build_object(
             'name', e.name,
             'legal_name', coalesce(e.legal_name, e.name),
             'registration_number', e.registration_number,
             'country_code', e.country_code),
           'delivery', jsonb_build_object(
             'site', s.name,
             'address', coalesce(s.address, '{}'::jsonb)),
           'customer', jsonb_build_object(
             'code', p.code,
             'name', p.name,
             'legal_name', coalesce(p.legal_name, p.name),
             'address', coalesce(d.address_snapshot, '{}'::jsonb)),
           'lines', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'line_no', l.line_no,
                      'item_code', i.code,
                      'description', coalesce(l.description, i.name),
                      'supplier_item_code', l.supplier_item_code,
                      'quantity', l.quantity,
                      'uom', u.code,
                      'unit_price_minor', l.unit_price_minor,
                      'net_minor', l.net_minor,
                      'tax_code', l.tax_code,
                      'tax_minor', coalesce(l.tax_minor, 0),
                      'required_date', l.required_date)
                    order by l.line_no)
               from erp.document_line l
               left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
               left join erp.uom u on u.tenant_id = l.tenant_id and u.id = l.uom_id
              where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled), '[]'::jsonb),
           'tax_summary', coalesce((
             select jsonb_agg(jsonb_build_object('tax_code', x.tax_code, 'net_minor', x.net, 'tax_minor', x.tax)
                              order by x.tax_code)
               from (select coalesce(l.tax_code, '') as tax_code, sum(l.net_minor) as net,
                            sum(coalesce(l.tax_minor, 0)) as tax
                       from erp.document_line l
                      where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled
                      group by 1) x), '[]'::jsonb),
           'totals', jsonb_build_object(
             'net_minor', coalesce(dv.net_minor, 0),
             'tax_minor', coalesce(dv.tax_minor, 0),
             'gross_minor', coalesce(dv.gross_minor, 0)))
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.document_view dv on dv.tenant_id = d.tenant_id and dv.id = d.id
    left join erp.entity e on e.tenant_id = d.tenant_id and e.id = d.entity_id
    left join erp.site s on s.tenant_id = d.tenant_id and s.id = d.site_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_order
     and dt.base_type_code = 'purchase_order'
$$;

revoke all on function erp.purchase_order_document(uuid) from public, anon;

comment on function erp.purchase_order_document(uuid) is
  'A purchase order as its supplier reads it, in the sections an issue freezes (20261004920000).';

create or replace function erp.supplier_email_address(p_party uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Where a supplier's orders go (20261004920000): their current purchasing
  -- contact with an email address, else their current default contact with
  -- one, else any current contact with one. Null when there is none.
  select jsonb_build_object('address', lower(btrim(c.email)), 'name', c.name)
    from erp.party_contact c
   where c.tenant_id = erp.current_tenant_id() and c.party_id = p_party
     and nullif(btrim(coalesce(c.email, '')), '') is not null
     and (c.valid_from is null or c.valid_from <= current_date)
     and (c.valid_to is null or c.valid_to > current_date)
   order by (lower(coalesce(c.contact_kind, '')) in ('purchasing', 'procurement', 'orders', 'purchase')) desc,
            coalesce(c.is_default, false) desc, c.created_at
   limit 1
$$;

revoke all on function erp.supplier_email_address(uuid) from public, anon;

comment on function erp.supplier_email_address(uuid) is
  'The address a supplier''s purchase orders go to: their purchasing contact, else their default '
  'contact, else any contact with an email address (20261004920000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Sending
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.email_address_or_refuse(p_address text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := lower(btrim(coalesce(p_address, '')));
begin
  -- An address as the queue keeps it (20261004920000): lower case, trimmed,
  -- shaped like one, and not one the organisation has stopped writing to.
  if v !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then
    raise exception 'CLOVEERP_EMAIL_ADDRESS_INVALID: % is not an email address', coalesce(nullif(v, ''), 'nothing')
      using errcode = '22023',
            hint = 'Type the address as name@example.com, one to a box, and separate copies with commas.';
  end if;
  if exists (select 1 from erp.email_suppression s
              where s.tenant_id = erp.current_tenant_id() and lower(s.address) = v) then
    raise exception 'CLOVEERP_EMAIL_ADDRESS_SUPPRESSED: % bounced or complained before, and nothing more is sent to it', v
      using errcode = '23514',
            hint = 'Ask the supplier for another address, or clear the suppression under Email on the Administration screen once they confirm it works.';
  end if;
  return v;
end;
$$;

revoke all on function erp.email_address_or_refuse(text) from public, anon;

create or replace function erp.send_purchase_order(p_order uuid, p_to text default null, p_cc text default null,
                                                   p_message text default null, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  v_base    text;
  v_state   text;
  v_default jsonb;
  v_to      text;
  v_to_name text;
  v_cc      text[] := '{}';
  v_part    text;
  v_last    erp.document_issue%rowtype;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_payload jsonb;
  v_seq     bigint;
  v_issue   uuid;
  v_sender  jsonb;
  v_buyer   erp.app_user%rowtype;
  v_org     text;
  v_email   uuid;
begin
  -- The order, held while it is sent, so two presses send it twice in order
  -- and the second sees the first.
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = p_order for update;
  select dt.base_type_code into v_base
    from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  if d.id is null or v_base is distinct from 'purchase_order' then
    raise exception 'CLOVEERP_PURCHASE_ORDER_NOT_SENDABLE: % is not a purchase order',
      coalesce(d.document_number, coalesce(p_order::text, 'nothing'))
      using errcode = '23514',
            hint = 'Approve the order first, or send it from the order''s own page while it is approved, sent or being received.';
  end if;

  -- Sending an order is buying, in the order's company and site.
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', d.id);

  v_state := erp.object_current_state('document', d.id);
  if d.is_cancelled or v_state not in ('approved', 'sent', 'partially_received', 'received')
     or coalesce(d.order_behaviour_code, '') = 'blanket' then
    raise exception 'CLOVEERP_PURCHASE_ORDER_NOT_SENDABLE: % is %, and an order goes to its supplier once approved and while goods are coming',
      d.document_number, case when d.is_cancelled then 'cancelled' else coalesce(v_state, 'in no state') end
      using errcode = '23514',
            hint = 'Approve the order first, or send it from the order''s own page while it is approved, sent or being received.';
  end if;

  -- The addresses: the one typed, else the supplier's; copies by comma.
  v_default := erp.supplier_email_address(d.party_id);
  if nullif(btrim(coalesce(p_to, '')), '') is not null then
    v_to := erp.email_address_or_refuse(p_to);
    v_to_name := case when v_default ->> 'address' = v_to then v_default ->> 'name' end;
  elsif v_default is not null then
    v_to := erp.email_address_or_refuse(v_default ->> 'address');
    v_to_name := v_default ->> 'name';
  else
    raise exception 'CLOVEERP_SUPPLIER_HAS_NO_EMAIL: % has no contact with an email address, and none was given',
      coalesce((select p.name from erp.party p where p.tenant_id = v_tenant and p.id = d.party_id), 'the supplier')
      using errcode = '23502',
            hint = 'Type the supplier''s address on the form, or give the supplier a contact with an email address on their record.';
  end if;
  for v_part in select btrim(x) from regexp_split_to_table(coalesce(p_cc, ''), '[,;]') x loop
    continue when v_part = '';
    v_cc := v_cc || erp.email_address_or_refuse(v_part);
  end loop;

  -- The last issue of the order not voided: a send after it says why, and
  -- its issue replaces it.
  select * into v_last from erp.document_issue i
   where i.tenant_id = v_tenant and i.source_document_id = d.id and i.document_kind = 'purchase_order'
     and i.status <> 'void'
   order by i.sequence_number desc limit 1;
  if v_last.id is not null and v_reason is null then
    raise exception 'CLOVEERP_PURCHASE_ORDER_RESEND_NEEDS_REASON: % went to its supplier already, as %',
      d.document_number, v_last.issued_number
      using errcode = '23514',
            hint = 'Say why it is going again: changed lines, a new address, the supplier lost it.';
  end if;

  -- Approved goes to Sent by the same press; the lifecycle's own move, which
  -- asks its own permission and posts the commitment.
  if v_state = 'approved' then
    perform erp.transition_document(d.id, 'send', 'sent to the supplier by email');
  end if;

  v_payload := erp.purchase_order_document(d.id);
  select b.* into v_buyer from erp.app_user b
   where b.tenant_id = v_tenant and b.id = erp.current_principal_id();
  v_payload := v_payload || jsonb_build_object(
    'buyer', jsonb_build_object('name', coalesce(nullif(btrim(v_buyer.display_name), ''), v_buyer.email),
                                'email', v_buyer.email),
    'message', nullif(btrim(coalesce(p_message, '')), ''),
    'reason', v_reason,
    'issued_on', current_date);

  -- The issue: one per send, numbered in the organisation's purchase order
  -- sends, its number the order's own, frozen as it read now. Reserved here;
  -- the worker files the PDF on it and marks it sent.
  perform pg_advisory_xact_lock(hashtext('document_issue:purchase_order:' || v_tenant::text));
  select coalesce(max(i.sequence_number), 0) + 1 into v_seq
    from erp.document_issue i where i.tenant_id = v_tenant and i.document_kind = 'purchase_order';
  insert into erp.document_issue (tenant_id, document_kind, source_document_id, sequence_prefix,
                                  sequence_number, issued_number, status, issued_by, issued_at,
                                  replaces_issue_id, contract_snapshot)
  values (v_tenant, 'purchase_order', d.id, 'PO-SEND-', v_seq,
          d.document_number || case when v_last.id is null then ''
                                    else ' (' || (select count(*) + 1 from erp.document_issue i
                                                   where i.tenant_id = v_tenant and i.source_document_id = d.id
                                                     and i.document_kind = 'purchase_order')::text || ')' end,
          'reserved', erp.current_principal_id(), now(), v_last.id, v_payload)
  returning id into v_issue;

  -- Who it comes from (owner): the organisation's verified domain, else the
  -- platform's address under the organisation's name, replies to the buyer.
  v_sender := erp.sender_for('transactional');
  v_org := coalesce((select e.legal_name from erp.entity e where e.tenant_id = v_tenant and e.id = d.entity_id),
                    (select t.name from erp.tenant t where t.id = v_tenant));

  insert into erp.document_email (tenant_id, document_id, document_issue_id, document_kind, to_address, to_name,
                                  cc_addresses, from_address, from_name, reply_to, message)
  values (v_tenant, d.id, v_issue, 'purchase_order', v_to, v_to_name, v_cc,
          v_sender ->> 'from_address', v_org,
          coalesce(case when (v_sender ->> 'own_domain')::boolean then v_sender ->> 'reply_to' end,
                   nullif(btrim(coalesce(v_buyer.email, '')), ''),
                   v_sender ->> 'reply_to'),
          nullif(btrim(coalesce(p_message, '')), ''))
  returning id into v_email;

  perform erp.append_event(
    'purchase_order.emailed', 'document', d.id,
    jsonb_build_object('reference', d.document_number, 'to_address', v_to, 'cc', to_jsonb(v_cc),
                       'document_issue_id', v_issue, 'document_email_id', v_email, 'reason', v_reason),
    d.entity_id, d.site_id);

  return jsonb_build_object(
    'order_id', d.id,
    'order_number', d.document_number,
    'order_state', erp.object_current_state('document', d.id),
    'document_issue_id', v_issue,
    'issued_number', (select i.issued_number from erp.document_issue i where i.id = v_issue),
    'document_email_id', v_email,
    'to_address', v_to,
    'cc', to_jsonb(v_cc),
    'status', 'queued');
end;
$$;

revoke all on function erp.send_purchase_order(uuid, text, text, text, text) from public, anon;

comment on function erp.send_purchase_order(uuid, text, text, text, text) is
  'Sends a purchase order to its supplier by email (20261004920000): moves an approved order to Sent, '
  'reserves an issue frozen as the order reads, and queues the email for the dispatch worker. '
  'Authorises procurement.order in the order''s company and site.';

create or replace function public.erp_send_purchase_order(p_order uuid, p_to text default null, p_cc text default null,
                                                          p_message text default null, p_reason text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.send_purchase_order(p_order, p_to, p_cc, p_message, p_reason) $$;

revoke all on function public.erp_send_purchase_order(uuid, text, text, text, text) from public, anon;
grant execute on function public.erp_send_purchase_order(uuid, text, text, text, text) to authenticated, service_role;

comment on function public.erp_send_purchase_order(uuid, text, text, text, text) is
  'Sends a purchase order to its supplier by email (20261004920000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_send_purchase_order', 'erp.send_purchase_order',
   'Sends a purchase order to its supplier: may move it from Approved to Sent, reserves a document issue and queues an email; authorises procurement.order in the order''s company and site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_send_purchase_order']);

-- The order's sends, as its page reads them

create or replace function erp.purchase_order_sends(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What a purchase order's page says about sending it (20261004920000): the
  -- address a send would go to, whether the reader may send it, whether a
  -- send must say why, and every send so far, newest first, with its issue,
  -- its addresses, how far it got and what the provider reported.
  select jsonb_build_object(
           'order_id', d.id,
           'default_to', erp.supplier_email_address(d.party_id) ->> 'address',
           'may_send', erp.object_current_state('document', d.id) in ('approved', 'sent', 'partially_received', 'received')
                       and not d.is_cancelled
                       and erp.has_permission('procurement.order', d.entity_id, d.site_id),
           'needs_reason', exists (select 1 from erp.document_issue i
                                    where i.tenant_id = d.tenant_id and i.source_document_id = d.id
                                      and i.document_kind = 'purchase_order' and i.status <> 'void'),
           'sends', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'document_email_id', m.id,
                      'document_issue_id', m.document_issue_id,
                      'issued_number', i.issued_number,
                      'issue_status', i.status,
                      'reason', i.contract_snapshot ->> 'reason',
                      'to_address', m.to_address,
                      'cc', to_jsonb(m.cc_addresses),
                      'from_address', m.from_address,
                      'reply_to', m.reply_to,
                      'status', m.status,
                      'attempts', m.attempts,
                      'queued_at', m.created_at,
                      'sent_at', m.sent_at,
                      'failure_reason', m.failure_reason,
                      'delivery_state', m.delivery_state,
                      'delivery_state_at', m.delivery_state_at,
                      'delivery_detail', m.delivery_detail,
                      'document_kept', m.document_path is not null,
                      'document_bytes', m.document_bytes,
                      'document_sha256', m.document_sha256,
                      'document_problem', m.document_problem,
                      'sent_by', coalesce(u.display_name, u.email))
                    order by m.created_at desc, i.sequence_number desc)
               from erp.document_email m
               join erp.document_issue i on i.tenant_id = m.tenant_id and i.id = m.document_issue_id
               left join erp.app_user u on u.tenant_id = m.tenant_id and u.id = m.created_by
              where m.tenant_id = d.tenant_id and m.document_id = d.id), '[]'::jsonb))
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_order
     and dt.base_type_code = 'purchase_order'
$$;

revoke all on function erp.purchase_order_sends(uuid) from public, anon;

comment on function erp.purchase_order_sends(uuid) is
  'A purchase order''s sends to its supplier, newest first, the address the next would go to and '
  'whether the reader may send (20261004920000).';

create or replace function public.erp_purchase_order_sends(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.purchase_order_sends(p_order) $$;

revoke all on function public.erp_purchase_order_sends(uuid) from public, anon;
grant execute on function public.erp_purchase_order_sends(uuid) to authenticated, service_role;

comment on function public.erp_purchase_order_sends(uuid) is
  'A purchase order''s sends to its supplier (20261004920000).';

create or replace function public.erp_purchase_order_document(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.purchase_order_document(p_order) $$;

revoke all on function public.erp_purchase_order_document(uuid) from public, anon;
grant execute on function public.erp_purchase_order_document(uuid) to authenticated, service_role;

comment on function public.erp_purchase_order_document(uuid) is
  'A purchase order as its supplier reads it, rendered on its page for sending by hand (20261004920000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The worker's half
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.claim_document_email_batch(p_limit integer, p_worker text)
returns table(id uuid, document_kind text, to_address text, to_name text, cc_addresses text[],
              from_address text, from_name text, reply_to text, message text, idempotency_key text,
              attempt integer, issued_number text, organisation_name text, payload jsonb)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_ids    uuid[];
begin
  -- The organisation's documents due to go out (20261004920000), marked
  -- sending in the claim with who holds them and until when, so a worker that
  -- dies mid-flight leaves rows visibly held and reclaimable: a send whose
  -- lease ran out is claimed again, under the same idempotency key, so the
  -- provider does not deliver it twice. The kill switch and a demonstration
  -- send nothing.
  if erp.is_killed('integration', 'email') or erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;

  with claimed as (
    select m.id
      from erp.document_email m
     where m.tenant_id = v_tenant
       and (m.status = 'queued' or (m.status = 'sending' and m.lease_expires_at < now()))
     order by m.created_at
     limit greatest(p_limit, 1)
     for update skip locked
  ),
  marked as (
    update erp.document_email m
       set status = 'sending', claimed_by = coalesce(p_worker, current_user), claimed_at = now(),
           lease_expires_at = now() + interval '5 minutes', attempts = m.attempts + 1, updated_at = now()
      from claimed c
     where m.id = c.id
     returning m.id
  )
  select coalesce(array_agg(mk.id), '{}'::uuid[]) into v_ids from marked mk;

  return query
    select m.id, m.document_kind, m.to_address, m.to_name, m.cc_addresses, m.from_address, m.from_name,
           m.reply_to, m.message, m.idempotency_key, m.attempts, i.issued_number,
           (select t.name from erp.tenant t where t.id = v_tenant), i.contract_snapshot
      from erp.document_email m
      join erp.document_issue i on i.tenant_id = m.tenant_id and i.id = m.document_issue_id
     where m.tenant_id = v_tenant and m.id = any (v_ids)
     order by m.created_at;
end;
$$;

revoke all on function erp.claim_document_email_batch(integer, text) from public, anon;

comment on function erp.claim_document_email_batch(integer, text) is
  'Claims an organisation''s queued outgoing documents for the dispatch worker, with the frozen payload '
  'each is rendered from (20261004920000).';

create or replace function erp.complete_document_email(p_id uuid, p_provider_message_id text,
                                                       p_document_path text, p_document_bytes integer,
                                                       p_document_sha256 text, p_document_problem text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  m        erp.document_email%rowtype;
begin
  -- Sent (20261004920000): the provider named it. Where the copy was kept,
  -- the issue files it and reads issued, then sent; where it was not, the
  -- issue stays reserved and the send says why, because an issue says issued
  -- only with its file.
  if coalesce(btrim(p_provider_message_id), '') = '' then
    raise exception 'CLOVEERP_EMAIL_NEEDS_PROVIDER_ID: a message is only sent once a provider names it'
      using errcode = 'P0001',
            hint = 'Pass the id the provider returned. Without it the row cannot honestly say sent.';
  end if;

  update erp.document_email x
     set status = 'sent', sent_at = now(), provider_message_id = p_provider_message_id,
         claimed_by = null, lease_expires_at = null, failure_reason = null,
         document_path = p_document_path, document_bytes = p_document_bytes,
         document_sha256 = p_document_sha256, document_problem = left(p_document_problem, 500),
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = p_id and x.status = 'sending'
  returning * into m;
  if m.id is null then
    return;
  end if;

  if p_document_path is not null and p_document_sha256 is not null then
    update erp.document_issue i
       set status = 'issued', storage_path = p_document_path, content_checksum = p_document_sha256,
           completed_at = now(), updated_at = now()
     where i.tenant_id = v_tenant and i.id = m.document_issue_id and i.status = 'reserved';
    update erp.document_issue i
       set status = 'sent', sent_at = now(), updated_at = now()
     where i.tenant_id = v_tenant and i.id = m.document_issue_id and i.status = 'issued';
  end if;
end;
$$;

revoke all on function erp.complete_document_email(uuid, text, text, integer, text, text) from public, anon;

comment on function erp.complete_document_email(uuid, text, text, integer, text, text) is
  'Settles an outgoing document the provider accepted, filing its kept copy on the issue and marking '
  'the issue sent (20261004920000).';

create or replace function erp.fail_document_email(p_id uuid, p_reason text, p_retry boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  m        erp.document_email%rowtype;
  v_number text;
begin
  -- Not sent (20261004920000). "Not now" goes back to the queue, five tries
  -- in all; "never", or the fifth, fails it, and the buyer who sent it is
  -- told in the product, which never fails.
  if p_retry then
    update erp.document_email x
       set status = case when x.attempts >= 5 then 'failed' else 'queued' end,
           failure_reason = left(p_reason, 500), claimed_by = null, lease_expires_at = null, updated_at = now()
     where x.tenant_id = v_tenant and x.id = p_id and x.status = 'sending'
    returning * into m;
    if m.id is null or m.status <> 'failed' then
      return;
    end if;
  else
    update erp.document_email x
       set status = 'failed', failure_reason = left(p_reason, 500), claimed_by = null, lease_expires_at = null,
           updated_at = now()
     where x.tenant_id = v_tenant and x.id = p_id and x.status = 'sending'
    returning * into m;
    if m.id is null then
      return;
    end if;
  end if;

  select d.document_number into v_number from erp.document d where d.tenant_id = v_tenant and d.id = m.document_id;
  if m.created_by is not null then
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (v_tenant, 'high', m.created_by, 'in_app',
            format('%s did not reach %s', coalesce(v_number, 'A purchase order'), m.to_address),
            format('The email could not be sent: %s. Check the address and send it again from the order.',
                   coalesce(m.failure_reason, 'the provider refused it')),
            'delivered', now(), now());
  end if;
end;
$$;

revoke all on function erp.fail_document_email(uuid, text, boolean) from public, anon;

comment on function erp.fail_document_email(uuid, text, boolean) is
  'Puts an outgoing document back on the queue, or fails it and tells the buyer in the product '
  '(20261004920000).';

-- E2. What the provider reports
--
-- Edited, not rewritten: four anchors over erp.record_email_delivery_event()
-- (md5 d2ba81b3…), and the register of what an event may be about.

alter table erp_meta.email_delivery_event drop constraint if exists email_delivery_event_matched_known;
alter table erp_meta.email_delivery_event add constraint email_delivery_event_matched_known
  check (matched = any (array['nothing', 'commercial_email', 'notification', 'enquiry', 'document_email']));

do $delivery$
declare
  v_sig  constant text := 'erp.record_email_delivery_event(text,text,text,text,timestamp with time zone,text,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_note     erp.notification;
$o$,
    $n$  v_note     erp.notification;
  -- A document an organisation sent (20261004920000).
  v_doc      erp.document_email;
$n$,

    $o$      elsif exists (select 1 from erp_meta.enquiry e$o$,
    $n$      else
        select * into v_doc from erp.document_email m
         where m.provider_message_id = v_message
         order by m.sent_at desc nulls last limit 1;
        if found then
          v_matched := 'document_email';
          v_tenant := v_doc.tenant_id;
        end if;
      end if;
      if v_matched <> 'nothing' then
        null;
      elsif exists (select 1 from erp_meta.enquiry e$n$,

    $o$  elsif v_state is not null and v_matched = 'notification' then$o$,
    $n$  elsif v_state is not null and v_matched = 'document_email' then
    update erp.document_email m
       set delivery_state = v_state, delivery_state_at = v_when,
           delivery_detail = coalesce(v_detail, m.delivery_detail), updated_at = now()
     where m.id = v_doc.id
       and erp.email_delivery_rank(v_state) > erp.email_delivery_rank(m.delivery_state);
    v_moved := found;
  elsif v_state is not null and v_matched = 'notification' then$n$,

    $o$    v_tenant := case when v_matched = 'notification' then v_tenant else v_platform end;$o$,
    $n$    -- The organisation that wrote to it stops writing to it.
    v_tenant := case when v_matched in ('notification', 'document_email') then v_tenant else v_platform end;$n$];
  v_hits integer;
begin
  if strpos(v_src, '20261004920000') > 0 then
    raise notice '% already reads a document''s delivery; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd2ba81b3a7456438cec66d50c98b86ae' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004920000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$delivery$;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.purchase_order_send_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_sb uuid;
  v_po uuid; v_po2 uuid; v_po3 uuid;
  v_send jsonb; v_send2 jsonb; v_sends jsonb; v_claim record; v_n integer; v_doc jsonb;
  v_issue uuid; v_email uuid; v_ev jsonb;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, with a buyer and somebody who only reads';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpos-' || v_tag, 'Purchase Order Send Suite',
      'admin@zzpos-' || v_tag || '.test', 'Send Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzpos-' || v_tag || '.test'),
           (a2, 'second@zzpos-' || v_tag || '.test'),
           (s_buy, 'buyer@zzpos-' || v_tag || '.test'),
           (s_read, 'reader@zzpos-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@zzpos-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('buyer@zzpos-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zzpos-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, product and two suppliers, one with a purchasing contact';
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZSMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZSEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZSBAG', 'Sent Bag', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZSBRAND');
    v_sb := erp_test.cash_payment_supplier('ZSNOMAIL');
    insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, is_default)
    values (rb.tenant_id, v_sa, 'accounts', 'Ann Accounts', 'accounts@brand.example', true),
           (rb.tenant_id, v_sa, 'purchasing', 'Paul Purchasing', 'Orders@Brand.example', false);

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the door, the queue, its refusals, its event and its screen';
    v_cases := v_cases + 1;
    case_name := 'the door is on the allow-list under its gate and on the Procurement screen''s help, the queue is governed under row security, the five refusals are registered with a next action, and purchase_order.emailed is current and named in English and German';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_send_purchase_order' and a.gate = 'erp.send_purchase_order')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/procurement' and 'erp_send_purchase_order' = any (h.actions))
          and exists (select 1 from erp_meta.table_policy p
                       where p.schema_name = 'erp' and p.table_name = 'document_email' and p.table_class = 'tenant_scoped')
          and (select c.relrowsecurity from pg_class c where c.oid = 'erp.document_email'::regclass)
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_PURCHASE_ORDER_NOT_SENDABLE', 'CLOVEERP_SUPPLIER_HAS_NO_EMAIL',
                                 'CLOVEERP_EMAIL_ADDRESS_INVALID', 'CLOVEERP_EMAIL_ADDRESS_SUPPRESSED',
                                 'CLOVEERP_PURCHASE_ORDER_RESEND_NEEDS_REASON')
                  and coalesce(f.next_action, '') <> '') = 5
          and exists (select 1 from erp_ref.event_type et where et.code = 'purchase_order.emailed' and et.is_current)
          and (select count(*) from erp_ref.resource x
                where x.key = 'event.purchase_order.emailed' and x.locale in ('en', 'de')) = 2;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Sent from Approved ───────────────────────────────────────────────
    v_step := 'an approved order sent by the buyer with a message';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 3, 12000, 'ZPOS2', false);
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_sends := public.erp_purchase_order_sends(v_po);
    v_send := public.erp_send_purchase_order(v_po, null, 'buying@us.example', 'Please confirm the delivery date.', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_issue := (v_send ->> 'document_issue_id')::uuid;
    v_email := (v_send ->> 'document_email_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'an approved order sent by the buyer goes to the supplier''s purchasing contact, lower case, with the copy asked for: the order moves to Sent, an issue is reserved under the order''s number with its frozen contract, one email is queued with replies to the buyer, and purchase_order.emailed is raised';
    passed := v_state is null
          and v_sends ->> 'default_to' = 'orders@brand.example'
          and (v_sends ->> 'may_send')::boolean
          and not (v_sends ->> 'needs_reason')::boolean
          and v_send ->> 'to_address' = 'orders@brand.example'
          and v_send -> 'cc' = '["buying@us.example"]'::jsonb
          and v_send ->> 'order_state' = 'sent'
          and erp.object_current_state('document', v_po) = 'sent'
          and exists (select 1 from erp.document_issue i
                       where i.id = v_issue and i.status = 'reserved' and i.document_kind = 'purchase_order'
                         and i.issued_number = (select d.document_number from erp.document d where d.id = v_po)
                         and jsonb_array_length(i.contract_snapshot -> 'lines') = 1
                         and (i.contract_snapshot #>> '{totals,net_minor}')::bigint = 36000
                         and i.contract_snapshot ->> 'message' = 'Please confirm the delivery date.'
                         and i.contract_snapshot #>> '{buyer,email}' = 'buyer@zzpos-' || v_tag || '.test')
          and exists (select 1 from erp.document_email m
                       where m.id = v_email and m.status = 'queued' and m.to_name = 'Paul Purchasing'
                         and m.reply_to = 'buyer@zzpos-' || v_tag || '.test'
                         and m.from_address <> '' )
          and exists (select 1 from erp.event e
                       where e.tenant_id = rb.tenant_id and e.event_type = 'purchase_order.emailed'
                         and e.aggregate_id = v_po);
    detail := coalesce(v_state, left(format('sends %s; send %s', v_sends, v_send), 700));
    return next;

    -- ── 3. What may not be sent ─────────────────────────────────────────────
    v_step := 'a draft order, something not an order, a supplier with no address, a bad address and a resend with no reason';
    v_po2 := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    perform erp.add_document_line(v_po2, v_item, 1, 1000, 'a draft');
    begin
      perform public.erp_send_purchase_order(v_po2, null, null, null, null);
      v_err := 'sent';
    exception when others then v_err := sqlerrm; end;
    v_po3 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sb, 1, 1000, 'ZPOS3', false);
    begin
      perform public.erp_send_purchase_order(v_po3, null, null, null, null);
      v_err2 := 'sent';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_send_purchase_order(v_po3, 'not an address', null, null, null);
      v_err3 := 'sent';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_send_purchase_order(v_po, null, null, null, null);
      v_err4 := 'sent';
    exception when others then v_err4 := sqlerrm; end;
    begin
      perform public.erp_send_purchase_order(gen_random_uuid(), 'a@b.example', null, null, null);
      v_err5 := 'sent';
    exception when others then v_err5 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a draft order and something not an order are refused as not sendable, a supplier with no address and none typed as having no email, a bad address as invalid, and a second send with no reason as needing one; nothing more is queued and the approved order stays approved';
    passed := v_state is null
          and v_err like 'CLOVEERP_PURCHASE_ORDER_NOT_SENDABLE:%'
          and v_err5 like 'CLOVEERP_PURCHASE_ORDER_NOT_SENDABLE:%'
          and v_err2 like 'CLOVEERP_SUPPLIER_HAS_NO_EMAIL:%'
          and v_err3 like 'CLOVEERP_EMAIL_ADDRESS_INVALID:%'
          and v_err4 like 'CLOVEERP_PURCHASE_ORDER_RESEND_NEEDS_REASON:%'
          and (select count(*) from erp.document_email m where m.tenant_id = rb.tenant_id) = 1
          and erp.object_current_state('document', v_po3) = 'approved';
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 800));
    return next;

    -- ── 4. Somebody who may only read ───────────────────────────────────────
    v_step := 'the reader asks for the sends and tries to send';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    v_sends := public.erp_purchase_order_sends(v_po);
    begin
      perform public.erp_send_purchase_order(v_po3, 'a@b.example', null, null, null);
      v_err := 'sent';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody who may only read sees the order''s one send and may not send, and the door refuses them procurement.order';
    passed := v_state is null
          and not (v_sends ->> 'may_send')::boolean
          and jsonb_array_length(v_sends -> 'sends') = 1
          and v_err like 'CLOVEERP_PERMISSION_DENIED: procurement.order%';
    detail := coalesce(v_state, left(format('%s; %s', v_sends, v_err), 500));
    return next;

    -- ── 5. The worker claims it ─────────────────────────────────────────────
    v_step := 'the worker claims the queue';
    select * into v_claim from erp.claim_document_email_batch(10, 'suite-worker');
    get diagnostics v_n = row_count;
    v_cases := v_cases + 1;
    case_name := 'the worker claims the queued send with its frozen payload, the addresses, the order''s number and the organisation, and the row reads sending, held by the worker, on its first attempt; a second claim takes nothing';
    passed := v_state is null
          and v_n = 1
          and v_claim.id = v_email
          and v_claim.to_address = 'orders@brand.example'
          and v_claim.cc_addresses = array['buying@us.example']
          and v_claim.issued_number = (select d.document_number from erp.document d where d.id = v_po)
          and v_claim.payload ->> 'kind' = 'purchase_order'
          and v_claim.attempt = 1
          and (select m.status from erp.document_email m where m.id = v_email) = 'sending'
          and (select m.claimed_by from erp.document_email m where m.id = v_email) = 'suite-worker'
          and not exists (select 1 from erp.claim_document_email_batch(10, 'suite-worker'));
    detail := coalesce(v_state, left(format('%s rows; %s', v_n, row_to_json(v_claim)), 600));
    return next;

    -- ── 6. Not now, then sent ───────────────────────────────────────────────
    v_step := 'a provider that says not now, a second claim, and a send';
    perform erp.fail_document_email(v_email, 'the provider is busy', true);
    v_err := (select m.status from erp.document_email m where m.id = v_email);
    perform erp.claim_document_email_batch(10, 'suite-worker');
    perform erp.complete_document_email(v_email, 're_123', 'purchase-order/' || v_email || '.pdf', 2048,
                                        repeat('ab', 32), null);
    v_cases := v_cases + 1;
    case_name := 'a provider''s not now puts the send back on the queue; claimed again and sent, it reads sent with the provider''s id and its kept copy, and its issue files that copy and reads sent';
    passed := v_state is null
          and v_err = 'queued'
          and exists (select 1 from erp.document_email m
                       where m.id = v_email and m.status = 'sent' and m.provider_message_id = 're_123'
                         and m.attempts = 2 and m.document_bytes = 2048)
          and exists (select 1 from erp.document_issue i
                       where i.id = v_issue and i.status = 'sent' and i.storage_path = 'purchase-order/' || v_email || '.pdf'
                         and i.content_checksum = repeat('ab', 32) and i.sent_at is not null);
    detail := coalesce(v_state, left(format('after retry %s; %s', v_err,
      (select row_to_json(m) from erp.document_email m where m.id = v_email)), 700));
    return next;

    -- ── 7. Delivered, then a resend that bounces ────────────────────────────
    v_step := 'the provider reports delivery; the order is sent again, with a reason, and bounces for good';
    v_ev := erp.record_email_delivery_event('evt-' || v_tag || '-1', 'email.delivered', 'delivered', 're_123',
                                            now(), 'orders@brand.example', null, null);
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_send2 := public.erp_send_purchase_order(v_po, 'new@brand.example', null, null, 'the supplier moved their orders desk');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_document_email_batch(10, 'suite-worker');
    perform erp.complete_document_email((v_send2 ->> 'document_email_id')::uuid, 're_456', null, null, null,
                                        'no storage is configured for the drain, so no copy was kept');
    perform erp.record_email_delivery_event('evt-' || v_tag || '-2', 'email.bounced', 'bounced', 're_456',
                                            now(), 'new@brand.example', 'Permanent', 'mailbox does not exist');
    v_sends := public.erp_purchase_order_sends(v_po);
    begin
      perform public.erp_send_purchase_order(v_po, 'new@brand.example', null, null, 'once more');
      v_err := 'sent';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'delivery reaches the first send; a second send says why, replaces the first issue and is numbered as the order''s second; sent without a kept copy its issue stays reserved and the send says why; a hard bounce marks it bounced and stops the organisation writing to that address';
    passed := v_state is null
          and (v_ev ->> 'matched') = 'document_email'
          and (select m.delivery_state from erp.document_email m where m.id = v_email) = 'delivered'
          and jsonb_array_length(v_sends -> 'sends') = 2
          and (v_sends ->> 'needs_reason')::boolean
          and v_sends #>> '{sends,0,delivery_state}' = 'bounced'
          and v_sends #>> '{sends,0,issue_status}' = 'reserved'
          and v_sends #>> '{sends,0,reason}' = 'the supplier moved their orders desk'
          and v_sends #>> '{sends,0,document_problem}' like 'no storage%'
          and v_sends #>> '{sends,0,issued_number}' like '% (2)'
          and exists (select 1 from erp.document_issue i
                       where i.id = (v_send2 ->> 'document_issue_id')::uuid and i.replaces_issue_id = v_issue)
          and exists (select 1 from erp.email_suppression s
                       where s.tenant_id = rb.tenant_id and s.address = 'new@brand.example')
          and v_err like 'CLOVEERP_EMAIL_ADDRESS_SUPPRESSED:%';
    detail := coalesce(v_state, left(format('event %s; sends %s; %s', v_ev, v_sends, v_err), 900));
    return next;

    -- ── 8. Failed for good tells the buyer ──────────────────────────────────
    v_step := 'a send the provider refuses for good';
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_send2 := public.erp_send_purchase_order(v_po3, 'desk@nomail.example', null, null, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_document_email_batch(10, 'suite-worker');
    perform erp.fail_document_email((v_send2 ->> 'document_email_id')::uuid, 'the address was refused', false);
    v_cases := v_cases + 1;
    case_name := 'a send the provider refuses for good reads failed with the reason, and the buyer who sent it is told in the product which order did not reach which address';
    passed := v_state is null
          and (select m.status from erp.document_email m where m.id = (v_send2 ->> 'document_email_id')::uuid) = 'failed'
          and exists (select 1 from erp.notification n
                       join erp.app_user u on u.id = n.app_user_id and u.auth_user_id = s_buy
                      where n.tenant_id = rb.tenant_id and n.channel_kind = 'in_app'
                        and n.subject like '%desk@nomail.example%');
    detail := coalesce(v_state, 'failed and told');
    return next;

    -- ── 9. What the page renders by hand ────────────────────────────────────
    v_step := 'the order''s document, for printing and sending by hand';
    v_doc := public.erp_purchase_order_document(v_po);
    v_cases := v_cases + 1;
    case_name := 'the order''s document carries the sections an issue freezes: the order, the company, the delivery site, the supplier, its lines with quantities and prices, the tax by code and the totals, and no cost';
    passed := v_state is null
          and v_doc ?& array['header', 'company', 'customer', 'lines', 'tax_summary', 'totals', 'delivery']
          and v_doc #>> '{customer,code}' = 'ZSBRAND'
          and (v_doc #>> '{lines,0,quantity}')::numeric = 3
          and (v_doc #>> '{lines,0,unit_price_minor}')::bigint = 12000
          and v_doc::text not like '%cost%';
    detail := coalesce(v_state, left(v_doc::text, 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzpos-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2, s_buy, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzpos rolled back with its orders, issues and sends');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PURCHASE_ORDER_SEND_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.purchase_order_send_suite() from public, anon;

comment on function erp_test.purchase_order_send_suite() is
  'A purchase order reaches its supplier (20261004920000): sent from Approved to the supplier''s '
  'purchasing contact with a frozen issue and a queued email, refused by name where it may not go, '
  'claimed, retried and sent by the worker with its copy filed, its delivery and bounce recorded and '
  'the address suppressed, a failure told to the buyer, and the document the page renders by hand.';

create or replace function erp_test.assert_purchase_order_send_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.purchase_order_send_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PURCHASE_ORDER_SEND_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A purchase order would not reach its supplier, or would reach somebody it must not. Read the case that failed.';
  end if;
  if v_total <> 10 then
    raise exception 'CLOVEERP_PURCHASE_ORDER_SEND_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('purchase order send: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_purchase_order_send_suite() from public, anon;

comment on function erp_test.assert_purchase_order_send_suite() is
  'A purchase order is emailed to its supplier and the send is tracked to delivery (20261004920000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Sending a purchase order to its supplier (20261004920000).'
  from (values
    ('Sent to the supplier'),
    ('The order as the supplier receives it: emailed from here with its PDF attached, or downloaded and sent by hand.'),
    ('Send to supplier'),
    ('Send again'),
    ('Download PDF'),
    ('Send this order to the supplier'),
    ('Emails the order with its PDF attached. An approved order moves to Sent. Replies come to you.'),
    ('To'),
    ('Copy to'),
    ('Separate addresses with commas.'),
    ('Message'),
    ('Please confirm the delivery date.'),
    ('Optional. Shown above the order in the email.'),
    ('Why it is going again'),
    ('Changed quantities on line 2'),
    ('Required for a second send. It travels with the order.'),
    ('Send'),
    ('Not sent yet. Send it from here, or download the PDF and send it yourself.'),
    ('queued'),
    ('sending'),
    ('sent'),
    ('delivered'),
    ('opened'),
    ('bounced'),
    ('failed'),
    ('Copy kept')
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
select erp.assert_document_issue_sound();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
