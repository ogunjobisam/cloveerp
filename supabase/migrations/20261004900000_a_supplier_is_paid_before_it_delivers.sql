set lock_timeout = '30s';

-- =============================================================================
-- 20261004900000  A supplier is paid before it delivers
-- -----------------------------------------------------------------------------
-- The first gap in procure-to-pay the owner named on 1 October 2026: a
-- supplier who asks for money before the goods (a deposit, a pro-forma), as a
-- retailer buying from a brand meets every season. Held to
-- docs/spec/p2p-target-flow.md: no table, no fifth document, no step on the
-- happy path. A prepayment is an amount asked for on the purchase order, paid
-- by the payment run, and taken by the bill.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Nothing paid a supplier except a payment run, and a run pays only bills
-- (erp.propose_payment_run() offers payable credits). A deposit was paid with a
-- manual journal against the bank, which the supplier's account never saw, so
-- the payables ageing stopped agreeing with the creditors control the moment
-- it was posted, and the bill that followed was offered to the next run in
-- full. A supplier paid a deposit was paid twice.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp_request_prepayment(p_order, p_amount_minor, p_due_on, p_reason): a
--     buyer (procurement.order in the order's company and site) asks for an
--     amount to be paid on an approved, sent or received purchase order, kept
--     in the order's attributes under prepayment. The amount is the whole
--     prepayment wanted on the order: never more than the order is worth, never
--     less than has been paid already, and nought withdraws what is unpaid.
--   * erp.propose_payment_run(): a request with something unpaid, due by the
--     run's horizon, in the run's currency, is a line naming the order and no
--     open item. An order already billed is held, as a disputed bill is, and
--     says why: its bill is what gets paid. The run is approved and paid as
--     every run is, by somebody other than its proposer.
--   * erp.pay_payment_run(): a prepayment line pays the supplier by the
--     supplier_payment rule, Dr the creditors control Cr the bank, on a payable
--     row naming the supplier and the order: a debit on the supplier's account,
--     which the ageing carries against the order, so the ageing and the control
--     agree throughout. The journal (prepayment.paid) names the supplier's
--     payment of the run, whose line says "Prepayment against PO-…", so the
--     remittance advice says what it paid.
--   * A bill registered against an order that was prepaid takes the
--     prepayment, by the system, as it registers (erp.transition_document(),
--     after the dispute check, before the order is closed): one journal,
--     prepayment.applied, Dr the payable (the bill, paid) Cr the payable
--     (the prepayment, used), on the one control account, and the bill moves to
--     part_paid or paid. The next run offers only what is left. A disputed bill
--     takes nothing until its dispute is resolved. A prepayment paid after its
--     order was billed goes to the order's open bills as it is paid.
--   * erp_allocate_prepayment(p_order, p_bill, p_amount_minor): Finance
--     (finance.post in the order's company) takes a prepayment to a bill of the
--     same supplier, company, control account and currency by hand, for a bill
--     that does not name the order.
--   * erp_order_prepayment(p_order): what was asked for, paid, used and is left
--     on an order, and whether the reader may ask. erp_supplier_prepayments():
--     every prepayment with something left, with the bills it may go to and
--     whether the reader may allocate it. The order's page and the Finance
--     screen draw them.
--   * Cancelling an order with a prepayment left is not refused (owner,
--     1 October 2026): the deposit stays on the supplier's account, listed
--     under Supplier prepayments until it is used on another bill or refunded.
--   * Refusals, registered, and three events: prepayment.requested,
--     prepayment.paid and prepayment.applied.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No VAT on a prepayment: input tax is claimed on the supplier's VAT
--     invoice, which is the bill. A deposit VAT invoice is a follow-up.
--   * No refund of a deposit the supplier gives back: a follow-up, with Cash in
--     taught to bank from a supplier.
--   * No reclassification of a supplier's debit balance to prepayments at the
--     year end: the creditors control holds it (owner, 1 October 2026).
--   * Not in the demonstration's month before the v1 checkpoint (owner).
--   * No new step on the happy path: requesting is an exception the buyer
--     reaches only when a supplier asks, and the allocation is the system's.
--
-- Proved by erp_test.supplier_prepayment_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

-- A1. The refusals

select erp.register_refusal('CLOVEERP_PREPAYMENT_NOT_AN_ORDER',
  'Asking for a prepayment on something that is not a purchase order the supplier may be paid against: one in draft or awaiting approval, closed, cancelled, or not an order at all.',
  'A prepayment is money paid to a supplier against an order they have been given; before the order is approved nothing has been agreed to pay for, and after it is closed or cancelled nothing more is owed on it.',
  'Ask on an approved, sent or received purchase order, from the order''s own page.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_EXCEEDS_ORDER',
  'Asking for more prepayment than the purchase order is worth.',
  'A prepayment is part or all of what the order will cost; paying more than that pays the supplier for goods nobody ordered.',
  'Ask for no more than the order''s total, including its tax, or amend the order first.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_BELOW_PAID',
  'Asking for less prepayment than has been paid on the order already.',
  'What has been paid has left the bank; lowering the request below it would say the supplier holds less of our money than they do.',
  'Ask for at least what has been paid, which the order''s prepayment shows. Ask for exactly that to withdraw the unpaid rest.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_AMOUNT_INVALID',
  'Asking for, or allocating, a prepayment amount that is negative, missing or nought where something must move.',
  'A prepayment request is an amount of money of nought or more, and an allocation moves some of a prepayment to a bill; less than nothing means nothing.',
  'Name an amount in minor units: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.');

select erp.register_refusal('CLOVEERP_NOTHING_PREPAID',
  'Allocating a prepayment from an order that has none left: nothing was paid on it, or all of it has been used.',
  'Only money paid to the supplier against the order, and not yet taken by a bill, can pay a bill; allocating anything else would settle the bill with money that never left.',
  'Pick the order from Supplier prepayments on the Finance screen, which lists only those with something left.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_OTHER_SUPPLIER',
  'Allocating a supplier''s prepayment to a bill that is not theirs.',
  'A prepayment is money one supplier holds of ours, and it pays only that supplier''s bills.',
  'Allocate it to one of the same supplier''s open bills, which Supplier prepayments offers on the order''s row.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_OTHER_COMPANY',
  'Allocating a prepayment to a bill of another company, ledger, control account or currency.',
  'A prepayment was paid from one company''s bank, in one currency, onto one creditors account, and each company''s books stand alone.',
  'Allocate it to a bill of the same company and currency, or move the balance between companies with a journal.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_EXCEEDS_LEFT',
  'Allocating more than is left of a prepayment.',
  'An allocation spends the prepayment; spending more than is left of it would pay the bill with money the supplier does not hold.',
  'Allocate no more than is left, which Supplier prepayments shows, or leave the amount out to allocate what is left.');

select erp.register_refusal('CLOVEERP_PREPAYMENT_EXCEEDS_OWING',
  'Allocating more of a prepayment to a bill than the bill still owes.',
  'A bill paid beyond what it owes would carry a credit of its own, and the rest of the prepayment belongs on the order, where it already is.',
  'Allocate no more than the bill owes, or leave the amount out to allocate what it owes.');

select erp.register_refusal('CLOVEERP_NO_PAYABLE_ACCOUNT',
  'Paying a prepayment in a company with no creditors control account.',
  'A prepayment is held on the supplier''s account until their bill takes it; a company with no payable control account has no supplier accounts to hold it on.',
  'Run the finance installer for the company, which creates the trade payables account, or install procurement controls.');

-- A2. The events

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.prepayment.requested', 'en', 'Prepayment requested', 'procurement',
   'Event raised when a buyer asks for part or all of a purchase order to be paid before the goods.'),
  ('event.prepayment.requested', 'de', 'Vorauszahlung angefordert', 'procurement',
   'Ereignis, wenn ein Einkäufer verlangt, dass ein Teil einer Bestellung vor der Lieferung bezahlt wird.'),
  ('event.prepayment.paid', 'en', 'Supplier prepaid', 'finance',
   'Event raised when a payment run pays a supplier in advance against a purchase order.'),
  ('event.prepayment.paid', 'de', 'Lieferant vorausbezahlt', 'finance',
   'Ereignis, wenn ein Zahlungslauf einen Lieferanten im Voraus für eine Bestellung bezahlt.'),
  ('event.prepayment.applied', 'en', 'Prepayment applied to a bill', 'finance',
   'Event raised when money paid to a supplier in advance pays one of their bills.'),
  ('event.prepayment.applied', 'de', 'Vorauszahlung verrechnet', 'finance',
   'Ereignis, wenn eine Vorauszahlung an einen Lieferanten mit einer seiner Rechnungen verrechnet wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('prepayment.requested', 1, 'document', 'procurement', 'event.prepayment.requested',
   'A buyer asked for part or all of a purchase order to be paid to the supplier before the goods.',
   '{"type":"object","required":["reference","requested_minor","currency"],
     "properties":{"reference":{"type":"string"},"requested_minor":{"type":"integer"},
                   "was_minor":{"type":"integer"},"currency":{"type":"string"},
                   "due_on":{"type":"string"},"reason":{"type":["string","null"]}}}'::jsonb,
   true),
  ('prepayment.paid', 1, 'document', 'finance', 'event.prepayment.paid',
   'A payment run paid a supplier in advance against a purchase order.',
   '{"type":"object","required":["reference","value_minor","currency"],
     "properties":{"reference":{"type":"string"},"order_number":{"type":"string"},
                   "value_minor":{"type":"integer"},"currency":{"type":"string"},
                   "posting_rule":{"type":"string"},"party_id":{"type":"string"},
                   "payment_id":{"type":["string","null"]}}}'::jsonb,
   true),
  ('prepayment.applied', 1, 'document', 'finance', 'event.prepayment.applied',
   'Money paid to a supplier in advance against an order paid one of their bills.',
   '{"type":"object","required":["value_minor","currency","order_id"],
     "properties":{"reference":{"type":"string"},"value_minor":{"type":"integer"},
                   "currency":{"type":"string"},"posting_rule":{"type":"string"},
                   "order_id":{"type":"string"},"order_number":{"type":"string"},
                   "by_hand":{"type":"boolean"}}}'::jsonb,
   true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code in ('prepayment.requested', 'prepayment.paid', 'prepayment.applied')
         and et.is_current and et.version = 1 and et.aggregate_type = 'document'
         and et.name_key = 'event.' || et.code) <> 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a prepayment event is declared already, and not as 20261004900000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. What an order's prepayment is
-- ═════════════════════════════════════════════════════════════════════════════

-- B1. Whether a supplier may be paid against an order

