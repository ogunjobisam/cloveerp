-- =============================================================================
-- An invoice is chased, and an email is tracked
--
-- Two halves of the same lifecycle, and they share a table, so they share a
-- migration: an invoice that is not paid is chased by email, and every email
-- the product sends now has an answer from the provider about whether it
-- arrived.
--
--   1. CHASING. A daily job in the platform's own organisation looks for
--      issued, unpaid contract invoices past their due date and queues a
--      reminder to the people the invoice itself went to: the billing contact,
--      otherwise the customer organisation's administrators. The day after it
--      falls due, then every seven days, to a maximum of four. Recording the
--      payment stops them, and so does voiding the invoice, because both take
--      the invoice out of the only state the sweep looks at. A demonstration
--      organisation is never emailed, as before.
--
--      The reminder is a third kind on erp_meta.commercial_email, so it is
--      claimed, sent, settled, attached to and recorded exactly as an order
--      form and an invoice already are (20260914097300, 20260915020000). Its
--      payload is the invoice's, with the reminder's number and how overdue it
--      was when the drain claimed it; the PDF it attaches is the invoice.
--
--   2. TRACKING. Resend posts what it knows about each message to a new Edge
--      Function (supabase/functions/resend_webhook), which verifies the
--      signature and hands the event here. erp.record_email_delivery_event()
--      is where every decision about it is taken: whether the event has been
--      seen before, which message it belongs to, whether that message's state
--      may move, and whether the address should now be sent nothing.
--
--      The state is kept twice on purpose: erp_meta.email_delivery_event is
--      the history — every event, once, whether or not it matched anything —
--      and the matched row carries the latest state, so a screen that lists
--      sends does not have to aggregate a log to say "delivered".
--
--      A bounce is a fact, not an error: a permanent one suppresses the
--      address, a temporary one does not, and neither causes a retry. A
--      complaint always suppresses. The claim then cancels anything queued for
--      a suppressed address with a reason a person can read, and the console
--      says who is suppressed and lets an operator clear one.
--
-- Proof: erp_test.invoice_chase_suite() (8 cases) and
-- erp_test.email_tracking_suite() (8 cases), each inside a block it rolls back.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A reminder is a third kind of commercial email
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.commercial_email drop constraint if exists commercial_email_kind_known;
alter table erp_meta.commercial_email add constraint commercial_email_kind_known
  check (kind in ('order_form', 'contract_invoice', 'invoice_reminder'));

alter table erp_meta.commercial_email drop constraint if exists commercial_email_names_its_document;
alter table erp_meta.commercial_email add constraint commercial_email_names_its_document check (
  (kind = 'order_form' and quote_document_id is not null and quote_tenant_id is not null and contract_invoice_id is null)
  or (kind in ('contract_invoice', 'invoice_reminder') and contract_invoice_id is not null and quote_document_id is null));

-- A reminder keeps its own copy of what it attached, under its own kind.
alter table erp_meta.commercial_email drop constraint if exists commercial_email_document_whole;
alter table erp_meta.commercial_email add constraint commercial_email_document_whole check (
  (document_path is null and document_bytes is null and document_sha256 is null)
  or (document_path ~ '^commercial/(order-form|contract-invoice|invoice-reminder)/[0-9a-f-]{36}\.pdf$'
      and document_bytes > 0
      and document_sha256 ~ '^[0-9a-f]{64}$'));

-- A reminder goes to whoever the invoice goes to.
create or replace function erp.commercial_email_recipients(p_kind text, p_document_id uuid)
returns table (address text, display_name text, source text, customer_tenant_id uuid, customer_tenant_code text)
language sql
stable
set search_path = ''
as $$
  select r.address, r.display_name, r.source, r.customer_tenant_id, r.customer_tenant_code
    from erp.quote_recipients(p_document_id) r
   where p_kind = 'order_form'
  union all
  select r.address, r.display_name, r.source, c.tenant_id, c.tenant_code
    from erp_meta.contract_invoice i
    join erp_meta.contract c on c.id = i.contract_id
    cross join lateral erp.contract_billing_recipients(c.id) r
   where p_kind in ('contract_invoice', 'invoice_reminder')
     and i.id = p_document_id
$$;

revoke all on function erp.commercial_email_recipients(text, uuid) from public, anon, authenticated;

comment on function erp.commercial_email_recipients(text, uuid) is
  'Who an order form, a contract invoice or a reminder for one is emailed to, and '
  'why: the quote''s customer contact, else the administrators of the organisation '
  'it was made for; the contract''s billing contact, else the customer '
  'organisation''s administrators.';

