set lock_timeout = '30s';

-- =============================================================================
-- 20260930400000  A credit kept on account is allocated to an invoice
-- -----------------------------------------------------------------------------
-- PR13 M5 (docs/spec/simplification-review.md §7 Finance, node F5): the gap
-- the cash tolerance left (20260929300000, "Nothing allocates an on-account
-- credit to a later invoice"). On top of the cash documents' screens
-- (20260930300000).
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Cash beyond what a customer owed, and beyond the settlement tolerance, is
-- kept on the customer's account (erp.post_cash_on_account(), Cr receivable on
-- a row that names the customer and no document), and the ageing carries it as
-- unallocated credit. Nothing applied it afterwards. The customer's next
-- invoice stood owing in full beside the credit, was dunned, and moved to paid
-- only if a person wrote a manual journal, which settles nothing: the invoice
-- stayed issued and the credit stayed in the ageing.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp_allocate_on_account(p_credit_item, p_invoice, p_amount_minor):
--     applies a credit kept on account to an open invoice of the same
--     customer, company, ledger, control account and currency, by
--     finance.post in the credit's company. The amount defaults to the lesser
--     of what is left of the credit and what the invoice owes; an amount named
--     is refused, not trimmed, beyond either.
--       - One journal, cash.allocated, by the cash application rule: Dr the
--         receivable (the credit, consumed) and Cr the receivable (the
--         invoice, settled), on the same control account, so the ledger nets
--         to nothing and the trial balance's receivable turnover grows by the
--         allocation. It names the receipt that kept the credit, where there
--         is one, so "which cash paid this invoice" is still read from
--         journal.document_id.
--       - Two subledger rows: a debit of the amount naming the customer and no
--         document, which takes the credit out of the ageing's unallocated
--         row, and a credit naming the invoice, which the invoice's
--         settled_minor takes as cash's does. The credit's own settled_minor
--         says how much of it has been allocated, and the debit's is its whole
--         amount, so no reader of open items (Apply cash, dunning, statement
--         matching, the credit position) ever takes it for something owed.
--       - Then erp.settle_paid_document(): the invoice moves to part_paid or
--         paid, derived, as it does after cash.
--   * The credit a person may allocate is one erp.post_cash_on_account()
--     wrote (a posted cash.on_account journal), with some of it left and the
--     ageing still carrying at least that much unallocated for the customer:
--     erp.on_account_credit_left().
--   * erp_on_account_credits(): the credits kept on account with something
--     left, each with its receipt, the open invoices of the same customer,
--     company and currency it may go to, and whether the reader may allocate
--     it (finance.post in its company). The Finance screen lists them under
--     Credit on account and draws Allocate on a row only when the database
--     says the reader may and there is an invoice to take it.
--   * Refusals, registered: nothing on account (not such a credit, or none
--     of it left), another customer's invoice, another company's, ledger's,
--     control account's or currency's, more than is left of the credit, more
--     than the invoice owes, and an amount that is not positive. A closed
--     period refuses at the ledger, CLOVEERP_PERIOD_CLOSED, below the door.
--   * The event cash.allocated, its payload and its names.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * Allocation is a door, not automatic at invoice issue (D9): an issuer
--     holding sales.invoice and not finance.post would leave an invoice owing
--     nothing and still issued, and issue would change its behaviour.
--   * A credit kept on account is one row, so the door takes it by its row:
--     no oldest-first attribution across several credits is needed, and the
--     journal names that row's receipt exactly.
--   * Dated today. A closed month is not allocated into; a person reopens it
--     or allocates in the open one.
--   * Unallocated credit notes (D15) and prepayments (D12) are not allocated
--     here: cash kept on account only.
--   * No undo (D10). A misallocation is corrected with a journal, as a
--     misapplied receipt is.
--   * No step is added to any flow: Credit on account is an exception list on
--     the Finance screen, not a step of the strip.
--
-- Proved by erp_test.on_account_allocation_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

-- A1. The refusals

select erp.register_refusal('CLOVEERP_NOTHING_ON_ACCOUNT',
  'Allocating something that is not a credit kept on a customer''s account, or one already allocated in full.',
  'Only cash kept on a customer''s account, beyond what they owed, is allocated to their invoices, and only as much of it as is left; allocating anything else would settle an invoice with money nobody received.',
  'Pick the credit from Credit on account on the Finance screen, which lists only those with something left.');

select erp.register_refusal('CLOVEERP_ALLOCATION_OTHER_CUSTOMER',
  'Allocating a customer''s credit to an invoice that is not theirs.',
  'A credit kept on account is the customer''s own money, and settles only their invoices.',
  'Allocate it to one of the customer''s own open invoices, which Credit on account offers on the credit''s row.');

select erp.register_refusal('CLOVEERP_ALLOCATION_OTHER_COMPANY',
  'Allocating a credit to an invoice of another company, ledger, control account or currency.',
  'A credit is banked in one company''s books, in one currency, on one receivable account, and each company''s books stand alone; it settles invoices in those books only.',
  'Allocate it to an invoice of the same company and currency, or move the balance between companies with a journal.');

select erp.register_refusal('CLOVEERP_ALLOCATION_EXCEEDS_CREDIT',
  'Allocating more than is left of a credit kept on account.',
  'An allocation spends the customer''s credit; spending more than is left of it would settle an invoice with money that is not there.',
  'Allocate no more than the credit has left, which Credit on account shows, or leave the amount out to allocate what is left.');

select erp.register_refusal('CLOVEERP_ALLOCATION_EXCEEDS_OWING',
  'Allocating more to an invoice than it still owes.',
  'An invoice settled beyond what it owes would carry a credit of its own, and the rest of the customer''s credit belongs on their account, where it already is.',
  'Allocate no more than the invoice owes, or leave the amount out to allocate what it owes.');

select erp.register_refusal('CLOVEERP_ALLOCATION_AMOUNT_INVALID',
  'Allocating an amount that is not positive.',
  'An allocation moves some of a credit to an invoice; nothing, or less than nothing, moves nothing.',
  'Name a positive amount in minor units, or leave it out to allocate as much as the credit and the invoice allow.');