create or replace function erp.prepayment_order_open(p_order uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A purchase order the supplier has been given, or may be (20261004900000):
  -- approved, sent, part received or received, and not cancelled. Before
  -- approval nothing is agreed; closed or cancelled, nothing more is owed.
  select exists (
    select 1
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_order
       and dt.base_type_code = 'purchase_order'
       and coalesce(d.order_behaviour_code, '') <> 'blanket'
       and not d.is_cancelled
       and erp.object_current_state('document', d.id) in ('approved', 'sent', 'partially_received', 'received'))
$$;

revoke all on function erp.prepayment_order_open(uuid) from public, anon;

comment on function erp.prepayment_order_open(uuid) is
  'Whether a supplier may be asked for, or paid, a prepayment against this purchase order: approved, '
  'sent, part received or received, not a blanket agreement and not cancelled (20261004900000).';

-- B2. What was asked for, what was paid, what is left, what is due

create or replace function erp.order_prepayment_requested(p_order uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- The whole prepayment a buyer asked for on the order (20261004900000),
  -- kept in its attributes; nought where nobody asked.
  select coalesce((
    select (d.attributes #>> '{prepayment,requested_minor}')::bigint
      from erp.document d
     where d.tenant_id = erp.current_tenant_id() and d.id = p_order), 0)::bigint
$$;

revoke all on function erp.order_prepayment_requested(uuid) from public, anon;

create or replace function erp.order_prepaid_minor(p_order uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- What payment runs have paid the supplier against the order
  -- (20261004900000): the payable debits naming the order that a posted
  -- prepayment.paid journal wrote. Not lessened by what bills have taken.
  select coalesce(sum(si.debit_minor), 0)::bigint
    from erp.subledger_item si
    join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
   where si.tenant_id = erp.current_tenant_id() and si.document_id = p_order
     and si.control_kind = 'payable'
     and j.source_code = 'prepayment.paid' and j.status = 'posted'
$$;

revoke all on function erp.order_prepaid_minor(uuid) from public, anon;

create or replace function erp.order_prepayment_left(p_order uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- What the supplier still holds of the order's prepayment (20261004900000):
  -- the payable rows naming the order, the prepayments paid less what bills
  -- have taken. Exactly what the ageing carries against the order, negated.
  select greatest(0, coalesce(sum(si.debit_minor - si.credit_minor), 0))::bigint
    from erp.subledger_item si
   where si.tenant_id = erp.current_tenant_id() and si.document_id = p_order
     and si.control_kind = 'payable'
$$;

revoke all on function erp.order_prepayment_left(uuid) from public, anon;

create or replace function erp.order_prepayment_due(p_order uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- What is asked for and not yet paid (20261004900000).
  select greatest(0, erp.order_prepayment_requested(p_order) - erp.order_prepaid_minor(p_order))::bigint
$$;

revoke all on function erp.order_prepayment_due(uuid) from public, anon;

comment on function erp.order_prepayment_requested(uuid) is
  'The whole prepayment asked for on a purchase order, from its attributes (20261004900000).';
comment on function erp.order_prepaid_minor(uuid) is
  'What payment runs have paid a supplier in advance against a purchase order (20261004900000).';
comment on function erp.order_prepayment_left(uuid) is
  'What the supplier still holds of a purchase order''s prepayment, not yet taken by a bill (20261004900000).';
comment on function erp.order_prepayment_due(uuid) is
  'What is asked for in advance on a purchase order and not yet paid (20261004900000).';

-- B3. The account a supplier is owed on, in a company

create or replace function erp.company_payable_account(p_entity_id uuid, p_ledger_id uuid, p_order uuid)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_line   jsonb;
  v_code   text;
  v_acc    uuid;
begin
  -- The account the supplier_payment rule debits, as determination resolves
  -- it for the order (20261004900000), so a prepayment sits on the same
  -- creditors account the supplier's bill is paid from. Otherwise the
  -- company's first payable control account, as erp.company_bank_account()
  -- finds the bank.
  select l.value into v_line
    from erp.posting_rule pr, jsonb_array_elements(pr.posting_lines) l
   where pr.tenant_id = v_tenant and pr.code = 'supplier_payment' and pr.status = 'active'
     and l.value ->> 'side' = 'debit'
   order by pr.version desc
   limit 1;
  if v_line is not null then
    v_code := coalesce(erp.posting_line_account_code(v_line, p_order, p_ledger_id), v_line ->> 'account');
    select a.id into v_acc from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = p_entity_id and a.code = v_code
       and a.control_kind = 'payable' and a.status = 'active';
  end if;
  if v_acc is null then
    select a.id into v_acc from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = p_entity_id
       and a.control_kind = 'payable' and a.status = 'active'
     order by a.code limit 1;
  end if;
  if v_acc is null then
    raise exception 'CLOVEERP_NO_PAYABLE_ACCOUNT: % has no creditors control account to hold a prepayment on',
      coalesce((select e.code from erp.entity e where e.tenant_id = v_tenant and e.id = p_entity_id), p_entity_id::text)
      using errcode = '23503',
            hint = 'Run the finance installer for the company, which creates the trade payables account, or install procurement controls.';
  end if;
  return v_acc;
end;
$$;

revoke all on function erp.company_payable_account(uuid, uuid, uuid) from public, anon;

comment on function erp.company_payable_account(uuid, uuid, uuid) is
  'The creditors control account a company owes its suppliers on, as the supplier_payment rule debits it '
  'for an order (20261004900000).';

-- B4. What a bill still owes

create or replace function erp.bill_owes_minor(p_bill uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- The open items of the bill, never more than the ageing says it owes
  -- (20261004900000), as erp.allocate_on_account() reads an invoice.
  select greatest(0::bigint, least(
           coalesce((select sum(si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0))
                              filter (where si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) > 0)
                       from erp.subledger_item si
                      where si.tenant_id = erp.current_tenant_id() and si.document_id = p_bill
                        and si.control_kind = 'payable'), 0),
           coalesce((select sum(b.outstanding_minor) from erp.ageing_balance b
                      where b.tenant_id = erp.current_tenant_id() and b.document_id = p_bill
                        and b.control_kind = 'payable'), 0)))::bigint
$$;

revoke all on function erp.bill_owes_minor(uuid) from public, anon;

comment on function erp.bill_owes_minor(uuid) is
  'What a supplier bill still owes: its open payable items, bounded by the ageing (20261004900000).';

-- B5. The order's prepayment, as its page reads it

create or replace function erp.order_prepayment(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What was asked for, paid, used and is left on a purchase order
  -- (20261004900000), the payments that paid it, and whether the reader may
  -- ask (procurement.order in the order's company and site) on an order that
  -- may be prepaid. The door decides regardless.
  select jsonb_build_object(
           'order_id', d.id,
           'order_number', d.document_number,
           'currency', d.currency,
           'order_gross_minor', coalesce(dv.gross_minor, 0)::bigint,
           'requested_minor', erp.order_prepayment_requested(d.id),
           'paid_minor', erp.order_prepaid_minor(d.id),
           'used_minor', erp.order_prepaid_minor(d.id) - erp.order_prepayment_left(d.id),
           'left_minor', erp.order_prepayment_left(d.id),
           'due_minor', erp.order_prepayment_due(d.id),
           'due_on', d.attributes #>> '{prepayment,due_on}',
           'reason', d.attributes #>> '{prepayment,reason}',
           'open', erp.prepayment_order_open(d.id),
           'may_request', erp.prepayment_order_open(d.id)
                          and erp.has_permission('procurement.order', d.entity_id, d.site_id),
           'payments', coalesce((
             select jsonb_agg(jsonb_build_object('document_id', pd.id, 'document_number', pd.document_number,
                                                 'paid_minor', x.paid, 'paid_on', x.paid_on)
                              order by x.paid_on, pd.document_number)
               from (select j.document_id, sum(si.debit_minor) as paid, min(si.posting_date) as paid_on
                       from erp.subledger_item si
                       join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
                      where si.tenant_id = d.tenant_id and si.document_id = d.id
                        and si.control_kind = 'payable'
                        and j.source_code = 'prepayment.paid' and j.status = 'posted'
                        and j.document_id is not null
                      group by j.document_id) x
               join erp.document pd on pd.tenant_id = d.tenant_id and pd.id = x.document_id), '[]'::jsonb))
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.document_view dv on dv.tenant_id = d.tenant_id and dv.id = d.id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_order
     and dt.base_type_code = 'purchase_order'
$$;

revoke all on function erp.order_prepayment(uuid) from public, anon;

comment on function erp.order_prepayment(uuid) is
  'A purchase order''s prepayment: asked for, paid, used, left and due, the payments that paid it, and '
  'whether the reader may ask (20261004900000). Null for anything that is not a purchase order.';

create or replace function public.erp_order_prepayment(p_order uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.order_prepayment(p_order) $$;

revoke all on function public.erp_order_prepayment(uuid) from public, anon;
grant execute on function public.erp_order_prepayment(uuid) to authenticated, service_role;

comment on function public.erp_order_prepayment(uuid) is
  'A purchase order''s prepayment, as its page draws it (20261004900000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. Asking for a prepayment
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.request_prepayment(p_order uuid, p_amount_minor bigint,
                                                  p_due_on date default null, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_state  text;
  v_gross  bigint;
  v_paid   bigint;
  v_was    bigint;
  v_due_on date := coalesce(p_due_on, current_date);
begin
  -- The order, held while its prepayment changes: a request and a run paying
  -- it wait for each other here.
  select x.* into d from erp.document x
   where x.tenant_id = v_tenant and x.id = p_order
     for update;
  select dt.base_type_code into v_base
    from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  if d.id is null or v_base is distinct from 'purchase_order' then
    raise exception 'CLOVEERP_PREPAYMENT_NOT_AN_ORDER: % is not a purchase order',
      coalesce(d.document_number, coalesce(p_order::text, 'nothing'))
      using errcode = '23514',
            hint = 'Ask on an approved, sent or received purchase order, from the order''s own page.';
  end if;

  -- Asking is buying: the buyer's permission, in the order's company and site.
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', d.id);

  if not erp.prepayment_order_open(d.id) then
    v_state := erp.object_current_state('document', d.id);
    raise exception 'CLOVEERP_PREPAYMENT_NOT_AN_ORDER: % is %, and a supplier is prepaid only on an approved, sent or received order',
      d.document_number, case when d.is_cancelled then 'cancelled' else coalesce(v_state, 'in no state') end
      using errcode = '23514',
            hint = 'Ask on an approved, sent or received purchase order, from the order''s own page.';
  end if;

  if p_amount_minor is null or p_amount_minor < 0 then
    raise exception 'CLOVEERP_PREPAYMENT_AMOUNT_INVALID: a prepayment request is nought or more, not %',
      coalesce(p_amount_minor::text, 'nothing')
      using errcode = '22023',
            hint = 'Name an amount in minor units: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.';
  end if;

  select coalesce(dv.gross_minor, 0)::bigint into v_gross
    from erp.document_view dv where dv.tenant_id = v_tenant and dv.id = d.id;
  if p_amount_minor > coalesce(v_gross, 0) then
    raise exception 'CLOVEERP_PREPAYMENT_EXCEEDS_ORDER: % is worth %, and % was asked for in advance',
      d.document_number, coalesce(v_gross, 0), p_amount_minor
      using errcode = '23514',
            hint = 'Ask for no more than the order''s total, including its tax, or amend the order first.';
  end if;

  v_paid := erp.order_prepaid_minor(d.id);
  if p_amount_minor < v_paid then
    raise exception 'CLOVEERP_PREPAYMENT_BELOW_PAID: % has been paid on % already, and % was asked for',
      v_paid, d.document_number, p_amount_minor
      using errcode = '23514',
            hint = 'Ask for at least what has been paid, which the order''s prepayment shows. Ask for exactly that to withdraw the unpaid rest.';
  end if;

  v_was := erp.order_prepayment_requested(d.id);

  update erp.document x
     set attributes = coalesce(x.attributes, '{}'::jsonb) || jsonb_build_object('prepayment', jsonb_build_object(
           'requested_minor', p_amount_minor,
           'due_on', v_due_on,
           'reason', nullif(btrim(coalesce(p_reason, '')), ''),
           'requested_by', erp.current_principal_id(),
           'requested_at', now())),
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = d.id;

  perform erp.append_event(
    'prepayment.requested', 'document', d.id,
    jsonb_build_object('reference', d.document_number, 'requested_minor', p_amount_minor,
                       'was_minor', v_was, 'currency', d.currency, 'due_on', v_due_on,
                       'reason', nullif(btrim(coalesce(p_reason, '')), '')),
    d.entity_id, d.site_id);

  return erp.order_prepayment(d.id);
end;
$$;

revoke all on function erp.request_prepayment(uuid, bigint, date, text) from public, anon;

comment on function erp.request_prepayment(uuid, bigint, date, text) is
  'Asks for part or all of a purchase order to be paid to the supplier in advance (20261004900000): the '
  'whole prepayment wanted, kept in the order''s attributes, paid by the next payment run that reaches '
  'it. Authorises procurement.order in the order''s company and site. Never more than the order is '
  'worth, never less than has been paid; nought withdraws the unpaid rest.';

create or replace function public.erp_request_prepayment(p_order uuid, p_amount_minor bigint,
                                                         p_due_on date default null, p_reason text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.request_prepayment(p_order, p_amount_minor, p_due_on, p_reason) $$;

revoke all on function public.erp_request_prepayment(uuid, bigint, date, text) from public, anon;
grant execute on function public.erp_request_prepayment(uuid, bigint, date, text) to authenticated, service_role;

comment on function public.erp_request_prepayment(uuid, bigint, date, text) is
  'Asks for part or all of a purchase order to be paid to the supplier in advance (20261004900000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_request_prepayment', 'erp.request_prepayment',
   'Asks for a prepayment on a purchase order: writes the order''s prepayment attribute and a prepayment.requested event; authorises procurement.order in the order''s company and site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_request_prepayment']);

-- ═════════════════════════════════════════════════════════════════════════════
-- D. A prepayment takes a bill
-- ═════════════════════════════════════════════════════════════════════════════

-- D1. The allocation itself, with nothing asked of it

create or replace function erp.apply_prepayment(p_order uuid, p_bill uuid, p_amount_minor bigint,
                                                p_by_hand boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  pre       erp.subledger_item%rowtype;
  r         record;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_rest    bigint;
  v_take    bigint;
  v_order   text;
  v_bill    text;
begin
  -- Takes p_amount_minor of the order's prepayment to the bill
  -- (20261004900000). The callers decide that it may; this writes it. One
  -- journal, prepayment.applied, by the supplier_payment rule, Dr the
  -- payable (the bill, paid) Cr the payable (the prepayment, used), on the one
  -- control account, and two payable rows: a credit naming the order, settled
  -- whole, which takes the prepayment out of the ageing; and a debit naming the
  -- bill, which pays it as a run's payment does, the bill's own items settled
  -- oldest first. Then the bill says what it owes, part_paid or paid, derived.
  if coalesce(p_amount_minor, 0) <= 0 then
    return null;
  end if;

  select si.* into pre
    from erp.subledger_item si
    join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
   where si.tenant_id = v_tenant and si.document_id = p_order and si.control_kind = 'payable'
     and si.debit_minor > 0 and j.source_code = 'prepayment.paid' and j.status = 'posted'
   order by si.posting_date, si.id
   limit 1;

  select d.document_number into v_order from erp.document d where d.tenant_id = v_tenant and d.id = p_order;
  select d.document_number into v_bill from erp.document d where d.tenant_id = v_tenant and d.id = p_bill;

  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'supplier_payment' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_PAYMENT_POSTING_RULE: paying a supplier has no promoted rule'
      using errcode = '23503',
      hint = 'Install procurement controls: erp_configure_procurement_controls().';
  end if;

  v_event := erp.append_event(
    'prepayment.applied', 'document', p_bill,
    jsonb_build_object('reference', v_bill, 'value_minor', p_amount_minor, 'currency', pre.currency,
                       'posting_rule', 'supplier_payment', 'order_id', p_order,
                       'order_number', v_order, 'by_hand', coalesce(p_by_hand, false)),
    pre.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, pre.entity_id, pre.ledger_id, 'prepayment.applied', v_event, current_date,
          format('Prepayment on %s applied to %s', coalesce(v_order, 'an order'), coalesce(v_bill, 'a bill')),
          'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, pre.control_account_id, p_amount_minor, 0, pre.currency, p_amount_minor, 0, 1,
          v_rule, v_version, v_event, 'the supplier''s bill, paid from the prepayment'),
         (v_tenant, v_journal, 2, pre.control_account_id, 0, p_amount_minor, pre.currency, 0, p_amount_minor, 1,
          v_rule, v_version, v_event, 'the prepayment on the order, used');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor,
                                  settled_minor, posting_date)
  values (v_tenant, pre.entity_id, pre.ledger_id, 'payable', pre.control_account_id,
          pre.party_id, p_order, v_journal, pre.currency, 0, p_amount_minor, p_amount_minor, current_date),
         (v_tenant, pre.entity_id, pre.ledger_id, 'payable', pre.control_account_id,
          pre.party_id, p_bill, v_journal, pre.currency, p_amount_minor, 0, 0, current_date);

  v_rest := p_amount_minor;
  for r in
    select si.id, si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) as owing
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.document_id = p_bill and si.control_kind = 'payable'
       and si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) > 0
     order by coalesce(si.due_date, si.posting_date), si.id
       for update
  loop
    exit when v_rest <= 0;
    v_take := least(v_rest, r.owing);
    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_take, updated_at = now()
     where id = r.id;
    v_rest := v_rest - v_take;
  end loop;

  -- Posted here: a closed period refuses it at the ledger, and the whole
  -- allocation with it.
  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  perform erp.settle_paid_document(p_bill,
    format('paid from the prepayment on %s', coalesce(v_order, 'its order')));

  return jsonb_build_object(
    'order_id', p_order,
    'order_number', v_order,
    'bill_id', p_bill,
    'bill_number', v_bill,
    'allocated_minor', p_amount_minor,
    'currency', pre.currency,
    'prepayment_left_minor', erp.order_prepayment_left(p_order),
    'bill_owes_minor', erp.bill_owes_minor(p_bill),
    'bill_state', erp.object_current_state('document', p_bill),
    'journal_id', v_journal);
end;
$$;

revoke all on function erp.apply_prepayment(uuid, uuid, bigint, boolean) from public, anon;

comment on function erp.apply_prepayment(uuid, uuid, bigint, boolean) is
  'Takes an amount of a purchase order''s prepayment to a supplier bill (20261004900000): a '
  'prepayment.applied journal by the supplier_payment rule, a row using the prepayment and one '
  'paying the bill, then erp.settle_paid_document(). Asks nothing; its callers decide.';

-- D2. Whether a prepayment and a bill are in the same books

create or replace function erp.prepayment_fits_bill(p_order uuid, p_bill uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- Null when the order's prepayment may pay the bill (20261004900000);
  -- otherwise which refusal says why not: another supplier, or another
  -- company, ledger, control account or currency.
  with pre as (
    select si.* from erp.subledger_item si
      join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
     where si.tenant_id = erp.current_tenant_id() and si.document_id = p_order
       and si.control_kind = 'payable' and si.debit_minor > 0
       and j.source_code = 'prepayment.paid' and j.status = 'posted'
     order by si.posting_date, si.id limit 1),
  bill as (
    select si.* from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id() and si.document_id = p_bill
       and si.control_kind = 'payable' and si.credit_minor > si.debit_minor)
  select case
           when not exists (select 1 from bill)
             or exists (select 1 from bill, pre where bill.party_id is distinct from pre.party_id)
             then 'CLOVEERP_PREPAYMENT_OTHER_SUPPLIER'
           when exists (select 1 from bill, pre
                         where bill.entity_id <> pre.entity_id or bill.ledger_id <> pre.ledger_id
                            or bill.control_account_id <> pre.control_account_id or bill.currency <> pre.currency)
             then 'CLOVEERP_PREPAYMENT_OTHER_COMPANY'
         end
$$;

revoke all on function erp.prepayment_fits_bill(uuid, uuid) from public, anon;

comment on function erp.prepayment_fits_bill(uuid, uuid) is
  'Null when a purchase order''s prepayment may pay a bill: the same supplier, company, ledger, control '
  'account and currency; otherwise the refusal that says why not (20261004900000).';

-- D3. By the system, as a bill registers and as a prepayment is paid

create or replace function erp.apply_prepayments_to_bill(p_bill uuid)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_owes   bigint;
  v_take   bigint;
  v_done   bigint := 0;
begin
  -- A bill that names an order its supplier was prepaid against takes the
  -- prepayment (20261004900000), as much as each order has left and the bill
  -- owes, orders oldest first. Only a bill that stands: registered or part
  -- paid, not disputed, not cancelled. A prepayment in other books is left for
  -- Finance, who can see it under Supplier prepayments.
  if erp.object_current_state('document', p_bill) not in ('registered', 'part_paid')
     or exists (select 1 from erp.document d where d.tenant_id = v_tenant and d.id = p_bill and d.is_cancelled) then
    return 0;
  end if;

  for r in
    select distinct o.id as order_id, o.document_number
      from erp.document_relation rel
      join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      join erp.document o on o.tenant_id = ol.tenant_id and o.id = ol.document_id
      join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where rel.tenant_id = v_tenant and rel.from_document_id = p_bill
       and rel.relation_kind = 'invoices' and odt.base_type_code = 'purchase_order'
     order by o.document_number
  loop
    v_owes := erp.bill_owes_minor(p_bill);
    exit when v_owes <= 0;
    v_take := least(erp.order_prepayment_left(r.order_id), v_owes);
    continue when v_take <= 0;
    continue when erp.prepayment_fits_bill(r.order_id, p_bill) is not null;
    perform erp.apply_prepayment(r.order_id, p_bill, v_take, false);
    v_done := v_done + v_take;
  end loop;
  return v_done;
end;
$$;

revoke all on function erp.apply_prepayments_to_bill(uuid) from public, anon;

comment on function erp.apply_prepayments_to_bill(uuid) is
  'Takes the prepayments of the orders a registered or part-paid bill bills, as much as each has left '
  'and the bill owes (20261004900000). Called as a bill registers or its dispute is resolved.';

create or replace function erp.apply_prepayment_to_order_bills(p_order uuid)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_done   bigint := 0;
  v_take   bigint;
begin
  -- A prepayment paid after its order was billed goes to the order's open
  -- bills as it is paid (20261004900000), oldest first.
  for r in
    select distinct b.id as bill_id, b.document_number, b.document_date
      from erp.document_relation rel
      join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
     where rel.tenant_id = v_tenant and ol.document_id = p_order
       and rel.relation_kind = 'invoices' and not b.is_cancelled
     order by b.document_date, b.document_number
  loop
    exit when erp.order_prepayment_left(p_order) <= 0;
    continue when erp.object_current_state('document', r.bill_id) not in ('registered', 'part_paid');
    continue when erp.prepayment_fits_bill(p_order, r.bill_id) is not null;
    v_take := least(erp.order_prepayment_left(p_order), erp.bill_owes_minor(r.bill_id));
    continue when v_take <= 0;
    perform erp.apply_prepayment(p_order, r.bill_id, v_take, false);
    v_done := v_done + v_take;
  end loop;
  return v_done;
end;
$$;

revoke all on function erp.apply_prepayment_to_order_bills(uuid) from public, anon;

comment on function erp.apply_prepayment_to_order_bills(uuid) is
  'Takes what is left of an order''s prepayment to its registered or part-paid bills, oldest first '
  '(20261004900000). Called as a payment run pays the prepayment.';

-- D4. By hand, from the Finance screen

create or replace function erp.allocate_prepayment(p_order uuid, p_bill uuid, p_amount_minor bigint default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pre      erp.subledger_item%rowtype;
  v_order  text;
  v_bill   text;
  v_left   bigint;
  v_owes   bigint;
  v_amount bigint;
  v_misfit text;
begin
  -- The prepayment's first row, held while it is spent: two allocations of one
  -- prepayment wait for each other here, and the second sees what the first
  -- left.
  select si.* into pre
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.document_id = p_order and si.control_kind = 'payable'
     and si.debit_minor > 0
     and exists (select 1 from erp.journal j
                  where j.tenant_id = v_tenant and j.id = si.journal_id
                    and j.source_code = 'prepayment.paid' and j.status = 'posted')
   order by si.posting_date, si.id
   limit 1
     for update;
  v_order := coalesce((select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = p_order),
                      coalesce(p_order::text, 'nothing'));
  if pre.id is null then
    raise exception 'CLOVEERP_NOTHING_PREPAID: nothing was paid in advance against %', v_order
      using errcode = '23503',
            hint = 'Pick the order from Supplier prepayments on the Finance screen, which lists only those with something left.';
  end if;

  -- Allocating is posting cash, in the company whose books hold the prepayment.
  perform erp.authorise('finance.post', pre.entity_id, null, null, 'party', pre.party_id);

  v_left := erp.order_prepayment_left(p_order);
  if v_left <= 0 then
    raise exception 'CLOVEERP_NOTHING_PREPAID: the prepayment on % has been used in full', v_order
      using errcode = '23514',
            hint = 'Pick the order from Supplier prepayments on the Finance screen, which lists only those with something left.';
  end if;

  v_bill := coalesce((select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = p_bill),
                     coalesce(p_bill::text, 'nothing'));
  v_misfit := erp.prepayment_fits_bill(p_order, p_bill);
  if v_misfit = 'CLOVEERP_PREPAYMENT_OTHER_SUPPLIER' then
    raise exception 'CLOVEERP_PREPAYMENT_OTHER_SUPPLIER: % is not a bill of the supplier prepaid on %', v_bill, v_order
      using errcode = '23514',
            hint = 'Allocate it to one of the same supplier''s open bills, which Supplier prepayments offers on the order''s row.';
  elsif v_misfit = 'CLOVEERP_PREPAYMENT_OTHER_COMPANY' then
    raise exception 'CLOVEERP_PREPAYMENT_OTHER_COMPANY: % is not in the books the prepayment on % was paid in (%, %)',
      v_bill, v_order,
      coalesce((select e.code from erp.entity e where e.tenant_id = v_tenant and e.id = pre.entity_id), pre.entity_id::text),
      pre.currency
      using errcode = '23514',
            hint = 'Allocate it to a bill of the same company and currency, or move the balance between companies with a journal.';
  end if;

  -- Held too, so what it owes cannot move under the allocation.
  perform 1 from erp.subledger_item si
   where si.tenant_id = v_tenant and si.document_id = p_bill and si.control_kind = 'payable'
   order by si.id
     for update;
  v_owes := erp.bill_owes_minor(p_bill);

  if p_amount_minor is not null and p_amount_minor <= 0 then
    raise exception 'CLOVEERP_PREPAYMENT_AMOUNT_INVALID: an allocation is a positive amount, not %', p_amount_minor
      using errcode = '22023',
            hint = 'Name an amount in minor units: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.';
  end if;
  v_amount := coalesce(p_amount_minor, least(v_left, v_owes));
  if v_amount > v_left then
    raise exception 'CLOVEERP_PREPAYMENT_EXCEEDS_LEFT: % is more than the % left of the prepayment on %',
      v_amount, v_left, v_order
      using errcode = '23514',
            hint = 'Allocate no more than is left, which Supplier prepayments shows, or leave the amount out to allocate what is left.';
  end if;
  if v_owes <= 0 or v_amount > v_owes then
    raise exception 'CLOVEERP_PREPAYMENT_EXCEEDS_OWING: % owes %, and % was to be allocated to it',
      v_bill, v_owes, v_amount
      using errcode = '23514',
            hint = 'Allocate no more than the bill owes, or leave the amount out to allocate what it owes.';
  end if;

  perform erp.require_cash_in_ledger_currency(pre.ledger_id, pre.currency);
  return erp.apply_prepayment(p_order, p_bill, v_amount, true);
end;
$$;

revoke all on function erp.allocate_prepayment(uuid, uuid, bigint) from public, anon;

comment on function erp.allocate_prepayment(uuid, uuid, bigint) is
  'Takes a purchase order''s prepayment to a bill of the same supplier, company, ledger, control account '
  'and currency, by hand (20261004900000). Authorises finance.post in the prepayment''s company. The '
  'amount defaults to the lesser of what is left and what the bill owes.';

create or replace function public.erp_allocate_prepayment(p_order uuid, p_bill uuid, p_amount_minor bigint default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.allocate_prepayment(p_order, p_bill, p_amount_minor) $$;

revoke all on function public.erp_allocate_prepayment(uuid, uuid, bigint) from public, anon;
grant execute on function public.erp_allocate_prepayment(uuid, uuid, bigint) to authenticated, service_role;

comment on function public.erp_allocate_prepayment(uuid, uuid, bigint) is
  'Takes a purchase order''s prepayment to one of the supplier''s open bills (20261004900000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_allocate_prepayment', 'erp.allocate_prepayment',
   'Takes a supplier''s prepayment to one of their bills: posts a prepayment.applied journal and two subledger rows, and moves the bill to part_paid or paid; authorises finance.post in the prepayment''s company.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/finance', array['erp_allocate_prepayment']);

-- D5. The list the Finance screen draws Allocate on

create or replace function erp.supplier_prepayments()
returns table(order_id uuid, order_number text, party_id uuid, party_name text, entity_id uuid,
              company text, currency char(3), paid_minor bigint, left_minor bigint,
              order_cancelled boolean, allocatable boolean, bills jsonb)
language sql
stable
set search_path = ''
as $$
  -- Every order a supplier was prepaid against with something left
  -- (20261004900000), oldest first, whether the order is cancelled, the
  -- supplier's open bills in the same company, control account and currency
  -- it may go to, oldest first, and whether the reader holds finance.post in
  -- its company. The door decides regardless.
  with pre as (
    select distinct on (si.document_id)
           si.document_id, si.party_id, si.entity_id, si.control_account_id, si.currency, si.posting_date
      from erp.subledger_item si
      join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
     where si.tenant_id = erp.current_tenant_id() and si.control_kind = 'payable'
       and si.debit_minor > 0 and j.source_code = 'prepayment.paid' and j.status = 'posted'
     order by si.document_id, si.posting_date, si.id)
  select o.id, o.document_number, pre.party_id, p.name, pre.entity_id, e.code, pre.currency,
         erp.order_prepaid_minor(o.id), erp.order_prepayment_left(o.id),
         -- A lifecycle's cancel moves the state and need not set the flag.
         o.is_cancelled or erp.object_current_state('document', o.id) = 'cancelled',
         erp.has_permission('finance.post', pre.entity_id),
         coalesce((select jsonb_agg(jsonb_build_object(
                             'document_id', b.document_id, 'document_number', d.document_number,
                             'owes_minor', b.outstanding_minor, 'due_on', b.due_on)
                           order by b.due_on, d.document_number)
                     from erp.ageing_balance b
                     join erp.document d on d.tenant_id = b.tenant_id and d.id = b.document_id
                     join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                    where b.tenant_id = o.tenant_id and b.entity_id = pre.entity_id
                      and b.control_account_id = pre.control_account_id and b.control_kind = 'payable'
                      and b.currency = pre.currency and b.party_id = pre.party_id
                      and dt.base_type_code = 'invoice_reference'
                      and b.outstanding_minor > 0), '[]'::jsonb)
    from pre
    join erp.document o on o.tenant_id = erp.current_tenant_id() and o.id = pre.document_id
    left join erp.party p on p.tenant_id = o.tenant_id and p.id = pre.party_id
    left join erp.entity e on e.tenant_id = o.tenant_id and e.id = pre.entity_id
   where erp.order_prepayment_left(o.id) > 0
   order by pre.posting_date, o.document_number
$$;

revoke all on function erp.supplier_prepayments() from public, anon;

comment on function erp.supplier_prepayments() is
  'The prepayments suppliers hold with something left, with the bills each may go to and whether the '
  'reader may allocate it (20261004900000).';

create or replace function public.erp_supplier_prepayments()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.order_number), '[]'::jsonb)
    from erp.supplier_prepayments() s
$$;

revoke all on function public.erp_supplier_prepayments() from public, anon;
grant execute on function public.erp_supplier_prepayments() to authenticated, service_role;

comment on function public.erp_supplier_prepayments() is
  'Supplier prepayments: what suppliers hold in advance, and which of their bills it may pay (20261004900000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The payment run pays a prepayment, and a bill takes it as it registers
-- ═════════════════════════════════════════════════════════════════════════════

-- E1. A prepayment line of a run, paid

create or replace function erp.pay_prepayment_line(p_proposal_id uuid, p_line_id uuid,
                                                   p_payment_type text, p_payments jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  pp        erp.payment_proposal%rowtype;
  l         erp.payment_proposal_line%rowtype;
  o         erp.document%rowtype;
  v_amount  bigint;
  v_ledger  uuid;
  v_control uuid;
  v_bank    uuid;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_key     text;
  v_payment uuid;
  v_on      date;
  v_payments jsonb := coalesce(p_payments, '{}'::jsonb);
begin
  -- One line of an approved run naming a purchase order and no open item
  -- (20261004900000): what is still due of the order's prepayment, no more
  -- than the line says, paid by the supplier_payment rule, Dr the creditors
  -- control on a row naming the supplier and the order, Cr the bank. On the
  -- supplier's payment of the run, kept in p_payments as erp.pay_payment_run()
  -- keeps it, whose line says what it paid. Then whatever bills the order has
  -- take it. Answers what it paid and the payments, as they now stand.
  select * into pp from erp.payment_proposal x where x.tenant_id = v_tenant and x.id = p_proposal_id;
  select * into l from erp.payment_proposal_line x
   where x.tenant_id = v_tenant and x.id = p_line_id and x.payment_proposal_id = p_proposal_id;
  if l.id is null or l.document_id is null or l.subledger_item_id is not null then
    return jsonb_build_object('paid_minor', 0, 'payments', v_payments);
  end if;

  -- The order, held, so a request lowered under the run waits for it.
  select * into o from erp.document x where x.tenant_id = v_tenant and x.id = l.document_id for update;
  if not erp.prepayment_order_open(o.id) then
    return jsonb_build_object('paid_minor', 0, 'payments', v_payments);
  end if;
  v_amount := least(coalesce(l.amount_minor, 0), erp.order_prepayment_due(o.id));
  if v_amount <= 0 then
    return jsonb_build_object('paid_minor', 0, 'payments', v_payments);
  end if;

  v_on := coalesce(pp.payment_date, current_date);

  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'supplier_payment' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_PAYMENT_POSTING_RULE: paying a supplier has no promoted rule'
      using errcode = '23503',
      hint = 'Install procurement controls: erp_configure_procurement_controls().';
  end if;

  -- The company's own ledger of the rule's code, as erp.post_document_finance()
  -- finds one for a document of another company.
  select lg.id into v_ledger
    from erp.ledger lg
   where lg.tenant_id = v_tenant and lg.entity_id = o.entity_id and lg.status = 'active'
   order by coalesce(lg.code = (select r0.code from erp.ledger r0
                                  where r0.id = (select pr.ledger_id from erp.posting_rule pr where pr.id = v_rule)),
                     false) desc,
            lg.is_primary desc, lg.code
   limit 1;
  perform erp.require_cash_in_ledger_currency(v_ledger, o.currency);
  v_control := erp.company_payable_account(o.entity_id, v_ledger, o.id);
  v_bank := erp.company_bank_account(o.entity_id);

  if p_payment_type is not null then
    v_key := o.party_id::text || ':' || o.entity_id::text || ':' || o.currency;
    v_payment := nullif(v_payments ->> v_key, '')::uuid;
    if v_payment is null then
      v_payment := erp.open_document(p_payment_type, o.party_id, o.entity_id, null, null, null, o.currency);
      update erp.document d
         set document_date = v_on,
             our_reference = pp.reference,
             attributes = d.attributes || jsonb_build_object('route', 'payment_run', 'payment_proposal_id', pp.id),
             updated_at = now()
       where d.tenant_id = v_tenant and d.id = v_payment;
      v_payments := v_payments || jsonb_build_object(v_key, v_payment);
    end if;
  end if;

  v_event := erp.append_event(
    'prepayment.paid', 'document', o.id,
    jsonb_build_object('reference', pp.reference, 'order_number', o.document_number,
                       'value_minor', v_amount, 'currency', o.currency, 'posting_rule', 'supplier_payment',
                       'party_id', o.party_id, 'payment_id', v_payment),
    o.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, o.entity_id, v_ledger, 'prepayment.paid', v_event, v_on,
          format('Prepayment against %s on %s', o.document_number, pp.reference), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_control, v_amount, 0, o.currency, v_amount, 0, 1,
          v_rule, v_version, v_event, 'paid to the supplier in advance of their bill'),
         (v_tenant, v_journal, 2, v_bank, 0, v_amount, o.currency, 0, v_amount, 1,
          v_rule, v_version, v_event, 'bank');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency,
                                  debit_minor, credit_minor, posting_date)
  values (v_tenant, o.entity_id, v_ledger, 'payable', v_control,
          o.party_id, o.id, v_journal, o.currency, v_amount, 0, v_on),
         (v_tenant, o.entity_id, v_ledger, 'bank', v_bank,
          null, null, v_journal, o.currency, 0, v_amount, v_on);

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
         document_id = v_payment
   where id = v_journal;

  if v_payment is not null then
    insert into erp.document_line (
      tenant_id, document_id, line_no, item_id, description, quantity,
      unit_price_minor, net_minor, currency)
    values (
      v_tenant, v_payment,
      coalesce((select max(x.line_no) from erp.document_line x
                 where x.tenant_id = v_tenant and x.document_id = v_payment), 0) + 10,
      null,
      'Prepayment against ' || o.document_number
        || coalesce(', your ref ' || nullif(o.their_reference, ''), ''),
      1, v_amount, v_amount, o.currency);
  end if;

  -- Paid after the order was billed: the bills take it now.
  perform erp.apply_prepayment_to_order_bills(o.id);

  return jsonb_build_object('paid_minor', v_amount, 'payments', v_payments);
end;
$$;

revoke all on function erp.pay_prepayment_line(uuid, uuid, text, jsonb) from public, anon;

comment on function erp.pay_prepayment_line(uuid, uuid, text, jsonb) is
  'Pays one prepayment line of an approved payment run (20261004900000): Dr the creditors control on a '
  'row naming the supplier and the order, Cr the bank, by the supplier_payment rule, on the supplier''s '
  'payment of the run; then the order''s open bills take it. Called by erp.pay_payment_run().';

-- E2. The run proposes what is due
--
-- Edited, not rewritten: one anchor over the body 20260929300000 left
-- (md5 0e68eb64…). Its arguments and its answer are unchanged.

do $propose$
declare
  v_sig  constant text := 'erp.propose_payment_run(date,character,interval)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  update erp.payment_proposal
     set total_minor = v_total, status = 'proposed', updated_at = now()
   where id = v_id;$o$,
    $n$  -- And every prepayment asked for on an order and not yet paid, due by the
  -- run's horizon, in the run's currency (20261004900000): a line naming the
  -- order and no open item. An order already billed is held, and says so: its
  -- bill is what gets paid, and the prepayment would pay it twice.
  for r in
    select o.id as order_id, o.party_id, o.document_number,
           erp.order_prepayment_due(o.id) as amount,
           coalesce((o.attributes #>> '{prepayment,due_on}')::date, current_date) as due_date
      from erp.document o
      join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where o.tenant_id = v_tenant
       and odt.base_type_code = 'purchase_order'
       and o.attributes ? 'prepayment'
       and o.currency = v_ccy
       and erp.prepayment_order_open(o.id)
       and erp.order_prepayment_due(o.id) > 0
       and coalesce((o.attributes #>> '{prepayment,due_on}')::date, current_date)
           <= coalesce(p_payment_date, current_date) + p_include_due_within
     order by 5, o.document_number
  loop
    v_held := null;
    if exists (select 1
                 from erp.document_relation rel
                 join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
                 join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
                 join erp.object_state bos on bos.tenant_id = b.tenant_id and bos.object_type = 'document'
                                          and bos.object_id = b.id
                 join erp.state bs on bs.id = bos.current_state_id
                where rel.tenant_id = v_tenant and ol.document_id = r.order_id
                  and rel.relation_kind = 'invoices' and not b.is_cancelled and bs.is_committed) then
      v_held := 'the order is billed; its bill is paid instead';
    end if;

    insert into erp.payment_proposal_line (
      tenant_id, payment_proposal_id, party_id, document_id, subledger_item_id,
      amount_minor, due_date, is_held, hold_reason)
    values (v_tenant, v_id, r.party_id, r.order_id, null,
            r.amount, r.due_date, v_held is not null, v_held);

    if v_held is null then v_total := v_total + r.amount; end if;
  end loop;

  update erp.payment_proposal
     set total_minor = v_total, status = 'proposed', updated_at = now()
   where id = v_id;$n$];
  v_hits integer;
begin
  if strpos(v_src, '20261004900000') > 0 then
    raise notice '% already proposes prepayments; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '0e68eb64aee0547408d2966135ee8748' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004900000 expects (md5 %)', v_sig, md5(v_src);
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
$propose$;

comment on function erp.propose_payment_run(date, character, interval) is
  'Proposes a payment run: every open supplier bill due by the horizon, a disputed or unmatched one held '
  'and saying why, and every prepayment asked for on an order and not yet paid, an order already billed '
  'held (20261004900000).';

-- E3. The run pays a prepayment line
--
-- Edited, not rewritten: two anchors over the body 20260930200000 left
-- (md5 5b3491c8…). Its arguments and its answer are unchanged.

do $pay_run$
declare
  v_sig  constant text := 'erp.pay_payment_run(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_answer       jsonb;
begin$o$,
    $n$  v_answer       jsonb;
  -- A prepayment line's answer (20261004900000).
  v_pre          jsonb;
begin$n$,

    $o$    select * into si from erp.subledger_item x
     where x.tenant_id = v_tenant and x.id = r.subledger_item_id for update;$o$,
    $n$    -- A line naming an order and no open item is a prepayment
    -- (20261004900000), paid by its own routine on the same payment.
    if r.subledger_item_id is null then
      v_pre := erp.pay_prepayment_line(p_proposal_id, r.id, v_payment_type, v_payments);
      v_payments := coalesce(v_pre -> 'payments', v_payments);
      if coalesce((v_pre ->> 'paid_minor')::bigint, 0) > 0 then
        v_paid := v_paid + (v_pre ->> 'paid_minor')::bigint;
        v_lines := v_lines + 1;
      end if;
      continue;
    end if;

    select * into si from erp.subledger_item x
     where x.tenant_id = v_tenant and x.id = r.subledger_item_id for update;$n$];
  v_hits integer;
begin
  if strpos(v_src, '20261004900000') > 0 then
    raise notice '% already pays prepayments; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '5b3491c8de791c89e70423951bb28623' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004900000 expects (md5 %)', v_sig, md5(v_src);
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
$pay_run$;

comment on function erp.pay_payment_run(uuid) is
  'Pays an approved payment run: each unheld line''s bill, by the supplier_payment rule, from the '
  'company''s bank, with a bill paid short within the settlement tolerance written off '
  '(20260929300000) and a bill left owing nothing settled. Where the organisation has a supplier '
  'payment type, one payment per supplier, whose lines are the bills it paid and whose journals name '
  'it, posted with the run; the answer lists them under payments (20260930200000). A line naming an '
  'order is a prepayment, paid by erp.pay_prepayment_line() (20261004900000).';

-- E4. A bill takes the prepayment as it registers
--
-- Edited, not rewritten: one anchor over erp.transition_document()'s body
-- (md5 64b13f59…), after the dispute check and before the order is closed,
-- so a bill disputed as it registers takes nothing, and a bill the
-- prepayment pays in full closes its order.

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  -- A purchase order is closed by the bill that settles it (20260922360000).$o$,
    $n$  -- A bill that names an order its supplier was paid for in advance takes the
  -- prepayment as it registers, or as its dispute is resolved
  -- (20261004900000): by the system, after the dispute check, so a bill
  -- disputed as it registers takes nothing, and before the order is closed,
  -- so a bill the prepayment pays in full closes it. Its state is read again,
  -- because the prepayment may have paid it.
  if dt.base_type_code = 'invoice_reference' and p_transition_code in ('register', 'resolve')
     and v_to in ('registered', 'part_paid') then
    if erp.apply_prepayments_to_bill(p_document_id) > 0 then
      v_to := erp.object_current_state('document', p_document_id);
    end if;
  end if;

  -- A purchase order is closed by the bill that settles it (20260922360000).$n$];
  v_hits integer;
begin
  if strpos(v_src, '20261004900000') > 0 then
    raise notice '% already applies prepayments; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '64b13f5958ab1d80a66c1964139a9018' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004900000 expects (md5 %)', v_sig, md5(v_src);
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
$transition$;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.prepayment_order(p_entity uuid, p_site uuid, p_item uuid, p_supplier uuid,
                                                     p_quantity numeric, p_price bigint, p_ref text,
                                                     p_send boolean default true)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_po uuid;
begin
  -- An order to the supplier, approved, and sent unless told not to
  -- (20261004900000): an order sent cannot be cancelled.
  v_po := erp.open_document('purchase_order', p_supplier, p_entity, p_site);
  perform erp.add_document_line(v_po, p_item, p_quantity, p_price, 'bought for ' || p_ref);
  perform erp.transition_document(v_po, 'submit', null);
  perform erp_test.approve_document(v_po, 'supplier prepayment suite');
  if coalesce(p_send, true) then
    perform erp.transition_document(v_po, 'send', null);
  end if;
  return v_po;
end;
$$;

revoke all on function erp_test.prepayment_order(uuid, uuid, uuid, uuid, numeric, bigint, text, boolean) from public, anon;

comment on function erp_test.prepayment_order(uuid, uuid, uuid, uuid, numeric, bigint, text, boolean) is
  'A purchase order, approved and sent, for the supplier prepayment suite (20261004900000).';

create or replace function erp_test.prepayment_bill(p_order uuid, p_quantity numeric, p_ref text,
                                                    p_price bigint default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  o     erp.document%rowtype;
  v_pol uuid;
  v_grn uuid;
  v_inv uuid;
begin
  -- p_quantity of the order's first line received, billed and registered
  -- (20261004900000). p_ref is the supplier's reference. With p_price, the
  -- bill charges that unit price rather than the order's, so three-way
  -- matching disputes it as it registers.
  select * into o from erp.document where tenant_id = erp.current_tenant_id() and id = p_order;
  select l.id into v_pol from erp.document_line l
   where l.tenant_id = o.tenant_id and l.document_id = o.id order by l.line_no limit 1;
  v_grn := erp.open_document('goods_receipt', o.party_id, o.entity_id, o.site_id);
  perform erp.receive_against(v_grn, v_pol, p_quantity, null);
  perform erp.transition_document(v_grn, 'post', null);
  if p_price is null then
    return erp.bill_from_receipt(v_grn, p_ref, current_date, current_date + 30, true);
  end if;
  v_inv := erp.open_document('purchase_invoice', o.party_id, o.entity_id, o.site_id, p_ref, null, o.currency);
  update erp.document set due_date = current_date + 30 where id = v_inv;
  perform erp.invoice_against(v_inv, v_pol, p_quantity, p_price);
  insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
  values (o.tenant_id, v_inv, v_grn, 'invoices');
  perform erp.transition_document(v_inv, 'register', 'supplier prepayment suite');
  return v_inv;
end;
$$;

revoke all on function erp_test.prepayment_bill(uuid, numeric, text, bigint) from public, anon;

comment on function erp_test.prepayment_bill(uuid, numeric, text, bigint) is
  'Part of a purchase order received and billed, for the supplier prepayment suite (20261004900000).';

create or replace function erp_test.prepayment_run(p_proposer uuid, p_payer uuid, p_orders uuid[], p_bills uuid[])
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_prop   uuid;
  v_pay    jsonb;
begin
  -- A run proposed by one administrator and approved and paid by another
  -- (20261004900000), paying only the orders' prepayments and the bills
  -- named: every other line the proposal offers is held, so one case's money
  -- is on no other case's payment.
  perform set_config('request.jwt.claims', json_build_object('sub', p_proposer)::text, true);
  v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
  update erp.payment_proposal_line l
     set is_held = true, hold_reason = coalesce(l.hold_reason, 'not this case''s')
   where l.tenant_id = v_tenant and l.payment_proposal_id = v_prop
     and not (l.document_id = any (coalesce(p_orders, '{}'::uuid[]) || coalesce(p_bills, '{}'::uuid[])));
  perform set_config('request.jwt.claims', json_build_object('sub', p_payer)::text, true);
  perform erp.approve_payment_run(v_prop);
  v_pay := erp.pay_payment_run(v_prop);
  perform set_config('request.jwt.claims', json_build_object('sub', p_proposer)::text, true);
  return v_pay || jsonb_build_object('proposal_id', v_prop);
end;
$$;

revoke all on function erp_test.prepayment_run(uuid, uuid, uuid[], uuid[]) from public, anon;

comment on function erp_test.prepayment_run(uuid, uuid, uuid[], uuid[]) is
  'A payment run of the orders'' prepayments and the bills named, proposed by one administrator and '
  'paid by another, for the supplier prepayment suite (20261004900000).';

create or replace function erp_test.supplier_prepayment_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 15;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  s_fin    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_item uuid;
  v_sa uuid; v_sb uuid;
  v_po uuid; v_po2 uuid; v_po3 uuid; v_po4 uuid; v_po5 uuid; v_po6 uuid; v_po7 uuid;
  v_bill uuid; v_bill2 uuid; v_bill3 uuid; v_other uuid;
  v_gross bigint; v_bgross bigint; v_bgross2 bigint;
  v_pre jsonb; v_pay jsonb; v_list jsonb; v_row jsonb; v_alloc jsonb;
  v_prop uuid; v_line jsonb; v_pmt uuid;
  v_n integer; v_n2 integer; v_bank0 bigint; v_bank1 bigint;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_tie text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys and pays, with two administrators, a buyer and a finance clerk';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzspp-' || v_tag, 'Supplier Prepayment Suite',
      'admin@zzspp-' || v_tag || '.test', 'Prepayment Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzspp-' || v_tag || '.test'),
           (a2, 'second@zzspp-' || v_tag || '.test'),
           (s_buy, 'buyer@zzspp-' || v_tag || '.test'),
           (s_fin, 'clerk@zzspp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    res := public.erp_invite_principal('second@zzspp-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('buyer@zzspp-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('clerk@zzspp-' || v_tag || '.test', 'Cal Clerk');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'finance', null, null, 'pays');
    perform set_config('request.jwt.claims', json_build_object('sub', s_fin)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, product and two suppliers';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZPMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZPEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPDRESS', 'Prepaid Dress', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZPBRAND');
    v_sb := erp_test.cash_payment_supplier('ZPOTHER');

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, their refusals, their events and their screens';
    v_cases := v_cases + 1;
    case_name := 'both write doors are on the allow-list under their gates and on their screens'' help, the ten refusals are registered with a next action, and the three events are current and named in English and German';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_request_prepayment' and a.gate = 'erp.request_prepayment')
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_allocate_prepayment' and a.gate = 'erp.allocate_prepayment')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/procurement' and 'erp_request_prepayment' = any (h.actions))
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance' and 'erp_allocate_prepayment' = any (h.actions))
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_PREPAYMENT_NOT_AN_ORDER', 'CLOVEERP_PREPAYMENT_EXCEEDS_ORDER',
                                 'CLOVEERP_PREPAYMENT_BELOW_PAID', 'CLOVEERP_PREPAYMENT_AMOUNT_INVALID',
                                 'CLOVEERP_NOTHING_PREPAID', 'CLOVEERP_PREPAYMENT_OTHER_SUPPLIER',
                                 'CLOVEERP_PREPAYMENT_OTHER_COMPANY', 'CLOVEERP_PREPAYMENT_EXCEEDS_LEFT',
                                 'CLOVEERP_PREPAYMENT_EXCEEDS_OWING', 'CLOVEERP_NO_PAYABLE_ACCOUNT')
                  and coalesce(f.next_action, '') <> '') = 10
          and (select count(*) from erp_ref.event_type et
                where et.code in ('prepayment.requested', 'prepayment.paid', 'prepayment.applied')
                  and et.is_current) = 3
          and (select count(*) from erp_ref.resource x
                where x.key in ('event.prepayment.requested', 'event.prepayment.paid',
                                'event.prepayment.applied')
                  and x.locale in ('en', 'de')) = 6;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. A buyer asks ─────────────────────────────────────────────────────
    v_step := 'a sent order of ten dresses, and the buyer asking for 30% of it in advance';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 10000, 'ZPP2');
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_po;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_pre := public.erp_request_prepayment(v_po, (v_gross * 3 / 10)::bigint, current_date, 'pro-forma 0042');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a buyer asks for 30% of a sent order in advance: the order''s prepayment says so, asked for and due, nothing paid, with the reason and the date, the buyer may ask, and prepayment.requested is raised against the order';
    passed := v_state is null
          and (v_pre ->> 'requested_minor')::bigint = v_gross * 3 / 10
          and (v_pre ->> 'due_minor')::bigint = v_gross * 3 / 10
          and (v_pre ->> 'paid_minor')::bigint = 0
          and (v_pre ->> 'left_minor')::bigint = 0
          and (v_pre ->> 'order_gross_minor')::bigint = v_gross
          and v_pre ->> 'reason' = 'pro-forma 0042'
          and v_pre ->> 'due_on' = current_date::text
          and (v_pre ->> 'open')::boolean
          and exists (select 1 from erp.event e
                       where e.tenant_id = rb.tenant_id and e.event_type = 'prepayment.requested'
                         and e.aggregate_id = v_po
                         and (e.payload ->> 'requested_minor')::bigint = v_gross * 3 / 10);
    detail := coalesce(v_state, left(v_pre::text, 400));
    return next;

    -- ── 3. What may not be asked ────────────────────────────────────────────
    v_step := 'asking on a draft order, a bill, a cancelled order, for more than the order, and for less than nothing';
    v_po2 := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    perform erp.add_document_line(v_po2, v_item, 1, 10000, 'a draft');
    begin
      perform public.erp_request_prepayment(v_po2, 100, null, null);
      v_err := 'asked';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_request_prepayment(gen_random_uuid(), 100, null, null);
      v_err2 := 'asked';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_request_prepayment(v_po, v_gross + 1, null, null);
      v_err3 := 'asked';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_request_prepayment(v_po, -1, null, null);
      v_err4 := 'asked';
    exception when others then v_err4 := sqlerrm; end;
    v_po3 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 10000, 'ZPP3', false);
    perform erp.transition_document(v_po3, 'cancel_approved', 'supplier prepayment suite');
    begin
      perform public.erp_request_prepayment(v_po3, 100, null, null);
      v_err5 := 'asked';
    exception when others then v_err5 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a draft order, something that is not an order and a cancelled order are refused as not an order; more than the order is worth and a negative amount are refused by name; the request stands as it was';
    passed := v_state is null
          and v_err like 'CLOVEERP_PREPAYMENT_NOT_AN_ORDER:%'
          and v_err2 like 'CLOVEERP_PREPAYMENT_NOT_AN_ORDER:%'
          and v_err3 like 'CLOVEERP_PREPAYMENT_EXCEEDS_ORDER:%'
          and v_err4 like 'CLOVEERP_PREPAYMENT_AMOUNT_INVALID:%'
          and v_err5 like 'CLOVEERP_PREPAYMENT_NOT_AN_ORDER:%'
          and erp.order_prepayment_requested(v_po) = v_gross * 3 / 10;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 600));
    return next;

    -- ── 4. Somebody who pays but does not buy ───────────────────────────────
    v_step := 'the finance clerk asking, and reading the order';
    perform set_config('request.jwt.claims', json_build_object('sub', s_fin)::text, true);
    begin
      perform public.erp_request_prepayment(v_po, 100, null, null);
      v_err := 'asked';
    exception when others then v_err := sqlerrm; end;
    v_pre := public.erp_order_prepayment(v_po);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody who may pay suppliers but not buy reads the order''s prepayment as not theirs to ask, and the door refuses them procurement.order';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERMISSION_DENIED: procurement.order%'
          and v_pre is not null
          and not (v_pre ->> 'may_request')::boolean
          and erp.order_prepayment_requested(v_po) = v_gross * 3 / 10;
    detail := coalesce(v_state, left(format('%s; may_request %s', v_err, v_pre ->> 'may_request'), 400));
    return next;

    -- ── 5. The run proposes it, and nothing moves before it is approved ─────
    v_step := 'a run proposed, and paid before anybody approved it';
    select coalesce(sum(si.credit_minor - si.debit_minor), 0) into v_bank0
      from erp.subledger_item si where si.tenant_id = rb.tenant_id and si.control_kind = 'bank';
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    select to_jsonb(l) into v_line from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_prop and l.document_id = v_po;
    begin
      perform erp.pay_payment_run(v_prop);
      v_err := 'paid';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a proposed run carries the request as a line naming the order and no open item, for what is due, unheld, in the run''s total; paid before it is approved it is refused, and nothing is prepaid';
    passed := v_state is null
          and v_line is not null
          and v_line -> 'subledger_item_id' = 'null'::jsonb
          and (v_line ->> 'amount_minor')::bigint = v_gross * 3 / 10
          and not (v_line ->> 'is_held')::boolean
          and (v_line ->> 'party_id')::uuid = v_sa
          and (select pp.total_minor from erp.payment_proposal pp where pp.id = v_prop) >= v_gross * 3 / 10
          and v_err like 'CLOVEERP_PAYMENT_NOT_APPROVED:%'
          and erp.order_prepaid_minor(v_po) = 0
          and erp.order_prepayment_due(v_po) = v_gross * 3 / 10;
    detail := coalesce(v_state, left(format('line %s; pay %s', v_line, v_err), 500));
    return next;

    -- ── 6. Paid ─────────────────────────────────────────────────────────────
    v_step := 'the run approved by the second administrator and paid';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select coalesce(sum(si.credit_minor - si.debit_minor), 0) into v_bank1
      from erp.subledger_item si where si.tenant_id = rb.tenant_id and si.control_kind = 'bank';
    v_pmt := (v_pay #>> '{payments,0,document_id}')::uuid;
    v_pre := public.erp_order_prepayment(v_po);
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'paid: a prepayment.paid journal debits trade payables and credits the bank by the supplier payment rule, a debit on the supplier''s account against the order, the supplier''s payment posted with the line "Prepayment against" the order, the bank down by it, the order prepaid and nothing due, the payables ageing carrying it against the order and tied to the control, and the next run not offering it';
    passed := v_state is null
          and (v_pay ->> 'paid_minor')::bigint = v_gross * 3 / 10
          and v_bank1 - v_bank0 = v_gross * 3 / 10
          and exists (select 1 from erp.journal j
                       join erp.journal_line jl on jl.journal_id = j.id and jl.line_no = 1
                       join erp.account a on a.id = jl.account_id and a.control_kind = 'payable'
                       join erp.posting_rule pr on pr.id = jl.posting_rule_id and pr.code = 'supplier_payment'
                      where j.tenant_id = rb.tenant_id and j.source_code = 'prepayment.paid'
                        and j.status = 'posted' and j.document_id = v_pmt
                        and jl.debit_minor = v_gross * 3 / 10)
          and exists (select 1 from erp.subledger_item si
                       where si.tenant_id = rb.tenant_id and si.document_id = v_po and si.party_id = v_sa
                         and si.control_kind = 'payable' and si.debit_minor = v_gross * 3 / 10)
          and erp.object_current_state('document', v_pmt) = 'posted'
          and exists (select 1 from erp.document_line l
                       where l.document_id = v_pmt and l.net_minor = v_gross * 3 / 10
                         and l.description like 'Prepayment against %'
                         and l.description like '%' || (select d.document_number from erp.document d where d.id = v_po) || '%')
          and (v_pre ->> 'paid_minor')::bigint = v_gross * 3 / 10
          and (v_pre ->> 'left_minor')::bigint = v_gross * 3 / 10
          and (v_pre ->> 'due_minor')::bigint = 0
          and jsonb_array_length(v_pre -> 'payments') = 1
          and (select b.outstanding_minor from erp.ageing_balance b
                where b.tenant_id = rb.tenant_id and b.document_id = v_po) = -(v_gross * 3 / 10)
          and v_tie = 'ties'
          and not exists (select 1 from erp.payment_proposal_line l
                           where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_prop
                             and l.document_id = v_po);
    detail := coalesce(v_state, left(format('pay %s; order %s; bank %s; %s', v_pay, v_pre, v_bank1 - v_bank0, v_tie), 700));
    return next;

    -- ── 7. The bill takes it ────────────────────────────────────────────────
    v_step := 'all ten dresses received and billed';
    v_bill := erp_test.prepayment_bill(v_po, 10, 'ZPP-INV-7');
    select dv.gross_minor::bigint into v_bgross from erp.document_view dv where dv.id = v_bill;
    v_pre := public.erp_order_prepayment(v_po);
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    select to_jsonb(l) into v_line from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_prop and l.document_id = v_bill;
    v_cases := v_cases + 1;
    case_name := 'the bill registered against the prepaid order takes the prepayment by itself: Part paid, owing the rest, a prepayment.applied journal netting to nothing on trade payables, nothing left on the order, the ageing tied, and the next run offering only the rest of the bill';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'part_paid'
          and erp.bill_owes_minor(v_bill) = v_bgross - v_gross * 3 / 10
          and (v_pre ->> 'left_minor')::bigint = 0
          and (v_pre ->> 'used_minor')::bigint = v_gross * 3 / 10
          and exists (select 1 from erp.journal j
                       where j.tenant_id = rb.tenant_id and j.source_code = 'prepayment.applied'
                         and j.status = 'posted'
                         and (select count(distinct jl.account_id) from erp.journal_line jl where jl.journal_id = j.id) = 1
                         and (select sum(jl.debit_minor) - sum(jl.credit_minor) from erp.journal_line jl
                               where jl.journal_id = j.id) = 0
                         and (select sum(jl.debit_minor) from erp.journal_line jl where jl.journal_id = j.id) = v_gross * 3 / 10)
          and not exists (select 1 from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.document_id = v_po)
          and v_tie = 'ties'
          and v_line is not null
          and (v_line ->> 'amount_minor')::bigint = v_bgross - v_gross * 3 / 10;
    detail := coalesce(v_state, left(format('bill %s owes %s of %s; order %s; line %s; %s',
      erp.object_current_state('document', v_bill), erp.bill_owes_minor(v_bill), v_bgross, v_pre, v_line, v_tie), 700));
    return next;

    -- ── 8. More prepaid than the first bill ─────────────────────────────────
    v_step := 'an order prepaid in full, and billed in two parts';
    v_po4 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 4, 10000, 'ZPP8');
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_po4;
    perform public.erp_request_prepayment(v_po4, v_gross, null, null);
    perform erp_test.prepayment_run(a1, a2, array[v_po4], null);
    v_bill := erp_test.prepayment_bill(v_po4, 1, 'ZPP-INV-8A');
    select dv.gross_minor::bigint into v_bgross from erp.document_view dv where dv.id = v_bill;
    v_n := erp.order_prepayment_left(v_po4)::integer;
    v_bill2 := erp_test.prepayment_bill(v_po4, 3, 'ZPP-INV-8B');
    select dv.gross_minor::bigint into v_bgross2 from erp.document_view dv where dv.id = v_bill2;
    v_cases := v_cases + 1;
    case_name := 'an order prepaid in full and billed in two parts: the first bill is Paid from the prepayment and the rest stays on the order, the second bill takes the rest and is Paid, nothing is left, and the order closes, received and billed';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'paid'
          and v_n = v_gross - v_bgross
          and erp.object_current_state('document', v_bill2) = 'paid'
          and v_bgross + v_bgross2 = v_gross
          and erp.order_prepayment_left(v_po4) = 0
          and erp.object_current_state('document', v_po4) = 'closed';
    detail := coalesce(v_state, left(format('first %s (%s), left %s, second %s (%s), order %s',
      erp.object_current_state('document', v_bill), v_bgross, v_n,
      erp.object_current_state('document', v_bill2), v_bgross2,
      erp.object_current_state('document', v_po4)), 500));
    return next;

    -- ── 9. Billed before it was prepaid ─────────────────────────────────────
    v_step := 'an order billed in part, then asked for in advance';
    v_po5 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 2, 10000, 'ZPP9');
    v_bill3 := erp_test.prepayment_bill(v_po5, 1, 'ZPP-INV-9');
    perform public.erp_request_prepayment(v_po5, 5000, null, null);
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    select to_jsonb(l) into v_line from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_prop and l.document_id = v_po5;
    v_cases := v_cases + 1;
    case_name := 'an order already billed is held on the run that would prepay it, saying its bill is paid instead, and its amount is not in the run''s total';
    passed := v_state is null
          and v_line is not null
          and (v_line ->> 'is_held')::boolean
          and v_line ->> 'hold_reason' = 'the order is billed; its bill is paid instead';
    detail := coalesce(v_state, left(coalesce(v_line::text, 'no line'), 400));
    return next;

    -- ── 10. Lowering a request ──────────────────────────────────────────────
    v_step := 'lowering a paid request below what was paid, then withdrawing the unpaid rest';
    v_po6 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 5, 10000, 'ZPP10');
    perform public.erp_request_prepayment(v_po6, 20000, null, null);
    perform erp_test.prepayment_run(a1, a2, array[v_po6], null);
    perform public.erp_request_prepayment(v_po6, 30000, null, null);
    begin
      perform public.erp_request_prepayment(v_po6, 19999, null, null);
      v_err := 'asked';
    exception when others then v_err := sqlerrm; end;
    v_pre := public.erp_request_prepayment(v_po6, 20000, null, 'the brand will wait');
    v_cases := v_cases + 1;
    case_name := 'a request lowered below what was paid is refused by name; lowered to what was paid it withdraws the unpaid rest, and nothing is due';
    passed := v_state is null
          and v_err like 'CLOVEERP_PREPAYMENT_BELOW_PAID:%'
          and (v_pre ->> 'requested_minor')::bigint = 20000
          and (v_pre ->> 'paid_minor')::bigint = 20000
          and (v_pre ->> 'due_minor')::bigint = 0;
    detail := coalesce(v_state, left(format('%s; %s', v_err, v_pre), 400));
    return next;

    -- ── 11. Supplier prepayments, and allocating by hand ────────────────────
    v_step := 'a bill of the same supplier that names another order, allocated from v_po6 by hand';
    v_po7 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 10000, 'ZPP11');
    v_other := erp_test.prepayment_bill(v_po7, 1, 'ZPP-INV-11');
    select dv.gross_minor::bigint into v_bgross from erp.document_view dv where dv.id = v_other;
    v_list := public.erp_supplier_prepayments();
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'order_id' = v_po6::text;
    perform set_config('request.jwt.claims', json_build_object('sub', s_fin)::text, true);
    v_alloc := public.erp_allocate_prepayment(v_po6, v_other, 5000);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'Supplier prepayments lists the prepayment with what is left and offers the supplier''s open bill; the finance clerk allocates part of it by hand, the bill is Part paid, the rest stays on the order, and the ageing ties';
    passed := v_state is null
          and v_row is not null
          and (v_row ->> 'left_minor')::bigint = 20000
          and (v_row ->> 'allocatable')::boolean
          and exists (select 1 from jsonb_array_elements(v_row -> 'bills') b
                       where (b ->> 'document_id')::uuid = v_other and (b ->> 'owes_minor')::bigint = v_bgross)
          and (v_alloc ->> 'allocated_minor')::bigint = 5000
          and (v_alloc ->> 'prepayment_left_minor')::bigint = 15000
          and (v_alloc ->> 'bill_owes_minor')::bigint = v_bgross - 5000
          and v_alloc ->> 'bill_state' = 'part_paid'
          and exists (select 1 from erp.event e
                       where e.tenant_id = rb.tenant_id and e.event_type = 'prepayment.applied'
                         and e.aggregate_id = v_other and (e.payload ->> 'by_hand')::boolean)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('listed %s; allocated %s; %s', v_row, v_alloc, v_tie), 600));
    return next;

    -- ── 12. What allocating by hand refuses ─────────────────────────────────
    v_step := 'allocations the prepayment or the bill cannot take, and somebody who may only buy';
    v_bill := erp_test.prepayment_bill(
      erp_test.prepayment_order(v_entity, v_site, v_item, v_sb, 1, 10000, 'ZPP12'), 1, 'ZPP-INV-12');
    select count(*) into v_n from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'prepayment.applied';
    begin
      perform public.erp_allocate_prepayment(v_po6, v_bill, null);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_allocate_prepayment(v_po7, v_other, null);
      v_err2 := 'allocated';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_allocate_prepayment(v_po6, v_other, 15001);
      v_err3 := 'allocated';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_allocate_prepayment(v_po6, v_other, 0);
      v_err4 := 'allocated';
    exception when others then v_err4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform public.erp_allocate_prepayment(v_po6, v_other, null);
      v_err5 := 'allocated';
    exception when others then v_err5 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n2 from erp.journal j where j.tenant_id = rb.tenant_id and j.source_code = 'prepayment.applied';
    v_cases := v_cases + 1;
    case_name := 'another supplier''s bill, an order with nothing prepaid, more than is left, nought, and a buyer without finance.post are each refused by name, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_PREPAYMENT_OTHER_SUPPLIER:%'
          and v_err2 like 'CLOVEERP_NOTHING_PREPAID:%'
          and v_err3 like 'CLOVEERP_PREPAYMENT_EXCEEDS_LEFT:%'
          and v_err4 like 'CLOVEERP_PREPAYMENT_AMOUNT_INVALID:%'
          and v_err5 like 'CLOVEERP_PERMISSION_DENIED: finance.post%'
          and v_n2 = v_n
          and erp.order_prepayment_left(v_po6) = 15000;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 700));
    return next;

    -- ── 13. More than the bill owes ─────────────────────────────────────────
    v_step := 'the rest of the bill, and then more';
    v_alloc := public.erp_allocate_prepayment(v_po6, v_other, null);
    begin
      perform public.erp_allocate_prepayment(v_po6, v_other, 1);
      v_err := 'allocated';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'left out, the amount is what the bill owes, and the bill is Paid; anything more is refused as more than the bill owes, and what is left stays on the order';
    passed := v_state is null
          and (v_alloc ->> 'allocated_minor')::bigint = v_bgross - 5000
          and erp.object_current_state('document', v_other) = 'paid'
          and v_err like 'CLOVEERP_PREPAYMENT_EXCEEDS_OWING:%'
          and erp.order_prepayment_left(v_po6) = 15000 - (v_bgross - 5000);
    detail := coalesce(v_state, left(format('%s; %s; left %s', v_alloc, v_err, erp.order_prepayment_left(v_po6)), 500));
    return next;

    -- ── 14. A disputed bill, and a cancelled order ──────────────────────────
    v_step := 'a prepaid order whose bill charges twice the price and is disputed as it registers, and an approved order prepaid then cancelled';
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 2, 10000, 'ZPP14');
    perform public.erp_request_prepayment(v_po2, 5000, null, null);
    perform erp_test.prepayment_run(a1, a2, array[v_po2], null);
    v_bill := erp_test.prepayment_bill(v_po2, 1, 'ZPP-INV-14', 20000);
    v_po3 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 10000, 'ZPP14B', false);
    perform public.erp_request_prepayment(v_po3, 4000, null, null);
    perform erp_test.prepayment_run(a1, a2, array[v_po3], null);
    perform erp.transition_document(v_po3, 'cancel_approved', 'supplier prepayment suite: the season was cancelled');
    select x into v_row from jsonb_array_elements(public.erp_supplier_prepayments()) x
     where x ->> 'order_id' = v_po3::text;
    begin
      v_tie := erp.assert_ageing_equals_control();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a disputed bill takes nothing of the prepayment; an order cancelled with a prepayment left is cancelled, and the deposit stays on the supplier''s account, listed under Supplier prepayments as cancelled, with the ageing tied';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'disputed'
          and erp.order_prepayment_left(v_po2) = 5000
          and erp.object_current_state('document', v_po3) = 'cancelled'
          and v_row is not null
          and (v_row ->> 'left_minor')::bigint = 4000
          and (v_row ->> 'order_cancelled')::boolean
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('%s; bill %s, left %s; order %s, listed left %s, cancelled %s',
      v_tie, erp.object_current_state('document', v_bill), erp.order_prepayment_left(v_po2),
      erp.object_current_state('document', v_po3), v_row ->> 'left_minor', v_row ->> 'order_cancelled'), 600));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzspp-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2, s_buy, s_fin))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzspp rolled back with its orders, runs, prepayments and bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_PREPAYMENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.supplier_prepayment_suite() from public, anon;