-- And a demonstration is a demonstration whichever of the three it is.
create or replace function erp.commercial_document_is_demonstration(p_kind text, p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case
    when p_kind = 'order_form' then exists (
      select 1
        from erp.commercial_quote cq
       where cq.document_id = p_document_id
         and (erp.tenant_is_demonstration(cq.tenant_id)
              or exists (select 1 from erp.tenant t
                          where t.code = cq.customer_tenant_code and erp.tenant_is_demonstration(t.id))))
    when p_kind in ('contract_invoice', 'invoice_reminder') then exists (
      select 1
        from erp_meta.contract_invoice i
       where i.id = p_document_id
         and erp.tenant_is_demonstration(i.tenant_id))
    else false
  end
$$;

revoke all on function erp.commercial_document_is_demonstration(text, uuid) from public, anon, authenticated;

-- The reminder attaches the invoice, under the invoice's own name.
create or replace function erp.commercial_document_filename(p_kind text, p_document_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_kind = 'order_form' then (
      select 'Order-form-' || regexp_replace(d.document_number, '[^A-Za-z0-9-]+', '-', 'g')
             || '-v' || cq.version || '.pdf'
        from erp.commercial_quote cq
        join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
       where cq.document_id = p_document_id)
    when p_kind in ('contract_invoice', 'invoice_reminder') then (
      select 'Invoice-' || regexp_replace(i.reference, '[^A-Za-z0-9-]+', '-', 'g') || '.pdf'
        from erp_meta.contract_invoice i
       where i.id = p_document_id)
  end
$$;

revoke all on function erp.commercial_document_filename(text, uuid) from public, anon, authenticated;

comment on function erp.commercial_document_filename(text, uuid) is
  'The name an order form, invoice or reminder PDF is attached and downloaded '
  'under: Order-form-<quote number>-v<version>.pdf or Invoice-<reference>.pdf.';

-- A customer downloads one copy of each document, not one per chase.
create or replace function erp.organisation_commercial_documents(p_tenant_id uuid)
returns table (email_id uuid, kind text, document_id uuid, filename text, document_bytes integer,
               sent_at timestamptz)
language sql
stable
set search_path = ''
as $$
  -- The latest stored copy of each order form and invoice the organisation was
  -- sent: invoices of its own contracts, and order forms of quotes made for it
  -- or that its contracts were made from. A reminder carries the invoice that
  -- is already listed, so it adds nothing here (20260915030000).
  select distinct on (x.kind, x.document_id)
         x.id, x.kind, x.document_id, erp.commercial_document_filename(x.kind, x.document_id),
         x.document_bytes, x.sent_at
    from (select e.id, e.kind, coalesce(e.quote_document_id, e.contract_invoice_id) as document_id,
                 e.document_bytes, e.sent_at
            from erp_meta.commercial_email e
           where e.status = 'sent'
             and e.document_path is not null
             and e.kind <> 'invoice_reminder'
             and ((e.kind = 'contract_invoice'
                   and exists (select 1 from erp_meta.contract_invoice i
                                where i.id = e.contract_invoice_id and i.tenant_id = p_tenant_id))
                  or (e.kind = 'order_form'
                      and (e.tenant_id = p_tenant_id
                           or exists (select 1 from erp_meta.contract c
                                       where c.quote_document_id = e.quote_document_id
                                         and c.tenant_id = p_tenant_id))))) x
   order by x.kind, x.document_id, x.sent_at desc
$$;

revoke all on function erp.organisation_commercial_documents(uuid) from public, anon, authenticated;

comment on function erp.organisation_commercial_documents(uuid) is
  'The latest stored PDF of every order form and contract invoice an organisation '
  'was sent, with the name it downloads under.';

-- The payload says which of the three it is, and how late the invoice is.
do $payload$
declare
  v_sig    constant text := 'erp.commercial_email_payload(uuid)';
  v_def    text := pg_get_functiondef('erp.commercial_email_payload(uuid)'::regprocedure);
  v_needle constant text := $n$  return erp.without_cost_or_margin(jsonb_build_object(
    'kind', 'contract_invoice',$n$;
  v_new    constant text := $n$  return erp.without_cost_or_margin(jsonb_build_object(
    -- A reminder carries the invoice it chases, its number, and how overdue the
    -- invoice was when the drain claimed it (20260915030000).
    'kind', e.kind,
    'reminder_number', case when e.kind = 'invoice_reminder' then e.send_number end,
    'days_overdue', case when e.kind = 'invoice_reminder'
                         then greatest(current_date - v_invoice.due_on, 0) end,$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not build an invoice payload exactly once, so it is not the 20260914097300 body', v_sig
      using hint = 'A later migration changed what the commercial email payload carries. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('''days_overdue''' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$payload$;

-- A send of a document is numbered among sends of that document, and a
-- reminder is numbered among reminders.
do $numbering$
declare
  v_sig    constant text := 'erp.queue_commercial_email(text,uuid)';
  v_def    text := pg_get_functiondef('erp.queue_commercial_email(text,uuid)'::regprocedure);
  v_needle constant text := $n$  select coalesce(max(e.send_number), 0) + 1 into v_send
    from erp_meta.commercial_email e
   where (p_kind = 'order_form' and e.quote_document_id = p_document_id)
      or (p_kind = 'contract_invoice' and e.contract_invoice_id = p_document_id);$n$;
  v_new    constant text := $n$  -- Among sends of this kind: a reminder is numbered among reminders, so
  -- chasing an invoice does not renumber the invoice (20260915030000).
  select coalesce(max(e.send_number), 0) + 1 into v_send
    from erp_meta.commercial_email e
   where e.kind = p_kind
     and ((p_kind = 'order_form' and e.quote_document_id = p_document_id)
          or (p_kind = 'contract_invoice' and e.contract_invoice_id = p_document_id));$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not number a send exactly once, so it is not the 20260914097300 body', v_sig
      using hint = 'A later migration changed how a send is numbered. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('e.kind = p_kind' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$numbering$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Chasing an unpaid invoice
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.invoice_reminder_state(p_invoice_id uuid)
returns table (reminders_sent integer, last_reminder_number integer, last_reminder_at timestamptz)
language sql
stable
set search_path = ''
as $$
  -- How far the chase has got: how many reminders reached the provider, the
  -- highest number queued at all, and when the last one was queued or sent.
  -- The highest number is what the next one follows, so a reminder that failed
  -- is not sent again under its own number and the four are four.
  select coalesce(count(*) filter (where e.status = 'sent'), 0)::integer,
         coalesce(max(e.send_number), 0)::integer,
         max(coalesce(e.sent_at, e.created_at))
    from erp_meta.commercial_email e
   where e.contract_invoice_id = p_invoice_id
     and e.kind = 'invoice_reminder'
$$;

revoke all on function erp.invoice_reminder_state(uuid) from public, anon, authenticated;

comment on function erp.invoice_reminder_state(uuid) is
  'How many reminders for an invoice have been sent, the number of the last one '
  'queued, and when it was queued or sent.';

create or replace function erp.invoice_reminder_limit()
returns integer
language sql
immutable
set search_path = ''
as $$ select 4 $$;

comment on function erp.invoice_reminder_limit() is
  'How many reminders one unpaid invoice is chased with before a person takes it '
  'over: four, the owner''s decision of 15 September 2026.';

create or replace function erp.invoice_reminder_interval_days()
returns integer
language sql
immutable
set search_path = ''
as $$ select 7 $$;

comment on function erp.invoice_reminder_interval_days() is
  'How long after one reminder the next may go: seven days. The first goes the '
  'day after the invoice falls due.';

create or replace function erp.queue_invoice_reminder(p_invoice_id uuid, p_reminder_number integer)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_by      constant text := 'the invoice reminder sweep';
  v_invoice erp_meta.contract_invoice;
  v_n       integer := 0;
  r         record;
begin
  -- The daily sweep queues these, over the connection the scheduler runs on.
  -- Invoker on purpose: inside a security definer function owned by the role
  -- that bypasses row-level security, erp.session_is_trusted() is true of
  -- everybody, and this check would mean nothing.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not queue invoice reminders', current_user
      using errcode = '42501', hint = 'The daily sweep queues these; a person sends an invoice again from the contract instead.';
  end if;

  select * into v_invoice from erp_meta.contract_invoice x where x.id = p_invoice_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INVOICE: %', p_invoice_id
      using errcode = '23503', hint = 'Open the contract''s invoices and try again.';
  end if;
  if v_invoice.status <> 'issued' then
    raise exception 'CLOVEERP_INVOICE_NOT_CHASEABLE: % is %, so there is nothing to chase', v_invoice.reference, v_invoice.status
      using errcode = '23514',
            hint = 'Only an issued invoice is chased: recording the payment or voiding it ends the chase.';
  end if;
  if v_invoice.due_on >= current_date then
    raise exception 'CLOVEERP_INVOICE_NOT_CHASEABLE: % is not due until %', v_invoice.reference, v_invoice.due_on
      using errcode = '23514',
            hint = 'A reminder goes the day after an invoice falls due, and not before.';
  end if;
  if p_reminder_number is null or p_reminder_number < 1 or p_reminder_number > erp.invoice_reminder_limit() then
    raise exception 'CLOVEERP_INVOICE_REMINDER_LIMIT: % is not one of the % reminders an invoice is chased with',
      coalesce(p_reminder_number, 0), erp.invoice_reminder_limit()
      using errcode = '23514',
            hint = 'Four reminders is the whole chase. After that a person decides what happens next.';
  end if;

  -- A demonstration organisation is chased no more than it is invoiced.
  if erp.commercial_document_is_demonstration('invoice_reminder', p_invoice_id) then
    return 0;
  end if;

  for r in select * from erp.commercial_email_recipients('invoice_reminder', p_invoice_id) loop
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number,
       to_address, to_name, recipient_source, requested_by, idempotency_key)
    values ('invoice_reminder', p_invoice_id, r.customer_tenant_id, r.customer_tenant_code,
            p_reminder_number, r.address, r.display_name, r.source, v_by,
            format('clove-invoice-reminder-%s-%s-%s', p_invoice_id, p_reminder_number, md5(lower(r.address))))
    on conflict on constraint commercial_email_once do nothing;
    if found then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

revoke all on function erp.queue_invoice_reminder(uuid, integer) from public, anon, authenticated;

comment on function erp.queue_invoice_reminder(uuid, integer) is
  'Queues the numbered reminder for an overdue, unpaid invoice to everybody the '
  'invoice itself goes to. Nothing for a demonstration organisation, and nothing '
  'twice: the key is the invoice, the number and the address. Trusted sessions '
  'only: the daily sweep calls it, and nobody signed in does.';

create or replace function erp.chase_overdue_invoices()
returns table (reference text, tenant_code text, reminder_number integer, days_overdue integer, queued integer)
language plpgsql
volatile
set search_path = ''
as $$
declare
  r      record;
  v_next integer;
  v_n    integer;
begin
  -- The scheduler runs this on its own connection, across every organisation's
  -- invoices. Invoker, so that trusted means trusted.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not chase invoices', current_user
      using errcode = '42501', hint = 'The scheduler runs this job; nobody signed in runs it by hand.';
  end if;
  -- The platform organisation's own job: these are the platform's invoices, and
  -- its email kill switch and sender identity are what send them.
  perform erp.require_platform_organisation();

  for r in
    select i.id, i.reference, i.tenant_code, i.due_on,
           s.last_reminder_number, s.last_reminder_at
      from erp_meta.contract_invoice i
      cross join lateral erp.invoice_reminder_state(i.id) s
     where i.status = 'issued'
       and i.due_on < current_date
     order by i.due_on, i.reference
  loop
    -- Four and no more.
    v_next := r.last_reminder_number + 1;
    continue when v_next > erp.invoice_reminder_limit();

    -- The first the day after it falls due; each one after it a week later.
    -- One a day at the very most, which this spacing already guarantees.
    continue when r.last_reminder_at is not null
             and r.last_reminder_at::date > current_date - erp.invoice_reminder_interval_days();

    v_n := erp.queue_invoice_reminder(r.id, v_next);
    continue when v_n = 0;

    reference := r.reference;
    tenant_code := r.tenant_code;
    reminder_number := v_next;
    days_overdue := current_date - r.due_on;
    queued := v_n;
    return next;
  end loop;
end;
$$;

revoke all on function erp.chase_overdue_invoices() from public, anon, authenticated;

comment on function erp.chase_overdue_invoices() is
  'The daily sweep for issued invoices past their due date: queues the next '
  'reminder for each, the day after it falls due and every seven days after '
  'that, up to four. Paying or voiding the invoice ends the chase, because '
  'neither is an issued invoice any more. Runs in the platform''s organisation.';

insert into erp_ref.job_handler (code, name_key, description, module_code, parameter_schema,
                                 default_timeout_seconds, forbids_overlap, is_current, sql_function,
                                 default_max_silence_seconds)
values ('commercial.chase_overdue_invoices', 'job_handler.chase_overdue_invoices.name',
        'Chases issued contract invoices that are past their due date and not recorded as paid: '
        'the day after one falls due, then every seven days, to a maximum of four reminders, to '
        'the billing contact or the customer organisation''s administrators. §17.10.',
        'administration', '{}'::jsonb, 300, true, true, 'chase_overdue_invoices', 3 * 86400)
on conflict (code) do update
  set name_key = excluded.name_key, description = excluded.description, module_code = excluded.module_code,
      parameter_schema = excluded.parameter_schema, default_timeout_seconds = excluded.default_timeout_seconds,
      forbids_overlap = excluded.forbids_overlap, is_current = excluded.is_current,
      sql_function = excluded.sql_function, default_max_silence_seconds = excluded.default_max_silence_seconds;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('job_handler.chase_overdue_invoices.name', 'en', 'Chase overdue invoices', 'administration'),
  ('job_handler.chase_overdue_invoices.name', 'de', 'Überfällige Rechnungen anmahnen', 'administration')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

-- The job itself, in the platform's organisation and nowhere else.
do $job$
declare v_platform uuid;
begin
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  if v_platform is null then
    raise notice 'no platform organisation yet: the chase job is created when one is designated';
    return;
  end if;
  perform set_config('erp.job_tenant_id', v_platform::text, true);
  perform set_config('erp.job_principal_id', '', true);
  perform erp.upsert_job('chase_overdue_invoices', 'Chase overdue invoices',
                         'commercial.chase_overdue_invoices', 'daily', null, '08:00'::time,
                         null, null, 'UTC', '{}'::jsonb, 300, null, true);
  perform set_config('erp.job_tenant_id', '', true);
end
$job$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. What the provider says afterwards
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.commercial_email add column if not exists delivery_state text;
alter table erp_meta.commercial_email add column if not exists delivery_state_at timestamptz;
alter table erp_meta.commercial_email add column if not exists delivery_detail text;

alter table erp_meta.commercial_email drop constraint if exists commercial_email_delivery_state_known;
alter table erp_meta.commercial_email add constraint commercial_email_delivery_state_known check (
  (delivery_state is null and delivery_state_at is null)
  or (delivery_state in ('sent', 'delayed', 'delivered', 'opened', 'complained', 'bounced')
      and delivery_state_at is not null));

comment on column erp_meta.commercial_email.delivery_state is
  'The last thing the provider said about this message (20260915030000): sent, '
  'delayed, delivered, opened, complained or bounced. status is what the queue '
  'did; this is what became of it afterwards.';

alter table erp.notification add column if not exists delivery_state text;
alter table erp.notification add column if not exists delivery_state_at timestamptz;

alter table erp.notification drop constraint if exists notification_delivery_state_known;
alter table erp.notification add constraint notification_delivery_state_known check (
  (delivery_state is null and delivery_state_at is null)
  or (delivery_state in ('sent', 'delayed', 'delivered', 'opened', 'complained', 'bounced')
      and delivery_state_at is not null));

-- An event arrives knowing only the provider's id for the message, so that is
-- the column it is looked up by, on both queues.
create index if not exists commercial_email_by_provider
  on erp_meta.commercial_email (provider_message_id) where provider_message_id is not null;
create index if not exists notification_by_provider
  on erp.notification (provider_message_id) where provider_message_id is not null;

create table if not exists erp_meta.email_delivery_event (
  id                  uuid primary key default gen_random_uuid(),
  -- The provider's own id for the event. The unique constraint is the replay
  -- check: an event delivered twice is recorded once.
  event_id            text not null,
  event_type          text not null,
  state               text,
  provider_message_id text,
  occurred_at         timestamptz not null default now(),
  to_address          text,
  bounce_kind         text,
  detail              text,
  matched             text not null default 'nothing',
  commercial_email_id uuid references erp_meta.commercial_email (id) on delete set null,
  -- No foreign key to erp.notification: a tenant's notifications are purged
  -- with the tenant, and the record that the provider said something is the
  -- platform's, not theirs.
  notification_id     uuid,
  tenant_id           uuid,
  suppressed          boolean not null default false,
  received_at         timestamptz not null default now(),
  constraint email_delivery_event_once unique (event_id),
  constraint email_delivery_event_state_known check (
    state is null or state in ('sent', 'delayed', 'delivered', 'opened', 'complained', 'bounced')),
  constraint email_delivery_event_matched_known check (
    matched in ('nothing', 'commercial_email', 'notification', 'enquiry'))
);

create index if not exists email_delivery_event_recent on erp_meta.email_delivery_event (received_at desc);
create index if not exists email_delivery_event_by_message on erp_meta.email_delivery_event (provider_message_id);

comment on table erp_meta.email_delivery_event is
  'Every delivery event the provider has posted, once each: what it said, which '
  'message it belonged to and whether it suppressed the address. The history '
  'behind the state each queue row carries, and the record that the provider '
  'was heard even when nothing here matched what it named.';

select erp_meta.register_table('erp_meta', 'email_delivery_event', 'platform_internal',
  'Delivery events from the email provider: one row per event, matched to the message it belongs to.');

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'email_delivery_event', 'to_address',
   'The address the provider reported on, kept as the record of why it was suppressed or '
   'why a message did not arrive. Part of the sending record, which outlives the organisation.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

-- How far along a message is. A state never moves backwards, so an event that
-- arrives out of order changes nothing.
create or replace function erp.email_delivery_rank(p_state text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_state
    when 'sent' then 10
    when 'delayed' then 20
    when 'delivered' then 30
    when 'opened' then 40
    when 'complained' then 50
    when 'bounced' then 60
    else 0
  end
$$;

comment on function erp.email_delivery_rank(text) is
  'The order delivery states may follow one another in, so a late event cannot '
  'move a message backwards.';

create or replace function erp.email_bounce_is_permanent(p_bounce_kind text)
returns boolean
language sql
immutable
set search_path = ''
as $$ select coalesce(lower(btrim(p_bounce_kind)) like 'permanent%', false) $$;

comment on function erp.email_bounce_is_permanent(text) is
  'Whether the provider called a bounce permanent. A temporary one suppresses '
  'nothing: the address may be fine tomorrow.';

create or replace function erp.record_email_delivery_event(
  p_event_id            text,
  p_event_type          text,
  p_state               text,
  p_provider_message_id text,
  p_occurred_at         timestamptz default null,
  p_recipient           text default null,
  p_bounce_kind         text default null,
  p_detail              text default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_event    text := nullif(btrim(coalesce(p_event_id, '')), '');
  v_message  text := nullif(btrim(coalesce(p_provider_message_id, '')), '');
  v_state    text := nullif(lower(btrim(coalesce(p_state, ''))), '');
  v_when     timestamptz := coalesce(p_occurred_at, now());
  v_address  text := lower(nullif(btrim(coalesce(p_recipient, '')), ''));
  v_detail   text := left(nullif(btrim(concat_ws(': ', nullif(btrim(coalesce(p_bounce_kind, '')), ''),
                                                 nullif(btrim(coalesce(p_detail, '')), ''))), ''), 300);
  v_platform uuid;
  v_ce       erp_meta.commercial_email;
  v_note     erp.notification;
  v_matched  text := 'nothing';
  v_tenant   uuid;
  v_moved    boolean := false;
  v_suppress text;
  v_suppressed boolean := false;
  v_id       uuid;
begin
  -- The webhook endpoint calls this over the drain's own connection. Nobody
  -- signed in tells the product that a message was delivered.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record delivery events', current_user
      using errcode = '42501', hint = 'The webhook endpoint records these over its own connection; nobody signed in does.';
  end if;
  if v_event is null or nullif(btrim(coalesce(p_event_type, '')), '') is null then
    raise exception 'CLOVEERP_EMAIL_EVENT_UNIDENTIFIED: an event with no id and type is not an event'
      using errcode = '22023', hint = 'The provider sends both; a request without them is refused before it reaches here.';
  end if;

  select po.tenant_id into v_platform from erp_meta.platform_organisation po;

  -- Which message it is about. The provider's id is what we stored when the
  -- message left, on whichever queue sent it.
  if v_message is not null then
    select * into v_ce from erp_meta.commercial_email ce
     where ce.provider_message_id = v_message
     order by ce.sent_at desc nulls last limit 1;
    if found then
      v_matched := 'commercial_email';
      v_tenant := v_ce.tenant_id;
    else
      select * into v_note from erp.notification n
       where n.provider_message_id = v_message
       order by n.sent_at desc nulls last limit 1;
      if found then
        v_matched := 'notification';
        v_tenant := v_note.tenant_id;
      elsif exists (select 1 from erp_meta.enquiry e
                     where v_message = any (string_to_array(coalesce(e.provider_message_id, ''), ','))) then
        -- An enquiry notice goes to staff, and its row records the ids of every
        -- message it sent. Nothing on it moves; the event is the record.
        v_matched := 'enquiry';
      end if;
    end if;
  end if;

  -- Recorded once, whatever it turned out to be about. A replay changes nothing
  -- and is not an error: the provider retries what it is not sure we heard.
  insert into erp_meta.email_delivery_event
    (event_id, event_type, state, provider_message_id, occurred_at, to_address, bounce_kind, detail,
     matched, commercial_email_id, notification_id, tenant_id)
  values (v_event, left(btrim(p_event_type), 100), v_state, v_message, v_when, v_address,
          nullif(btrim(coalesce(p_bounce_kind, '')), ''), left(nullif(btrim(coalesce(p_detail, '')), ''), 500),
          v_matched, v_ce.id, v_note.id, v_tenant)
  on conflict on constraint email_delivery_event_once do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('recorded', false, 'reason', 'that event was recorded already',
                              'matched', v_matched);
  end if;

  -- The message's own state, when this event moves it forward.
  if v_state is not null and v_matched = 'commercial_email' then
    update erp_meta.commercial_email ce
       set delivery_state = v_state, delivery_state_at = v_when,
           delivery_detail = coalesce(v_detail, ce.delivery_detail)
     where ce.id = v_ce.id
       and erp.email_delivery_rank(v_state) > erp.email_delivery_rank(ce.delivery_state);
    v_moved := found;
  elsif v_state is not null and v_matched = 'notification' then
    update erp.notification n
       set delivery_state = v_state, delivery_state_at = v_when,
           -- The tenant's own screens read status and delivered_at, and have
           -- since before there was a webhook to write them.
           delivered_at = case when v_state in ('delivered', 'opened') then coalesce(n.delivered_at, v_when)
                               else n.delivered_at end,
           status = case when v_state in ('delivered', 'opened') and n.status = 'sent' then 'delivered'
                         when v_state in ('bounced', 'complained') and n.status in ('sent', 'delivered') then 'failed'
                         else n.status end,
           failure_reason = case when v_state in ('bounced', 'complained')
                                 then left(concat_ws(': ', 'the provider could not deliver it', v_detail), 500)
                                 else n.failure_reason end
     where n.id = v_note.id
       and erp.email_delivery_rank(v_state) > erp.email_delivery_rank(n.delivery_state);
    v_moved := found;
  end if;

  -- A permanent bounce or a complaint stops this address being written to
  -- again, by the organisation that wrote to it. A temporary bounce does not:
  -- the mailbox may be full today and empty tomorrow.
  if v_address is not null and v_state in ('bounced', 'complained')
     and (v_state = 'complained' or erp.email_bounce_is_permanent(p_bounce_kind)) then
    v_suppress := case when v_state = 'complained' then 'complaint' else 'hard_bounce' end;
    v_tenant := case when v_matched = 'notification' then v_tenant else v_platform end;
    if v_tenant is not null then
      insert into erp.email_suppression (tenant_id, address, reason, is_permanent, note)
      values (v_tenant, v_address, v_suppress, true,
              left(concat_ws(': ', 'the provider reported a ' || v_suppress, v_detail), 500))
      on conflict (tenant_id, address) do update
        set reason = excluded.reason, is_permanent = true,
            note = coalesce(excluded.note, erp.email_suppression.note);
      v_suppressed := true;
    end if;
  end if;

  -- What a person must see: a message that did not arrive, and an address the
  -- product has stopped writing to. The whole history is the event table.
  if v_state in ('bounced', 'complained') then
    insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, target, reason, detail)
    values ('the email provider', 'system', 'platform.email_' || v_state, v_tenant, v_message,
            coalesce(v_detail, p_event_type),
            jsonb_build_object('event_id', v_event, 'matched', v_matched, 'address', v_address,
                               'suppressed', v_suppressed));
  end if;

  return jsonb_build_object('recorded', true, 'matched', v_matched, 'state', v_state,
                            'moved', v_moved, 'suppressed', v_suppressed);
end;
$$;

revoke all on function erp.record_email_delivery_event(text, text, text, text, timestamptz, text, text, text)
  from public, anon, authenticated;

comment on function erp.record_email_delivery_event(text, text, text, text, timestamptz, text, text, text) is
  'Records one delivery event from the email provider: once per event id, matched '
  'to the commercial email, notification or enquiry notice it names, moving that '
  'message''s delivery state forward only. A permanent bounce or a complaint '
  'suppresses the address for the organisation that wrote to it, and is audited. '
  'Trusted sessions only: the webhook endpoint calls it.';

-- Nothing is sent to an address the provider has told us about.
do $suppression$
declare
  v_sig    constant text := 'erp.claim_commercial_email_batch(integer,text)';
  v_def    text := pg_get_functiondef('erp.claim_commercial_email_batch(integer,text)'::regprocedure);
  v_needle constant text := $n$  -- Nothing is sent for a demonstration, or for a document that no longer
  -- exists.
  with judged as (
    select ce.id,
           (erp.commercial_document_is_demonstration(ce.kind, coalesce(ce.quote_document_id, ce.contract_invoice_id))
            or (ce.tenant_id is not null and erp.tenant_is_demonstration(ce.tenant_id))
            or (ce.quote_tenant_id is not null and erp.tenant_is_demonstration(ce.quote_tenant_id))) as demonstration,
           ((ce.kind = 'order_form'
             and not exists (select 1 from erp.commercial_quote cq
                              where cq.document_id = ce.quote_document_id
                                and cq.order_form_render_id is not null))
            or (ce.tenant_id is not null
                and not exists (select 1 from erp.tenant t where t.id = ce.tenant_id))) as gone
      from erp_meta.commercial_email ce
     where ce.status = 'queued')
  update erp_meta.commercial_email ce
     set status = 'cancelled',
         failure_reason = case when j.demonstration then 'a demonstration organisation sends no email'
                               else 'the document it would send no longer exists' end
    from judged j
   where ce.id = j.id
     and (j.demonstration or j.gone);$n$;
  v_new    constant text := $n$  -- Nothing is sent for a demonstration, for a document that no longer
  -- exists, or to an address the provider has told us to stop writing to
  -- (20260915030000).
  with judged as (
    select ce.id,
           (erp.commercial_document_is_demonstration(ce.kind, coalesce(ce.quote_document_id, ce.contract_invoice_id))
            or (ce.tenant_id is not null and erp.tenant_is_demonstration(ce.tenant_id))
            or (ce.quote_tenant_id is not null and erp.tenant_is_demonstration(ce.quote_tenant_id))) as demonstration,
           ((ce.kind = 'order_form'
             and not exists (select 1 from erp.commercial_quote cq
                              where cq.document_id = ce.quote_document_id
                                and cq.order_form_render_id is not null))
            or (ce.tenant_id is not null
                and not exists (select 1 from erp.tenant t where t.id = ce.tenant_id))) as gone,
           exists (select 1 from erp.email_suppression s
                    where s.tenant_id = v_platform
                      and s.address = lower(btrim(ce.to_address))) as suppressed
      from erp_meta.commercial_email ce
     where ce.status = 'queued')
  update erp_meta.commercial_email ce
     set status = 'cancelled',
         failure_reason = case when j.demonstration then 'a demonstration organisation sends no email'
                               when j.suppressed then 'the provider reported this address as undeliverable or a complaint; clear the suppression to write to it again'
                               else 'the document it would send no longer exists' end
    from judged j
   where ce.id = j.id
     and (j.demonstration or j.gone or j.suppressed);$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not cancel what it must not send exactly once, so it is not the 20260914097300 body', v_sig
      using hint = 'A later migration changed what the claim cancels. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('j.suppressed' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$suppression$;

-- The console's send history says what became of each message.
do $sends$
declare
  v_sig    constant text := 'erp.commercial_email_sends(uuid,uuid)';
  v_def    text := pg_get_functiondef('erp.commercial_email_sends(uuid,uuid)'::regprocedure);
  v_needle constant text := $n$           'document_problem', e.document_problem)$n$;
  v_new    constant text := $n$           'document_problem', e.document_problem,
           'delivery_state', e.delivery_state, 'delivery_state_at', e.delivery_state_at,
           'delivery_detail', e.delivery_detail)$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry its document fields exactly once, so it is not the 20260915020000 body', v_sig
      using hint = 'A later migration changed what a send says. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('''delivery_state''' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$sends$;

-- Today says how far the chase has got on each overdue invoice.
do $open_invoices$
declare
  v_sig    constant text := 'public.erp_platform_open_invoices()';
  v_def    text := pg_get_functiondef('public.erp_platform_open_invoices()'::regprocedure);
  v_needle constant text := $n$             'days_overdue', greatest(current_date - i.due_on, 0))$n$;
  v_new    constant text := $n$             'days_overdue', greatest(current_date - i.due_on, 0),
             -- How far the chase has got (20260915030000).
             'reminders_sent', s.reminders_sent, 'last_reminder_at', s.last_reminder_at)$n$;
  v_from   constant text := $n$      from erp_meta.contract_invoice i
      join erp_meta.contract c on c.id = i.contract_id$n$;
  v_from_new constant text := $n$      from erp_meta.contract_invoice i
      join erp_meta.contract c on c.id = i.contract_id
      cross join lateral erp.invoice_reminder_state(i.id) s$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1
     or (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914082000 body this migration patches', v_sig
      using hint = 'A later migration changed what Today reads about open invoices. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(replace(v_def, v_needle, v_new), v_from, v_from_new);
  if position('erp.invoice_reminder_state(i.id)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the function.';
  end if;
end
$open_invoices$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. What the console sees, and what an operator can do about it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_platform_email_delivery(p_limit integer default 50)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_platform uuid;
  v_limit    integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  perform erp_meta.require_platform('support');
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  return jsonb_build_object(
    'trouble', coalesce((
      select jsonb_agg(jsonb_build_object(
               'event_id', x.event_id, 'state', x.state, 'occurred_at', x.occurred_at,
               'to_address', x.to_address, 'bounce_kind', x.bounce_kind, 'detail', x.detail,
               'matched', x.matched, 'suppressed', x.suppressed,
               'kind', x.kind, 'document_id', x.document_id, 'tenant_code', x.tenant_code)
             order by x.occurred_at desc)
        from (select ev.event_id, ev.state, ev.occurred_at, ev.to_address, ev.bounce_kind, ev.detail,
                     ev.matched, ev.suppressed, ce.kind,
                     coalesce(ce.quote_document_id, ce.contract_invoice_id) as document_id,
                     coalesce(ce.tenant_code, t.code) as tenant_code
                from erp_meta.email_delivery_event ev
                left join erp_meta.commercial_email ce on ce.id = ev.commercial_email_id
                left join erp.tenant t on t.id = ev.tenant_id
               where ev.state in ('bounced', 'complained')
               order by ev.occurred_at desc
               limit v_limit) x), '[]'::jsonb),
    'suppressed', coalesce((
      select jsonb_agg(jsonb_build_object(
               'address', s.address, 'reason', s.reason, 'suppressed_at', s.suppressed_at,
               'note', s.note)
             order by s.suppressed_at desc)
        from erp.email_suppression s
       where s.tenant_id = v_platform), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_object_agg(x.state, x.n)
        from (select ev.state, count(*) as n
                from erp_meta.email_delivery_event ev
               where ev.state is not null
                 and ev.received_at > now() - interval '30 days'
               group by ev.state) x), '{}'::jsonb));
end;
$$;

revoke all on function public.erp_platform_email_delivery(integer) from public, anon;
grant execute on function public.erp_platform_email_delivery(integer) to authenticated, service_role;

comment on function public.erp_platform_email_delivery(integer) is
  'What the email provider has said lately: every bounce and complaint with the '
  'message it was about, the addresses the platform has stopped writing to, and '
  'a count of each state in the last thirty days. Platform support and above.';

create or replace function public.erp_platform_clear_email_suppression(p_address text, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v          erp_meta.platform_staff;
  v_platform uuid;
  v_address  text := lower(nullif(btrim(coalesce(p_address, '')), ''));
  v_row      erp.email_suppression;
begin
  v := erp_meta.require_platform('operator');
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  delete from erp.email_suppression s
   where s.tenant_id = v_platform and s.address = v_address
  returning * into v_row;
  if not found then
    raise exception 'CLOVEERP_EMAIL_SUPPRESSION_NOT_FOUND: nothing is stopping email to %', coalesce(v_address, 'that address')
      using errcode = 'P0002', hint = 'The list on Jobs and queue shows the addresses that are suppressed.';
  end if;
  perform erp_meta.platform_log(v, 'platform.email_suppression_cleared', v_platform, v_address,
                                coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'cleared by an operator'),
                                jsonb_build_object('reason_it_was_suppressed', v_row.reason,
                                                   'suppressed_at', v_row.suppressed_at));
  return jsonb_build_object('address', v_address, 'cleared', true, 'was', v_row.reason);
end;
$$;

revoke all on function public.erp_platform_clear_email_suppression(text, text) from public, anon;
grant execute on function public.erp_platform_clear_email_suppression(text, text) to authenticated, service_role;

comment on function public.erp_platform_clear_email_suppression(text, text) is
  'Writes to an address again after a bounce or a complaint: removes the '
  'platform organisation''s suppression of it and records who decided that. '
  'Platform staff at operator and above.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Registration
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_email_delivery', 'erp_meta.require_platform',
   'Platform staff read what the provider said about the product''s email. Volatile because the gate binds the staff identity on first sight, which is the write.'),
  ('erp_platform_clear_email_suppression', 'erp_meta.require_platform',
   'An operator decides that an address bounced or complained about may be written to again, and the decision is recorded.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_email_delivery',
   'Reads erp_meta.email_delivery_event, erp_meta.commercial_email and erp.email_suppression, platform_internal and across organisations. Gated by erp_meta.require_platform(''support'') on its first line.'),
  ('public', 'erp_platform_clear_email_suppression',
   'Deletes the platform organisation''s suppression of one address and audits it. Gated by erp_meta.require_platform(''operator'') on its first line.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_INVOICE_NOT_CHASEABLE',
  'Chasing an invoice that is not issued, or that is not yet past its due date.',
  'Only an issued invoice past its due date is chased: paying it or voiding it ends the chase, and nothing is chased before it is due.',
  'Check the invoice on the contract. If it is paid, there is nothing to chase; if it is not due yet, the sweep will chase it the day after it falls due.');

select erp.register_refusal('CLOVEERP_INVOICE_REMINDER_LIMIT',
  'Sending a reminder beyond the four an unpaid invoice is chased with.',
  'Four reminders is the whole automatic chase. After that the answer is a person, not another email.',
  'Speak to the customer, or record the payment if it has arrived.');

select erp.register_refusal('CLOVEERP_EMAIL_EVENT_UNIDENTIFIED',
  'Recording a delivery event that carries no id or no type.',
  'An event is recorded once, by the provider''s own id for it; without one there is no way to know whether it has been seen before.',
  'Nothing to do: the endpoint refuses a request like this before it reaches the database.');

select erp.register_refusal('CLOVEERP_EMAIL_SUPPRESSION_NOT_FOUND',
  'Clearing a suppression for an address that is not suppressed.',
  'Nothing is stopping email to that address, so there is nothing to clear.',
  'Check the address against the suppressed list on Jobs and queue.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suites
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Both provision their own organisations, people and staff inside a block that
-- is rolled back at the end, so they run on the live database when this
-- migration is deployed and leave nothing behind. No message ever leaves: a
-- queued row is as far as either suite goes.

create or replace function erp_test.invoice_chase_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag       text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_pcode     text;
  v_ccode     text;
  v_dcode     text;
  a_admin     uuid := gen_random_uuid();
  a_owner     uuid := gen_random_uuid();
  a_customer  uuid := gen_random_uuid();
  a_demo      uuid := gen_random_uuid();
  v_step      text := 'starting';
  v_state     text;
  rp          record;
  rc          record;
  rd          record;
  c           record;
  v_platform  uuid;
  v_customer  uuid;
  v_q         uuid;
  v_contract  uuid;
  v_inv       uuid;
  v_inv2      uuid;
  v_reference text;
  v_demo_q    uuid;
  v_demo_ct   uuid;
  v_demo_inv  uuid;
  v_n         integer;
  v_rows      integer;
  i           integer;
  res         jsonb;
  v_payload   jsonb;

  ok_early    boolean; msg_early    text;
  ok_first    boolean; msg_first    text;
  ok_wait     boolean; msg_wait     text;
  ok_four     boolean; msg_four     text;
  ok_paid     boolean; msg_paid     text;
  ok_payload  boolean; msg_payload  text;
  ok_demo     boolean; msg_demo     text;
begin
  begin
    v_pcode := 'zzicp-' || v_tag;
    v_ccode := 'zzicc-' || v_tag;
    -- A demonstration organisation is one whose code begins demo-.
    v_dcode := 'demo-zzicd-' || v_tag;

    v_step := 'the organisations are provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Chase', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into rc from erp.provision_tenant(v_ccode, 'Chase Customer Ltd', 'admin@' || v_ccode || '.test', 'Customer Admin');
    v_customer := rc.tenant_id;
    select * into rd from erp.provision_tenant(v_dcode, 'Demonstration Customer Ltd', 'admin@' || v_dcode || '.test', 'Demo Admin');
    insert into auth.users (id, email) values
      (a_admin, 'admin@' || v_pcode || '.test'),
      (a_owner, 'owner@' || v_pcode || '.test'),
      (a_customer, 'admin@' || v_ccode || '.test'),
      (a_demo, 'admin@' || v_dcode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('owner@' || v_pcode || '.test', a_owner, 'Chase Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_demo)::text, true);
    perform erp.claim_invitation(rd.admin_token);

    v_step := 'the platform organisation is designated and sells the list';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'the invoice chase suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_platform);

    v_step := 'a contract is signed and its first invoice issued';
    v_q := erp.open_commercial_quote('ZZCHASE', 'Chase Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30, v_ccode);
    perform erp.add_quote_line(v_q, 'PLAN-STANDARD', 1, 10);
    perform erp.submit_quote(v_q);
    perform erp.issue_quote(v_q);
    perform erp.quote_transition(v_q, 'accept', 'order form returned signed');
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    v_contract := erp.create_contract_from_quote(v_q, v_ccode, 'Chase Customer Ltd', 'Clove ERP Ltd', current_date,
                                                 12, 'automatic', 90, 'England and Wales', 'monthly');
    perform erp.sign_contract(v_contract, 'A. Customer, director', 'Chase Owner, director', 'agreement to the order form');
    perform erp.generate_invoice_schedule(v_contract);
    res := public.erp_platform_set_billing_contact(v_contract, 'accounts@' || v_ccode || '.test', 'Accounts Team');
    select i.id, i.reference into v_inv, v_reference
      from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq limit 1;
    select i.id into v_inv2 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq offset 1 limit 1;
    perform erp.issue_contract_invoice(v_inv);

    -- ── Nothing is chased before it is due ──────────────────────────────────
    v_step := 'the sweep runs while the invoice is not yet due';
    update erp_meta.contract_invoice set due_on = current_date + 1 where id = v_inv;
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    select count(*) into v_n from erp.chase_overdue_invoices();
    ok_early := v_n = 0
            and not exists (select 1 from erp_meta.commercial_email e
                             where e.contract_invoice_id = v_inv and e.kind = 'invoice_reminder');
    begin
      perform erp.queue_invoice_reminder(v_inv, 1);
      ok_early := false; msg_early := 'an invoice that is not due was chased by hand';
    exception when others then
      ok_early := ok_early and sqlerrm like 'CLOVEERP_INVOICE_NOT_CHASEABLE%';
      msg_early := 'nothing while it is not due; by hand: ' || left(sqlerrm, 60);
    end;

    -- ── The day after it falls due ──────────────────────────────────────────
    v_step := 'the sweep runs the day after the invoice falls due';
    update erp_meta.contract_invoice set due_on = current_date - 1 where id = v_inv;
    select count(*) into v_n from erp.chase_overdue_invoices();
    select count(*) into v_rows from erp_meta.commercial_email e
     where e.contract_invoice_id = v_inv and e.kind = 'invoice_reminder';
    ok_first := v_n = 1 and v_rows = 1
            and exists (select 1 from erp_meta.commercial_email e
                         where e.contract_invoice_id = v_inv and e.kind = 'invoice_reminder'
                           and e.send_number = 1 and e.status = 'queued'
                           and e.to_address = 'accounts@' || v_ccode || '.test'
                           and e.recipient_source = 'billing_contact'
                           and e.tenant_id = v_customer
                           and e.requested_by = 'the invoice reminder sweep');
    -- Twice in one day is once.
    perform erp.chase_overdue_invoices();
    select count(*) into v_rows from erp_meta.commercial_email e
     where e.contract_invoice_id = v_inv and e.kind = 'invoice_reminder';
    ok_first := ok_first and v_rows = 1;
    msg_first := format('%s reminder row(s) after two sweeps in a day', v_rows);

    -- ── The next waits a week ───────────────────────────────────────────────
    v_step := 'the sweep runs again three days later, and then a week later';
    update erp_meta.commercial_email set created_at = now() - interval '3 days'
     where contract_invoice_id = v_inv and kind = 'invoice_reminder';
    select count(*) into v_n from erp.chase_overdue_invoices();
    ok_wait := v_n = 0;
    update erp_meta.commercial_email set created_at = now() - interval '8 days'
     where contract_invoice_id = v_inv and kind = 'invoice_reminder';
    select count(*) into v_n from erp.chase_overdue_invoices();
    ok_wait := ok_wait and v_n = 1
           and exists (select 1 from erp_meta.commercial_email e
                        where e.contract_invoice_id = v_inv and e.kind = 'invoice_reminder'
                          and e.send_number = 2);
    msg_wait := 'nothing on the third day; the second reminder on the eighth';

    -- ── Four, and no more ───────────────────────────────────────────────────
    v_step := 'the sweep runs week after week';
    for i in 1 .. 4 loop
      update erp_meta.commercial_email set created_at = now() - interval '8 days'
       where contract_invoice_id = v_inv and kind = 'invoice_reminder';
      perform erp.chase_overdue_invoices();
    end loop;
    select coalesce(max(e.send_number), 0) into v_n from erp_meta.commercial_email e
     where e.contract_invoice_id = v_inv and e.kind = 'invoice_reminder';
    ok_four := v_n = 4;
    begin
      perform erp.queue_invoice_reminder(v_inv, 5);
      ok_four := false; msg_four := 'a fifth reminder was queued';
    exception when others then
      ok_four := ok_four and sqlerrm like 'CLOVEERP_INVOICE_REMINDER_LIMIT%';
      msg_four := format('%s reminders, and the fifth is refused: %s', v_n, left(sqlerrm, 50));
    end;

    -- ── Paying it ends the chase ────────────────────────────────────────────
    v_step := 'the second invoice is issued, falls due, and is paid';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.issue_contract_invoice(v_inv2);
    update erp_meta.contract_invoice set due_on = current_date - 30 where id = v_inv2;
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.chase_overdue_invoices();
    select count(*) into v_rows from erp_meta.commercial_email e
     where e.contract_invoice_id = v_inv2 and e.kind = 'invoice_reminder';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.record_invoice_paid(v_inv2, 'zz-chase-payment');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    update erp_meta.commercial_email set created_at = now() - interval '8 days'
     where contract_invoice_id = v_inv2 and kind = 'invoice_reminder';
    perform erp.chase_overdue_invoices();
    ok_paid := v_rows = 1
           and (select count(*) from erp_meta.commercial_email e
                 where e.contract_invoice_id = v_inv2 and e.kind = 'invoice_reminder') = 1;
    begin
      perform erp.queue_invoice_reminder(v_inv2, 2);
      ok_paid := false; msg_paid := 'a paid invoice was chased';
    exception when others then
      ok_paid := ok_paid and sqlerrm like 'CLOVEERP_INVOICE_NOT_CHASEABLE%';
      msg_paid := 'one reminder before it was paid, none after: ' || left(sqlerrm, 50);
    end;

    -- ── What the reminder carries ───────────────────────────────────────────
    v_step := 'the drain claims a reminder from a connection with no organisation';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    for c in select * from erp.claim_commercial_email_batch(500, 'zz-invoice-chase') loop
      if c.email_kind = 'invoice_reminder'
         and c.email_id in (select e.id from erp_meta.commercial_email e where e.contract_invoice_id = v_inv) then
        v_payload := c.payload;
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
    ok_payload := v_payload ->> 'kind' = 'invoice_reminder'
              and (v_payload ->> 'reminder_number')::integer between 1 and 4
              and (v_payload ->> 'days_overdue')::integer >= 1
              and v_payload ->> 'reference' = v_reference
              and v_payload ->> 'filename' = 'Invoice-' || v_reference || '.pdf'
              and (v_payload ->> 'total_minor')::bigint > 0
              and v_payload -> 'payment_details' is not null
              and erp_test.keys_naming_cost_or_margin(v_payload) is null;
    msg_payload := format('reminder %s, %s days overdue, %s',
                          coalesce(v_payload ->> 'reminder_number', 'none'),
                          coalesce(v_payload ->> 'days_overdue', 'none'),
                          coalesce(v_payload ->> 'filename', 'no file name'));

    -- ── A demonstration is never chased ─────────────────────────────────────
    v_step := 'a demonstration organisation has an overdue invoice';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_demo_q := erp.open_commercial_quote('ZZCHASEDEMO', 'Demonstration Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30, v_dcode);
    perform erp.add_quote_line(v_demo_q, 'PLAN-STANDARD', 1, 10);
    perform erp.submit_quote(v_demo_q);
    perform erp.issue_quote(v_demo_q);
    perform erp.quote_transition(v_demo_q, 'accept', 'order form returned signed');
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    v_demo_ct := erp.create_contract_from_quote(v_demo_q, v_dcode, 'Demonstration Customer Ltd', 'Clove ERP Ltd', current_date,
                                                12, 'automatic', 90, 'England and Wales', 'monthly');
    perform erp.sign_contract(v_demo_ct, 'A. Demo, director', 'Chase Owner, director', 'agreement to the order form');
    perform erp.generate_invoice_schedule(v_demo_ct);
    select i.id into v_demo_inv from erp_meta.contract_invoice i where i.contract_id = v_demo_ct order by i.seq limit 1;
    perform erp.issue_contract_invoice(v_demo_inv);
    update erp_meta.contract_invoice set due_on = current_date - 20 where id = v_demo_inv;
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.chase_overdue_invoices();
    ok_demo := not exists (select 1 from erp_meta.commercial_email e
                            where e.contract_invoice_id = v_demo_inv)
           and erp.queue_invoice_reminder(v_demo_inv, 1) = 0;
    msg_demo := 'a demonstration organisation is invoiced and chased by nobody';

    v_step := 'done';
    raise exception 'ZZ_INVOICE_CHASE_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_INVOICE_CHASE_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'an invoice that is not yet due is chased by nobody';
  passed := v_state is null and coalesce(ok_early, false);
  detail := coalesce(v_state, msg_early);
  return next;

  case_name := 'the first reminder goes the day after it falls due, once, to the people the invoice went to';
  passed := v_state is null and coalesce(ok_first, false);
  detail := coalesce(v_state, msg_first);
  return next;

  case_name := 'the next reminder waits seven days';
  passed := v_state is null and coalesce(ok_wait, false);
  detail := coalesce(v_state, msg_wait);
  return next;

  case_name := 'four reminders is the whole chase';
  passed := v_state is null and coalesce(ok_four, false);
  detail := coalesce(v_state, msg_four);
  return next;

  case_name := 'recording the payment ends the chase';
  passed := v_state is null and coalesce(ok_paid, false);
  detail := coalesce(v_state, msg_paid);
  return next;

  case_name := 'the reminder carries the invoice, its number, how overdue it is, and no cost or margin';
  passed := v_state is null and coalesce(ok_payload, false);
  detail := coalesce(v_state, msg_payload);
  return next;

  case_name := 'a demonstration organisation is never chased';
  passed := v_state is null and coalesce(ok_demo, false);
  detail := coalesce(v_state, msg_demo);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ccode, v_dcode))
        and not exists (select 1 from auth.users au where au.id in (a_admin, a_owner, a_customer, a_demo))
        and not exists (select 1 from erp_meta.commercial_email e where e.kind = 'invoice_reminder'
                          and e.requested_by = 'the invoice reminder sweep'
                          and e.tenant_code in (v_ccode, v_dcode))
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'the organisations, people, staff, contracts, invoices, reminders and every setting went with the block';
  return next;
end;
$$;

revoke all on function erp_test.invoice_chase_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invoice_chase_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _invoice_chase_result on commit drop as
    select * from erp_test.invoice_chase_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _invoice_chase_result s;
  drop table _invoice_chase_result;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVOICE_CHASE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_INVOICE_CHASE_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('chasing invoices: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_invoice_chase_suite() from public, anon, authenticated;

create or replace function erp_test.email_tracking_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag       text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_pcode     text;
  v_ccode     text;
  a_admin     uuid := gen_random_uuid();
  a_owner     uuid := gen_random_uuid();
  a_support   uuid := gen_random_uuid();
  a_customer  uuid := gen_random_uuid();
  v_step      text := 'starting';
  v_state     text;
  rp          record;
  rc          record;
  v_platform  uuid;
  v_customer  uuid;
  v_person    uuid;
  v_contract  uuid;
  v_invoice   uuid;
  ce_sent     uuid;
  ce_queued   uuid;
  ce_bounce   uuid;
  ce_soft     uuid;
  v_note      uuid;
  v_address   text;
  v_gone      text;
  v_soft      text;
  res         jsonb;
  n           erp.notification;
  e           erp_meta.commercial_email;

  ok_once     boolean; msg_once     text;
  ok_order    boolean; msg_order    text;
  ok_bounce   boolean; msg_bounce   text;
  ok_soft     boolean; msg_soft     text;
  ok_stop     boolean; msg_stop     text;
  ok_clear    boolean; msg_clear    text;
  ok_note     boolean; msg_note     text;
  ok_console  boolean; msg_console  text;
begin
  begin
    v_pcode := 'zzetp-' || v_tag;
    v_ccode := 'zzetc-' || v_tag;
    v_address := 'accounts@' || v_ccode || '.test';
    v_gone := 'gone@' || v_ccode || '.test';
    v_soft := 'full@' || v_ccode || '.test';

    v_step := 'the organisations, the staff and one sent invoice email';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Tracking', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into rc from erp.provision_tenant(v_ccode, 'Tracking Customer Ltd', 'admin@' || v_ccode || '.test', 'Customer Admin');
    v_customer := rc.tenant_id;
    insert into auth.users (id, email) values
      (a_admin, 'admin@' || v_pcode || '.test'),
      (a_owner, 'owner@' || v_pcode || '.test'),
      (a_support, 'support@' || v_pcode || '.test'),
      (a_customer, 'admin@' || v_ccode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('owner@' || v_pcode || '.test', a_owner, 'Tracking Owner', 'owner'),
      ('support@' || v_pcode || '.test', a_support, 'Tracking Support', 'support');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'the email tracking suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_platform);
    perform set_config('request.jwt.claims', '', true);

    -- A contract and an invoice, written directly: what is proved here is what
    -- becomes of the email, not how the invoice came to exist.
    insert into erp_meta.contract
      (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
       customer_legal_name, platform_legal_name, plan_code, term_kind, currency, annual_value_minor,
       commencement, initial_term_months, current_term_start, current_term_end, governing_law, status)
    values (v_customer, v_ccode, v_platform, gen_random_uuid(), 'ZZTRACK-1', 1,
            'Tracking Customer Ltd', 'Clove ERP Ltd', (select p.code from erp_meta.plan p order by p.code limit 1),
            'annual', 'GBP', 1200000, current_date, 12, current_date, current_date + 365,
            'England and Wales', 'active')
    returning id into v_contract;
    insert into erp_meta.contract_invoice
      (contract_id, tenant_id, tenant_code, seq, reference, period_start, period_end, due_on,
       currency, subscription_minor, total_minor, status, issued_at)
    values (v_contract, v_customer, v_ccode, 1, 'ZZTRACK-INV-' || v_tag, current_date, current_date + 30,
            current_date + 14, 'GBP', 100000, 100000, 'issued', now())
    returning id into v_invoice;

    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, provider_message_id, sent_at, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 1, v_address, 'Accounts Team',
            'billing_contact', 'sent', 'zz-msg-' || v_tag, now(), 'owner@' || v_pcode || '.test',
            'zz-key-sent-' || v_tag)
    returning id into ce_sent;
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 2, v_address, 'Accounts Team',
            'billing_contact', 'queued', 'owner@' || v_pcode || '.test', 'zz-key-queued-' || v_tag)
    returning id into ce_queued;
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, provider_message_id, sent_at, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 3, v_gone, 'Somebody Gone',
            'administrator', 'sent', 'zz-bounce-' || v_tag, now(), 'owner@' || v_pcode || '.test',
            'zz-key-bounce-' || v_tag)
    returning id into ce_bounce;
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, provider_message_id, sent_at, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 4, v_soft, 'Full Mailbox',
            'administrator', 'sent', 'zz-soft-' || v_tag, now(), 'owner@' || v_pcode || '.test',
            'zz-key-soft-' || v_tag)
    returning id into ce_soft;

    select u.id into v_person from erp.app_user u
     where u.tenant_id = v_customer and u.auth_user_id = a_customer;
    -- The customer's own organisation is the context its notification is written in.
    perform erp.set_job_tenant(v_customer);
    insert into erp.notification
      (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, provider_message_id)
    values (v_customer, 'info', v_person, 'email', 'Something happened', 'A message the provider took.',
            'sent', now(), 'zz-note-' || v_tag)
    returning id into v_note;
    perform set_config('erp.job_tenant_id', '', true);

    -- ── One event, recorded once ────────────────────────────────────────────
    v_step := 'the provider says the invoice email was delivered, twice';
    res := erp.record_email_delivery_event('evt-delivered-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    select * into e from erp_meta.commercial_email where id = ce_sent;
    ok_once := (res ->> 'recorded')::boolean
           and res ->> 'matched' = 'commercial_email'
           and (res ->> 'moved')::boolean
           and e.delivery_state = 'delivered' and e.delivery_state_at is not null
           and e.status = 'sent';
    res := erp.record_email_delivery_event('evt-delivered-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    ok_once := ok_once and not (res ->> 'recorded')::boolean
           and res ->> 'reason' = 'that event was recorded already'
           and (select count(*) from erp_meta.email_delivery_event ev
                 where ev.event_id = 'evt-delivered-' || v_tag) = 1;
    msg_once := format('delivered, recorded %s time(s)',
                       (select count(*) from erp_meta.email_delivery_event ev
                         where ev.event_id = 'evt-delivered-' || v_tag));

    -- ── A state never goes backwards ────────────────────────────────────────
    v_step := 'a late "sent" arrives after the delivery, and then an "opened"';
    res := erp.record_email_delivery_event('evt-late-sent-' || v_tag, 'email.sent', 'sent',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    select * into e from erp_meta.commercial_email where id = ce_sent;
    ok_order := (res ->> 'recorded')::boolean and not (res ->> 'moved')::boolean
            and e.delivery_state = 'delivered';
    res := erp.record_email_delivery_event('evt-opened-' || v_tag, 'email.opened', 'opened',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    select * into e from erp_meta.commercial_email where id = ce_sent;
    ok_order := ok_order and (res ->> 'moved')::boolean and e.delivery_state = 'opened';
    msg_order := 'a late send changed nothing; an open moved it on';

    -- ── A permanent bounce ──────────────────────────────────────────────────
    v_step := 'an address bounces permanently';
    res := erp.record_email_delivery_event('evt-bounce-' || v_tag, 'email.bounced', 'bounced',
                                           'zz-bounce-' || v_tag, now(), v_gone, 'Permanent/Suppressed',
                                           'The recipient does not exist.');
    select * into e from erp_meta.commercial_email where id = ce_bounce;
    ok_bounce := e.delivery_state = 'bounced'
             and e.delivery_detail like 'Permanent/Suppressed%'
             and (res ->> 'suppressed')::boolean
             and exists (select 1 from erp.email_suppression s
                          where s.tenant_id = v_platform and s.address = v_gone
                            and s.reason = 'hard_bounce' and s.is_permanent)
             and exists (select 1 from erp_meta.platform_audit a
                          where a.action = 'platform.email_bounced' and a.target = 'zz-bounce-' || v_tag);
    msg_bounce := 'bounced, suppressed and audited';

    -- ── A temporary one is not a fact about the address ─────────────────────
    v_step := 'a mailbox is full today';
    res := erp.record_email_delivery_event('evt-soft-' || v_tag, 'email.bounced', 'bounced',
                                           'zz-soft-' || v_tag, now(), v_soft, 'Transient/MailboxFull',
                                           'The mailbox is full.');
    ok_soft := not (res ->> 'suppressed')::boolean
           and not exists (select 1 from erp.email_suppression s
                            where s.tenant_id = v_platform and s.address = v_soft)
           and (select ce.delivery_state from erp_meta.commercial_email ce where ce.id = ce_soft) = 'bounced';
    msg_soft := 'a temporary bounce is recorded and suppresses nothing';

    -- ── A complaint stops the next one ──────────────────────────────────────
    v_step := 'the customer marks it as spam, and the drain claims what is queued';
    res := erp.record_email_delivery_event('evt-complaint-' || v_tag, 'email.complained', 'complained',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    ok_stop := (res ->> 'suppressed')::boolean
           and exists (select 1 from erp.email_suppression s
                        where s.tenant_id = v_platform and s.address = v_address
                          and s.reason = 'complaint' and s.is_permanent);
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform erp.claim_commercial_email_batch(500, 'zz-email-tracking');
    perform set_config('erp.job_tenant_id', '', true);
    select * into e from erp_meta.commercial_email where id = ce_queued;
    ok_stop := ok_stop and e.status = 'cancelled'
           and e.failure_reason like 'the provider reported this address as undeliverable%';
    msg_stop := format('the queued message was %s: %s', e.status, left(coalesce(e.failure_reason, ''), 60));

    -- ── An operator decides otherwise ───────────────────────────────────────
    v_step := 'an operator clears the suppression, and a customer tries to';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    res := public.erp_platform_clear_email_suppression(v_address, 'the customer asked us to write again');
    ok_clear := (res ->> 'cleared')::boolean and res ->> 'was' = 'complaint'
            and not exists (select 1 from erp.email_suppression s
                             where s.tenant_id = v_platform and s.address = v_address)
            and exists (select 1 from erp_meta.platform_audit a
                         where a.action = 'platform.email_suppression_cleared' and a.target = v_address);
    begin
      perform public.erp_platform_clear_email_suppression(v_address, null);
      ok_clear := false; msg_clear := 'clearing a suppression that does not exist said it did';
    exception when others then
      ok_clear := ok_clear and sqlerrm like 'CLOVEERP_EMAIL_SUPPRESSION_NOT_FOUND%';
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    begin
      perform public.erp_platform_clear_email_suppression(v_gone, null);
      ok_clear := false; msg_clear := 'a customer cleared a suppression';
    exception when others then
      ok_clear := ok_clear and sqlerrm like 'CLOVEERP_NOT_PLATFORM_STAFF%';
      msg_clear := 'the operator cleared it; nobody else can';
    end;

    -- ── The other queue, and an event about nothing we sent ─────────────────
    v_step := 'the provider answers about a notification, and about a message we never sent';
    res := erp.record_email_delivery_event('evt-note-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-note-' || v_tag, now(), 'admin@' || v_ccode || '.test', null, null);
    select * into n from erp.notification where id = v_note;
    ok_note := res ->> 'matched' = 'notification'
           and n.status = 'delivered' and n.delivered_at is not null
           and n.delivery_state = 'delivered';
    res := erp.record_email_delivery_event('evt-stranger-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-nobody-' || v_tag, now(), 'somebody@example.test', null, null);
    ok_note := ok_note and (res ->> 'recorded')::boolean and res ->> 'matched' = 'nothing'
           and exists (select 1 from erp_meta.email_delivery_event ev
                        where ev.event_id = 'evt-stranger-' || v_tag and ev.matched = 'nothing');
    msg_note := 'the notification was delivered; an event about nothing is still recorded';

    -- ── What the console reads ──────────────────────────────────────────────
    v_step := 'support reads what the provider has said, and a customer asks to';
    perform set_config('request.jwt.claims', json_build_object('sub', a_support)::text, true);
    res := public.erp_platform_email_delivery(50);
    ok_console := exists (select 1 from jsonb_array_elements(res -> 'trouble') x
                           where x ->> 'to_address' = v_gone and x ->> 'state' = 'bounced'
                             and (x ->> 'suppressed')::boolean)
              and exists (select 1 from jsonb_array_elements(res -> 'suppressed') x
                           where x ->> 'address' = v_gone and x ->> 'reason' = 'hard_bounce')
              and (res -> 'recent' ->> 'delivered')::integer >= 1;
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    begin
      perform public.erp_platform_email_delivery(50);
      ok_console := false; msg_console := 'a customer read the platform''s delivery log';
    exception when others then
      ok_console := ok_console and sqlerrm like 'CLOVEERP_NOT_PLATFORM_STAFF%';
      msg_console := 'support reads the bounces and the suppressed list; a customer is refused';
    end;

    v_step := 'done';
    raise exception 'ZZ_EMAIL_TRACKING_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_EMAIL_TRACKING_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'a delivery is recorded once, and says so the second time';
  passed := v_state is null and coalesce(ok_once, false);
  detail := coalesce(v_state, msg_once);
  return next;

  case_name := 'an event that arrives late cannot move a message backwards';
  passed := v_state is null and coalesce(ok_order, false);
  detail := coalesce(v_state, msg_order);
  return next;

  case_name := 'a permanent bounce is recorded, suppresses the address and is audited';
  passed := v_state is null and coalesce(ok_bounce, false);
  detail := coalesce(v_state, msg_bounce);
  return next;

  case_name := 'a temporary bounce suppresses nothing';
  passed := v_state is null and coalesce(ok_soft, false);
  detail := coalesce(v_state, msg_soft);
  return next;

  case_name := 'a complaint stops the next message to that address, with a reason a person can read';
  passed := v_state is null and coalesce(ok_stop, false);
  detail := coalesce(v_state, msg_stop);
  return next;

  case_name := 'an operator clears a suppression and it is recorded; a customer cannot';
  passed := v_state is null and coalesce(ok_clear, false);
  detail := coalesce(v_state, msg_clear);
  return next;

  case_name := 'a notification is tracked too, and an event about nothing we sent is still kept';
  passed := v_state is null and coalesce(ok_note, false);
  detail := coalesce(v_state, msg_note);
  return next;

  case_name := 'platform staff read the bounces and the suppressed addresses; a customer is refused';
  passed := v_state is null and coalesce(ok_console, false);
  detail := coalesce(v_state, msg_console);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ccode))
        and not exists (select 1 from auth.users au where au.id in (a_admin, a_owner, a_support, a_customer))
        and not exists (select 1 from erp_meta.email_delivery_event ev where ev.event_id like '%' || v_tag)
        and not exists (select 1 from erp.email_suppression s where s.address like '%' || v_ccode || '.test')
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'the organisations, people, staff, messages, events, suppressions and every setting went with the block';
  return next;
end;
$$;

revoke all on function erp_test.email_tracking_suite() from public, anon, authenticated;

create or replace function erp_test.assert_email_tracking_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _email_tracking_result on commit drop as
    select * from erp_test.email_tracking_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _email_tracking_result s;
  drop table _email_tracking_result;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_EMAIL_TRACKING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_EMAIL_TRACKING_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('email tracking: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_email_tracking_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_personal_data_register_sound();
select erp.assert_suite_verdicts_strict();
select erp.assert_job_handlers_resolvable();
select erp.assert_scheduler_integrity();
select erp_test.assert_commercial_email_suite();
select erp_test.assert_commercial_document_suite();
select erp_test.assert_invoice_chase_suite();
select erp_test.assert_email_tracking_suite();