-- A2. The event

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.cash.allocated', 'en', 'Credit on account allocated', 'finance',
   'Event raised when cash kept on a customer''s account is allocated to one of their invoices.'),
  ('event.cash.allocated', 'de', 'Guthaben zugeordnet', 'finance',
   'Ereignis, wenn ein Guthaben auf dem Kundenkonto einer Rechnung des Kunden zugeordnet wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('cash.allocated', 1, 'document', 'finance', 'event.cash.allocated',
        'Cash kept on a customer''s account was allocated to one of their invoices.',
        '{"type":"object","required":["value_minor","currency","subledger_item_id"],
          "properties":{"reference":{"type":"string"},"value_minor":{"type":"integer"},
                        "currency":{"type":"string"},"posting_rule":{"type":"string"},
                        "subledger_item_id":{"type":"string"},"receipt_id":{"type":["string","null"]}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'cash.allocated' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.cash.allocated') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: cash.allocated is declared already, and not as 20260930400000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The credit, the door and the list
-- ═════════════════════════════════════════════════════════════════════════════

-- B1. What is left of a credit kept on account

create or replace function erp.on_account_credit_left(p_item_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- A credit erp.post_cash_on_account() kept on a customer's account
  -- (20260929300000): a receivable row naming the customer and no document,
  -- a credit only, written by a posted cash.on_account journal. What is left
  -- of it is its amount less what has been allocated from it (its
  -- settled_minor, 20260930400000), and never more than the ageing still
  -- carries unallocated for that customer in its company, control account and
  -- currency, so the one computation of what is owed stays the bound. Nought
  -- for anything else.
  select coalesce((
    select greatest(0::bigint,
             least(si.credit_minor - coalesce(si.settled_minor, 0),
                   -coalesce((select b.outstanding_minor from erp.ageing_balance b
                               where b.tenant_id = si.tenant_id and b.entity_id = si.entity_id
                                 and b.control_account_id = si.control_account_id
                                 and b.control_kind = 'receivable' and b.currency = si.currency
                                 and b.party_id = si.party_id and b.document_id is null), 0)))
      from erp.subledger_item si
      join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
     where si.tenant_id = erp.current_tenant_id() and si.id = p_item_id
       and si.control_kind = 'receivable' and si.document_id is null and si.party_id is not null
       and si.credit_minor > 0 and si.debit_minor = 0
       and j.source_code = 'cash.on_account' and j.status = 'posted'), 0)::bigint
$$;

revoke all on function erp.on_account_credit_left(uuid) from public, anon;

comment on function erp.on_account_credit_left(uuid) is
  'What is left to allocate of a credit kept on a customer''s account (20260930400000): its amount '
  'less what has been allocated from it, bounded by the unallocated credit the ageing carries. '
  'Nought for anything that is not such a credit.';

-- B2. The door

create or replace function erp.allocate_on_account(p_credit_item uuid, p_invoice uuid,
                                                   p_amount_minor bigint default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  cr        erp.subledger_item%rowtype;
  r         record;
  v_left    bigint;
  v_owes    bigint;
  v_open    bigint;
  v_amount  bigint;
  v_rest    bigint;
  v_take    bigint;
  v_rule    uuid;
  v_version integer;
  v_receipt uuid;
  v_number  text;
  v_event   uuid;
  v_journal uuid;
  v_customer text;
begin
  -- The credit, held while it is spent: two allocations of one credit wait
  -- for each other here, and the second sees what the first left.
  select si.* into cr
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.id = p_credit_item
     and si.control_kind = 'receivable' and si.document_id is null and si.party_id is not null
     and si.credit_minor > 0 and si.debit_minor = 0
     and exists (select 1 from erp.journal j
                  where j.tenant_id = v_tenant and j.id = si.journal_id
                    and j.source_code = 'cash.on_account' and j.status = 'posted')
     for update;
  if not found then
    raise exception 'CLOVEERP_NOTHING_ON_ACCOUNT: % is not a credit kept on a customer''s account', p_credit_item
      using errcode = '23503',
            hint = 'Pick the credit from Credit on account on the Finance screen, which lists only those with something left.';
  end if;

  -- Allocating is posting cash, in the company whose books hold the credit.
  perform erp.authorise('finance.post', cr.entity_id, null, null, 'party', cr.party_id);

  v_customer := coalesce((select p.code from erp.party p where p.tenant_id = v_tenant and p.id = cr.party_id),
                         cr.party_id::text);
  v_left := erp.on_account_credit_left(cr.id);
  if v_left <= 0 then
    raise exception 'CLOVEERP_NOTHING_ON_ACCOUNT: the credit kept on % has nothing left to allocate', v_customer
      using errcode = '23514',
            hint = 'Pick the credit from Credit on account on the Finance screen, which lists only those with something left.';
  end if;

  -- The invoice: the customer's receivable, in the credit's books.
  if not exists (select 1 from erp.subledger_item si
                  where si.tenant_id = v_tenant and si.document_id = p_invoice
                    and si.control_kind = 'receivable' and si.party_id = cr.party_id) then
    raise exception 'CLOVEERP_ALLOCATION_OTHER_CUSTOMER: % is not an invoice of %',
      coalesce((select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = p_invoice),
               coalesce(p_invoice::text, 'nothing')), v_customer
      using errcode = '23514',
            hint = 'Allocate it to one of the customer''s own open invoices, which Credit on account offers on the credit''s row.';
  end if;
  if exists (select 1 from erp.subledger_item si
              where si.tenant_id = v_tenant and si.document_id = p_invoice and si.control_kind = 'receivable'
                and (si.party_id is distinct from cr.party_id or si.entity_id <> cr.entity_id
                     or si.ledger_id <> cr.ledger_id or si.control_account_id <> cr.control_account_id
                     or si.currency <> cr.currency)) then
    raise exception 'CLOVEERP_ALLOCATION_OTHER_COMPANY: % is not in the books the credit of % is kept in (%, %)',
      coalesce((select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = p_invoice),
               p_invoice::text),
      v_customer,
      coalesce((select e.code from erp.entity e where e.tenant_id = v_tenant and e.id = cr.entity_id), cr.entity_id::text),
      cr.currency
      using errcode = '23514',
            hint = 'Allocate it to an invoice of the same company and currency, or move the balance between companies with a journal.';
  end if;

  -- Held too, so what it owes cannot move under the allocation.
  perform 1 from erp.subledger_item si
   where si.tenant_id = v_tenant and si.document_id = p_invoice and si.control_kind = 'receivable'
   order by si.id
     for update;

  select d.document_number into v_number
    from erp.document d where d.tenant_id = v_tenant and d.id = p_invoice;

  -- What it owes: the one computation of what is owed, and never more than its
  -- open items, which are what the allocation settles.
  select coalesce(sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))
                    filter (where si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0), 0)
    into v_open
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.document_id = p_invoice and si.control_kind = 'receivable';
  v_owes := greatest(0::bigint, least(v_open,
              coalesce((select sum(b.outstanding_minor) from erp.ageing_balance b
                         where b.tenant_id = v_tenant and b.document_id = p_invoice
                           and b.control_kind = 'receivable'), 0)::bigint));

  if p_amount_minor is not null and p_amount_minor <= 0 then
    raise exception 'CLOVEERP_ALLOCATION_AMOUNT_INVALID: an allocation is a positive amount, not %', p_amount_minor
      using errcode = '22023',
            hint = 'Name a positive amount in minor units, or leave it out to allocate as much as the credit and the invoice allow.';
  end if;
  v_amount := coalesce(p_amount_minor, least(v_left, v_owes));
  if v_amount > v_left then
    raise exception 'CLOVEERP_ALLOCATION_EXCEEDS_CREDIT: % is more than the % left of the credit kept on %',
      v_amount, v_left, v_customer
      using errcode = '23514',
            hint = 'Allocate no more than the credit has left, which Credit on account shows, or leave the amount out to allocate what is left.';
  end if;
  if v_amount > v_owes or v_owes <= 0 then
    raise exception 'CLOVEERP_ALLOCATION_EXCEEDS_OWING: % owes %, and % was to be allocated to it',
      coalesce(v_number, p_invoice::text), v_owes, v_amount
      using errcode = '23514',
            hint = 'Allocate no more than the invoice owes, or leave the amount out to allocate what it owes.';
  end if;

  perform erp.require_cash_in_ledger_currency(cr.ledger_id, cr.currency);

  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503', hint = 'erp.configure_receivables() installs it.';
  end if;

  -- The receipt that kept the credit, if the organisation had receipts then.
  select j.document_id into v_receipt
    from erp.journal j where j.tenant_id = v_tenant and j.id = cr.journal_id;

  v_event := erp.append_event(
    'cash.allocated', 'document', p_invoice,
    jsonb_build_object('reference', v_number, 'posting_rule', 'cash_application',
                       'value_minor', v_amount, 'currency', cr.currency,
                       'subledger_item_id', cr.id, 'receipt_id', v_receipt),
    cr.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status, document_id)
  values (v_tenant, cr.entity_id, cr.ledger_id, 'cash.allocated', v_event, current_date,
          format('Credit on account allocated to %s', coalesce(v_number, 'an invoice')), 'draft', v_receipt)
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, cr.control_account_id, v_amount, 0, cr.currency, v_amount, 0, 1,
          v_rule, v_version, v_event, 'the credit kept on the customer''s account, allocated'),
         (v_tenant, v_journal, 2, cr.control_account_id, 0, v_amount, cr.currency, 0, v_amount, 1,
          v_rule, v_version, v_event, 'applied to receivable');

  -- The credit, consumed: settled whole, so no reader of open items takes it
  -- for something owed.
  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                  settled_minor, posting_date)
  values (v_tenant, cr.entity_id, cr.ledger_id, 'receivable', cr.control_account_id,
          cr.party_id, null, v_journal, cr.currency, v_amount, 0, v_amount, current_date),
  -- The invoice, settled, as cash settles it.
         (v_tenant, cr.entity_id, cr.ledger_id, 'receivable', cr.control_account_id,
          cr.party_id, p_invoice, v_journal, cr.currency, 0, v_amount, 0, current_date);

  v_rest := v_amount;
  for r in
    select si.id, si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) as owing
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.document_id = p_invoice and si.control_kind = 'receivable'
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
     order by coalesce(si.due_date, si.posting_date), si.id
  loop
    exit when v_rest <= 0;
    v_take := least(v_rest, r.owing);
    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_take, updated_at = now()
     where id = r.id;
    v_rest := v_rest - v_take;
  end loop;

  update erp.subledger_item
     set settled_minor = coalesce(settled_minor, 0) + v_amount, updated_at = now()
   where id = cr.id;

  -- Posted here: a closed period refuses it at the ledger, and the whole
  -- allocation with it.
  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  -- And the invoice says what it now owes: part_paid or paid, derived.
  perform erp.settle_paid_document(p_invoice,
    format('allocated from the credit kept on account%s',
           coalesce(' by ' || (select d.document_number from erp.document d
                                where d.tenant_id = v_tenant and d.id = v_receipt), '')));

  return jsonb_build_object(
    'credit_item_id', cr.id,
    'invoice_id', p_invoice,
    'invoice_number', v_number,
    'allocated_minor', v_amount,
    'currency', cr.currency,
    'credit_left_minor', erp.on_account_credit_left(cr.id),
    'invoice_owes_minor', coalesce((select sum(b.outstanding_minor) from erp.ageing_balance b
                                     where b.tenant_id = v_tenant and b.document_id = p_invoice
                                       and b.control_kind = 'receivable'), 0)::bigint,
    'invoice_state', erp.object_current_state('document', p_invoice),
    'journal_id', v_journal,
    'receipt_id', v_receipt,
    'receipt_number', (select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = v_receipt));
