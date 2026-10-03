set lock_timeout = '30s';

-- =============================================================================
-- 20261004990000  A supplier confirms the order
-- -----------------------------------------------------------------------------
-- Owner, 3 October 2026: the next purchasing gap. A purchase order went to its
-- supplier (20261004920000) and nothing recorded the answer: whether they took
-- it, when they will deliver, or that they can only send part of it.
--
-- Owner decisions:
--   * The supplier answers from a link in the PO email, with no sign-in, and
--     the buyer can record an answer on the supplier's behalf.
--   * Changed quantities or dates wait for the buyer, who accepts or rejects.
--   * An order nobody has confirmed is flagged to its buyer after a number of
--     days set in the procurement policy (default three).
--   * A sent order can be cancelled while nothing of it has been received.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.purchase_order_confirmation: one per sent order, awaiting →
--      confirmed, changes proposed or declined; withdrawn if the order is
--      cancelled. erp.document_line keeps the supplier's confirmed quantity
--      and date beside ours.
--   B. A link per send (erp.supplier_response_link): a random token, its
--      digest kept and the token itself only in the email, minted as the
--      dispatch worker claims the send (erp.claim_document_email_batch gains
--      response_token). A retried send keeps the links it minted, so whichever
--      copy the provider delivered works; a later send revokes them. Thirty
--      days.
--   C. The supplier's page reaches the database through a server function on
--      the service role, never as anon: erp_supplier_response_peek reads the
--      order a token names, erp_supplier_respond records the answer.
--   D. The buyer: erp_record_supplier_confirmation (an answer given by phone
--      or reply), erp_decide_supplier_changes (accept, which amends the
--      quantities through erp.amend_document_line and records the dates, or
--      reject, which asks the supplier again), and erp_cancel_sent_order.
--   E. purchase_order gains cancel_sent, sent → cancelled, refused once
--      anything of the order has been received. Procurement lifecycle
--      version 4. An order already sent on version 3 stays on version 3 (D11)
--      and is refused by name.
--   F. Planning reads the confirmed date where there is one
--      (erp.scheduled_supply).
--   G. procurement.policy gains confirmation_chase_days (3), read by the daily
--      job procurement.confirmation_overdue, which tells the order's buyer
--      once.
--   H. The supplier's page is /respond; the name is reserved.
--
-- Proved by erp_test.supplier_confirmation_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_SUPPLIER_LINK_UNKNOWN',
  'Answering an order through a link that is not one, has expired, or was replaced by a later send.',
  'The link is the only thing that lets a supplier answer without signing in, so a wrong or old one answers nothing.',
  'Use the link in the most recent email of the order, or reply to the buyer.');

select erp.register_refusal('CLOVEERP_ORDER_NOT_AWAITING_ANSWER',
  'Answering an order that has been answered already, or is no longer open.',
  'An answer the buyer has accepted, or an order received, closed or cancelled, is settled; a second answer would undo what was agreed.',
  'Reply to the buyer, who can send the order again for a new answer.');

select erp.register_refusal('CLOVEERP_CONFIRMATION_DECISION_UNKNOWN',
  'Answering an order with something other than confirming it or declining it.',
  'An order is taken, taken with changes, or declined; there is no other answer to record.',
  'Confirm the order, with any changed quantities or dates on its lines, or decline it with a reason.');

select erp.register_refusal('CLOVEERP_CONFIRMATION_LINE_INVALID',
  'Answering a line that is not on the order, for more than was ordered or none of it, or for a date before the order.',
  'A confirmation is about the lines that were ordered; more than was asked for is a new order, and nothing at all is declining the line.',
  'Give each changed line a quantity between one unit and what was ordered and a date on or after the order date, or decline the order.');

select erp.register_refusal('CLOVEERP_DECLINE_NEEDS_A_REASON',
  'Declining an order without saying why.',
  'A buyer told only "no" cannot find another supplier for the right reason.',
  'Say why the order is declined: out of stock, discontinued, price, lead time.');

select erp.register_refusal('CLOVEERP_NO_CHANGES_TO_DECIDE',
  'Accepting or rejecting a supplier''s changes when the supplier proposed none.',
  'There is nothing to accept or reject until the supplier proposes a change.',
  'Wait for the supplier''s answer, or record it for them.');

select erp.register_refusal('CLOVEERP_SENT_ORDER_CANNOT_CANCEL',
  'Cancelling an order that is not sent, has goods received against it, or was sent under a lifecycle without the move.',
  'Goods already received are owed for; an order with receipts is closed short or returned, not cancelled.',
  'Return what arrived and close the order, or, for an order sent before procurement was upgraded, ask the supplier and close it when the rest is settled.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.purchase_order.supplier_responded', 'en', 'Supplier answered the order', 'procurement',
   'Event raised when a supplier confirms an order, proposes changes to it, or declines it.'),
  ('event.purchase_order.supplier_responded', 'de', 'Lieferant hat die Bestellung beantwortet', 'procurement',
   'Ereignis, wenn ein Lieferant eine Bestellung bestätigt, Änderungen vorschlägt oder sie ablehnt.'),
  ('event.purchase_order.changes_decided', 'en', 'Supplier''s changes decided', 'procurement',
   'Event raised when the buyer accepts or rejects the changes a supplier proposed to an order.'),
  ('event.purchase_order.changes_decided', 'de', 'Änderungen des Lieferanten entschieden', 'procurement',
   'Ereignis, wenn der Einkäufer die vom Lieferanten vorgeschlagenen Änderungen annimmt oder ablehnt.'),
  ('job_handler.confirmation_overdue.name', 'en', 'Orders awaiting confirmation', 'procurement',
   'Job handler name (20261004990000).'),
  ('job_handler.confirmation_overdue.name', 'de', 'Unbestätigte Bestellungen', 'procurement', null)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('purchase_order.supplier_responded', 1, 'document', 'procurement', 'event.purchase_order.supplier_responded',
   'A supplier confirmed an order, proposed changes to it, or declined it; or the buyer recorded that answer.',
   '{"type":"object","required":["reference","status","via"],"properties":{"reference":{"type":"string"},"status":{"type":"string"},"via":{"type":"string"},"changed_lines":{"type":"integer"}}}'::jsonb, true),
  ('purchase_order.changes_decided', 1, 'document', 'procurement', 'event.purchase_order.changes_decided',
   'The buyer accepted or rejected the changes a supplier proposed to an order.',
   '{"type":"object","required":["reference","accepted"],"properties":{"reference":{"type":"string"},"accepted":{"type":"boolean"},"amended_lines":{"type":"integer"}}}'::jsonb, true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code in ('purchase_order.supplier_responded', 'purchase_order.changes_decided')
         and et.is_current and et.version = 1 and et.name_key = 'event.' || et.code) <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a confirmation event is declared already, and not as 20261004990000 declares it';
  end if;
end
$event$;

-- The supplier's page, /respond, is a top-level route: no organisation may
-- take it as its address.
insert into erp_meta.reserved_tenant_code (code, reason)
values ('respond', 'a top-level route of the application: the supplier''s answer to a purchase order (20261004990000)')
on conflict (code) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The tables and columns
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.document_line add column if not exists confirmed_quantity numeric(20,6);
alter table erp.document_line add column if not exists confirmed_date date;

comment on column erp.document_line.confirmed_quantity is
  'What the supplier confirmed it will deliver of a purchase order line (20261004990000).';
comment on column erp.document_line.confirmed_date is
  'When the supplier confirmed it will deliver a purchase order line; planning reads it before the date we asked for (20261004990000).';

create table if not exists erp.purchase_order_confirmation (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  order_id          uuid not null,
  status            text not null default 'awaiting',
  awaiting_since    timestamptz not null default now(),
  responded_at      timestamptz,
  responded_via     text,
  responded_by      uuid,
  supplier_reference text,
  note              text,
  proposal          jsonb not null default '[]'::jsonb,
  decided_at        timestamptz,
  decided_by        uuid,
  decision_note     text,
  chased_at         timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint purchase_order_confirmation_tenant_id_id_key unique (tenant_id, id),
  constraint purchase_order_confirmation_one_per_order unique (tenant_id, order_id),
  constraint purchase_order_confirmation_order_fk foreign key (tenant_id, order_id)
    references erp.document(tenant_id, id) on delete restrict,
  constraint purchase_order_confirmation_status_known check
    (status in ('awaiting', 'confirmed', 'changes_proposed', 'declined', 'withdrawn')),
  constraint purchase_order_confirmation_via_known check
    (responded_via is null or responded_via in ('supplier', 'buyer')),
  constraint purchase_order_confirmation_proposal_is_a_list check (jsonb_typeof(proposal) = 'array')
);