comment on function erp_test.supplier_prepayment_suite() is
  'A supplier is paid before it delivers (20261004900000): a buyer asks on an order, a run proposed by '
  'one administrator and paid by another pays it onto the supplier''s account against the order, the '
  'ageing tied; the bill takes it as it registers, in one bill or two, the order closing; a billed '
  'order is held; a request is never below what was paid; Finance allocates by hand and is refused by '
  'name; a disputed bill takes nothing; a cancelled order keeps its deposit listed.';

create or replace function erp_test.assert_supplier_prepayment_suite()
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
    from erp_test.supplier_prepayment_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SUPPLIER_PREPAYMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A supplier would be paid twice, or not at all, or the ageing would leave the control. Read the case that failed.';
  end if;
  if v_total <> 15 then
    raise exception 'CLOVEERP_SUPPLIER_PREPAYMENT_SUITE_SHRANK: % case(s), expected 15', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('supplier prepayment: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_supplier_prepayment_suite() from public, anon;

comment on function erp_test.assert_supplier_prepayment_suite() is
  'A supplier is paid in advance against an order, and the bill takes it, without paying twice '
  '(20261004900000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A purchase order''s prepayment, and Supplier prepayments on the Finance screen (20261004900000).'
  from (values
    ('Prepayment'),
    ('Money the supplier asked for before the goods. The next payment run pays it, and their bill takes it when it arrives.'),
    ('Asked for'),
    ('Paid'),
    ('Used by bills'),
    ('Left with the supplier'),
    ('Due'),
    ('Request a prepayment'),
    ('Change the prepayment'),
    ('Ask for part or all of this order to be paid before the goods. The whole amount wanted, not an extra amount.'),
    ('Amount in advance'),
    ('Nought withdraws whatever has not been paid yet.'),
    ('Pay by'),
    ('The payment run that reaches this date pays it.'),
    ('Reason'),
    ('Their pro-forma or deposit invoice'),
    ('Ask'),
    ('Supplier prepayments'),
    ('Money paid to suppliers in advance of their bills, kept on their account until a bill takes it.'),
    ('No supplier holds a prepayment. Money paid in advance of a bill lands here until the bill takes it.'),
    ('Order'),
    ('Left'),
    ('Allocate'),
    ('Allocate a prepayment'),
    ('Pays one of the supplier''s open bills from the prepayment. The bill moves to part paid or paid.'),
    ('Bill'),
    ('Leave empty to allocate as much as the prepayment and the bill allow.'),
    ('{amount} prepaid to {supplier}')
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