end;
$$;

revoke all on function erp.allocate_on_account(uuid, uuid, bigint) from public, anon;

comment on function erp.allocate_on_account(uuid, uuid, bigint) is
  'Allocates a credit kept on a customer''s account to one of their open invoices in the same company, '
  'ledger, control account and currency (20260930400000): a cash.allocated journal by the cash '
  'application rule naming the receipt that kept the credit, a row consuming the credit and one '
  'settling the invoice, then erp.settle_paid_document(). Authorises finance.post in the credit''s '
  'company. The amount defaults to the lesser of what is left and what is owed.';

create or replace function public.erp_allocate_on_account(p_credit_item uuid, p_invoice uuid,
                                                          p_amount_minor bigint default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.allocate_on_account(p_credit_item, p_invoice, p_amount_minor) $$;

revoke all on function public.erp_allocate_on_account(uuid, uuid, bigint) from public, anon;
grant execute on function public.erp_allocate_on_account(uuid, uuid, bigint) to authenticated, service_role;

comment on function public.erp_allocate_on_account(uuid, uuid, bigint) is
  'Allocates a credit kept on a customer''s account to one of their open invoices (20260930400000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_allocate_on_account', 'erp.allocate_on_account',
   'Allocates a credit kept on a customer''s account to one of their invoices: posts a cash.allocated journal and two subledger rows, and moves the invoice to part_paid or paid; authorises finance.post in the credit''s company.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/finance', array['erp_allocate_on_account']);