comment on table erp.purchase_order_confirmation is
  'A sent purchase order''s answer from its supplier (20261004990000): awaiting, confirmed, changes '
  'proposed or declined, who answered and how, and the buyer''s decision on any changes.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'purchase_order_confirmation', 'tenant_scoped',
   'One per sent purchase order: its state moves as the supplier answers and the buyer decides, so not append-only.')
on conflict (schema_name, table_name) do nothing;

create table if not exists erp.supplier_response_link (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  order_id          uuid not null,
  document_email_id uuid not null,
  token_digest      text not null unique,
  expires_at        timestamptz not null,
  revoked_at        timestamptz,
  revoked_reason    text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint supplier_response_link_tenant_id_id_key unique (tenant_id, id),
  constraint supplier_response_link_order_fk foreign key (tenant_id, order_id)
    references erp.document(tenant_id, id) on delete restrict,
  constraint supplier_response_link_send_fk foreign key (tenant_id, document_email_id)
    references erp.document_email(tenant_id, id) on delete restrict,
  constraint supplier_response_link_digest_shape check (token_digest ~ '^[0-9a-f]{64}$')
);

create index if not exists supplier_response_link_order on erp.supplier_response_link (tenant_id, order_id)
  where revoked_at is null;

comment on table erp.supplier_response_link is
  'A link a supplier answers a purchase order through, one per claim of a send (20261004990000): the '
  'SHA-256 digest of a random token whose only copy went into the email, when it expires and whether a '
  'later send revoked it.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'supplier_response_link', 'tenant_scoped',
   'A supplier''s answer link per send: a digest, an expiry and a revocation, revoked when the order is sent again.')
on conflict (schema_name, table_name) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The policy: how long an order may wait
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.config_type
   set value_schema = jsonb_set(value_schema, '{properties,confirmation_chase_days}',
                                '{"type": "integer", "minimum": 1, "maximum": 60}'::jsonb),
       default_value = default_value || '{"confirmation_chase_days": 3}'::jsonb,
       clean_path = clean_path || ' An order its supplier has not answered in three days is flagged to its buyer.'
 where code = 'procurement.policy'
   and not (value_schema -> 'properties' ? 'confirmation_chase_days');

do $policy$
begin
  if (select (ct.default_value ->> 'confirmation_chase_days')::integer from erp_ref.config_type ct
       where ct.code = 'procurement.policy') is distinct from 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: procurement.policy does not carry confirmation_chase_days as 20261004990000 declares it';
  end if;
