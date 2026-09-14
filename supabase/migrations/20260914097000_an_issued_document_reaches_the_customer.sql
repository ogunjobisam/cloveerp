-- =============================================================================
-- An issued document reaches the customer
--
-- Issuing an order form or a contract invoice wrote a record and told nobody
-- outside the console. The order form was rendered, archived and fingerprinted,
-- and the person it was for heard of it only if somebody at Clove ERP copied it
-- into an email by hand. An invoice was issued with a due date and a total, and
-- the customer read it only if an administrator happened to open Your
-- agreement. The owner decided on 14 September that both go out the moment
-- they are issued.
--
--   1. Who it goes to.
--      An order form goes to the customer contact the quote records: the
--      business partner's contact with an email address, the default one first.
--      A quote made for an organisation already on Clove ERP with no contact
--      goes to that organisation's administrators. A quote with neither goes to
--      nobody, and the console says "No customer email on this quote" and lets
--      an operator add the address and send it.
--      An invoice goes to the contract's billing contact when one is set, and
--      otherwise to the customer organisation's administrators: people who are
--      active, hold its administrator role through a grant in force, and are
--      neither platform support inside it nor platform staff.
--
--   2. What it says.
--      An order form email carries the quote's lines with their discounts and
--      nets, the recurring and one-off totals, the term and the date it is
--      valid until, read from the order form as issued. An invoice email carries
--      its lines, total and due date, the VAT statement from
--      erp.contract_invoice_terms(), and where to pay. Where to pay is a setting
--      an owner fills in from the console (erp_meta.platform_billing_details).
--      Until it is set, an invoice email says payment details will follow from
--      the accounts team, and Today says to add them.
--
--   3. How it leaves.
--      Issuing queues one row per recipient in erp_meta.commercial_email. The
--      dispatch drain claims them once a pass over its own trusted connection
--      (erp.claim_commercial_email_batch), renders them in the shared layout
--      (src/lib/email/commercial-email.ts), sends them with an idempotency key
--      and settles each one. The claim keeps the lease the notification queue
--      keeps, stops for the platform organisation's email kill switch, and
--      cancels a row whose document is gone. A demonstration organisation
--      queues nothing, and a row queued for one is cancelled at the claim.
--
--   4. What the console can do.
--      It shows each send as sent, queued, failed or cancelled, with the
--      address and the time. An operator or owner can send again, which queues
--      a new attempt with a new idempotency key and is written to the platform
--      log. Only an owner sets payment details or a contract's billing contact.
--
-- The claim returns the order form's price as it was issued, never its cost or
-- margin, and passes everything through erp.without_cost_or_margin() as well.
--
-- Proof: erp_test.commercial_email_suite() (10 cases). It builds its own
-- organisations inside a block it rolls back, so nothing it queues is ever
-- committed and no drain can send it.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. An address that can receive email
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.email_address_usable(p_address text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- Something, an @, and a domain with a dot in it. The enquiry form checks the
  -- same shape.
  select coalesce(btrim(p_address) ~ '^[^@[:space:]<>"]+@[^@[:space:]<>"]+\.[A-Za-z]{2,}$', false)
$$;

revoke all on function erp.email_address_usable(text) from public, anon, authenticated;

comment on function erp.email_address_usable(text) is
  'Whether an address has the shape of one that can receive email: something, '
  'an @, and a domain with a dot in it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Where invoices ask to be paid
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.platform_billing_details (
  id                          boolean primary key default true,
  legal_name                  text not null,
  registered_address          text,
  company_number              text,
  bank_account_name           text not null,
  sort_code                   text not null,
  account_number              text not null,
  payment_reference_guidance  text,
  updated_at                  timestamptz not null default now(),
  updated_by                  text not null,
  constraint platform_billing_details_one_row check (id),
  constraint platform_billing_details_sort_code_shape check (sort_code ~ '^[0-9]{2}-[0-9]{2}-[0-9]{2}$'),
  constraint platform_billing_details_account_number_shape check (account_number ~ '^[0-9]{6,10}$')
);

comment on table erp_meta.platform_billing_details is
  'The company that sends contract invoices and the account they ask to be paid '
  'into. One row, set by a platform owner from the console. Shown on every '
  'invoice email and on the invoice as the customer reads it.';

select erp_meta.register_table('erp_meta', 'platform_billing_details', 'platform_internal',
  'The company that sends invoices and the account they ask to be paid into. One row, owner-set.');

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'platform_billing_details', 'registered_address',
   'The registered office of the company that issues invoices, printed on each one as the law asks. '
   'It is a company''s address, not a person''s.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

create or replace function erp.platform_payment_details()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What a customer is told to pay into, or null until an owner has said.
  select jsonb_build_object(
           'legal_name', d.legal_name,
           'registered_address', d.registered_address,
           'company_number', d.company_number,
           'bank_account_name', d.bank_account_name,
           'sort_code', d.sort_code,
           'account_number', d.account_number,
           'payment_reference_guidance', d.payment_reference_guidance)
    from erp_meta.platform_billing_details d
$$;

revoke all on function erp.platform_payment_details() from public, anon, authenticated;

comment on function erp.platform_payment_details() is
  'The payment details every contract invoice carries, or null while none are set.';

create or replace function public.erp_platform_billing_details()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((
    select jsonb_build_object(
             'set', true,
             'legal_name', d.legal_name,
             'registered_address', d.registered_address,
             'company_number', d.company_number,
             'bank_account_name', d.bank_account_name,
             'sort_code', d.sort_code,
             'account_number', d.account_number,
             'payment_reference_guidance', d.payment_reference_guidance,
             'updated_at', d.updated_at,
             'updated_by', d.updated_by)
      from erp_meta.platform_billing_details d),
    jsonb_build_object('set', false));
end;
$$;

create or replace function public.erp_platform_set_billing_details(
  p_legal_name text,
  p_registered_address text,
  p_company_number text,
  p_bank_account_name text,
  p_sort_code text,
  p_account_number text,
  p_payment_reference_guidance text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v         erp_meta.platform_staff;
  v_sort    text;
  v_account text;
begin
  v := erp_meta.require_platform('owner');

  if coalesce(btrim(p_legal_name), '') = '' or coalesce(btrim(p_bank_account_name), '') = ''
     or coalesce(btrim(p_sort_code), '') = '' or coalesce(btrim(p_account_number), '') = '' then
    raise exception 'CLOVEERP_PAYMENT_DETAILS_INCOMPLETE: the company name, the account name, the sort code and the account number are all needed'
      using errcode = '23514';
  end if;

  v_sort := regexp_replace(p_sort_code, '[[:space:]-]', '', 'g');
  if v_sort !~ '^[0-9]{6}$' then
    raise exception 'CLOVEERP_SORT_CODE_INVALID: a sort code is six digits'
      using errcode = '22023';
  end if;
  v_sort := substr(v_sort, 1, 2) || '-' || substr(v_sort, 3, 2) || '-' || substr(v_sort, 5, 2);

  v_account := regexp_replace(p_account_number, '[[:space:]]', '', 'g');
  if v_account !~ '^[0-9]{6,10}$' then
    raise exception 'CLOVEERP_ACCOUNT_NUMBER_INVALID: an account number is six to ten digits'
      using errcode = '22023';
  end if;

  insert into erp_meta.platform_billing_details
    (id, legal_name, registered_address, company_number, bank_account_name, sort_code, account_number,
     payment_reference_guidance, updated_at, updated_by)
  values (true, btrim(p_legal_name), nullif(btrim(p_registered_address), ''), nullif(btrim(p_company_number), ''),
          btrim(p_bank_account_name), v_sort, v_account, nullif(btrim(p_payment_reference_guidance), ''),
          now(), v.email)
  on conflict (id) do update set
    legal_name = excluded.legal_name,
    registered_address = excluded.registered_address,
    company_number = excluded.company_number,
    bank_account_name = excluded.bank_account_name,
    sort_code = excluded.sort_code,
    account_number = excluded.account_number,
    payment_reference_guidance = excluded.payment_reference_guidance,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  -- The log says that they changed and whose they are, never the numbers.
  perform erp_meta.platform_log(v, 'platform.billing_details_set', null, null,
                                'payment details for contract invoices',
                                jsonb_build_object('legal_name', btrim(p_legal_name),
                                                   'account_ending', right(v_account, 2)));

  return jsonb_build_object('set', true, 'legal_name', btrim(p_legal_name), 'sort_code', v_sort,
                            'account_number', v_account, 'updated_by', v.email);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A contract's billing contact
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.contract add column if not exists billing_email text;
alter table erp_meta.contract add column if not exists billing_name text;

alter table erp_meta.contract drop constraint if exists contract_billing_email_usable;
-- The same shape erp.email_address_usable() reads, written out: a constraint
-- that calls a function ties the table to it.
alter table erp_meta.contract add constraint contract_billing_email_usable check (
  billing_email is null or btrim(billing_email) ~ '^[^@[:space:]<>"]+@[^@[:space:]<>"]+\.[A-Za-z]{2,}$');

comment on column erp_meta.contract.billing_email is
  'Where this contract''s invoices are emailed. When empty they go to the customer '
  'organisation''s administrators. Set by a platform owner.';

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'contract', 'billing_email',
   'The address a customer asked its invoices to be sent to, held on the contract, which is the '
   'billing record that outlives the organisation. An owner clears or changes it when asked.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

create or replace function public.erp_platform_set_billing_contact(p_contract_id uuid, p_email text, p_name text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  c       erp_meta.contract;
  v_email text := nullif(btrim(coalesce(p_email, '')), '');
begin
  v := erp_meta.require_platform('owner');
  select * into c from erp_meta.contract x where x.id = p_contract_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_CONTRACT: %', p_contract_id
      using errcode = '23503', hint = 'Open the contract from the list and try again.';
  end if;
  if v_email is not null and not erp.email_address_usable(v_email) then
    raise exception 'CLOVEERP_EMAIL_ADDRESS_INVALID: % cannot receive email', v_email
      using errcode = '22023';
  end if;

  update erp_meta.contract
     set billing_email = v_email,
         billing_name = case when v_email is null then null else nullif(btrim(p_name), '') end,
         updated_at = now()
   where id = p_contract_id;

  perform erp_meta.platform_log(v, 'platform.billing_contact_set', c.tenant_id, p_contract_id::text,
                                case when v_email is null then 'invoices go to the organisation''s administrators'
                                     else 'invoices go to the billing contact' end,
                                jsonb_build_object('billing_contact_set', v_email is not null));

  return jsonb_build_object('contract_id', p_contract_id, 'billing_email', v_email,
                            'billing_name', case when v_email is null then null else nullif(btrim(p_name), '') end);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A quote's customer contact
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.set_quote_contact(p_document_id uuid, p_name text, p_email text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_party  uuid;
  v_id     uuid;
  v_email  text := nullif(btrim(coalesce(p_email, '')), '');
  v_name   text := nullif(btrim(coalesce(p_name, '')), '');
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', p_document_id);

  select d.party_id into v_party
    from erp.commercial_quote cq
    join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
   where cq.tenant_id = v_tenant and cq.document_id = p_document_id;
  if v_party is null then
    raise exception 'CLOVEERP_UNKNOWN_QUOTE: %', p_document_id
      using errcode = '23503', hint = 'Open the quote from the list and try again.';
  end if;
  if v_email is null or not erp.email_address_usable(v_email) then
    raise exception 'CLOVEERP_EMAIL_ADDRESS_INVALID: % cannot receive email', coalesce(v_email, 'an empty address')
      using errcode = '22023';
  end if;

  -- The business partner's commercial contact: the one an order form goes to.
  select pc.id into v_id
    from erp.party_contact pc
   where pc.tenant_id = v_tenant and pc.party_id = v_party and pc.contact_kind = 'commercial'
   order by pc.is_default desc, pc.updated_at desc
   limit 1;
  if v_id is null then
    insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, is_default)
    values (v_tenant, v_party, 'commercial', v_name, v_email, true)
    returning id into v_id;
  else
    update erp.party_contact
       set name = v_name, email = v_email, is_default = true, valid_to = null, updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;
  update erp.party_contact
     set is_default = false, updated_at = now()
   where tenant_id = v_tenant and party_id = v_party and id <> v_id and is_default;

  return jsonb_build_object('contact_id', v_id, 'email', v_email, 'name', v_name);
end;
$$;

comment on function erp.set_quote_contact(uuid, text, text) is
  'Sets the customer contact a quote''s order form is emailed to: the commercial '
  'contact of the quote''s business partner, made its default. Inside the '
  'platform''s organisation, under sales.order.';

create or replace function public.erp_set_quote_contact(p_document_id uuid, p_name text, p_email text)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.set_quote_contact(p_document_id, p_name, p_email); $$;

select erp_meta.add_help_actions('/commercial/quotes', array['erp_set_quote_contact']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Who a document goes to
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.organisation_administrators(p_tenant_id uuid)
returns table (address text, display_name text)
language sql
stable
set search_path = ''
as $$
  -- The people who administer an organisation today: active, holding its
  -- administrator role through a grant in force, and neither platform support
  -- inside it nor platform staff.
  select distinct on (lower(btrim(u.email))) btrim(u.email), nullif(btrim(u.display_name), '')
    from erp.app_user u
    join erp.user_role ur on ur.tenant_id = u.tenant_id and ur.app_user_id = u.id
    join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
   where u.tenant_id = p_tenant_id
     and u.status = 'active'
     and u.kind = 'person'
     and r.code = 'administrator'
     and r.status = 'active'
     and ur.valid_from <= current_date
     and (ur.valid_to is null or ur.valid_to >= current_date)
     and erp.email_address_usable(u.email)
     and not erp.is_support_principal(u.tenant_id, u.id)
     and not exists (select 1 from erp_meta.platform_staff s
                      where s.revoked_at is null
                        and (lower(btrim(s.email)) = lower(btrim(u.email))
                             or (s.auth_user_id is not null and s.auth_user_id = u.auth_user_id)))
   order by lower(btrim(u.email)), u.created_at
$$;

revoke all on function erp.organisation_administrators(uuid) from public, anon, authenticated;

comment on function erp.organisation_administrators(uuid) is
  'The administrators of an organisation an invoice or order form is emailed to: '
  'active people holding its administrator role today, never platform support '
  'inside it and never platform staff.';

create or replace function erp.quote_recipients(p_document_id uuid)
returns table (address text, display_name text, source text, customer_tenant_id uuid, customer_tenant_code text)
language sql
stable
set search_path = ''
as $$
  with q as (
    select cq.tenant_id, d.party_id, cq.customer_tenant_code, t.id as customer_id
      from erp.commercial_quote cq
      join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
      left join erp.tenant t on t.code = cq.customer_tenant_code
     where cq.document_id = p_document_id),
  contact as (
    -- The customer contact the quote's business partner records, the default
    -- one first, then the one changed last.
    select btrim(pc.email) as address, nullif(btrim(pc.name), '') as display_name
      from q
      join erp.party_contact pc on pc.tenant_id = q.tenant_id and pc.party_id = q.party_id
     where erp.email_address_usable(pc.email)
       and pc.valid_from <= current_date
       and (pc.valid_to is null or pc.valid_to > current_date)
     order by pc.is_default desc, pc.updated_at desc
     limit 1)
  select c.address, c.display_name, 'customer_contact'::text, q.customer_id, q.customer_tenant_code
    from contact c
    cross join q
  union all
  -- With no contact, the organisation the quote was made for.
  select a.address, a.display_name, 'customer_administrator'::text, q.customer_id, q.customer_tenant_code
    from q
    cross join lateral erp.organisation_administrators(q.customer_id) a
   where q.customer_id is not null
     and not exists (select 1 from contact)
$$;

revoke all on function erp.quote_recipients(uuid) from public, anon, authenticated;

create or replace function erp.contract_billing_recipients(p_contract_id uuid)
returns table (address text, display_name text, source text)
language sql
stable
set search_path = ''
as $$
  select btrim(c.billing_email), nullif(btrim(c.billing_name), ''), 'billing_contact'::text
    from erp_meta.contract c
   where c.id = p_contract_id
     and erp.email_address_usable(c.billing_email)
  union all
  select a.address, a.display_name, 'administrator'::text
    from erp_meta.contract c
    cross join lateral erp.organisation_administrators(c.tenant_id) a
   where c.id = p_contract_id
     and not erp.email_address_usable(c.billing_email)
$$;

revoke all on function erp.contract_billing_recipients(uuid) from public, anon, authenticated;

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
   where p_kind = 'contract_invoice'
     and i.id = p_document_id
$$;

revoke all on function erp.commercial_email_recipients(text, uuid) from public, anon, authenticated;

comment on function erp.commercial_email_recipients(text, uuid) is
  'Who an order form or contract invoice is emailed to, and why: the quote''s '
  'customer contact, else the administrators of the organisation it was made '
  'for; the contract''s billing contact, else the customer organisation''s '
  'administrators.';

create or replace function erp.commercial_document_is_demonstration(p_kind text, p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_kind
    when 'order_form' then exists (
      select 1
        from erp.commercial_quote cq
       where cq.document_id = p_document_id
         and (erp.tenant_is_demonstration(cq.tenant_id)
              or exists (select 1 from erp.tenant t
                          where t.code = cq.customer_tenant_code and erp.tenant_is_demonstration(t.id))))
    when 'contract_invoice' then exists (
      select 1
        from erp_meta.contract_invoice i
       where i.id = p_document_id
         and erp.tenant_is_demonstration(i.tenant_id))
    else false
  end
$$;

revoke all on function erp.commercial_document_is_demonstration(text, uuid) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The queue
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.commercial_email (
  id                   uuid primary key default gen_random_uuid(),
  kind                 text not null,
  quote_document_id    uuid,
  quote_tenant_id      uuid,
  contract_invoice_id  uuid references erp_meta.contract_invoice (id) on delete cascade,
  tenant_id            uuid,
  tenant_code          text,
  send_number          integer not null,
  to_address           text not null,
  to_name              text,
  recipient_source     text not null,
  status               text not null default 'queued',
  attempts             integer not null default 0,
  claimed_by           text,
  claimed_at           timestamptz,
  lease_expires_at     timestamptz,
  provider_message_id  text,
  sent_at              timestamptz,
  failure_reason       text,
  requested_by         text not null,
  created_at           timestamptz not null default now(),
  idempotency_key      text not null,
  constraint commercial_email_kind_known check (kind in ('order_form', 'contract_invoice')),
  constraint commercial_email_names_its_document check (
    (kind = 'order_form' and quote_document_id is not null and quote_tenant_id is not null and contract_invoice_id is null)
    or (kind = 'contract_invoice' and contract_invoice_id is not null and quote_document_id is null)),
  constraint commercial_email_status_known check (status in ('queued', 'sending', 'sent', 'failed', 'cancelled')),
  constraint commercial_email_source_known check (
    recipient_source in ('customer_contact', 'customer_administrator', 'billing_contact', 'administrator')),
  constraint commercial_email_sent_is_named check (
    status <> 'sent' or (provider_message_id is not null and sent_at is not null)),
  constraint commercial_email_send_number_positive check (send_number >= 1),
  constraint commercial_email_once unique (idempotency_key)
);

create index if not exists commercial_email_waiting on erp_meta.commercial_email (status, created_at);
create index if not exists commercial_email_by_quote on erp_meta.commercial_email (quote_document_id);
create index if not exists commercial_email_by_invoice on erp_meta.commercial_email (contract_invoice_id);

comment on table erp_meta.commercial_email is
  'Every email of an issued order form or contract invoice: one row per recipient '
  'per send, queued when the document is issued or sent again, claimed and settled '
  'by the dispatch drain. The idempotency key is the document, the send and the '
  'recipient, so a provider that saw a send once does not deliver it twice.';

select erp_meta.register_table('erp_meta', 'commercial_email', 'platform_internal',
  'Order forms and contract invoices emailed to customers: one row per recipient per send.');

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'commercial_email', 'to_address',
   'The address an order form or invoice was sent to, kept as the record that the customer was '
   'sent it. Part of the billing record, which outlives the organisation.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

create or replace function erp.queue_commercial_email(p_kind text, p_document_id uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor   erp_meta.platform_staff;
  v_by      text;
  v_quote   erp.commercial_quote;
  v_invoice erp_meta.contract_invoice;
  v_send    integer;
  v_n       integer := 0;
  r         record;
begin
  if p_kind is null or p_kind not in ('order_form', 'contract_invoice') then
    raise exception 'CLOVEERP_COMMERCIAL_EMAIL_KIND_UNKNOWN: % is neither an order form nor a contract invoice', coalesce(p_kind, 'nothing')
      using errcode = '22023', hint = 'Send an order form or a contract invoice.';
  end if;

  -- Platform staff at operator or above may send either. Anybody else sends an
  -- order form only as part of issuing it, inside the platform's organisation.
  v_actor := erp_meta.platform_actor();
  if v_actor.id is null or erp_meta.platform_rank(v_actor.staff_role) < erp_meta.platform_rank('operator') then
    if p_kind = 'contract_invoice' then
      perform erp_meta.require_platform('operator');
    end if;
    perform erp.require_platform_organisation();
    perform erp.authorise('sales.order', null, null, null, 'commercial_quote', p_document_id);
  end if;
  v_by := coalesce(v_actor.email,
                   (select u.email from erp.app_user u where u.id = erp.current_principal_id()),
                   current_user);

  if p_kind = 'order_form' then
    select * into v_quote from erp.commercial_quote x where x.document_id = p_document_id;
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_QUOTE: %', p_document_id
        using errcode = '23503', hint = 'Open the quote from the list and try again.';
    end if;
    if v_quote.order_form_render_id is null then
      raise exception 'CLOVEERP_COMMERCIAL_EMAIL_NOT_ISSUED: version % has no order form yet', v_quote.version
        using errcode = '23514';
    end if;
  else
    select * into v_invoice from erp_meta.contract_invoice x where x.id = p_document_id;
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_INVOICE: %', p_document_id
        using errcode = '23503', hint = 'Open the contract''s invoices and try again.';
    end if;
    if v_invoice.status not in ('issued', 'paid') then
      raise exception 'CLOVEERP_COMMERCIAL_EMAIL_NOT_ISSUED: % is %', v_invoice.reference, v_invoice.status
        using errcode = '23514';
    end if;
  end if;

  -- A demonstration sends nothing outside the product.
  if erp.commercial_document_is_demonstration(p_kind, p_document_id) then
    return 0;
  end if;

  select coalesce(max(e.send_number), 0) + 1 into v_send
    from erp_meta.commercial_email e
   where (p_kind = 'order_form' and e.quote_document_id = p_document_id)
      or (p_kind = 'contract_invoice' and e.contract_invoice_id = p_document_id);

  for r in select * from erp.commercial_email_recipients(p_kind, p_document_id) loop
    insert into erp_meta.commercial_email
      (kind, quote_document_id, quote_tenant_id, contract_invoice_id, tenant_id, tenant_code, send_number,
       to_address, to_name, recipient_source, requested_by, idempotency_key)
    values (p_kind,
            case when p_kind = 'order_form' then p_document_id end,
            case when p_kind = 'order_form' then v_quote.tenant_id end,
            case when p_kind = 'contract_invoice' then p_document_id end,
            r.customer_tenant_id, r.customer_tenant_code, v_send,
            r.address, r.display_name, r.source, v_by,
            format('clove-%s-%s-%s-%s', replace(p_kind, '_', '-'), p_document_id, v_send, md5(lower(r.address))));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

comment on function erp.queue_commercial_email(text, uuid) is
  'Queues an issued order form or contract invoice for every recipient it goes to, '
  'as the next send of that document. Nothing for a demonstration organisation, and '
  'nothing when nobody has an address. Called when the document is issued and by '
  'the console''s Send again. Security definer to write erp_meta.commercial_email; '
  'platform staff at operator, or somebody issuing the quote under sales.order.';

-- Issuing an order form sends it.
do $issue_quote$
declare
  v_sig   constant text := 'erp.issue_quote(uuid)';
  v_def   text := pg_get_functiondef('erp.issue_quote(uuid)'::regprocedure);
  v_pairs text[][] := array[
    array[$n$v_render jsonb; v_content text; v_req jsonb; v_render_id uuid; v_state text;$n$,
          $n$v_render jsonb; v_content text; v_req jsonb; v_render_id uuid; v_state text; v_emails integer;$n$],
    array[$n$  update erp.commercial_quote set order_form_render_id = v_render_id, order_form_issued_at = now(), updated_at = now()
   where id = q.id;$n$,
          $n$  update erp.commercial_quote set order_form_render_id = v_render_id, order_form_issued_at = now(), updated_at = now()
   where id = q.id;
  -- The order form goes to the customer the moment it is issued (20260914097000).
  v_emails := erp.queue_commercial_email('order_form', p_document_id);$n$],
    array[$n$'checksum', md5(v_content), 'version', q.version);$n$,
          $n$'checksum', md5(v_content), 'version', q.version, 'emails_queued', v_emails);$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_pairs[i][1], 80)
        using hint = 'A later migration changed how a quote is issued. Read pg_get_functiondef() of it and patch that body.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
  if position('erp.queue_commercial_email(''order_form'', p_document_id)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the function.';
  end if;
end
$issue_quote$;

-- Issuing an invoice sends it, before the person is set aside to tell the
-- customer's organisation.
do $issue_invoice$
declare
  v_sig    constant text := 'erp.issue_contract_invoice(uuid)';
  v_def    text := pg_get_functiondef('erp.issue_contract_invoice(uuid)'::regprocedure);
  v_needle constant text := $n$   where id = p_invoice_id;
  perform erp_meta.act_in_tenant(c.tenant_id);$n$;
  v_new    constant text := $n$   where id = p_invoice_id;
  -- The invoice goes to the customer the moment it is issued (20260914097000).
  perform erp.queue_commercial_email('contract_invoice', p_invoice_id);
  perform erp_meta.act_in_tenant(c.tenant_id);$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not act in the customer''s organisation straight after issuing exactly once', v_sig
      using hint = 'A later migration changed how an invoice is issued. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('erp.queue_commercial_email(''contract_invoice'', p_invoice_id)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$issue_invoice$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The claim and the settle
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.commercial_email_payload(p_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  e          erp_meta.commercial_email;
  q          erp.commercial_quote;
  v_number   text;
  v_customer text;
  v_render   jsonb;
  v_pricing  jsonb;
  v_invoice  erp_meta.contract_invoice;
  v_contract erp_meta.contract;
begin
  select * into e from erp_meta.commercial_email x where x.id = p_id;
  if not found then
    return null;
  end if;

  if e.kind = 'order_form' then
    select * into q from erp.commercial_quote x where x.document_id = e.quote_document_id;
    select d.document_number, coalesce(nullif(btrim(p.legal_name), ''), p.name)
      into v_number, v_customer
      from erp.document d
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
     where d.tenant_id = q.tenant_id and d.id = q.document_id;
    select o.content::jsonb into v_render
      from erp.output_render o
     where o.tenant_id = q.tenant_id and o.id = q.order_form_render_id;
    -- The price as the order form was issued with it. One issued before
    -- 20260914093000 carried none of its own, so it is read from the quote.
    v_pricing := v_render -> 'pricing';
    if v_pricing is null then
      perform erp.set_job_tenant(q.tenant_id);
      v_pricing := erp.order_form_pricing(q.document_id);
    end if;
    return erp.without_cost_or_margin(jsonb_build_object(
      'kind', 'order_form',
      'document_number', v_number,
      'quote_version', q.version,
      'customer_name', v_customer,
      'recipient_name', e.to_name,
      'currency', coalesce(v_pricing ->> 'currency', q.currency::text),
      'lines', coalesce(v_pricing -> 'lines', '[]'::jsonb),
      'totals', coalesce(v_pricing -> 'totals', '{}'::jsonb),
      'term_kind', q.term_kind,
      'term_months', q.term_months,
      'valid_until', q.valid_until,
      'price_book', v_render ->> 'price_book',
      'issued_at', q.order_form_issued_at,
      'issuer_email', e.requested_by));
  end if;

  select * into v_invoice from erp_meta.contract_invoice x where x.id = e.contract_invoice_id;
  select * into v_contract from erp_meta.contract x where x.id = v_invoice.contract_id;
  return erp.without_cost_or_margin(jsonb_build_object(
    'kind', 'contract_invoice',
    'reference', v_invoice.reference,
    'customer_name', v_contract.customer_legal_name,
    'supplier_name', v_contract.platform_legal_name,
    'recipient_name', e.to_name,
    'currency', v_invoice.currency::text,
    'period_start', v_invoice.period_start,
    'period_end', v_invoice.period_end,
    'issued_on', (v_invoice.issued_at at time zone 'UTC')::date,
    'due_on', v_invoice.due_on,
    'lines', v_invoice.lines,
    'subscription_minor', v_invoice.subscription_minor,
    'overage_minor', v_invoice.overage_minor,
    'one_off_minor', v_invoice.one_off_minor,
    'recurring_minor', v_invoice.subscription_minor + v_invoice.overage_minor,
    'total_minor', v_invoice.total_minor,
    'tax_statement', coalesce(v_invoice.tax_statement,
                              erp.contract_invoice_terms(v_contract.platform_legal_name) ->> 'tax_statement'),
    'payment_details', erp.platform_payment_details(),
    'plan_code', v_contract.plan_code,
    'issuer_email', e.requested_by));
end;
$$;

revoke all on function erp.commercial_email_payload(uuid) from public, anon, authenticated;

comment on function erp.commercial_email_payload(uuid) is
  'Everything the sender needs to write one commercial email: for an order form '
  'its number, customer, lines with discount and net, totals, term and validity; '
  'for an invoice its reference, lines, totals, due date, VAT statement and '
  'payment details. Never a cost or a margin.';

create or replace function erp.claim_commercial_email_batch(p_limit integer default 20, p_worker text default null)
returns table (email_id uuid, email_kind text, recipient_address text, recipient_name text,
               sender_address text, reply_address text, send_key text, attempt integer, payload jsonb)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_platform uuid;
  v_sender   jsonb;
  r          record;
begin
  -- The drain calls this over its own connection, once a pass and for no
  -- organisation in particular. Nobody signed in claims a customer's mail.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not claim commercial email', current_user
      using errcode = '42501', hint = 'The dispatch drain claims these over its own connection; nobody signed in does.';
  end if;

  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  if v_platform is null then
    return;
  end if;

  -- The platform's organisation sends these: its email kill switch stops them,
  -- and its sender identity is who they are from.
  perform erp.set_job_tenant(v_platform);
  if erp.is_killed('integration', 'email') then
    return;
  end if;
  v_sender := erp.sender_for('transactional');

  -- A lease that ran out goes back to the queue: the drain that held it died
  -- before it could say what happened.
  update erp_meta.commercial_email ce
     set status = 'queued', claimed_by = null, claimed_at = null, lease_expires_at = null
   where ce.status = 'sending'
     and ce.lease_expires_at < now();

  -- Nothing is sent for a demonstration, or for a document that no longer
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
     and (j.demonstration or j.gone);

  -- The batch is marked sending inside the claim, with who holds it and until
  -- when, as the notification queue does (20260906112000).
  for r in
    with next_up as (
      select ce.id
        from erp_meta.commercial_email ce
       where ce.status = 'queued'
       order by ce.created_at
       limit greatest(coalesce(p_limit, 20), 1)
       for update skip locked)
    update erp_meta.commercial_email ce
       set status = 'sending',
           claimed_by = coalesce(p_worker, current_user),
           claimed_at = now(),
           lease_expires_at = now() + interval '5 minutes',
           attempts = ce.attempts + 1
      from next_up n
     where ce.id = n.id
    returning ce.id, ce.kind, ce.to_address, ce.to_name, ce.requested_by, ce.idempotency_key, ce.attempts
  loop
    email_id := r.id;
    email_kind := r.kind;
    recipient_address := r.to_address;
    recipient_name := r.to_name;
    sender_address := v_sender ->> 'from_address';
    -- Replies go to whoever issued it or sent it again.
    reply_address := case when erp.email_address_usable(r.requested_by) then btrim(r.requested_by)
                          else v_sender ->> 'reply_to' end;
    send_key := r.idempotency_key;
    attempt := r.attempts;
    payload := erp.commercial_email_payload(r.id);
    return next;
  end loop;
end;
$$;

revoke all on function erp.claim_commercial_email_batch(integer, text) from public, anon, authenticated;

comment on function erp.claim_commercial_email_batch(integer, text) is
  'Claims up to p_limit queued order form and invoice emails for the dispatch drain, '
  'marking them sending under a five-minute lease held by p_worker, after returning '
  'expired leases to the queue and cancelling what a demonstration or a missing '
  'document would send. Nothing while the platform organisation''s email kill '
  'switch is on. Trusted sessions only.';

create or replace function erp.complete_commercial_email(p_id uuid, p_provider_message_id text)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not settle commercial email', current_user
      using errcode = '42501', hint = 'The dispatch drain settles these over its own connection; nobody signed in does.';
  end if;
  if coalesce(btrim(p_provider_message_id), '') = '' then
    raise exception 'CLOVEERP_EMAIL_NOT_SENT: an email is sent when the provider names it'
      using errcode = '22023', hint = 'Settle it as failed, or wait for the provider''s id.';
  end if;
  update erp_meta.commercial_email
     set status = 'sent', provider_message_id = btrim(p_provider_message_id), sent_at = now(),
         claimed_by = null, lease_expires_at = null, failure_reason = null
   where id = p_id and status = 'sending';
  if not found then
    raise exception 'CLOVEERP_COMMERCIAL_EMAIL_NOT_SENDING: % is not being sent', p_id
      using errcode = '23514', hint = 'Its lease ran out and it went back to the queue; the next pass sends it.';
  end if;
end;
$$;

revoke all on function erp.complete_commercial_email(uuid, text) from public, anon, authenticated;

create or replace function erp.fail_commercial_email(p_id uuid, p_reason text, p_retry boolean default true)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare v_status text;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not settle commercial email', current_user
      using errcode = '42501', hint = 'The dispatch drain settles these over its own connection; nobody signed in does.';
  end if;
  -- A failure that may pass is tried again, five times in all; one the
  -- provider said never to, or the fifth, is failed and stays failed until
  -- somebody sends it again.
  update erp_meta.commercial_email
     set status = case when coalesce(p_retry, false) and attempts < 5 then 'queued' else 'failed' end,
         failure_reason = left(coalesce(nullif(btrim(p_reason), ''), 'the send failed and said nothing'), 500),
         claimed_by = null, claimed_at = null, lease_expires_at = null
   where id = p_id and status = 'sending'
  returning status into v_status;
  if v_status is null then
    raise exception 'CLOVEERP_COMMERCIAL_EMAIL_NOT_SENDING: % is not being sent', p_id
      using errcode = '23514', hint = 'Its lease ran out and it went back to the queue; the next pass sends it.';
  end if;
  return v_status;
end;
$$;

revoke all on function erp.fail_commercial_email(uuid, text, boolean) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. What the console reads and does
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.commercial_email_sends(p_quote_document_id uuid, p_contract_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'kind', e.kind,
           'document_id', coalesce(e.quote_document_id, e.contract_invoice_id),
           'send_number', e.send_number, 'to_address', e.to_address, 'to_name', e.to_name,
           'recipient_source', e.recipient_source, 'status', e.status, 'attempts', e.attempts,
           'sent_at', e.sent_at, 'failure_reason', e.failure_reason,
           'requested_by', e.requested_by, 'created_at', e.created_at)
         order by e.created_at desc, e.to_address), '[]'::jsonb)
    from erp_meta.commercial_email e
   where (p_quote_document_id is not null and e.quote_document_id = p_quote_document_id)
      or (p_contract_id is not null
          and e.contract_invoice_id in (select i.id from erp_meta.contract_invoice i where i.contract_id = p_contract_id))
$$;

revoke all on function erp.commercial_email_sends(uuid, uuid) from public, anon, authenticated;

create or replace function public.erp_platform_commercial_emails(p_quote_document_id uuid default null,
                                                                p_contract_id uuid default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare c erp_meta.contract;
begin
  perform erp_meta.require_platform('support');
  if p_quote_document_id is not null then
    return jsonb_build_object(
      'demonstration', erp.commercial_document_is_demonstration('order_form', p_quote_document_id),
      'recipients', coalesce((select jsonb_agg(jsonb_build_object('address', r.address, 'name', r.display_name,
                                                                  'source', r.source))
                                from erp.commercial_email_recipients('order_form', p_quote_document_id) r), '[]'::jsonb),
      'sends', erp.commercial_email_sends(p_quote_document_id, null));
  end if;
  if p_contract_id is not null then
    select * into c from erp_meta.contract x where x.id = p_contract_id;
    return jsonb_build_object(
      'demonstration', coalesce(erp.tenant_is_demonstration(c.tenant_id), false),
      'billing_email', c.billing_email,
      'billing_name', c.billing_name,
      'recipients', coalesce((select jsonb_agg(jsonb_build_object('address', r.address, 'name', r.display_name,
                                                                  'source', r.source))
                                from erp.contract_billing_recipients(p_contract_id) r), '[]'::jsonb),
      'sends', erp.commercial_email_sends(null, p_contract_id));
  end if;
  return jsonb_build_object('demonstration', false, 'recipients', '[]'::jsonb, 'sends', '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_send_commercial_email(p_kind text, p_document_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  v_n    integer;
  v_tenant uuid;
begin
  v := erp_meta.require_platform('operator');
  if p_kind is null or p_kind not in ('order_form', 'contract_invoice') then
    raise exception 'CLOVEERP_COMMERCIAL_EMAIL_KIND_UNKNOWN: % is neither an order form nor a contract invoice', coalesce(p_kind, 'nothing')
      using errcode = '22023', hint = 'Send an order form or a contract invoice.';
  end if;
  if erp.commercial_document_is_demonstration(p_kind, p_document_id) then
    raise exception 'CLOVEERP_DEMONSTRATION_SENDS_NO_EMAIL: a demonstration organisation is sent nothing'
      using errcode = '42501';
  end if;
  select r.customer_tenant_id into v_tenant
    from erp.commercial_email_recipients(p_kind, p_document_id) r
   limit 1;
  if not found then
    raise exception 'CLOVEERP_NO_CUSTOMER_EMAIL: nobody this document goes to has an email address'
      using errcode = '23514';
  end if;

  v_n := erp.queue_commercial_email(p_kind, p_document_id);

  perform erp_meta.platform_log(v, 'platform.commercial_email_sent_again', v_tenant, p_document_id::text,
                                replace(p_kind, '_', ' '), jsonb_build_object('queued', v_n));
  return jsonb_build_object('kind', p_kind, 'document_id', p_document_id, 'queued', v_n);
end;
$$;

-- The customer reads the payment details on its own invoices.
do $agreement$
declare
  v_sig    constant text := 'erp.my_agreement()';
  v_def    text := pg_get_functiondef('erp.my_agreement()'::regprocedure);
  v_needle constant text := $n$    'sub_processors', coalesce(($n$;
  v_new    constant text := $n$    -- Where the invoices ask to be paid (20260914097000).
    'payment_details', erp.platform_payment_details(),
    'sub_processors', coalesce(($n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not list its sub-processors exactly once, so it is not the 20260914093000 body', v_sig
      using hint = 'A later migration changed what the customer reads of its agreement. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('erp.platform_payment_details()' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$agreement$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Registration
-- ═════════════════════════════════════════════════════════════════════════════

revoke all on function public.erp_platform_billing_details() from public, anon;
revoke all on function public.erp_platform_set_billing_details(text, text, text, text, text, text, text) from public, anon;
revoke all on function public.erp_platform_set_billing_contact(uuid, text, text) from public, anon;
revoke all on function public.erp_set_quote_contact(uuid, text, text) from public, anon;
revoke all on function public.erp_platform_commercial_emails(uuid, uuid) from public, anon;
revoke all on function public.erp_platform_send_commercial_email(text, uuid) from public, anon;
grant execute on function public.erp_platform_billing_details() to authenticated, service_role;
grant execute on function public.erp_platform_set_billing_details(text, text, text, text, text, text, text) to authenticated, service_role;
grant execute on function public.erp_platform_set_billing_contact(uuid, text, text) to authenticated, service_role;
grant execute on function public.erp_set_quote_contact(uuid, text, text) to authenticated, service_role;
grant execute on function public.erp_platform_commercial_emails(uuid, uuid) to authenticated, service_role;
grant execute on function public.erp_platform_send_commercial_email(text, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_billing_details', 'erp_meta.require_platform',
   'Platform staff read. The gate binds the staff identity on first sight, which is the write; the door must therefore be volatile.'),
  ('erp_platform_commercial_emails', 'erp_meta.require_platform',
   'Platform staff read. The gate binds the staff identity on first sight, which is the write; the door must therefore be volatile.'),
  ('erp_platform_set_billing_details', 'erp_meta.require_platform',
   'Sets the company and account every contract invoice asks to be paid into. Owner only, and written to the platform log without the numbers.'),
  ('erp_platform_set_billing_contact', 'erp_meta.require_platform',
   'Sets or clears where a contract''s invoices are emailed. Owner only, and written to the platform log.'),
  ('erp_platform_send_commercial_email', 'erp_meta.require_platform',
   'Queues an issued order form or invoice to be emailed again. Operator or owner, and written to the platform log.'),
  ('erp_set_quote_contact', 'erp.set_quote_contact',
   'Sets the customer contact a quote''s order form is emailed to. Inside the platform''s organisation; sales.order.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_billing_details',
   'Reads erp_meta.platform_billing_details, platform_internal. Gated by erp_meta.require_platform(''support'') on its first line.'),
  ('public', 'erp_platform_set_billing_details',
   'Writes erp_meta.platform_billing_details, platform_internal. Gated by erp_meta.require_platform(''owner'') on its first line.'),
  ('public', 'erp_platform_set_billing_contact',
   'Writes the billing contact on erp_meta.contract, platform_internal. Gated by erp_meta.require_platform(''owner'') on its first line.'),
  ('public', 'erp_platform_commercial_emails',
   'Reads erp_meta.commercial_email and who a quote or contract would be emailed to, across organisations. Gated by erp_meta.require_platform(''support'') on its first line.'),
  ('public', 'erp_platform_send_commercial_email',
   'Queues rows in erp_meta.commercial_email for a customer''s document. Gated by erp_meta.require_platform(''operator'') on its first line.'),
  ('erp', 'queue_commercial_email',
   'Writes erp_meta.commercial_email when an order form or invoice is issued, from the invoker issue_quote as well as the platform doors. '
   'Refuses anybody who is neither platform staff at operator nor authorised for sales.order inside the platform''s organisation.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_PAYMENT_DETAILS_INCOMPLETE',
  'Saving payment details without the company name, the account name, the sort code or the account number.',
  'Every invoice tells the customer where to pay, and one with a detail missing asks for a payment nobody can make.',
  'Fill in the company name, the account name, the sort code and the account number, then save again.');

select erp.register_refusal('CLOVEERP_SORT_CODE_INVALID',
  'Saving a sort code that is not six digits.',
  'A sort code is six digits, and a customer copies it from the invoice exactly as it is shown.',
  'Enter the six digits of the sort code, such as 12-34-56.');

select erp.register_refusal('CLOVEERP_ACCOUNT_NUMBER_INVALID',
  'Saving an account number that is not six to ten digits.',
  'A customer copies the account number from the invoice, so it has to be the number the bank uses.',
  'Enter the account number as digits only, usually eight of them.');

select erp.register_refusal('CLOVEERP_EMAIL_ADDRESS_INVALID',
  'Saving an email address that cannot receive email.',
  'An order form or invoice sent to an address with no @ and no domain would never arrive, and nobody would know.',
  'Enter the whole address, such as accounts@example.co.uk.');

select erp.register_refusal('CLOVEERP_NO_CUSTOMER_EMAIL',
  'Sending an order form or invoice that has nobody to send it to.',
  'An order form goes to the customer contact on the quote or the administrators of the organisation it was made for, and an invoice to the billing contact or the organisation''s administrators. None of them has an email address.',
  'Add the customer''s email address on the quote, or a billing contact on the contract, then send it.');

select erp.register_refusal('CLOVEERP_DEMONSTRATION_SENDS_NO_EMAIL',
  'Emailing an order form or invoice for a demonstration organisation.',
  'A demonstration organisation never sends email outside the product, so nobody is written to by accident.',
  'Read the order form or the invoice in the console instead.');

select erp.register_refusal('CLOVEERP_COMMERCIAL_EMAIL_NOT_ISSUED',
  'Emailing an order form or invoice before it has been issued.',
  'What the customer receives is the document as it was issued, and there is none yet.',
  'Issue the quote or the invoice first. Issuing sends it.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Organisations, people and staff of its own, provisioned inside a block that
-- is rolled back at the end, so nothing it writes is ever committed: no drain
-- can send a row it queues, and the payment details and designation it sets
-- are gone with it. It runs on the live database when this migration is
-- deployed.

create or replace function erp_test.commercial_email_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_pcode    text;
  v_ccode    text;
  a_admin    uuid := gen_random_uuid();
  a_owner    uuid := gen_random_uuid();
  a_operator uuid := gen_random_uuid();
  a_customer uuid := gen_random_uuid();
  a_second   uuid := gen_random_uuid();
  a_support  uuid := gen_random_uuid();
  a_staffer  uuid := gen_random_uuid();
  v_step     text := 'starting';
  v_state    text;
  rp         record;
  rc         record;
  c          record;
  v_platform uuid;
  v_customer uuid;
  u_id       uuid;
  v_q1       uuid;
  v_q2       uuid;
  v_contract uuid;
  v_inv1     uuid;
  v_inv2     uuid;
  v_inv3     uuid;
  v_first_key text;
  v_n        integer;
  v_ok       boolean;
  v_msg      text;
  res        jsonb;
  v_form     jsonb;
  v_invoice  jsonb;
  v_keys     text;
  v_reply    text;
  v_claimed  integer := 0;
  v_status1  text;
  v_status2  text;

  ok_quote    boolean; msg_quote    text;
  ok_nobody   boolean; msg_nobody   text;
  ok_billing  boolean; msg_billing  text;
  ok_admins   boolean; msg_admins   text;
  ok_owner    boolean; msg_owner    text;
  ok_claim    boolean; msg_claim    text;
  ok_settle   boolean; msg_settle   text;
  ok_again    boolean; msg_again    text;
  ok_demo     boolean; msg_demo     text;
begin
  begin
    v_pcode := 'zzcmp-' || v_tag;
    v_ccode := 'zzcmc-' || v_tag;

    -- ── Organisations, people and staff ─────────────────────────────────────
    v_step := 'the organisations are provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Mail', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into rc from erp.provision_tenant(v_ccode, 'Mail Customer Ltd', 'admin@' || v_ccode || '.test', 'Customer Admin');
    v_customer := rc.tenant_id;
    insert into auth.users (id, email) values
      (a_admin, 'admin@' || v_pcode || '.test'),
      (a_owner, 'owner@' || v_pcode || '.test'),
      (a_operator, 'operator@' || v_pcode || '.test'),
      (a_customer, 'admin@' || v_ccode || '.test'),
      (a_second, 'second@' || v_ccode || '.test'),
      (a_support, 'support@' || v_ccode || '.test'),
      (a_staffer, 'staffer@' || v_ccode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('owner@' || v_pcode || '.test', a_owner, 'Mail Owner', 'owner'),
      ('operator@' || v_pcode || '.test', a_operator, 'Mail Operator', 'operator'),
      -- Staff who also administer the customer: never written to as the customer.
      ('staffer@' || v_ccode || '.test', null, 'Mail Staffer', 'support');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    perform erp.claim_invitation(rc.admin_token);

    v_step := 'the customer has a second administrator, a support principal and a member of staff';
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_customer, a_second, 'person', 'active', 'Second Admin', 'second@' || v_ccode || '.test', 'en')
    returning id into u_id;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select v_customer, u_id, ro.id, 'the suite needs a second administrator'
      from erp.role ro where ro.tenant_id = v_customer and ro.code = 'administrator' and ro.status = 'active';
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_customer, a_support, 'person', 'active', 'Platform Support Person', 'support@' || v_ccode || '.test', 'en')
    returning id into u_id;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select v_customer, u_id, ro.id, 'Platform owner support access: the commercial email suite'
      from erp.role ro where ro.tenant_id = v_customer and ro.code = 'administrator' and ro.status = 'active';
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_customer, a_staffer, 'person', 'active', 'Staff Member', 'staffer@' || v_ccode || '.test', 'en')
    returning id into u_id;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select v_customer, u_id, ro.id, 'the suite needs an administrator who is also platform staff'
      from erp.role ro where ro.tenant_id = v_customer and ro.code = 'administrator' and ro.status = 'active';

    v_step := 'the platform organisation is designated and sells the list';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'the commercial email suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_platform);

    -- ── 1. An order form goes to the customer contact ───────────────────────
    v_step := 'a quote with a customer contact is issued';
    v_q1 := erp.open_commercial_quote('ZZMAIL', 'Mail Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30, v_ccode);
    res := public.erp_set_quote_contact(v_q1, 'Dana Buyer', 'dana@' || v_ccode || '.test');
    perform erp.add_quote_line(v_q1, 'PLAN-STANDARD', 1, 10);
    perform erp.submit_quote(v_q1);
    res := erp.issue_quote(v_q1);
    select count(*) into v_n from erp_meta.commercial_email e where e.quote_document_id = v_q1;
    ok_quote := v_n = 1
            and (res ->> 'emails_queued')::integer = 1
            and exists (select 1 from erp_meta.commercial_email e
                         where e.quote_document_id = v_q1 and e.kind = 'order_form'
                           and e.to_address = 'dana@' || v_ccode || '.test' and e.to_name = 'Dana Buyer'
                           and e.recipient_source = 'customer_contact' and e.status = 'queued'
                           and e.send_number = 1 and e.tenant_id = v_customer
                           and e.requested_by = 'admin@' || v_pcode || '.test');
    msg_quote := format('%s row(s) for the quote; issue said %s', v_n, coalesce(res ->> 'emails_queued', 'nothing'));

    -- ── 2. A quote with nobody to send to ───────────────────────────────────
    v_step := 'a quote with no customer email is issued';
    v_q2 := erp.open_commercial_quote('ZZNOMAIL', 'No Address Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30);
    perform erp.add_quote_line(v_q2, 'PLAN-STARTER');
    perform erp.submit_quote(v_q2);
    res := erp.issue_quote(v_q2);
    select count(*) into v_n from erp_meta.commercial_email e where e.quote_document_id = v_q2;
    perform set_config('request.jwt.claims', json_build_object('sub', a_operator)::text, true);
    begin
      perform public.erp_platform_send_commercial_email('order_form', v_q2);
      v_ok := false; v_msg := 'sending a quote with nobody to send to was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NO_CUSTOMER_EMAIL%'; v_msg := left(sqlerrm, 80);
    end;
    res := public.erp_platform_commercial_emails(v_q2, null);
    ok_nobody := v_n = 0 and v_ok and jsonb_array_length(res -> 'recipients') = 0
             and jsonb_array_length(res -> 'sends') = 0;
    msg_nobody := format('%s row(s); send again: %s', v_n, v_msg);

    -- ── 3–4. An invoice goes to the billing contact, or the administrators ─
    v_step := 'a contract is made and signed';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.quote_transition(v_q1, 'accept', 'order form returned signed');
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    v_contract := erp.create_contract_from_quote(v_q1, v_ccode, 'Mail Customer Ltd', 'Clove ERP Ltd', current_date,
                                                 12, 'automatic', 90, 'England and Wales', 'monthly');
    perform erp.sign_contract(v_contract, 'A. Customer, director', 'Mail Owner, director', 'agreement to the order form');
    perform erp.generate_invoice_schedule(v_contract);
    select i.id into v_inv1 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq limit 1;
    select i.id into v_inv2 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq offset 1 limit 1;
    select i.id into v_inv3 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq offset 2 limit 1;

    v_step := 'only an owner sets a billing contact or payment details';
    perform set_config('request.jwt.claims', json_build_object('sub', a_operator)::text, true);
    ok_owner := true; msg_owner := '';
    begin
      perform public.erp_platform_set_billing_contact(v_contract, 'accounts@' || v_ccode || '.test', 'Accounts');
      ok_owner := false; msg_owner := 'an operator set a billing contact; ';
    exception when others then
      ok_owner := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%';
      msg_owner := 'billing contact: ' || left(sqlerrm, 60) || '; ';
    end;
    begin
      perform public.erp_platform_set_billing_details('Suite Supplier Ltd', '1 Nowhere Lane, Testtown', '00000000',
                                                      'Suite Supplier Ltd', '00-00-00', '00000000', null);
      ok_owner := false; msg_owner := msg_owner || 'an operator set payment details';
    exception when others then
      ok_owner := ok_owner and sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%';
      msg_owner := msg_owner || 'payment details: ' || left(sqlerrm, 60);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    begin
      perform public.erp_platform_set_billing_details('Suite Supplier Ltd', null, null,
                                                      'Suite Supplier Ltd', '00-00-0', '00000000', null);
      ok_owner := false; msg_owner := msg_owner || '; a five-digit sort code was saved';
    exception when others then
      ok_owner := ok_owner and sqlerrm like 'CLOVEERP_SORT_CODE_INVALID%';
    end;
    res := public.erp_platform_set_billing_details('Suite Supplier Ltd', '1 Nowhere Lane, Testtown', '00000000',
                                                   'Suite Supplier Ltd', '000000', '00000000',
                                                   'Quote the invoice reference.');
    ok_owner := ok_owner and (res ->> 'sort_code') = '00-00-00'
            and (public.erp_platform_billing_details() ->> 'set')::boolean
            and exists (select 1 from erp_meta.platform_audit a
                         where a.action = 'platform.billing_details_set' and a.actor_email = 'owner@' || v_pcode || '.test'
                           and position('00000000' in a.detail::text) = 0);

    v_step := 'an invoice with a billing contact is issued';
    res := public.erp_platform_set_billing_contact(v_contract, 'accounts@' || v_ccode || '.test', 'Accounts Team');
    perform erp.issue_contract_invoice(v_inv1);
    select count(*) into v_n from erp_meta.commercial_email e where e.contract_invoice_id = v_inv1;
    ok_billing := v_n = 1
              and exists (select 1 from erp_meta.commercial_email e
                           where e.contract_invoice_id = v_inv1 and e.kind = 'contract_invoice'
                             and e.to_address = 'accounts@' || v_ccode || '.test' and e.to_name = 'Accounts Team'
                             and e.recipient_source = 'billing_contact' and e.status = 'queued'
                             and e.tenant_id = v_customer and e.requested_by = 'owner@' || v_pcode || '.test');
    msg_billing := format('%s row(s) for the first invoice', v_n);

    v_step := 'an invoice without a billing contact is issued';
    res := public.erp_platform_set_billing_contact(v_contract, null, null);
    perform erp.issue_contract_invoice(v_inv2);
    select string_agg(e.to_address || ' (' || e.recipient_source || ')', ', ' order by e.to_address)
      into v_msg
      from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2;
    ok_admins := (select count(*) from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2) = 2
             and exists (select 1 from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2
                            and e.to_address = 'admin@' || v_ccode || '.test' and e.recipient_source = 'administrator')
             and exists (select 1 from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2
                            and e.to_address = 'second@' || v_ccode || '.test')
             and not exists (select 1 from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2
                                and e.to_address in ('support@' || v_ccode || '.test', 'staffer@' || v_ccode || '.test'));
    msg_admins := coalesce(v_msg, 'nobody');

    -- ── 6. The claim, from a bare connection ────────────────────────────────
    v_step := 'the drain claims from a connection with no organisation and nobody signed in';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    v_keys := null;
    for c in select * from erp.claim_commercial_email_batch(500, 'zz-commercial-mail') loop
      if c.email_id in (select e.id from erp_meta.commercial_email e
                         where e.quote_document_id = v_q1 or e.contract_invoice_id in (v_inv1, v_inv2)) then
        v_claimed := v_claimed + 1;
        v_keys := coalesce(v_keys || ', ', '') || coalesce(erp_test.keys_naming_cost_or_margin(c.payload), '');
        if c.email_kind = 'order_form' then
          v_form := c.payload;
          v_reply := c.reply_address;
        elsif c.recipient_address = 'accounts@' || v_ccode || '.test' then
          v_invoice := c.payload;
        end if;
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
    ok_claim := v_claimed = 4
            and nullif(replace(coalesce(v_keys, ''), ', ', ''), '') is null
            and v_form ->> 'document_number' = (select d.document_number from erp.document d where d.id = v_q1)
            and v_form ->> 'customer_name' = 'Mail Customer Ltd'
            and jsonb_array_length(v_form -> 'lines') = 1
            and (v_form -> 'lines' -> 0 ->> 'discount_pct')::numeric = 10
            and (v_form -> 'totals' ->> 'net_minor')::bigint = (v_form -> 'lines' -> 0 ->> 'net_minor')::bigint
            and v_form ->> 'valid_until' is not null
            and v_reply = 'admin@' || v_pcode || '.test'
            and v_invoice ->> 'reference' = (select i.reference from erp_meta.contract_invoice i where i.id = v_inv1)
            and (v_invoice ->> 'due_on')::date = current_date + 14
            and v_invoice ->> 'tax_statement' = 'Clove ERP Ltd is not registered for VAT; no VAT is charged.'
            and v_invoice -> 'payment_details' ->> 'sort_code' = '00-00-00'
            and v_invoice -> 'payment_details' ->> 'bank_account_name' = 'Suite Supplier Ltd'
            and not exists (select 1 from erp_meta.commercial_email e
                             where (e.quote_document_id = v_q1 or e.contract_invoice_id in (v_inv1, v_inv2))
                               and not (e.status = 'sending' and e.claimed_by = 'zz-commercial-mail' and e.attempts = 1));
    msg_claim := format('%s of ours claimed; cost or margin keys: %s; order form %s; invoice due %s, details %s',
                        v_claimed, coalesce(nullif(replace(coalesce(v_keys, ''), ', ', ''), ''), 'none'),
                        coalesce(v_form ->> 'document_number', 'missing'), coalesce(v_invoice ->> 'due_on', 'missing'),
                        coalesce((v_invoice -> 'payment_details')::text, 'none'));

    -- ── 7. Settled ──────────────────────────────────────────────────────────
    v_step := 'the drain settles what it sent and what failed';
    perform erp.complete_commercial_email(
      (select e.id from erp_meta.commercial_email e where e.quote_document_id = v_q1 and e.send_number = 1), 'zz-provider-1');
    v_status1 := erp.fail_commercial_email(
      (select e.id from erp_meta.commercial_email e where e.contract_invoice_id = v_inv1), 'resend responded 503', true);
    v_status2 := erp.fail_commercial_email(
      (select e.id from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2
          and e.to_address = 'second@' || v_ccode || '.test'), 'resend responded 422', false);
    ok_settle := exists (select 1 from erp_meta.commercial_email e
                          where e.quote_document_id = v_q1 and e.send_number = 1 and e.status = 'sent'
                            and e.provider_message_id = 'zz-provider-1' and e.sent_at is not null and e.lease_expires_at is null)
             and v_status1 = 'queued' and v_status2 = 'failed'
             and exists (select 1 from erp_meta.commercial_email e
                          where e.contract_invoice_id = v_inv1 and e.status = 'queued' and e.failure_reason = 'resend responded 503');
    begin
      perform erp.complete_commercial_email(
        (select e.id from erp_meta.commercial_email e where e.contract_invoice_id = v_inv1), 'zz-provider-2');
      ok_settle := false; msg_settle := 'a queued row was settled as sent; ';
    exception when others then
      msg_settle := '';
      ok_settle := ok_settle and sqlerrm like 'CLOVEERP_COMMERCIAL_EMAIL_NOT_SENDING%';
    end;
    msg_settle := msg_settle || format('retry left it %s, a permanent failure left it %s', v_status1, v_status2);

    -- ── 8. Send again ───────────────────────────────────────────────────────
    v_step := 'an operator sends the order form again';
    select e.idempotency_key into v_first_key from erp_meta.commercial_email e
     where e.quote_document_id = v_q1 and e.send_number = 1;
    perform set_config('request.jwt.claims', json_build_object('sub', a_operator)::text, true);
    res := public.erp_platform_send_commercial_email('order_form', v_q1);
    ok_again := (res ->> 'queued')::integer = 1
            and exists (select 1 from erp_meta.commercial_email e
                         where e.quote_document_id = v_q1 and e.send_number = 2 and e.status = 'queued'
                           and e.idempotency_key <> v_first_key
                           and e.to_address = 'dana@' || v_ccode || '.test'
                           and e.requested_by = 'operator@' || v_pcode || '.test')
            and exists (select 1 from erp_meta.platform_audit a
                         where a.action = 'platform.commercial_email_sent_again'
                           and a.actor_email = 'operator@' || v_pcode || '.test' and a.target = v_q1::text)
            and jsonb_array_length(public.erp_platform_commercial_emails(v_q1, null) -> 'sends') = 2;
    msg_again := format('send again queued %s; keys differ: %s', coalesce(res ->> 'queued', 'nothing'),
                        (select bool_and(e.idempotency_key <> v_first_key) from erp_meta.commercial_email e
                          where e.quote_document_id = v_q1 and e.send_number = 2));

    -- ── 9. A demonstration ──────────────────────────────────────────────────
    v_step := 'the customer becomes a demonstration';
    perform set_config('request.jwt.claims', '', true);
    update erp.tenant set code = 'demo-' || v_tag where id = v_customer;
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.issue_contract_invoice(v_inv3);
    select count(*) into v_n from erp_meta.commercial_email e where e.contract_invoice_id = v_inv3;
    perform set_config('request.jwt.claims', json_build_object('sub', a_operator)::text, true);
    begin
      perform public.erp_platform_send_commercial_email('contract_invoice', v_inv3);
      v_ok := false; v_msg := 'the console sent a demonstration''s invoice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DEMONSTRATION_SENDS_NO_EMAIL%'; v_msg := left(sqlerrm, 80);
    end;
    perform set_config('request.jwt.claims', '', true);
    for c in select * from erp.claim_commercial_email_batch(500, 'zz-commercial-mail') loop
      if c.email_id in (select e.id from erp_meta.commercial_email e
                         where e.quote_document_id = v_q1 or e.contract_invoice_id in (v_inv1, v_inv2, v_inv3)) then
        v_ok := false; v_msg := v_msg || '; the claim handed over a demonstration''s email';
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
    ok_demo := v_n = 0 and v_ok
           and not exists (select 1 from erp_meta.commercial_email e
                            where (e.quote_document_id = v_q1 or e.contract_invoice_id in (v_inv1, v_inv2))
                              and e.status = 'queued')
           and exists (select 1 from erp_meta.commercial_email e
                        where e.quote_document_id = v_q1 and e.send_number = 2 and e.status = 'cancelled'
                          and e.failure_reason = 'a demonstration organisation sends no email');
    msg_demo := format('%s row(s) for its invoice; %s', v_n, v_msg);

    v_step := 'done';
    raise exception 'ZZ_COMMERCIAL_EMAIL_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_COMMERCIAL_EMAIL_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'an issued quote queues one order form email, to the customer contact the quote records';
  passed := v_state is null and coalesce(ok_quote, false);
  detail := coalesce(v_state, msg_quote);
  return next;

  case_name := 'a quote with no customer email queues nothing, and the console says so when asked to send it';
  passed := v_state is null and coalesce(ok_nobody, false);
  detail := coalesce(v_state, msg_nobody);
  return next;

  case_name := 'an issued invoice goes to the contract''s billing contact';
  passed := v_state is null and coalesce(ok_billing, false);
  detail := coalesce(v_state, msg_billing);
  return next;

  case_name := 'without a billing contact it goes to the organisation''s administrators, never to platform support or staff';
  passed := v_state is null and coalesce(ok_admins, false);
  detail := coalesce(v_state, msg_admins);
  return next;

  case_name := 'only an owner sets payment details or a billing contact, and the log keeps no account number';
  passed := v_state is null and coalesce(ok_owner, false);
  detail := coalesce(v_state, msg_owner);
  return next;

  case_name := 'a bare connection claims each email with what it needs, payment details included, and no cost or margin at any depth';
  passed := v_state is null and coalesce(ok_claim, false);
  detail := coalesce(v_state, msg_claim);
  return next;

  case_name := 'a sent email is settled with the provider''s id, and a failure is tried again or failed as the drain says';
  passed := v_state is null and coalesce(ok_settle, false);
  detail := coalesce(v_state, msg_settle);
  return next;

  case_name := 'send again queues a new attempt with a new idempotency key, and the platform log records who';
  passed := v_state is null and coalesce(ok_again, false);
  detail := coalesce(v_state, msg_again);
  return next;

  case_name := 'a demonstration organisation queues nothing, the console refuses to send, and the claim cancels what was queued';
  passed := v_state is null and coalesce(ok_demo, false);
  detail := coalesce(v_state, msg_demo);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ccode, 'demo-' || v_tag))
        and not exists (select 1 from auth.users au
                         where au.id in (a_admin, a_owner, a_operator, a_customer, a_second, a_support, a_staffer))
        and not exists (select 1 from erp_meta.platform_staff s where s.email like '%@zzcm_-' || v_tag || '.test')
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'the organisations, people, staff, emails, payment details and every setting went with the block';
  return next;
end;
$$;

revoke all on function erp_test.commercial_email_suite() from public, anon, authenticated;

create or replace function erp_test.assert_commercial_email_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _commercial_email_result on commit drop as
    select * from erp_test.commercial_email_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _commercial_email_result s;
  drop table _commercial_email_result;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_COMMERCIAL_EMAIL_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_COMMERCIAL_EMAIL_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('commercial email: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_commercial_email_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
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
select erp_test.assert_commercial_email_suite();