-- B3. The list the screen draws Allocate on

create or replace function erp.on_account_credits()
returns table(credit_item_id uuid, party_id uuid, party_name text, entity_id uuid, company text,
              currency char(3), kept_on date, credit_minor bigint, left_minor bigint,
              receipt_id uuid, receipt_number text, allocatable boolean, invoices jsonb)
language sql
stable
set search_path = ''
as $$
  -- Every credit kept on a customer's account with something left
  -- (20260930400000), oldest first, with the receipt that kept it, the open
  -- invoices of the same customer, company, control account and currency it
  -- may be allocated to, oldest first, and whether the reader holds
  -- finance.post in its company. The door decides regardless.
  select si.id, si.party_id, p.name, si.entity_id, e.code, si.currency, si.posting_date,
         si.credit_minor, erp.on_account_credit_left(si.id),
         j.document_id, rd.document_number,
         erp.has_permission('finance.post', si.entity_id),
         coalesce((select jsonb_agg(jsonb_build_object(
                             'document_id', b.document_id, 'document_number', d.document_number,
                             'owes_minor', b.outstanding_minor, 'due_on', b.due_on)
                           order by b.due_on, d.document_number)
                     from erp.ageing_balance b
                     join erp.document d on d.tenant_id = b.tenant_id and d.id = b.document_id
                    where b.tenant_id = si.tenant_id and b.entity_id = si.entity_id
                      and b.control_account_id = si.control_account_id and b.control_kind = 'receivable'
                      and b.currency = si.currency and b.party_id = si.party_id
                      and b.document_id is not null and b.outstanding_minor > 0), '[]'::jsonb)
    from erp.subledger_item si
    join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
    left join erp.party p on p.tenant_id = si.tenant_id and p.id = si.party_id
    left join erp.entity e on e.tenant_id = si.tenant_id and e.id = si.entity_id
    left join erp.document rd on rd.tenant_id = si.tenant_id and rd.id = j.document_id
   where si.tenant_id = erp.current_tenant_id()
     and si.control_kind = 'receivable' and si.document_id is null and si.party_id is not null
     and si.credit_minor > 0 and si.debit_minor = 0
     and j.source_code = 'cash.on_account' and j.status = 'posted'
     and erp.on_account_credit_left(si.id) > 0
   order by si.posting_date, si.id
$$;

revoke all on function erp.on_account_credits() from public, anon;

comment on function erp.on_account_credits() is
  'The credits kept on customers'' accounts with something left to allocate, with the receipt that '
  'kept each, the open invoices it may go to and whether the reader may allocate it (20260930400000).';

create or replace function public.erp_on_account_credits()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(c) order by c.kept_on, c.credit_item_id), '[]'::jsonb)
    from erp.on_account_credits() c
$$;

revoke all on function public.erp_on_account_credits() from public, anon;
grant execute on function public.erp_on_account_credits() to authenticated, service_role;

comment on function public.erp_on_account_credits() is
  'Credit on account: what customers have on account to allocate, and to which invoices (20260930400000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.on_account_invoice(p_entity uuid, p_site uuid, p_item uuid, p_customer uuid,
                                                       p_ccy character, p_ref text, p_price bigint)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_inv uuid;
begin
  -- An invoice to a customer the case already has, issued (20260930400000).
  v_inv := erp.create_document('sales_invoice', p_entity, p_site, p_customer,
                               current_date, p_ccy, p_ref, '{}'::jsonb);
  perform erp.add_document_line(v_inv, p_item, 1, p_price, 'a sale, ' || p_ref);
  perform erp.transition_document(v_inv, 'issue', 'on-account allocation suite');
  return v_inv;
end;
$$;

revoke all on function erp_test.on_account_invoice(uuid, uuid, uuid, uuid, character, text, bigint) from public, anon;

create or replace function erp_test.on_account_allocation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_item uuid;
  v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_cust uuid; v_cust2 uuid;
  v_gross bigint; v_gross2 bigint;
  v_rows jsonb; v_rcpt uuid; v_credit uuid; v_credit2 uuid;
  v_list jsonb; v_row jsonb; v_alloc jsonb; v_alloc2 jsonb;
  v_e2 uuid; v_site2 uuid; v_other uuid; v_eur uuid; v_c5 uuid; v_c5_cust uuid; v_c5_open uuid;
  v_period uuid; v_was text;
  v_n integer; v_n2 integer; v_left bigint; v_left2 bigint;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text; v_tie text;