end
$policy$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Sending awaits an answer, and every send carries a link
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.await_supplier_confirmation(p_order uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  -- A sent order awaits its supplier's answer (20261004990000). Sent again,
  -- it awaits a new one: whatever was agreed is asked again.
  insert into erp.purchase_order_confirmation (tenant_id, order_id, status, awaiting_since)
  values (v_tenant, p_order, 'awaiting', now())
  on conflict (tenant_id, order_id) do update
     set status = 'awaiting', awaiting_since = now(), chased_at = null, updated_at = now()
  returning id into v_id;

  -- The daily look for orders nobody answered, installed with the first
  -- order sent; a job somebody switched off stays off.
  if not exists (select 1 from erp.job j
                  where j.tenant_id = v_tenant and j.handler_code = 'procurement.confirmation_overdue') then
    perform erp.upsert_job('confirmation_overdue', 'Orders awaiting confirmation', 'procurement.confirmation_overdue',
                           'daily', null, time '07:00', null, null, 'UTC', '{}'::jsonb, 120, null, true);
  end if;
  return v_id;
end;
$$;

revoke all on function erp.await_supplier_confirmation(uuid) from public, anon;

comment on function erp.await_supplier_confirmation(uuid) is
  'A sent purchase order awaits its supplier''s answer; sent again, a new one (20261004990000).';

-- The hook, in erp.transition_document(), after landed cost's. Edited, not
-- rewritten: one anchor over the body 20261004970000 left (md5 d2712316…).

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    perform erp.capitalise_landed_cost(p_document_id);
  end if;
$o$;
  v_new  constant text := $n$    perform erp.capitalise_landed_cost(p_document_id);
  end if;

  -- A purchase order sent to its supplier awaits the supplier's answer
  -- (20261004990000).
  if dt.base_type_code = 'purchase_order' and p_transition_code = 'send' then
    perform erp.await_supplier_confirmation(p_document_id);
  end if;
$n$;
begin
  if strpos(v_src, '20261004990000') > 0 then
    raise notice '% already awaits a supplier''s answer; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd271231683ac4490905abb3791b8dcf9' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004990000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- The claim, restated with the link it mints. Its result gains a column, so
-- it is dropped and made again; the body is 20261004920000's, checked first.

do $claim_check$
declare
  v_src text := (select p.prosrc from pg_proc p where p.oid = 'erp.claim_document_email_batch(integer,text)'::regprocedure);
begin
  if strpos(v_src, '20261004990000') = 0 and strpos(v_src, 'The kill switch and a demonstration') = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.claim_document_email_batch is not the body 20261004990000 restates';
  end if;
end
$claim_check$;

drop function if exists erp.claim_document_email_batch(integer, text);

create function erp.claim_document_email_batch(p_limit integer, p_worker text)
returns table(id uuid, document_kind text, to_address text, to_name text, cc_addresses text[],
              from_address text, from_name text, reply_to text, message text, idempotency_key text,
              attempt integer, issued_number text, organisation_name text, payload jsonb,
              response_token text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_ids    uuid[];
  v_tokens jsonb := '{}'::jsonb;
  m        record;
  v_raw    text;
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
    select x.id
      from erp.document_email x
     where x.tenant_id = v_tenant
       and (x.status = 'queued' or (x.status = 'sending' and x.lease_expires_at < now()))
     order by x.created_at
     limit greatest(p_limit, 1)
     for update skip locked
  ),
  marked as (
    update erp.document_email x
       set status = 'sending', claimed_by = coalesce(p_worker, current_user), claimed_at = now(),
           lease_expires_at = now() + interval '5 minutes', attempts = x.attempts + 1, updated_at = now()
      from claimed c
     where x.id = c.id
     returning x.id
  )
  select coalesce(array_agg(mk.id), '{}'::uuid[]) into v_ids from marked mk;

  -- A purchase order's send carries the link its supplier answers through
  -- (20261004990000). Minted per claim and kept for the send, so a retried
  -- send whose first copy the provider delivered still answers; the first
  -- claim of a later send revokes the links of every earlier one. The token's
  -- only copy goes into the email; the table keeps its digest.
  for m in
    select x.id, x.document_id, x.attempts from erp.document_email x
     where x.tenant_id = v_tenant and x.id = any (v_ids) and x.document_kind = 'purchase_order'
  loop
    if m.attempts = 1 then
      update erp.supplier_response_link l
         set revoked_at = now(), revoked_reason = 'the order was sent again', updated_at = now()
       where l.tenant_id = v_tenant and l.order_id = m.document_id
         and l.document_email_id <> m.id and l.revoked_at is null;
      -- Sent again, it is asked again: what was agreed was agreed to the
      -- copy before.
      if exists (select 1 from erp.document_email e
                  where e.tenant_id = v_tenant and e.document_id = m.document_id and e.id <> m.id)
         and exists (select 1 from erp.purchase_order_confirmation c
                      where c.tenant_id = v_tenant and c.order_id = m.document_id and c.status <> 'withdrawn') then
        perform erp.await_supplier_confirmation(m.document_id);
      end if;
    end if;
    v_raw := encode(extensions.gen_random_bytes(32), 'hex');
    insert into erp.supplier_response_link (tenant_id, order_id, document_email_id, token_digest, expires_at)
    values (v_tenant, m.document_id, m.id, encode(extensions.digest(v_raw, 'sha256'), 'hex'),
            now() + interval '30 days');
    v_tokens := v_tokens || jsonb_build_object(m.id::text, v_raw);
  end loop;

  return query
    select x.id, x.document_kind, x.to_address, x.to_name, x.cc_addresses, x.from_address, x.from_name,
           x.reply_to, x.message, x.idempotency_key, x.attempts, i.issued_number,
           (select t.name from erp.tenant t where t.id = v_tenant), i.contract_snapshot,
           v_tokens ->> x.id::text
      from erp.document_email x
      join erp.document_issue i on i.tenant_id = x.tenant_id and i.id = x.document_issue_id
     where x.tenant_id = v_tenant and x.id = any (v_ids)
     order by x.created_at;
end;
$$;

revoke all on function erp.claim_document_email_batch(integer, text) from public, anon;

comment on function erp.claim_document_email_batch(integer, text) is
  'Claims an organisation''s queued outgoing documents for the dispatch worker, with the frozen payload '
  'each is rendered from (20261004920000) and, for a purchase order, the token of the link its supplier '
  'answers through, whose only copy this is (20261004990000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The answer
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.purchase_order_answerable(p_order uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether an order may still be answered by its supplier (20261004990000):
  -- sent or received in part, and awaiting an answer or with changes the
  -- buyer has not decided.
  select coalesce((
    select erp.object_current_state('document', p_order) in ('sent', 'partially_received')
       and c.status in ('awaiting', 'changes_proposed')
      from erp.purchase_order_confirmation c
     where c.tenant_id = erp.current_tenant_id() and c.order_id = p_order), false)
$$;

revoke all on function erp.purchase_order_answerable(uuid) from public, anon;

create or replace function erp.record_supplier_response(p_order uuid, p_response jsonb, p_via text, p_by uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  c          erp.purchase_order_confirmation%rowtype;
  v_decision text := lower(btrim(coalesce(p_response ->> 'decision', '')));
  v_note     text := nullif(btrim(coalesce(p_response ->> 'note', '')), '');
  v_ref      text := nullif(btrim(coalesce(p_response ->> 'supplier_reference', '')), '');
  v_lines    jsonb := coalesce(p_response -> 'lines', '[]'::jsonb);
  x          jsonb;
  l          erp.document_line%rowtype;
  v_qty      numeric;
  v_date     date;
  v_proposal jsonb := '[]'::jsonb;
  v_status   text;
begin
  -- An order's answer (20261004990000), from its supplier's link or recorded
  -- by its buyer. Confirm, with each changed line's quantity and date, or
  -- decline with a reason. A change to any line is a proposal the buyer
  -- decides; an answer that changes nothing confirms the order as ordered.
  select x2.* into d from erp.document x2 where x2.tenant_id = v_tenant and x2.id = p_order for update;
  select x2.* into c from erp.purchase_order_confirmation x2 where x2.tenant_id = v_tenant and x2.order_id = p_order
     for update;
  if d.id is null or c.id is null or c.status = 'withdrawn'
     or erp.object_current_state('document', p_order) not in ('sent', 'partially_received')
     or (p_via = 'supplier' and c.status not in ('awaiting', 'changes_proposed')) then
    raise exception 'CLOVEERP_ORDER_NOT_AWAITING_ANSWER: % is not awaiting an answer', coalesce(d.document_number, 'the order')
      using errcode = '23514', hint = 'Reply to the buyer, who can send the order again for a new answer.';
  end if;
  if v_decision not in ('confirm', 'decline') then
    raise exception 'CLOVEERP_CONFIRMATION_DECISION_UNKNOWN: % is not an answer to an order', coalesce(p_response ->> 'decision', 'nothing')
      using errcode = '22023',
            hint = 'Confirm the order, with any changed quantities or dates on its lines, or decline it with a reason.';
  end if;
  if v_decision = 'decline' and v_note is null then
    raise exception 'CLOVEERP_DECLINE_NEEDS_A_REASON: % was declined without a reason', d.document_number
      using errcode = '23514', hint = 'Say why the order is declined: out of stock, discontinued, price, lead time.';
  end if;

  if v_decision = 'confirm' then
    if jsonb_typeof(v_lines) <> 'array' then
      v_lines := '[]'::jsonb;
    end if;
    for x in select value from jsonb_array_elements(v_lines) loop
      select x2.* into l from erp.document_line x2
       where x2.tenant_id = v_tenant and x2.document_id = p_order and not x2.is_cancelled
         and x2.id::text = (x ->> 'line_id');
      v_qty := coalesce(nullif(x ->> 'quantity', '')::numeric, l.quantity);
      v_date := nullif(x ->> 'date', '')::date;
      if l.id is null or v_qty <= 0 or v_qty > l.quantity or (v_date is not null and v_date < d.document_date) then
        raise exception 'CLOVEERP_CONFIRMATION_LINE_INVALID: line % of % cannot be answered with % by %',
          coalesce(l.line_no::text, x ->> 'line_id', '?'), d.document_number, coalesce(x ->> 'quantity', 'its quantity'),
          coalesce(x ->> 'date', 'its date')
          using errcode = '22023',
                hint = 'Give each changed line a quantity between one unit and what was ordered and a date on or after the order date, or decline the order.';
      end if;
      if v_qty <> l.quantity
         or (v_date is not null and v_date is distinct from coalesce(l.required_date, d.required_date)) then
        v_proposal := v_proposal || jsonb_build_object(
          'line_id', l.id, 'line_no', l.line_no, 'ordered_quantity', l.quantity, 'quantity', v_qty,
          'required_date', coalesce(l.required_date, d.required_date), 'date', coalesce(v_date, l.required_date, d.required_date));
      end if;
    end loop;
    v_status := case when jsonb_array_length(v_proposal) = 0 then 'confirmed' else 'changes_proposed' end;
  else
    v_status := 'declined';
  end if;

  update erp.purchase_order_confirmation
     set status = v_status, responded_at = now(), responded_via = p_via, responded_by = p_by,
         supplier_reference = coalesce(v_ref, supplier_reference), note = v_note,
         proposal = v_proposal, decided_at = null, decided_by = null, updated_at = now()
   where id = c.id;

  -- Confirmed as ordered: every line at what we ordered and when we asked.
  if v_status = 'confirmed' then
    update erp.document_line x2
       set confirmed_quantity = x2.quantity, confirmed_date = coalesce(x2.required_date, d.required_date),
           updated_at = now()
     where x2.tenant_id = v_tenant and x2.document_id = p_order and not x2.is_cancelled;
  end if;

  perform erp.append_event('purchase_order.supplier_responded', 'document', p_order,
    jsonb_build_object('reference', d.document_number, 'status', v_status, 'via', p_via,
                       'changed_lines', jsonb_array_length(v_proposal)),
    d.entity_id, d.site_id);

  -- The buyer hears of an answer that asks something of them.
  if p_via = 'supplier' and v_status in ('changes_proposed', 'declined') and d.created_by is not null then
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (v_tenant, (case v_status when 'declined' then 'high' else 'medium' end)::erp.notification_severity, d.created_by, 'in_app',
            case v_status when 'declined' then format('The supplier declined order %s', d.document_number)
                          else format('The supplier proposed changes to order %s', d.document_number) end,
            case v_status when 'declined' then format('Their reason: %s. Cancel the order or send it elsewhere from its page.', v_note)
                          else format('%s line(s) changed. Accept or reject the changes on the order''s page.', jsonb_array_length(v_proposal)) end,
            'delivered', now(), now());
  end if;

  return erp.purchase_order_confirmation(p_order);
end;
$$;

revoke all on function erp.record_supplier_response(uuid, jsonb, text, uuid) from public, anon;

comment on function erp.record_supplier_response(uuid, jsonb, text, uuid) is
  'Records an order''s answer, from its supplier''s link or by its buyer: confirmed, changes proposed or '
  'declined (20261004990000). Called by erp.supplier_respond and erp.record_supplier_confirmation, which '
  'authorise.';

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The supplier's page: a token, through the service role
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.supplier_link(p_token text)
returns erp.supplier_response_link
language sql
stable
security definer
set search_path = ''
as $$
  -- The link a token names, while it holds (20261004990000): not revoked,
  -- not expired. Read by digest, so the token is never compared or kept.
  select l.* from erp.supplier_response_link l
   where p_token ~ '^[0-9a-f]{64}$'
     and l.token_digest = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and l.revoked_at is null and l.expires_at > now()
$$;

revoke all on function erp.supplier_link(text) from public, anon, authenticated;

comment on function erp.supplier_link(text) is
  'The supplier answer link a token names while it holds (20261004990000). UNGATED BY DESIGN: the token '
  'is the authority; called by the two service-role doors only.';

create or replace function public.erp_supplier_response_peek(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  -- The order a supplier's link names, as the supplier may see it
  -- (20261004990000): what the PDF already showed them, the lines as they
  -- stand, and where the answer is. Null for a token that is not one, so a
  -- wrong guess learns nothing. Runs as its owner because the caller is no
  -- organisation; every read is held to the link's own.
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
           'expires_at', lk.expires_at,
           'lines', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'line_id', l.id, 'line_no', l.line_no,
                      'description', coalesce(l.description, i.name),
                      'item_code', i.code, 'supplier_item_code', l.supplier_item_code,
                      'quantity', l.quantity, 'uom', u.code,
                      'unit_price_minor', l.unit_price_minor,
                      'required_date', coalesce(l.required_date, d.required_date),
                      'confirmed_quantity', l.confirmed_quantity, 'confirmed_date', l.confirmed_date)
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

comment on function public.erp_supplier_response_peek(text) is
  'The order a supplier''s answer link names, as the supplier may see it, or null (20261004990000). '
  'Executed by service_role alone, from src/lib/supplier-response.functions.ts.';

create or replace function erp.supplier_respond(p_token text, p_response jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  lk erp.supplier_response_link%rowtype;
begin
  -- A supplier's answer through its link (20261004990000): the link is the
  -- authority, so a link that does not hold answers nothing. The work is
  -- done in the link's organisation, as nobody, on a trusted connection.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not answer for a supplier', current_user
      using errcode = '42501', hint = 'The supplier''s page answers through the server, never from the browser.';
  end if;
  select (erp.supplier_link(p_token)).* into lk;
  if lk.id is null then
    raise exception 'CLOVEERP_SUPPLIER_LINK_UNKNOWN: that link answers no order'
      using errcode = '42501', hint = 'Use the link in the most recent email of the order, or reply to the buyer.';
  end if;
  perform erp.set_job_tenant(lk.tenant_id);
  perform set_config('erp.job_principal_id', '', true);
  return erp.record_supplier_response(lk.order_id, p_response, 'supplier', null);
end;
$$;

revoke all on function erp.supplier_respond(text, jsonb) from public, anon;

create or replace function public.erp_supplier_respond(p_token text, p_response jsonb)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select erp.supplier_respond(p_token, p_response) $$;

revoke all on function public.erp_supplier_respond(text, jsonb) from public, anon, authenticated;
grant execute on function public.erp_supplier_respond(text, jsonb) to service_role;

comment on function public.erp_supplier_respond(text, jsonb) is
  'A supplier''s answer to a purchase order through its link (20261004990000). Executed by service_role '
  'alone, from src/lib/supplier-response.functions.ts.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'supplier_link',
   'UNGATED BY DESIGN: the token is the authority. Runs as its owner to read a link by the digest of its '
   'token; returns one link while it holds. Called only by the two service-role doors below.'),
  ('public', 'erp_supplier_response_peek',
   'UNGATED BY DESIGN: a supplier is no principal and has no organisation; the link''s token is the '
   'authority. Executable by service_role alone, from the server function behind /respond. Runs as its '
   'owner because the caller has no tenant; every read is held to the link''s own organisation and order, '
   'and answers null for a token that is not one. erp_test.supplier_confirmation_suite proves it.'),
  ('public', 'erp_supplier_respond',
   'UNGATED BY DESIGN: as erp_supplier_response_peek, the token is the authority. Executable by service_role '
   'alone; erp.supplier_respond refuses an untrusted session and a link that does not hold, then works in '
   'the link''s organisation as nobody.')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale, ungated_because) values
  ('erp_supplier_respond', 'erp.supplier_respond',
   'Records a supplier''s answer to a purchase order through the link in its email: confirmed, changes '
   'proposed or declined. The link''s token is the authority; service_role only, from the server function behind /respond.',
   'bearer_token')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale,
  ungated_because = excluded.ungated_because;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The buyer
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.purchase_order_confirmation(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A purchase order's answer, as its page reads it (20261004990000): the
  -- status, who answered and how, the supplier's reference and note, any
  -- proposed changes, the buyer's decision, and what the reader may do.
  select jsonb_build_object(
           'order_id', d.id, 'order', d.document_number,
           'state', erp.object_current_state('document', d.id),
           'status', c.status, 'awaiting_since', c.awaiting_since,
           'responded_at', c.responded_at, 'responded_via', c.responded_via,
           'supplier_reference', c.supplier_reference, 'note', c.note,
           'proposal', coalesce(c.proposal, '[]'::jsonb),
           'decided_at', c.decided_at, 'decision_note', c.decision_note,
           'received_any', exists (select 1 from erp.document_line l
                                    where l.tenant_id = d.tenant_id and l.document_id = d.id
                                      and coalesce(l.quantity_fulfilled, 0) > 0),
           'lines', coalesce((select jsonb_agg(jsonb_build_object(
                       'line_id', l.id, 'line_no', l.line_no, 'description', coalesce(l.description, i.name),
                       'quantity', l.quantity, 'required_date', coalesce(l.required_date, d.required_date),
                       'confirmed_quantity', l.confirmed_quantity, 'confirmed_date', l.confirmed_date) order by l.line_no)
                        from erp.document_line l
                        left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
                       where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled), '[]'::jsonb),
           'may_record', erp.has_permission('procurement.order', d.entity_id, d.site_id),
           'may_cancel', erp.has_permission('procurement.approve', d.entity_id, d.site_id))
    from erp.document d
    left join erp.purchase_order_confirmation c on c.tenant_id = d.tenant_id and c.order_id = d.id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_order and c.id is not null
$$;

revoke all on function erp.purchase_order_confirmation(uuid) from public, anon;

create or replace function public.erp_purchase_order_confirmation(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.purchase_order_confirmation(p_order) $$;

revoke all on function public.erp_purchase_order_confirmation(uuid) from public, anon;
grant execute on function public.erp_purchase_order_confirmation(uuid) to authenticated, service_role;

comment on function public.erp_purchase_order_confirmation(uuid) is
  'A sent purchase order''s answer from its supplier, for its page (20261004990000).';

create or replace function erp.record_supplier_confirmation(p_order uuid, p_response jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d erp.document%rowtype;
begin
  -- An answer the supplier gave by phone or reply, recorded by the buyer
  -- (20261004990000).
  select x.* into d from erp.document x where x.tenant_id = erp.require_tenant_id() and x.id = p_order;
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', p_order);
  return erp.record_supplier_response(p_order, p_response, 'buyer', erp.current_principal_id());
end;
$$;

revoke all on function erp.record_supplier_confirmation(uuid, jsonb) from public, anon;

create or replace function public.erp_record_supplier_confirmation(p_order uuid, p_response jsonb)
returns jsonb
language sql
set search_path = ''
as $$ select erp.record_supplier_confirmation(p_order, p_response) $$;

revoke all on function public.erp_record_supplier_confirmation(uuid, jsonb) from public, anon;
grant execute on function public.erp_record_supplier_confirmation(uuid, jsonb) to authenticated, service_role;

comment on function public.erp_record_supplier_confirmation(uuid, jsonb) is
  'Records the supplier''s answer to an order on their behalf (20261004990000). Authorises procurement.order.';

create or replace function erp.decide_supplier_changes(p_order uuid, p_accept boolean, p_note text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  c        erp.purchase_order_confirmation%rowtype;
  x        jsonb;
  v_amended integer := 0;
begin
  -- The buyer's decision on a supplier's proposed changes (20261004990000).
  -- Accepted: each changed quantity through the amendment door, which asks
  -- what any change to the order asks, and every line's confirmed quantity
  -- and date. Rejected: the order awaits a new answer, with the buyer's note.
  select x2.* into d from erp.document x2 where x2.tenant_id = v_tenant and x2.id = p_order;
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', p_order);
  select x2.* into c from erp.purchase_order_confirmation x2
   where x2.tenant_id = v_tenant and x2.order_id = p_order for update;
  if c.id is null or c.status <> 'changes_proposed' then
    raise exception 'CLOVEERP_NO_CHANGES_TO_DECIDE: % has no changes waiting', coalesce(d.document_number, 'the order')
      using errcode = '23514', hint = 'Wait for the supplier''s answer, or record it for them.';
  end if;

  if p_accept then
    for x in select value from jsonb_array_elements(c.proposal) loop
      if (x ->> 'quantity')::numeric <> (x ->> 'ordered_quantity')::numeric then
        perform erp.amend_document_line((x ->> 'line_id')::uuid, (x ->> 'quantity')::numeric,
          format('the supplier confirmed %s of %s%s', x ->> 'quantity', x ->> 'ordered_quantity',
                 case when c.supplier_reference is null then '' else ' (' || c.supplier_reference || ')' end));
        v_amended := v_amended + 1;
      end if;
    end loop;
    update erp.document_line l
       set confirmed_quantity = l.quantity,
           confirmed_date = coalesce((select (x2 ->> 'date')::date from jsonb_array_elements(c.proposal) x2
                                       where x2 ->> 'line_id' = l.id::text),
                                     l.required_date, d.required_date),
           updated_at = now()
     where l.tenant_id = v_tenant and l.document_id = p_order and not l.is_cancelled;
    update erp.purchase_order_confirmation
       set status = 'confirmed', decided_at = now(), decided_by = erp.current_principal_id(),
           decision_note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now()
     where id = c.id;
  else
    update erp.purchase_order_confirmation
       set status = 'awaiting', awaiting_since = now(), chased_at = null, decided_at = now(),
           decided_by = erp.current_principal_id(), decision_note = nullif(btrim(coalesce(p_note, '')), ''),
           updated_at = now()
     where id = c.id;
  end if;

  perform erp.append_event('purchase_order.changes_decided', 'document', p_order,
    jsonb_build_object('reference', d.document_number, 'accepted', p_accept, 'amended_lines', v_amended),
    d.entity_id, d.site_id);
  return erp.purchase_order_confirmation(p_order);
end;
$$;

revoke all on function erp.decide_supplier_changes(uuid, boolean, text) from public, anon;

create or replace function public.erp_decide_supplier_changes(p_order uuid, p_accept boolean, p_note text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.decide_supplier_changes(p_order, p_accept, p_note) $$;

revoke all on function public.erp_decide_supplier_changes(uuid, boolean, text) from public, anon;
grant execute on function public.erp_decide_supplier_changes(uuid, boolean, text) to authenticated, service_role;

comment on function public.erp_decide_supplier_changes(uuid, boolean, text) is
  'Accepts or rejects the changes a supplier proposed to an order (20261004990000). Authorises procurement.order.';

create or replace function erp.cancel_sent_order(p_order uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
begin
  -- A sent order the supplier will not fill, cancelled while nothing of it
  -- has been received (20261004990000; owner). Its answer is withdrawn and
  -- its links stop answering.
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = p_order for update;
  perform erp.authorise('procurement.approve', d.entity_id, d.site_id, null, 'document', p_order);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_REASON_REQUIRED: cancelling a sent order needs a reason'
      using errcode = '23514', hint = 'Say why the order is cancelled, so the supplier and the auditor can read it.';
  end if;
  if d.id is null or erp.object_current_state('document', p_order) <> 'sent'
     or exists (select 1 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = p_order
                   and coalesce(l.quantity_fulfilled, 0) > 0)
     or not exists (select 1 from erp.available_transitions('document', p_order) t where t.transition_code = 'cancel_sent') then
    raise exception 'CLOVEERP_SENT_ORDER_CANNOT_CANCEL: % cannot be cancelled', coalesce(d.document_number, 'the order')
      using errcode = '23514',
            hint = 'Return what arrived and close the order, or, for an order sent before procurement was upgraded, ask the supplier and close it when the rest is settled.';
  end if;

  perform erp.transition_document(p_order, 'cancel_sent', btrim(p_reason));
  update erp.purchase_order_confirmation
     set status = 'withdrawn', decision_note = btrim(p_reason), updated_at = now()
   where tenant_id = v_tenant and order_id = p_order;
  update erp.supplier_response_link
     set revoked_at = now(), revoked_reason = 'the order was cancelled', updated_at = now()
   where tenant_id = v_tenant and order_id = p_order and revoked_at is null;
  return jsonb_build_object('order_id', p_order, 'order', d.document_number,
                            'state', erp.object_current_state('document', p_order));
end;
$$;

revoke all on function erp.cancel_sent_order(uuid, text) from public, anon;

create or replace function public.erp_cancel_sent_order(p_order uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.cancel_sent_order(p_order, p_reason) $$;

revoke all on function public.erp_cancel_sent_order(uuid, text) from public, anon;
grant execute on function public.erp_cancel_sent_order(uuid, text) to authenticated, service_role;

comment on function public.erp_cancel_sent_order(uuid, text) is
  'Cancels a sent purchase order nothing has been received against (20261004990000). Authorises procurement.approve.';

create or replace function public.erp_awaiting_confirmations()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The sent orders still waiting on their supplier, longest first, with
  -- those whose supplier proposed changes or declined beside them
  -- (20261004990000).
  select coalesce(jsonb_agg(x order by (x ->> 'status') = 'awaiting', x ->> 'awaiting_since'), '[]'::jsonb) from (
    select jsonb_build_object(
             'order_id', d.id, 'order', d.document_number, 'supplier', p.name,
             'status', c.status, 'awaiting_since', c.awaiting_since,
             'days_waiting', (current_date - c.awaiting_since::date),
             'overdue', c.status = 'awaiting'
               and c.awaiting_since < now() - make_interval(days =>
                     coalesce((erp.procurement_policy(d.entity_id, d.site_id) ->> 'confirmation_chase_days')::integer, 3))) as x
      from erp.purchase_order_confirmation c
      join erp.document d on d.tenant_id = c.tenant_id and d.id = c.order_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
     where c.tenant_id = erp.current_tenant_id()
       and c.status in ('awaiting', 'changes_proposed', 'declined')
       and erp.object_current_state('document', d.id) in ('sent', 'partially_received')) t
$$;

revoke all on function public.erp_awaiting_confirmations() from public, anon;
grant execute on function public.erp_awaiting_confirmations() to authenticated, service_role;

comment on function public.erp_awaiting_confirmations() is
  'Sent purchase orders still waiting on their supplier, or with an answer the buyer must act on (20261004990000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_record_supplier_confirmation', 'erp.record_supplier_confirmation',
   'Records a supplier''s answer to an order on their behalf: the confirmation, the lines, a note; authorises procurement.order.'),
  ('erp_decide_supplier_changes', 'erp.decide_supplier_changes',
   'Accepts a supplier''s changes, amending quantities through erp.amend_document_line, or rejects them; authorises procurement.order.'),
  ('erp_cancel_sent_order', 'erp.cancel_sent_order',
   'Cancels a sent order nothing has been received against, withdraws its answer and revokes its links; authorises procurement.approve.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement',
  array['erp_record_supplier_confirmation', 'erp_decide_supplier_changes', 'erp_cancel_sent_order']);

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The cancel move: procurement lifecycle version 4
-- ═════════════════════════════════════════════════════════════════════════════

do $lifecycle$
declare
  v_sig  constant text := 'erp.procurement_lifecycle_items(text,bigint,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),$o$;
  v_new  constant text := $n$            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve'),
            -- A sent order nothing was received against (20261004990000),
            -- moved only by erp.cancel_sent_order, which checks the receipts.
            jsonb_build_object('code','cancel_sent','name','Cancel','from','sent','to','cancelled','required_permission','procurement.approve')))),$n$;
begin
  if strpos(v_src, '20261004990000') > 0 then
    raise notice '% already cancels a sent order; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '38f9f23f018cf35895caee034e856905' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004990000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lifecycle$;

update erp_ref.module_installer
   set current_version = 4,
       description = description
         || ' Version 4 (20261004990000): a sent order nothing was received against can be cancelled.'
 where install_code = 'procurement-lifecycle' and current_version = 3;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-lifecycle', 4, x.value ->> 'kind', x.value ->> 'key', (x.value -> 'payload') - 'entity', 110
  from jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
 where (x.value ->> 'kind', x.value ->> 'key') = ('state_machine', 'purchase_order')
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-lifecycle') is distinct from 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement lifecycle installer is not at version 4';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 4
         and ui.payload -> 'transitions' @> '[{"code": "cancel_sent"}]'::jsonb) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 4 of procurement lifecycle is not the purchase order with cancel_sent';
  end if;
end
$register$;

-- Driven by a routine: the register names it. Edited, not rewritten: one
-- anchor over the body 20261002500000 left (md5 069f814e…).

do $drivers$
declare
  v_sig  constant text := 'erp.transition_driver_register()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$'erp.cancel_shipment(uuid,text)')
    ) as x(machine_code, transition_code, driver, detail)$o$;
  v_new  constant text := $n$'erp.cancel_shipment(uuid,text)'),
      ('purchase_order',       'cancel_sent',               'routine', 'erp.cancel_sent_order(uuid,text)')
    ) as x(machine_code, transition_code, driver, detail)$n$;
begin
  if strpos(v_src, 'cancel_sent_order') > 0 then
    raise notice '% already names cancel_sent; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '069f814e3c3d3f270e3a3262b56ca87f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004990000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$drivers$;

-- ═════════════════════════════════════════════════════════════════════════════
-- I. Planning reads the date the supplier gave
-- ═════════════════════════════════════════════════════════════════════════════

do $supply$
declare
  v_sig  constant text := 'erp.scheduled_supply(uuid,uuid,date,date,boolean)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(dl.required_date, d.required_date, d.document_date),$o$;
  v_new  constant text := $n$  -- When the supplier said it would come, before when we asked (20261004990000).
  select coalesce(dl.confirmed_date, dl.required_date, d.required_date, d.document_date),$n$;
begin
  if strpos(v_src, '20261004990000') > 0 then
    raise notice '% already reads the confirmed date; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '2dde1ae789368065505f8dafedffb2c6' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004990000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$supply$;

-- ═════════════════════════════════════════════════════════════════════════════
-- J. The daily look for orders nobody answered
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.notify_unconfirmed_orders()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_n      integer := 0;
begin
  -- Sent orders whose supplier has not answered within the procurement
  -- policy's days (20261004990000): their buyer is told once, until the
  -- order is sent again.
  for r in
    select c.id, d.document_number, d.created_by, p.name as supplier,
           current_date - c.awaiting_since::date as days
      from erp.purchase_order_confirmation c
      join erp.document d on d.tenant_id = c.tenant_id and d.id = c.order_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
     where c.tenant_id = v_tenant and c.status = 'awaiting' and c.chased_at is null
       and d.created_by is not null
       and erp.object_current_state('document', d.id) = 'sent'
       and c.awaiting_since < now() - make_interval(days =>
             coalesce((erp.procurement_policy(d.entity_id, d.site_id) ->> 'confirmation_chase_days')::integer, 3))
       for update of c
  loop
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (v_tenant, 'medium', r.created_by, 'in_app',
            format('%s has not confirmed order %s', coalesce(r.supplier, 'The supplier'), r.document_number),
            format('It was sent %s day(s) ago and is still unanswered. Chase the supplier, or record their answer on the order''s page.', r.days),
            'delivered', now(), now());
    update erp.purchase_order_confirmation set chased_at = now(), updated_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function erp.notify_unconfirmed_orders() from public, anon;

comment on function erp.notify_unconfirmed_orders() is
  'The daily look for sent purchase orders nobody answered within the procurement policy''s days: tells '
  'each order''s buyer once (20261004990000). Run by the job procurement.confirmation_overdue.';

insert into erp_ref.job_handler (code, name_key, description, module_code, parameter_schema,
                                 default_timeout_seconds, forbids_overlap, is_current, sql_function,
                                 default_max_silence_seconds)
values ('procurement.confirmation_overdue', 'job_handler.confirmation_overdue.name',
        'Tells a purchase order''s buyer when its supplier has not answered it within the procurement policy''s days (20261004990000).',
        'procurement', '{"type":"object"}'::jsonb, 120, true, true, 'notify_unconfirmed_orders', 172800)
on conflict (code) do update set name_key = excluded.name_key, description = excluded.description,
  sql_function = excluded.sql_function, is_current = true;

-- ═════════════════════════════════════════════════════════════════════════════
-- K. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.supplier_confirmation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_look   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid;
  v_po uuid; v_po2 uuid; v_po3 uuid; v_l1 uuid; v_l2 uuid; v_mail uuid;
  v_tok text; v_tok2 text; v_peek jsonb; v_conf jsonb; v_n integer; v_n2 integer; v_supply date;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, a supplier, and a reader who may not order';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpoc-' || v_tag, 'Supplier Confirmation Suite',
      'admin@zzpoc-' || v_tag || '.test', 'Confirm Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzpoc-' || v_tag || '.test'), (s_look, 'looker@zzpoc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('looker@zzpoc-' || v_tag || '.test', 'Lou Looker');
    perform public.erp_save_role(null, 'po_looker', 'Looker', 'Reads purchasing', array['procurement.read']);
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'po_looker', null, null, 'reads');
    perform set_config('request.jwt.claims', json_build_object('sub', s_look)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCCOAT', 'Confirmed Coat', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCSCARF', 'Confirmed Scarf', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZCBRAND');

    -- Ten coats and ten scarves, approved and emailed to the supplier.
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZCO1', false);
    perform erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
    select l.id into v_l1 from erp.document_line l where l.document_id = v_po and l.item_id = v_item;
    select l.id into v_l2 from erp.document_line l where l.document_id = v_po and l.item_id = v_item2;
    res := public.erp_send_purchase_order(v_po, 'orders@zcbrand-' || v_tag || '.test', null, null, null);
    select t.response_token, t.id into v_tok, v_mail from erp.claim_document_email_batch(10, 'suite') t
     where t.document_kind = 'purchase_order' limit 1;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, the refusals, the events, the route, the policy and the lifecycle';
    v_cases := v_cases + 1;
    case_name := 'the buyer''s three write doors are on the allow-list under their gates and the supplier''s as a bearer token, the seven refusals are registered, both events are current in English and German, /respond is reserved, the policy waits three days, and procurement lifecycle 4 cancels a sent order';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance a
                where (a.function_name, a.gate) in (('erp_record_supplier_confirmation', 'erp.record_supplier_confirmation'),
                                                    ('erp_decide_supplier_changes', 'erp.decide_supplier_changes'),
                                                    ('erp_cancel_sent_order', 'erp.cancel_sent_order'))) = 3
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_supplier_respond' and a.ungated_because = 'bearer_token')
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_SUPPLIER_LINK_UNKNOWN', 'CLOVEERP_ORDER_NOT_AWAITING_ANSWER',
                                 'CLOVEERP_CONFIRMATION_DECISION_UNKNOWN', 'CLOVEERP_CONFIRMATION_LINE_INVALID',
                                 'CLOVEERP_DECLINE_NEEDS_A_REASON', 'CLOVEERP_NO_CHANGES_TO_DECIDE',
                                 'CLOVEERP_SENT_ORDER_CANNOT_CANCEL')
                  and coalesce(f.next_action, '') <> '') = 7
          and (select count(*) from erp_ref.resource x
                where x.key in ('event.purchase_order.supplier_responded', 'event.purchase_order.changes_decided')
                  and x.locale in ('en', 'de')) = 4
          and exists (select 1 from erp_meta.reserved_tenant_code r where r.code = 'respond')
          and (erp.procurement_policy(v_entity, v_site) ->> 'confirmation_chase_days')::integer = 3
          and exists (select 1 from erp.available_transitions('document', v_po) t where t.transition_code = 'cancel_sent');
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Sending awaits, and the email carries a link ─────────────────────
    v_step := 'the order as it went out';
    v_cases := v_cases + 1;
    case_name := 'a sent order awaits its supplier''s answer, its email carries a 64-character token whose digest alone is kept, and the daily look is installed';
    passed := v_state is null
          and erp.object_current_state('document', v_po) = 'sent'
          and (select c.status from erp.purchase_order_confirmation c where c.order_id = v_po) = 'awaiting'
          and v_tok ~ '^[0-9a-f]{64}$'
          and exists (select 1 from erp.supplier_response_link l
                       where l.order_id = v_po and l.document_email_id = v_mail
                         and l.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'))
          and not exists (select 1 from erp.supplier_response_link l where l.token_digest = v_tok)
          and exists (select 1 from erp.job j where j.tenant_id = rb.tenant_id and j.handler_code = 'procurement.confirmation_overdue');
    detail := coalesce(v_state, coalesce(left(v_tok, 8), 'no token'));
    return next;

    -- ── 3. The supplier's page reads the order, and nothing else ────────────
    v_step := 'the link read as the supplier''s page reads it';
    v_peek := public.erp_supplier_response_peek(v_tok);
    v_cases := v_cases + 1;
    case_name := 'the link shows the supplier their order, its two lines and that it awaits an answer; a token that is not one shows nothing';
    passed := v_state is null
          and v_peek ->> 'order' = (select d.document_number from erp.document d where d.id = v_po)
          and jsonb_array_length(v_peek -> 'lines') = 2
          and (v_peek ->> 'can_respond')::boolean
          and v_peek ->> 'status' = 'awaiting'
          and public.erp_supplier_response_peek(repeat('0', 64)) is null
          and public.erp_supplier_response_peek('not a token') is null;
    detail := coalesce(v_state, left(coalesce(v_peek::text, 'nothing'), 400));
    return next;

    -- ── 4. What the supplier may not say ────────────────────────────────────
    v_step := 'answers that are not answers';
    begin perform erp.supplier_respond(v_tok, '{"decision": "maybe"}'); v_err := 'answered';
    exception when others then v_err := sqlerrm; end;
    begin perform erp.supplier_respond(v_tok, '{"decision": "decline"}'); v_err2 := 'answered';
    exception when others then v_err2 := sqlerrm; end;
    begin perform erp.supplier_respond(v_tok, jsonb_build_object('decision', 'confirm',
            'lines', jsonb_build_array(jsonb_build_object('line_id', v_l1, 'quantity', 11)))); v_err3 := 'answered';
    exception when others then v_err3 := sqlerrm; end;
    begin perform erp.supplier_respond(v_tok, jsonb_build_object('decision', 'confirm',
            'lines', jsonb_build_array(jsonb_build_object('line_id', gen_random_uuid(), 'quantity', 1)))); v_err4 := 'answered';
    exception when others then v_err4 := sqlerrm; end;
    begin perform erp.supplier_respond(repeat('a', 64), '{"decision": "confirm"}'); v_err5 := 'answered';
    exception when others then v_err5 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an answer that is neither, a decline with no reason, more than was ordered, a line not on the order, and a link that is not one are each refused by name, and the order still awaits';
    passed := v_state is null
          and v_err like 'CLOVEERP_CONFIRMATION_DECISION_UNKNOWN:%'
          and v_err2 like 'CLOVEERP_DECLINE_NEEDS_A_REASON:%'
          and v_err3 like 'CLOVEERP_CONFIRMATION_LINE_INVALID:%'
          and v_err4 like 'CLOVEERP_CONFIRMATION_LINE_INVALID:%'
          and v_err5 like 'CLOVEERP_SUPPLIER_LINK_UNKNOWN:%'
          and (select c.status from erp.purchase_order_confirmation c where c.order_id = v_po) = 'awaiting';
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 700));
    return next;

    -- ── 5. The supplier proposes changes ────────────────────────────────────
    v_step := 'eight coats a week late, and the scarves as ordered';
    perform set_config('request.jwt.claims', '', true);
    v_conf := erp.supplier_respond(v_tok, jsonb_build_object('decision', 'confirm', 'supplier_reference', 'SO-77',
                'note', 'Two coats are on back order',
                'lines', jsonb_build_array(jsonb_build_object('line_id', v_l1, 'quantity', 8, 'date', (current_date + 21)::text),
                                           jsonb_build_object('line_id', v_l2))));
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a supplier who can send eight coats a week late proposes a change to one line: it waits for the buyer, who is told, and nothing on the order moves yet';
    passed := v_state is null
          and v_conf ->> 'status' = 'changes_proposed'
          and jsonb_array_length(v_conf -> 'proposal') = 1
          and v_conf ->> 'supplier_reference' = 'SO-77'
          and (select l.quantity from erp.document_line l where l.id = v_l1) = 10
          and (select l.confirmed_quantity from erp.document_line l where l.id = v_l1) is null
          and exists (select 1 from erp.notification n where n.tenant_id = rb.tenant_id
                         and n.subject like 'The supplier proposed changes to order %')
          and exists (select 1 from erp.event e where e.tenant_id = rb.tenant_id
                         and e.event_type = 'purchase_order.supplier_responded' and e.aggregate_id = v_po);
    detail := coalesce(v_state, left(coalesce(v_conf::text, 'nothing'), 500));
    return next;

    -- ── 6. Rejected, then accepted ──────────────────────────────────────────
    v_step := 'the buyer rejects, the supplier answers again, the buyer accepts';
    v_conf := public.erp_decide_supplier_changes(v_po, false, 'We need all ten by the date');
    v_n := (select count(*) from erp.supplier_response_link l where l.order_id = v_po and l.revoked_at is null);
    perform set_config('request.jwt.claims', '', true);
    perform erp.supplier_respond(v_tok, jsonb_build_object('decision', 'confirm', 'supplier_reference', 'SO-77',
                'lines', jsonb_build_array(jsonb_build_object('line_id', v_l1, 'quantity', 8, 'date', (current_date + 14)::text))));
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_conf := public.erp_decide_supplier_changes(v_po, true, null);
    select s.due_on into v_supply from erp.scheduled_supply(v_item, v_site, current_date, current_date + 60, false) s
     where s.source = 'purchase_order' limit 1;
    v_cases := v_cases + 1;
    case_name := 'rejected, the order awaits again with the buyer''s note and its link still answers; the supplier''s second answer accepted, the coats are amended to eight, both lines carry what was confirmed, and planning expects the coats on the supplier''s date';
    passed := v_state is null
          and v_n = 1
          and v_conf ->> 'status' = 'confirmed'
          and (select l.quantity from erp.document_line l where l.id = v_l1) = 8
          and (select l.confirmed_quantity from erp.document_line l where l.id = v_l1) = 8
          and (select l.confirmed_date from erp.document_line l where l.id = v_l1) = current_date + 14
          and (select l.confirmed_quantity from erp.document_line l where l.id = v_l2) = 10
          and v_supply = current_date + 14
          and exists (select 1 from erp.event e where e.tenant_id = rb.tenant_id
                         and e.event_type = 'purchase_order.changes_decided' and e.aggregate_id = v_po
                         and (e.payload ->> 'accepted')::boolean);
    detail := coalesce(v_state, left(format('%s; supply %s', v_conf, v_supply), 600));
    return next;

    -- ── 7. Settled is settled ───────────────────────────────────────────────
    v_step := 'answering a confirmed order, and deciding nothing';
    perform set_config('request.jwt.claims', '', true);
    begin perform erp.supplier_respond(v_tok, '{"decision": "confirm"}'); v_err := 'answered';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin perform public.erp_decide_supplier_changes(v_po, true, null); v_err2 := 'decided';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_look)::text, true);
    begin perform public.erp_record_supplier_confirmation(v_po, '{"decision": "confirm"}'); v_err3 := 'recorded';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'once confirmed, the supplier''s link answers no more, there are no changes to decide, and a reader without procurement.order cannot record an answer';
    passed := v_state is null
          and v_err like 'CLOVEERP_ORDER_NOT_AWAITING_ANSWER:%'
          and v_err2 like 'CLOVEERP_NO_CHANGES_TO_DECIDE:%'
          and v_err3 like 'CLOVEERP_PERMISSION_DENIED: procurement.order%';
    detail := coalesce(v_state, left(format('%s | %s | %s', v_err, v_err2, v_err3), 500));
    return next;

    -- ── 8. Sent again, the old link stops ───────────────────────────────────
    v_step := 'the order sent again';
    res := public.erp_send_purchase_order(v_po, 'orders@zcbrand-' || v_tag || '.test', null, null, 'Quantities changed on line 1');
    select t.response_token into v_tok2 from erp.claim_document_email_batch(10, 'suite') t
     where t.document_kind = 'purchase_order' limit 1;
    v_cases := v_cases + 1;
    case_name := 'sent again, the order awaits a new answer, its new email carries a new link, and the old link shows nothing';
    passed := v_state is null
          and v_tok2 ~ '^[0-9a-f]{64}$' and v_tok2 <> v_tok
          and public.erp_supplier_response_peek(v_tok) is null
          and public.erp_supplier_response_peek(v_tok2) ->> 'status' = 'awaiting';
    detail := coalesce(v_state, format('old %s, new %s', public.erp_supplier_response_peek(v_tok) is null,
                                       public.erp_supplier_response_peek(v_tok2) ->> 'status'));
    return next;

    -- ── 9. Declined, and cancelled ──────────────────────────────────────────
    v_step := 'a second order declined, then cancelled';
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 5, 9000, 'ZCO2');
    v_conf := public.erp_record_supplier_confirmation(v_po2, '{"decision": "decline", "note": "Discontinued"}');
    begin perform public.erp_cancel_sent_order(v_po2, ''); v_err := 'cancelled';
    exception when others then v_err := sqlerrm; end;
    res := public.erp_cancel_sent_order(v_po2, 'The supplier discontinued the coat');
    v_cases := v_cases + 1;
    case_name := 'an answer recorded by the buyer declines a second order without telling the buyer what they did; it is cancelled with a reason, not without, and its answer is withdrawn';
    passed := v_state is null
          and v_conf ->> 'status' = 'declined'
          and v_conf ->> 'responded_via' = 'buyer'
          and not exists (select 1 from erp.notification n where n.tenant_id = rb.tenant_id
                             and n.subject = format('The supplier declined order %s',
                                 (select d.document_number from erp.document d where d.id = v_po2)))
          and v_err like 'CLOVEERP_REASON_REQUIRED:%'
          and erp.object_current_state('document', v_po2) = 'cancelled'
          and (select c.status from erp.purchase_order_confirmation c where c.order_id = v_po2) = 'withdrawn';
    detail := coalesce(v_state, left(format('%s | %s | %s', v_conf, v_err, res), 500));
    return next;

    -- ── 10. Not once goods have come ────────────────────────────────────────
    v_step := 'cancelling an order with goods received, and a draft';
    v_po3 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_po3, v_l2, 2, null);
    perform erp.transition_document(v_po3, 'post', null);
    begin perform public.erp_cancel_sent_order(v_po, 'Changed our mind'); v_err := 'cancelled';
    exception when others then v_err := sqlerrm; end;
    v_po3 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 9000, 'ZCO3', false);
    begin perform public.erp_cancel_sent_order(v_po3, 'Not sent'); v_err2 := 'cancelled';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an order with goods received against it, and an order never sent, are refused cancellation by name';
    passed := v_state is null
          and v_err like 'CLOVEERP_SENT_ORDER_CANNOT_CANCEL:%'
          and v_err2 like 'CLOVEERP_SENT_ORDER_CANNOT_CANCEL:%'
          and erp.object_current_state('document', v_po) = 'partially_received';
    detail := coalesce(v_state, left(format('%s | %s', v_err, v_err2), 500));
    return next;

    -- ── 11. The buyer is told of the silent ones, once ──────────────────────
    v_step := 'an order four days unanswered, looked at twice';
    v_po3 := erp_test.prepayment_order(v_entity, v_site, v_item2, v_sa, 3, 1000, 'ZCO4');
    update erp.purchase_order_confirmation set awaiting_since = now() - interval '4 days' where order_id = v_po3;
    v_n := erp.notify_unconfirmed_orders();
    v_n2 := erp.notify_unconfirmed_orders();
    v_cases := v_cases + 1;
    case_name := 'an order its supplier has left four days unanswered is flagged to its buyer once, and listed as overdue among those awaiting';
    passed := v_state is null
          and v_n = 1 and v_n2 = 0
          and exists (select 1 from erp.notification n where n.tenant_id = rb.tenant_id
                         and n.subject like '% has not confirmed order %')
          and exists (select 1 from jsonb_array_elements(public.erp_awaiting_confirmations()) x
                       where (x ->> 'order_id')::uuid = v_po3 and (x ->> 'overdue')::boolean);
    detail := coalesce(v_state, format('first %s, second %s', v_n, v_n2));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzpoc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_look))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzpoc rolled back with its orders, answers and links');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_CONFIRMATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.supplier_confirmation_suite() from public, anon;