begin
  begin
    -- ── The fixture: an organisation configured as the demonstration is ─────
    v_step := 'an organisation that invoices and banks receipts, configured from now on';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzoaa-' || v_tag, 'On Account Allocation Suite',
      'admin@zzoaa-' || v_tag || '.test', 'On Account Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzoaa-' || v_tag || '.test'),
           (s_read, 'reader@zzoaa-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a person who may read the books but not post cash';
    res := public.erp_invite_principal('reader@zzoaa-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit and product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZOMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZOEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZOWID', 'On Account Widget', v_uom, 'active') returning id into v_item;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the door, its refusals, its event and its screen';
    v_cases := v_cases + 1;
    case_name := 'the door is on the write allow-list under its gate and on the Finance screen''s help, its six refusals are registered with a next action, and cash.allocated is a current event named in English and German';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_allocate_on_account' and a.gate = 'erp.allocate_on_account')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance' and 'erp_allocate_on_account' = any (h.actions))
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_NOTHING_ON_ACCOUNT', 'CLOVEERP_ALLOCATION_OTHER_CUSTOMER',
                                 'CLOVEERP_ALLOCATION_OTHER_COMPANY', 'CLOVEERP_ALLOCATION_EXCEEDS_CREDIT',
                                 'CLOVEERP_ALLOCATION_EXCEEDS_OWING', 'CLOVEERP_ALLOCATION_AMOUNT_INVALID')
                  and coalesce(f.next_action, '') <> '') = 6
          and exists (select 1 from erp_ref.event_type et where et.code = 'cash.allocated' and et.is_current)
          and (select count(*) from erp_ref.resource x
                where x.key = 'event.cash.allocated' and x.locale in ('en', 'de')) = 2;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. £100 on account, then an invoice, then Allocate ──────────────────
    v_step := 'an invoice paid £100 over, and the customer''s next invoice';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZOA2', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZOA2-OVER') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    select si.id into v_credit
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
       and si.control_kind = 'receivable' and j.source_code = 'cash.on_account';
    v_inv2 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA2-NEXT', 25000);
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    v_list := public.erp_on_account_credits();
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'credit_item_id' = v_credit::text;
    v_step := 'allocating the £100 to the next invoice';
    v_alloc := public.erp_allocate_on_account(v_credit, v_inv2, null);
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := '£100 on account and a later invoice: Credit on account lists the credit with its receipt and offers the invoice; Allocate leaves the invoice owing the rest, Part paid, the on-account row gone from the ageing and from the list, the ageing tied, and the journal naming the receipt';
    passed := v_state is null
          and v_row is not null
          and (v_row ->> 'left_minor')::bigint = 10000
          and (v_row ->> 'receipt_id')::uuid = v_rcpt
          and v_row ->> 'receipt_number' = (select d.document_number from erp.document d where d.id = v_rcpt)
          and (v_row ->> 'allocatable')::boolean
          and jsonb_array_length(v_row -> 'invoices') = 1
          and (v_row #>> '{invoices,0,document_id}')::uuid = v_inv2
          and (v_row #>> '{invoices,0,owes_minor}')::bigint = v_gross2
          and (v_alloc ->> 'allocated_minor')::bigint = 10000
          and (v_alloc ->> 'credit_left_minor')::bigint = 0
          and (v_alloc ->> 'invoice_owes_minor')::bigint = v_gross2 - 10000
          and v_alloc ->> 'invoice_state' = 'part_paid'
          and erp.object_current_state('document', v_inv2) = 'part_paid'
          and (select b.outstanding_minor from erp.ageing_balance b
                where b.tenant_id = rb.tenant_id and b.document_id = v_inv2) = v_gross2 - 10000
          and not exists (select 1 from erp.ageing_balance b
                           where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null)
          and (select r.total_minor from erp.receivables_ageing() r where r.party_id = v_cust) = v_gross2 - 10000
          and not exists (select 1 from jsonb_array_elements(public.erp_on_account_credits()) x
                           where x ->> 'credit_item_id' = v_credit::text)
          and (select j.document_id from erp.journal j where j.id = (v_alloc ->> 'journal_id')::uuid) = v_rcpt
          and v_alloc ->> 'receipt_number' = (select d.document_number from erp.document d where d.id = v_rcpt)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('listed %s; allocated %s; %s', v_row, v_alloc, v_tie), 500));
    return next;

    -- ── 3. An allocation that covers an invoice ─────────────────────────────
    v_step := 'a credit larger than the next invoice';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZOA3', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    perform public.erp_apply_cash(v_cust, v_gross + 40000, v_ccy, 'ZOA3-OVER');
    select si.id into v_credit
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
       and si.control_kind = 'receivable' and j.source_code = 'cash.on_account';
    v_inv2 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA3-NEXT', 10000);
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    v_alloc := public.erp_allocate_on_account(v_credit, v_inv2, null);
    select x into v_row from jsonb_array_elements(public.erp_on_account_credits()) x
     where x ->> 'credit_item_id' = v_credit::text;
    v_cases := v_cases + 1;
    case_name := 'an allocation that covers the invoice makes it Paid, and what is left of the credit stays on account, listed with no invoice to take it';
    passed := v_state is null
          and v_gross2 < 40000
          and (v_alloc ->> 'allocated_minor')::bigint = v_gross2
          and (v_alloc ->> 'invoice_owes_minor')::bigint = 0
          and erp.object_current_state('document', v_inv2) = 'paid'
          and not exists (select 1 from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.document_id = v_inv2)
          and (select b.outstanding_minor from erp.ageing_balance b
                where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null) = -(40000 - v_gross2)
          and (v_row ->> 'left_minor')::bigint = 40000 - v_gross2
          and (v_alloc ->> 'credit_left_minor')::bigint = 40000 - v_gross2
          and v_row -> 'invoices' = '[]'::jsonb;
    detail := coalesce(v_state, left(format('allocated %s; listed %s', v_alloc, v_row), 400));
    return next;

    -- ── 4. An amount named ──────────────────────────────────────────────────
    v_step := 'part of what is left, named, and then the rest';
    v_inv3 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA4-NEXT', 50000);
    v_left := erp.on_account_credit_left(v_credit);
    v_alloc := public.erp_allocate_on_account(v_credit, v_inv3, 1000);
    v_alloc2 := public.erp_allocate_on_account(v_credit, v_inv3, null);
    v_cases := v_cases + 1;
    case_name := 'an amount named is what is allocated, and the next allocation takes what is left of the credit; the invoice is Part paid by both';
    passed := v_state is null
          and (v_alloc ->> 'allocated_minor')::bigint = 1000
          and (v_alloc ->> 'credit_left_minor')::bigint = v_left - 1000
          and (v_alloc2 ->> 'allocated_minor')::bigint = v_left - 1000
          and (v_alloc2 ->> 'credit_left_minor')::bigint = 0
          and erp.object_current_state('document', v_inv3) = 'part_paid'
          and (select sum(si.credit_minor) from erp.subledger_item si
                where si.tenant_id = rb.tenant_id and si.document_id = v_inv3
                  and si.control_kind = 'receivable') = v_left
          and not exists (select 1 from erp.ageing_balance b
                           where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null);
    detail := coalesce(v_state, left(format('left %s; credited %s; %s then %s', v_left,
      (select sum(si.credit_minor) from erp.subledger_item si
        where si.tenant_id = rb.tenant_id and si.document_id = v_inv3 and si.control_kind = 'receivable'),
      v_alloc ->> 'allocated_minor', v_alloc2), 400));
    return next;

    -- ── 5. Two credits of one customer ──────────────────────────────────────
    v_step := 'two overpayments by one customer, and a third invoice';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZOA13', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    perform public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZOA13-OVER-1');
    v_inv2 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA13-SECOND', 50000);
    perform public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZOA13-OVER-2');
    select si.id into v_credit
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
       and si.control_kind = 'receivable' and j.source_code = 'cash.on_account'
     order by j.created_at, si.id limit 1;
    select si.id into v_credit2
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
       and si.control_kind = 'receivable' and j.source_code = 'cash.on_account' and si.id <> v_credit;
    v_inv3 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA13-THIRD', 25000);
    v_alloc := public.erp_allocate_on_account(v_credit, v_inv3, null);
    v_left := erp.on_account_credit_left(v_credit);
    v_left2 := erp.on_account_credit_left(v_credit2);
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv3, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    v_alloc2 := public.erp_allocate_on_account(v_credit2, v_inv3, null);
    v_cases := v_cases + 1;
    case_name := 'two credits of one customer are spent apart: the first, allocated in full, is refused again while the second keeps its whole amount, and each allocation names its own receipt';
    passed := v_state is null
          and v_credit2 is not null
          and (v_alloc ->> 'allocated_minor')::bigint = 10000
          and v_left = 0 and v_left2 = 10000
          and v_err like 'CLOVEERP_NOTHING_ON_ACCOUNT:%'
          and (v_alloc2 ->> 'allocated_minor')::bigint = 10000
          and (v_alloc ->> 'receipt_id') is not null
          and (v_alloc2 ->> 'receipt_id') is not null
          and (v_alloc ->> 'receipt_id') <> (v_alloc2 ->> 'receipt_id')
          and (v_alloc ->> 'receipt_id')::uuid = (select j.document_id from erp.subledger_item si
                                                   join erp.journal j on j.id = si.journal_id where si.id = v_credit)
          and erp.object_current_state('document', v_inv3) = 'part_paid';
    detail := coalesce(v_state, left(format('left %s and %s; again %s; %s then %s', v_left, v_left2, v_err,
      v_alloc ->> 'receipt_number', v_alloc2 ->> 'receipt_number'), 400));
    return next;

    -- A fresh credit for the refusals: £300 on account.
    v_step := 'a customer with £300 on account and an invoice owing, and a second customer';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZOA5', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    perform public.erp_apply_cash(v_cust, v_gross + 30000, v_ccy, 'ZOA5-OVER');
    select si.id into v_credit
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
       and si.control_kind = 'receivable' and j.source_code = 'cash.on_account';
    v_inv2 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA5-NEXT', 10000);
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    v_inv3 := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZOA5B', 10000);
    v_c5 := v_credit; v_c5_cust := v_cust;
    select count(*) into v_n from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated';

    -- ── 6. Another customer's invoice ───────────────────────────────────────
    v_step := 'the credit allocated to another customer''s invoice';
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv3, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(v_credit, gen_random_uuid(), null);
      v_err2 := 'allocated';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a credit allocated to another customer''s invoice, or to nothing, is refused by name and writes nothing';
    passed := v_state is null
          and v_err like 'CLOVEERP_ALLOCATION_OTHER_CUSTOMER:%'
          and v_err2 like 'CLOVEERP_ALLOCATION_OTHER_CUSTOMER:%'
          and erp.on_account_credit_left(v_credit) = 30000
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated') = v_n;
    detail := coalesce(v_state, left(format('%s | %s', v_err, v_err2), 400));
    return next;

    -- ── 7. More than the credit, more than the invoice owes, nothing ────────
    v_step := 'amounts the credit or the invoice cannot take';
    v_inv3 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA7-BIG', 50000);
    v_c5_open := v_inv3;
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv3, 30001);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv2, v_gross2 + 1);
      v_err2 := 'allocated';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv2, 0);
      v_err3 := 'allocated';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv, null);
      v_err4 := 'allocated';
    exception when others then v_err4 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'more than is left of the credit, more than the invoice owes, nought, and an invoice already paid are each refused by name, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_ALLOCATION_EXCEEDS_CREDIT:%'
          and v_err2 like 'CLOVEERP_ALLOCATION_EXCEEDS_OWING:%'
          and v_err3 like 'CLOVEERP_ALLOCATION_AMOUNT_INVALID:%'
          and v_err4 like 'CLOVEERP_ALLOCATION_EXCEEDS_OWING:%'
          and erp.on_account_credit_left(v_credit) = 30000
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated') = v_n;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s', v_err, v_err2, v_err3, v_err4), 500));
    return next;

    -- ── 8. Not a credit on account ──────────────────────────────────────────
    v_step := 'allocating what is not a credit kept on account';
    begin
      perform public.erp_allocate_on_account(
        (select si.id from erp.subledger_item si
          where si.tenant_id = rb.tenant_id and si.document_id = v_inv2 and si.debit_minor > 0 limit 1),
        v_inv2, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(
        (select si.id from erp.subledger_item si join erp.journal j on j.id = si.journal_id
          where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.control_kind = 'receivable'
            and si.credit_minor > 0 and j.source_code = 'cash.applied' limit 1),
        v_inv2, null);
      v_err2 := 'allocated';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(gen_random_uuid(), v_inv2, null);
      v_err3 := 'allocated';
    exception when others then v_err3 := sqlerrm; end;
    -- The credit of case 2, allocated in full.
    select si.id into v_credit2
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
      join erp.party p on p.id = si.party_id
     where si.tenant_id = rb.tenant_id and p.code = 'ZOA2' and si.document_id is null
       and si.credit_minor > 0 and j.source_code = 'cash.on_account';
    begin
      perform public.erp_allocate_on_account(v_credit2, v_inv2, null);
      v_err4 := 'allocated';
    exception when others then v_err4 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an invoice''s own row, cash applied to an invoice, an unknown row and a credit already allocated in full are refused as nothing on account, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOTHING_ON_ACCOUNT:%'
          and v_err2 like 'CLOVEERP_NOTHING_ON_ACCOUNT:%'
          and v_err3 like 'CLOVEERP_NOTHING_ON_ACCOUNT:%'
          and v_err4 like 'CLOVEERP_NOTHING_ON_ACCOUNT:%'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated') = v_n;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s', v_err, v_err2, v_err3, v_err4), 500));
    return next;

    -- ── 9. A closed period ──────────────────────────────────────────────────
    v_step := 'closing this month and allocating into it';
    select fp.id, fp.status::text into v_period, v_was
      from erp.fiscal_period fp
     where fp.tenant_id = rb.tenant_id
       and fp.ledger_id = (select si.ledger_id from erp.subledger_item si where si.id = v_credit)
       and current_date between fp.starts_on and fp.ends_on;
    update erp.fiscal_period set status = 'closed', closed_at = clock_timestamp()
     where tenant_id = rb.tenant_id and id = v_period;
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv2, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    update erp.fiscal_period set status = v_was::erp.period_status, closed_at = null
     where tenant_id = rb.tenant_id and id = v_period;
    v_cases := v_cases + 1;
    case_name := 'a closed month refuses the allocation at the ledger, and the invoice, the credit and the journals are as they were';
    passed := v_state is null
          and v_period is not null
          and v_err like 'CLOVEERP_PERIOD_CLOSED:%'
          and erp.on_account_credit_left(v_credit) = 30000
          and erp.object_current_state('document', v_inv2) = 'issued'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated') = v_n;
    detail := coalesce(v_state, left(coalesce(v_err, 'no period'), 300));
    return next;

    -- ── 10. Somebody who may only read ──────────────────────────────────────
    v_step := 'the list and the door, for somebody who may read the books but not post';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    select x into v_row from jsonb_array_elements(public.erp_on_account_credits()) x
     where x ->> 'credit_item_id' = v_credit::text;
    begin
      perform public.erp_allocate_on_account(v_credit, v_inv2, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody who may read the books sees the credit listed as not theirs to allocate, and the door refuses them finance.post';
    passed := v_state is null
          and v_row is not null
          and not (v_row ->> 'allocatable')::boolean
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.post%'
          and erp.on_account_credit_left(v_credit) = 30000;
    detail := coalesce(v_state, left(format('listed %s; door %s', v_row ->> 'allocatable', v_err), 300));
    return next;

    -- ── 11. What the ledger carries ─────────────────────────────────────────
    v_step := 'the credit allocated, and its journal read';
    v_alloc := public.erp_allocate_on_account(v_credit, v_inv2, null);
    v_cases := v_cases + 1;
    case_name := 'the allocation journal is cash.allocated, posted today, and every line names the cash application rule and the cash.allocated event; it debits and credits the one receivable account alike, and its two subledger rows consume the credit and settle the invoice';
    passed := v_state is null
          and erp.object_current_state('document', v_inv2) = 'paid'
          and exists (select 1 from erp.journal j
                       where j.id = (v_alloc ->> 'journal_id')::uuid and j.source_code = 'cash.allocated'
                         and j.status = 'posted' and j.posting_date = current_date)
          and (select count(*) from erp.journal_line l
                 join erp.posting_rule pr on pr.id = l.posting_rule_id and pr.code = 'cash_application'
                 join erp.event e on e.id = l.source_event_id and e.event_type = 'cash.allocated'
                where l.journal_id = (v_alloc ->> 'journal_id')::uuid) = 2
          and (select count(distinct l.account_id) from erp.journal_line l
                where l.journal_id = (v_alloc ->> 'journal_id')::uuid) = 1
          and (select sum(l.debit_minor) - sum(l.credit_minor) from erp.journal_line l
                where l.journal_id = (v_alloc ->> 'journal_id')::uuid) = 0
          and exists (select 1 from erp.subledger_item si
                       where si.journal_id = (v_alloc ->> 'journal_id')::uuid and si.document_id is null
                         and si.debit_minor = v_gross2 and si.settled_minor = v_gross2 and si.party_id = v_cust)
          and exists (select 1 from erp.subledger_item si
                       where si.journal_id = (v_alloc ->> 'journal_id')::uuid and si.document_id = v_inv2
                         and si.credit_minor = v_gross2)
          and not exists (select 1 from erp.open_receivables(v_ccy) o
                           where o.subledger_item_id in (select si.id from erp.subledger_item si
                                                          where si.journal_id = (v_alloc ->> 'journal_id')::uuid));
    detail := coalesce(v_state, left(v_alloc::text, 400));
    return next;

    -- ── 12. An organisation that kept cash on account with no receipt ───────
    v_step := 'putting the organisation back to receivables version 1';
    update erp.document_type set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'cash_receipt';
    update erp.state_machine set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'cash_receipt';
    update erp.module_installation i set installer_version = 1
     where i.tenant_id = rb.tenant_id and i.install_code = 'receivables';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZOA12', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    perform public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZOA12-V1');
    select si.id into v_credit
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
       and si.control_kind = 'receivable' and j.source_code = 'cash.on_account';
    v_inv2 := erp_test.on_account_invoice(v_entity, v_site, v_item, v_cust, v_ccy, 'ZOA12-NEXT', 25000);
    begin
      perform public.erp_allocate_on_account(
        (select si.id from erp.subledger_item si join erp.journal j on j.id = si.journal_id
          where si.tenant_id = rb.tenant_id and si.party_id = v_cust and si.document_id is null
            and si.credit_minor > 0 and j.source_code = 'cash.applied' limit 1),
        v_inv2, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    select x into v_row from jsonb_array_elements(public.erp_on_account_credits()) x
     where x ->> 'credit_item_id' = v_credit::text;
    v_alloc := public.erp_allocate_on_account(v_credit, v_inv2, null);
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'cash kept on account with no receipt, on receivables version 1, is listed with none and allocated as any other: the journal names no document, the invoice is Part paid, and the ageing ties; the cash that paid an invoice, naming none, is not on account';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOTHING_ON_ACCOUNT:%'
          and v_row is not null and v_row -> 'receipt_id' = 'null'::jsonb
          and (v_alloc ->> 'allocated_minor')::bigint = 10000
          and v_alloc -> 'receipt_id' = 'null'::jsonb
          and (select j.document_id from erp.journal j where j.id = (v_alloc ->> 'journal_id')::uuid) is null
          and erp.object_current_state('document', v_inv2) = 'part_paid'
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('applied row: %s; listed %s; allocated %s; %s', v_err, v_row, v_alloc, v_tie), 400));
    return next;

    -- ── 13. Another company's invoice, and another currency's ───────────────
    -- Last, because its invoices are written straight to the subledger, as the
    -- receipt suite's two-company cases are, and so the ageing no longer ties.
    v_step := 'a second company, and an invoice of the customer''s there and one in euros';
    perform erp.create_entity('ZOA2CO', 'On Account Second', null, v_ccy, 'GB');
    select e.id into v_e2 from erp.entity e where e.tenant_id = rb.tenant_id and e.code = 'ZOA2CO';
    perform erp.configure_finance(extract(year from current_date)::integer, v_ccy, v_e2);
    select s.id into v_site2 from erp.site s where s.tenant_id = rb.tenant_id and s.entity_id = v_e2
     order by s.code limit 1;
    v_other := erp.open_document('sales_invoice', v_c5_cust, v_e2, v_site2);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select rb.tenant_id, v_e2, l.id, 'receivable', a.id, v_c5_cust, v_other, v_ccy, 30000, 0, current_date, current_date + 30
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = rb.tenant_id and l.entity_id = v_e2 and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     order by a.code limit 1;
    v_eur := erp.open_document('sales_invoice', v_c5_cust, v_entity, v_site);
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select si.tenant_id, si.entity_id, si.ledger_id, 'receivable', si.control_account_id, v_c5_cust, v_eur,
           case when v_ccy = 'EUR' then 'USD' else 'EUR' end, 30000, 0, current_date, current_date + 30
      from erp.subledger_item si where si.id = v_c5;
    v_left2 := erp.on_account_credit_left(v_c5);
    select count(*) into v_n from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated';
    begin
      perform public.erp_allocate_on_account(v_c5, v_other, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_allocate_on_account(v_c5, v_eur, null);
      v_err2 := 'allocated';
    exception when others then v_err2 := sqlerrm; end;
    select x into v_row from jsonb_array_elements(public.erp_on_account_credits()) x
     where x ->> 'credit_item_id' = v_c5::text;
    v_cases := v_cases + 1;
    case_name := 'the customer''s invoice in another company, or in another currency, is refused by name, writes nothing, and is not offered on the credit''s row';
    passed := v_state is null
          and v_left2 > 0
          and v_err like 'CLOVEERP_ALLOCATION_OTHER_COMPANY:%'
          and v_err2 like 'CLOVEERP_ALLOCATION_OTHER_COMPANY:%'
          and erp.on_account_credit_left(v_c5) = v_left2
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'cash.allocated') = v_n
          and (select string_agg(i ->> 'document_id', ',') from jsonb_array_elements(v_row -> 'invoices') i) = v_c5_open::text;
    detail := coalesce(v_state, left(format('%s | %s | offered %s', v_err, v_err2, v_row -> 'invoices'), 400));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzoaa-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzoaa rolled back with its invoices, receipts, credits and allocations');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ON_ACCOUNT_ALLOCATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.on_account_allocation_suite() from public, anon;