comment on function erp_test.supplier_confirmation_suite() is
  'A supplier confirms the order (20261004990000): sending awaits an answer through a link whose token '
  'only the email holds; the supplier''s page reads one order; changes wait for the buyer, who rejects or '
  'accepts; planning reads the confirmed date; re-sending replaces the link; a declined order is cancelled '
  'while nothing is received; the silent ones are flagged once.';

create or replace function erp_test.assert_supplier_confirmation_suite()
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
    from erp_test.supplier_confirmation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SUPPLIER_CONFIRMATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A supplier''s answer would be lost, or a link would answer what it should not. Read the case that failed.';
  end if;
  if v_total <> 12 then
    raise exception 'CLOVEERP_SUPPLIER_CONFIRMATION_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('supplier confirmation: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_supplier_confirmation_suite() from public, anon;

comment on function erp_test.assert_supplier_confirmation_suite() is
  'A purchase order''s supplier answers it, through its own link or the buyer, and the order, planning '
  'and the buyer follow (20261004990000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- L. Three suites that pinned what this moves
-- ═════════════════════════════════════════════════════════════════════════════
--
-- parameter_budget_suite counted p2p at three settings; it holds four now.
-- procurement_policy_suite pinned the defaults without the chase and a new
-- install at version 3. procurement_reseed_suite required the current
-- version's purchase order machine to equal version 2's, as the way of saying
-- it still declares inherit_approval; version 4 adds cancel_sent, so it says
-- that directly. Re-pinned, not rewritten: one anchor or two over each body.

do $repin$
declare
  r      record;
  v_src  text;
  v_def  text;
  v_hits integer;
begin
  for r in
    select * from (values
      ('erp_test.parameter_budget_suite()', 'b71696d02ec8dbffa6908212be2c75e7',
       array[$o1$          and (select r.parameters from erp.parameter_budget_report() r where r.cycle_code = 'p2p') = 3;$o1$,
             $n1$          -- Four since 20261004990000: the confirmation chase.
          and (select r.parameters from erp.parameter_budget_report() r where r.cycle_code = 'p2p') = 4;$n1$]),
      ('erp_test.procurement_policy_suite()', '2a0320dc18ead576d9e121dc7a75e657',
       array[$o2$      v_p0 = jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 0, 'invoice_match_mode', 'three_way')$o2$,
             $n2$      -- With the confirmation chase since 20261004990000.
      v_p0 = jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 0, 'invoice_match_mode', 'three_way',
                                'confirmation_chase_days', 3)$n2$,
             $o3$      v_ver = 3
$o3$,
             $n3$      -- Version 4 since 20261004990000: a sent order can be cancelled.
      v_ver = 4
$n3$]),
      ('erp_test.procurement_reseed_suite()', 'e22ccd8ea03a3f751e39d8ac18b89d45',
       array[$o4$                     and p.payload = (select ui.payload from erp_ref.module_upgrade_item ui
                                       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2
                                         and (ui.object_kind, ui.object_key) = ('state_machine', 'purchase_order')))$o4$,
             $n4$                     -- It still declares inherit_approval, which keeps it excused;
                     -- since 20261004990000 it also cancels a sent order.
                     and p.payload -> 'transitions' @> '[{"code": "inherit_approval"}]'::jsonb)$n4$])
    ) as x(sig, md5, pairs)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261004990000') > 0 then
      raise notice '% already re-pinned; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.md5 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004990000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    for v_i in 1 .. array_length(r.pairs, 1) / 2 loop
      v_hits := (length(v_def) - length(replace(v_def, r.pairs[2*v_i - 1], ''))) / length(r.pairs[2*v_i - 1]);
      if v_hits <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', r.sig, v_i, v_hits;
      end if;
      v_def := replace(v_def, r.pairs[2*v_i - 1], r.pairs[2*v_i]);
    end loop;
    execute v_def;
  end loop;