comment on function erp_test.on_account_allocation_suite() is
  'A credit kept on a customer''s account is allocated to their invoices (20260930400000): listed with '
  'its receipt and the invoices it may take, allocated by default or by an amount, the invoice Part '
  'paid or Paid, the ageing tied and its journal naming the receipt; refused by name for another '
  'customer''s, company''s or currency''s invoice, beyond the credit or what is owed, for anything not '
  'on account, in a closed month and to somebody who may only read; on receivables version 1 too.';

create or replace function erp_test.assert_on_account_allocation_suite()
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
    from erp_test.on_account_allocation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ON_ACCOUNT_ALLOCATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A credit kept on account would settle what it may not, or fail to settle what it may. Read the case that failed.';
  end if;
  if v_total <> 14 then
    raise exception 'CLOVEERP_ON_ACCOUNT_ALLOCATION_SUITE_SHRANK: % case(s), expected 14', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('on-account allocation: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_on_account_allocation_suite() from public, anon;

comment on function erp_test.assert_on_account_allocation_suite() is
  'A credit kept on a customer''s account is allocated to their open invoices, and refused where it '
  'may not go (20260930400000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The words the screen says
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Credit on account on the Finance screen, and its Allocate (20260930400000).'
  from (values
    ('Credit on account'),
    ('Cash customers paid beyond what they owed, kept on their account until it is allocated to an invoice.'),
    ('Nothing is kept on account. Cash beyond what a customer owes lands here, to be allocated to their next invoice.'),
    ('Kept on'),
    ('Receipt'),
    ('Left'),
    ('Allocate'),
    ('Allocate a credit on account'),
    ('Settles one of the customer''s open invoices from the credit. The invoice moves to part paid or paid.'),
    ('Invoice'),
    ('Leave empty to allocate as much as the credit and the invoice allow.'),
    ('{amount} on account for {customer}')
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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