end
$repin$;

-- ═════════════════════════════════════════════════════════════════════════════
-- M. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A supplier''s confirmation of a purchase order (20261004990000).'
  from (values
    ('Accept the changes'),
    ('Accept the supplier''s changes'),
    ('Answered'),
    ('Awaiting confirmation'),
    ('Cancel the order'),
    ('Cancel this order'),
    ('Cancels the order before anything has arrived. The supplier''s link stops working; tell them yourself.'),
    ('Confirmed'),
    ('Every sent order has its supplier''s answer.'),
    ('For an answer the supplier gave by phone or email. Lines left out are taken as ordered; a changed line waits for you to accept it.'),
    ('Kept with the order for the supplier and the auditor.'),
    ('Record the supplier''s answer'),
    ('Reject the changes'),
    ('Reject the supplier''s changes'),
    ('Sent orders their supplier has not confirmed, or answered with changes or a refusal.'),
    ('Shown to the supplier with the order.'),
    ('Supplier confirmation'),
    ('The order is unchanged and waits for a new answer. The supplier sees your note when they open their link.'),
    ('The order''s quantities change to what the supplier can send, and each line keeps the date they gave.'),
    ('The supplier proposed'),
    ('Their note'),
    ('They can send'),
    ('They say'),
    ('Waiting since'),
    ('Wanted by'),
    ('What you need instead'),
    ('Your note'),
    ('by the supplier'),
    ('days'),
    ('recorded by the buyer'),
    ('What the supplier said about this order: taken as it is, taken with changes, or declined. They answer from the link in the order''s email; you can record an answer they gave you.'),
    ('What the supplier said'),
    ('They will send it'),
    ('They cannot take it'),
    ('Their reference'),
    ('SO-1234'),
    ('Optional. Their own order number.'),
    ('What they said'),
    ('Two coats on back order'),
    ('Needed when they cannot take it.'),
    ('Lines they changed'),
    ('Line'),
    ('Add a changed line'),
    ('By'),
    ('Item'),
    ('Ordered'),
    ('8'),
    ('Why it is cancelled'),
    ('The supplier discontinued the item'),
    ('We need all ten by the date'),
    ('Accept'),
    ('Reject'),
    ('Record'),
    ('Changes proposed'),
    ('Declined'),
    ('Withdrawn'),
    ('Late')
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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
