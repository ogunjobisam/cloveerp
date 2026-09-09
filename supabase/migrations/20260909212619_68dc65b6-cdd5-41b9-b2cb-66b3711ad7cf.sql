-- ═════════════════════════════════════════════════════════════════════════════
-- A supplier bill is paid, and the balance goes to nil
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The purchase invoice has existed since procurement controls were written: a
-- lifecycle, a numbering rule, and a posting rule that debits
-- goods-received-not-invoiced and credits trade payables. What it never had was
-- a way in and a way out. Nobody could raise one from a receipt, nothing
-- installed procurement controls unless an administrator knew to press the
-- button, and approving a payment run marked the proposal approved and stopped:
-- no bank entry, no settlement, no bill marked paid. So the accrual grew for
-- ever and the supplier ledger did not exist.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Configuration: the supplier payment rule
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.configure_procurement_controls(
  p_approver_role text default 'administrator',
  p_over_receipt_pct numeric default 5,
  p_price_variance_pct numeric default 2,
  p_price_variance_minor bigint default 100
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'procurement-controls', 'Procurement controls',
    'What may be received against an order, what may be invoiced against a '
    'receipt, who has to look when neither agrees, and how the supplier is paid.',
    jsonb_build_array(
      jsonb_build_object('kind','approval_chain','key','match_exception','payload',
        jsonb_build_object(
          'code','match_exception','name','Invoice match exception',
          'object_type','match_exception',
          'applies_when','true'::jsonb, 'priority',100,
          'material_fields', jsonb_build_array('quantity_variance','price_variance_minor'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer','name','Buyer',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      jsonb_build_object('kind','receipt_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default receipt tolerance',
          'over_pct', p_over_receipt_pct,
          -- Under-delivery is not an error: the rest is still outstanding, and
          -- that is what the outstanding quantity is for.
          'under_pct', 100,
          'over_action','accept')),

      jsonb_build_object('kind','match_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default match tolerance',
          'quantity_pct', 0,
          'price_pct', p_price_variance_pct,
          'price_absolute_minor', p_price_variance_minor,
          'approval_chain','match_exception')),

      -- The purchase invoice, which procurement has been missing since it was
      -- built. Without it there is no third document to match against and, more
      -- pointedly, nothing ever debits goods-received-not-invoiced: the finance
      -- bridge credits 2100 on every receipt and the balance grows for ever.
      jsonb_build_object('kind','state_machine','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match')))),

      -- Registering the invoice is what clears GRNI: the receipt credited it,
      -- and this debits it and credits the supplier instead.
      jsonb_build_object('kind','posting_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','name','Purchase invoice','ledger','GL',
          'event_type','document.purchase_invoice.registered',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','2100','side','debit','rate',1,
                               'description','Clearing goods received not invoiced'),
            jsonb_build_object('account','2000','side','credit','rate',1,
                               'description','Trade payable')))),

      -- And paying it is what clears the supplier. Without a promoted rule an
      -- approved payment run had nothing to post under, which is why approving
      -- one used to be the end of the story.
      jsonb_build_object('kind','posting_rule','key','supplier_payment','payload',
        jsonb_build_object(
          'code','supplier_payment','name','Supplier payment','ledger','GL',
          'event_type','payment.made',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','2000','side','debit','rate',1,
                               'description','Paid to the supplier'),
            jsonb_build_object('account','1000','side','credit','rate',1,
                               'description','Bank'))))));

  insert into erp.numbering_rule (
    tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  select v_tenant, 'purchase_invoice', e.id, 'PINV-', 6, 'yearly', 1
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
    order by e.code limit 1
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, numbering_rule_id, posting_rule_code)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code;

  return v_cs;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Billing a receipt
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.bill_from_receipt(
  p_receipt_id uuid,
  p_their_reference text default null,
  p_invoice_date date default null,
  p_due_date date default null,
  p_register boolean default true)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  rd       erp.document%rowtype;
  v_base   text;
  v_inv    uuid;
  v_date   date := coalesce(p_invoice_date, current_date);
  r        record;
  v_lines  integer := 0;
begin
  select * into rd from erp.document d where d.tenant_id = v_tenant and d.id = p_receipt_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: no document %', p_receipt_id using errcode = '23503',
      hint = 'Name a goods receipt: erp_documents() lists them.';
  end if;

  select dt.base_type_code into v_base from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = rd.document_type_id;
  if v_base is distinct from 'receipt' then
    raise exception 'CLOVEERP_NOT_A_RECEIPT: % is not a goods receipt', rd.document_number
      using errcode = '23514',
      hint = 'Raise the bill from the goods receipt, so that what is billed is what arrived.';
  end if;

  if not exists (select 1 from erp.document_type x
                  where x.tenant_id = v_tenant and x.code = 'purchase_invoice') then
    raise exception 'CLOVEERP_NO_PURCHASE_INVOICE_TYPE: this organisation has no supplier bill configured'
      using errcode = '23503',
      hint = 'Install procurement controls on the Configuration screen: erp_configure_procurement_controls().';
  end if;

  -- Posted means the stock actually moved, and moving it is what raised the
  -- accrual this bill clears. Billing before that books a payable for goods
  -- nobody has seen.
  if not exists (select 1 from erp.stock_movement m
                  where m.tenant_id = v_tenant and m.document_id = p_receipt_id) then
    raise exception 'CLOVEERP_RECEIPT_NOT_POSTED: % has not moved any stock', rd.document_number
      using errcode = '23514',
      hint = 'Post the goods receipt first: transition it with erp_transition_document().';
  end if;

  if exists (select 1 from erp.document_relation rel
              join erp.document i2 on i2.id = rel.from_document_id
              join erp.document_type it on it.id = i2.document_type_id
             where rel.tenant_id = v_tenant and rel.to_document_id = p_receipt_id
               and rel.relation_kind = 'invoices'
               and it.code = 'purchase_invoice' and not i2.is_cancelled) then
    raise exception 'CLOVEERP_ALREADY_BILLED: % already has a supplier bill', rd.document_number
      using errcode = '23505',
      hint = 'Cancel the bill that exists before raising another against the same receipt.';
  end if;

  perform erp.authorise('procurement.match', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);

  v_inv := erp.open_document('purchase_invoice', rd.party_id, rd.entity_id, rd.site_id,
                             p_their_reference, null, rd.currency);

  update erp.document
     set document_date = v_date,
         due_date = coalesce(p_due_date, v_date + 30),
         notes = coalesce(notes, format('Billed from %s', rd.document_number)),
         updated_at = now()
   where id = v_inv;

  -- What arrived, line by line, against the order line it arrived against — so
  -- three-way matching and the order's invoiced quantity work exactly as they
  -- do when somebody bills by hand.
  for r in
    select rel.to_line_id as order_line_id, sum(rel.quantity) as qty
      from erp.document_relation rel
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_receipt_id
       and rel.relation_kind = 'fulfils'
       and rel.to_line_id is not null
     group by rel.to_line_id
  loop
    perform erp.invoice_against(v_inv, r.order_line_id, r.qty, null);
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then
    raise exception 'CLOVEERP_RECEIPT_HAS_NO_ORDER_LINES: % was not received against an order', rd.document_number
      using errcode = '23514',
      hint = 'Receive against a purchase order line: erp_receive_against().';
  end if;

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind)
  values (v_tenant, v_inv, p_receipt_id, 'invoices');

  if coalesce(p_register, true) then
    perform erp.transition_document(v_inv, 'register', 'billed from ' || rd.document_number);
  end if;

  return v_inv;
end;
$$;

comment on function erp.bill_from_receipt(uuid, text, date, date, boolean) is
  'The supplier''s bill, raised from a posted goods receipt: billed for what '
  'arrived, matched against the order, and registered so the accrual clears.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proposing, and then actually paying
-- ═════════════════════════════════════════════════════════════════════════════

-- Settled amounts are netted off. Without this a run proposed after a payment
-- offered the same bill again, and the second run paid it twice.
create or replace function erp.propose_payment_run(
  p_payment_date date default null,
  p_currency char(3) default null,
  p_include_due_within interval default interval '7 days')
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_ccy    char(3);
  v_id     uuid;
  r        record;
  v_total  bigint := 0;
  v_held   text;
begin
  perform erp.authorise('finance.approve_payment', null, null, null,
                        'payment_proposal', null);

  select e.id, coalesce(p_currency, e.base_currency) into v_entity, v_ccy
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1;

  insert into erp.payment_proposal (
    tenant_id, entity_id, reference, payment_date, currency, status)
  values (v_tenant, v_entity,
          -- To the millisecond: two runs proposed in the same second would
          -- collide on the reference, which is a defect a busy Monday morning
          -- would find rather than the suite.
          'PAY-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          coalesce(p_payment_date, current_date), v_ccy, 'draft')
  returning id into v_id;

  for r in
    select si.id as subledger_item_id, si.party_id, si.document_id,
           si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) as amount,
           si.due_date, d.document_number
      from erp.subledger_item si
      left join erp.document d on d.id = si.document_id
     where si.tenant_id = v_tenant
       and si.control_kind = 'payable'
       -- Settled, not merely credited: a bill this organisation has already
       -- paid is not offered to the next run.
       and si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) > 0
       and si.currency = v_ccy
       and coalesce(si.due_date, current_date)
           <= coalesce(p_payment_date, current_date) + p_include_due_within
  loop
    -- An invoice in dispute is not paid. The hold is stated on the line rather
    -- than the line being left out, because a payment run that silently omits
    -- an invoice is one nobody can reconcile against the ledger.
    v_held := null;
    if r.document_id is not null then
      select s.code into v_held
        from erp.object_state os
        join erp.state s on s.id = os.current_state_id
       where os.tenant_id = v_tenant and os.object_type = 'document'
         and os.object_id = r.document_id and s.code = 'disputed';
    end if;

    -- An unresolved match exception is a hold too: paying an invoice that does
    -- not agree with the receipt is exactly what three-way matching is for.
    if v_held is null and r.document_id is not null
       and exists (select 1 from erp.match_exception me
                   where me.tenant_id = v_tenant and me.resolved_at is null
                     and me.invoice_document_id = r.document_id) then
      v_held := 'unresolved match exception';
    end if;

    insert into erp.payment_proposal_line (
      tenant_id, payment_proposal_id, party_id, document_id, subledger_item_id,
      amount_minor, due_date, is_held, hold_reason)
    values (v_tenant, v_id, r.party_id, r.document_id, r.subledger_item_id,
            r.amount, r.due_date, v_held is not null, v_held);

    if v_held is null then v_total := v_total + r.amount; end if;
  end loop;

  update erp.payment_proposal
     set total_minor = v_total, status = 'proposed', updated_at = now()
   where id = v_id;

  return v_id;
end;
$$;

create or replace function erp.pay_payment_run(p_proposal_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  pp        erp.payment_proposal%rowtype;
  v_bank    uuid;
  v_rule    uuid;
  v_rule_version integer;
  v_event   uuid;
  v_journal uuid;
  si        erp.subledger_item%rowtype;
  r         record;
  v_owing   bigint;
  v_amount  bigint;
  v_paid    bigint := 0;
  v_lines   integer := 0;
  v_docs    integer := 0;
begin
  select * into pp from erp.payment_proposal x
   where x.tenant_id = v_tenant and x.id = p_proposal_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PAYMENT_PROPOSAL: no payment run %', p_proposal_id
      using errcode = '23503', hint = 'erp_payment_proposals() lists the runs.';
  end if;

  if pp.status = 'paid' then
    raise exception 'CLOVEERP_PAYMENT_ALREADY_PAID: % was paid already', pp.reference
      using errcode = '23505',
      hint = 'Propose a new run for whatever is still outstanding: erp_propose_payment_run().';
  end if;

  if pp.status <> 'approved' then
    raise exception 'CLOVEERP_PAYMENT_NOT_APPROVED: % is %', pp.reference, pp.status
      using errcode = '23514',
      hint = 'Somebody other than the proposer approves the run first: erp_approve_payment_run().';
  end if;

  perform erp.authorise('finance.post', pp.entity_id, null, null,
                        'payment_proposal', p_proposal_id);

  select a.id into v_bank from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = pp.entity_id
     and a.control_kind = 'bank' and a.status = 'active'
   order by a.code limit 1;
  if v_bank is null then
    raise exception 'CLOVEERP_NO_BANK_ACCOUNT: the money has nowhere to leave from'
      using errcode = '23503',
      hint = 'The finance installer creates the bank account: erp_configure_finance().';
  end if;

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'supplier_payment' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_PAYMENT_POSTING_RULE: paying a supplier has no promoted rule'
      using errcode = '23503',
      hint = 'Install procurement controls: erp_configure_procurement_controls().';
  end if;

  for r in
    select l.* from erp.payment_proposal_line l
     where l.tenant_id = v_tenant and l.payment_proposal_id = p_proposal_id
       and not l.is_held
     order by l.created_at, l.id
  loop
    select * into si from erp.subledger_item x
     where x.tenant_id = v_tenant and x.id = r.subledger_item_id for update;
    if not found or si.control_kind <> 'payable' then
      continue;
    end if;

    v_owing := si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0);
    v_amount := least(coalesce(r.amount_minor, 0), v_owing);
    if v_amount <= 0 then
      continue;
    end if;

    v_event := erp.append_event(
      'payment.made', 'posting', p_proposal_id,
      jsonb_build_object('reference', pp.reference, 'posting_rule', 'supplier_payment',
                         'value_minor', v_amount, 'currency', si.currency,
                         'party_id', si.party_id, 'document_id', si.document_id),
      pp.entity_id, null);

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                             posting_date, description, status)
    values (v_tenant, si.entity_id, si.ledger_id, 'payment.made', v_event,
            coalesce(pp.payment_date, current_date),
            format('Supplier payment %s', pp.reference), 'draft')
    returning id into v_journal;

    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, 1, si.control_account_id, v_amount, 0, si.currency, v_amount, 0, 1,
            v_rule, v_rule_version, v_event, 'paid to the supplier'),
           (v_tenant, v_journal, 2, v_bank, 0, v_amount, si.currency, 0, v_amount, 1,
            v_rule, v_rule_version, v_event, 'bank');

    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency,
                                    debit_minor, credit_minor, posting_date)
    values (v_tenant, si.entity_id, si.ledger_id, 'payable', si.control_account_id,
            si.party_id, si.document_id, v_journal, si.currency, v_amount, 0,
            coalesce(pp.payment_date, current_date)),
           (v_tenant, si.entity_id, si.ledger_id, 'bank', v_bank,
            null, null, v_journal, si.currency, 0, v_amount,
            coalesce(pp.payment_date, current_date));

    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_amount, updated_at = now()
     where id = si.id;

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;

    v_paid := v_paid + v_amount;
    v_lines := v_lines + 1;

    -- A bill that owes nothing is paid, and says so. The state is what the
    -- screens and the supplier read, so leaving it registered would be the
    -- ledger and the document disagreeing.
    if si.document_id is not null
       and coalesce((select sum(x.credit_minor - x.debit_minor - coalesce(x.settled_minor, 0))
                       from erp.subledger_item x
                      where x.tenant_id = v_tenant and x.control_kind = 'payable'
                        and x.document_id = si.document_id), 0) <= 0
       and exists (select 1 from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = v_tenant and os.object_type = 'document'
                      and os.object_id = si.document_id and s.code = 'registered') then
      perform erp.transition_document(si.document_id, 'pay', 'paid on ' || pp.reference);
      v_docs := v_docs + 1;
    end if;
  end loop;

  update erp.payment_proposal
     set status = 'paid', total_minor = v_paid, updated_at = now()
   where id = p_proposal_id;

  return jsonb_build_object(
    'proposal_id', p_proposal_id, 'reference', pp.reference,
    'currency', pp.currency, 'lines_paid', v_lines,
    'paid_minor', v_paid, 'documents_settled', v_docs,
    'held', (select count(*) from erp.payment_proposal_line l
              where l.tenant_id = v_tenant and l.payment_proposal_id = p_proposal_id and l.is_held));
end;
$$;

comment on function erp.pay_payment_run(uuid) is
  'Pays an approved payment run: the bank is credited, each payable settled, '
  'and a bill that owes nothing is marked paid. Held lines are never paid.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. What is owed, and to whom
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.supplier_balances()
returns table (
  party_id uuid, party_code text, party_name text, currency char(3),
  owing_minor bigint, overdue_minor bigint, paid_minor bigint, held_minor bigint,
  oldest_due date, open_documents integer)
language sql
stable
security invoker
set search_path = ''
as $$
  with items as (
    select si.party_id, si.currency, si.document_id,
           si.credit_minor - si.debit_minor as amt,
           si.debit_minor as paid,
           coalesce(si.due_date, si.posting_date) as due
      from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'payable'
       and si.party_id is not null
  ),
  held as (
    select l.party_id, sum(l.amount_minor) as held_minor
      from erp.payment_proposal_line l
      join erp.payment_proposal pp on pp.id = l.payment_proposal_id
     where l.tenant_id = erp.current_tenant_id()
       and l.is_held and pp.status in ('draft', 'proposed', 'approved')
     group by l.party_id
  )
  select i.party_id, p.code, p.name, i.currency,
         sum(i.amt)::bigint,
         coalesce(sum(i.amt) filter (where i.due < current_date), 0)::bigint,
         sum(i.paid)::bigint,
         coalesce(max(h.held_minor), 0)::bigint,
         min(i.due) filter (where i.amt > 0),
         count(distinct i.document_id) filter (where i.amt > 0)::integer
    from items i
    join erp.party p on p.id = i.party_id
    left join held h on h.party_id = i.party_id
   group by i.party_id, p.code, p.name, i.currency
  having sum(i.amt) <> 0 or coalesce(max(h.held_minor), 0) <> 0
   order by 5 desc
$$;

create or replace function erp.payables_ageing(p_as_at date default null)
returns table (
  party_id uuid, party_name text, currency char(3),
  not_due_minor bigint, days_1_30_minor bigint, days_31_60_minor bigint,
  days_61_90_minor bigint, days_90_plus_minor bigint, total_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  with open_items as (
    select si.party_id, si.currency,
           si.credit_minor - si.debit_minor as amt,
           coalesce(si.due_date, si.posting_date) as due
      from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'payable'
       and si.party_id is not null
  )
  select o.party_id, p.name, o.currency,
         coalesce(sum(o.amt) filter (where o.due >= coalesce(p_as_at, current_date)), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 1 and 30), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 31 and 60), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 61 and 90), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due > 90), 0)::bigint,
         sum(o.amt)::bigint
    from open_items o
    join erp.party p on p.id = o.party_id
   group by o.party_id, p.name, o.currency
  having sum(o.amt) <> 0
   order by 9 desc
$$;

create or replace function erp.payment_proposal_lines(p_proposal_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_id', l.id,
           'supplier', p.name,
           'document_number', d.document_number,
           'amount_minor', l.amount_minor,
           'due_date', l.due_date,
           'held', l.is_held,
           'hold_reason', l.hold_reason)
         order by l.is_held, l.due_date nulls last), '[]'::jsonb)
    from erp.payment_proposal_line l
    left join erp.party p on p.id = l.party_id
    left join erp.document d on d.id = l.document_id
   where l.tenant_id = erp.current_tenant_id()
     and l.payment_proposal_id = p_proposal_id
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. An organisation has this on the day it is made
-- ═════════════════════════════════════════════════════════════════════════════

do $backfill$
declare v_src text; v_needle text;
begin
  v_src := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_needle := '  -- Receivables is where cash application''s posting rule lives.';
  if position(v_needle in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.ensure_demo_configuration is not the deployed body';
  end if;
  if position('procurement-controls' in v_src) > 0 then
    return;
  end if;

  execute replace(v_src, v_needle,
       E'  -- Procurement controls own the supplier bill and the payment rule. An\n'
    || E'  -- organisation without them accrues goods received not invoiced for ever.\n'
    || E'  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = ''procurement-controls'') then\n'
    || E'    perform erp.configure_procurement_controls();\n'
    || E'    v_did := v_did || ''"procurement controls"''::jsonb;\n'
    || E'  elsif exists (select 1 from erp.module_installation i where i.tenant_id = p_tenant_id and i.install_code = ''procurement-controls'')\n'
    || E'        and exists (select 1 from erp.plan_module_upgrade(''procurement-controls'')) then\n'
    || E'    perform erp.upgrade_module_configuration(''procurement-controls'');\n'
    || E'    v_did := v_did || ''"procurement controls upgraded"''::jsonb;\n'
    || E'  end if;\n\n' || v_needle);
end
$backfill$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_bill_from_receipt(
  p_receipt_id uuid,
  p_their_reference text default null,
  p_invoice_date date default null,
  p_due_date date default null)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_id uuid;
begin
  v_id := erp.bill_from_receipt(p_receipt_id, p_their_reference, p_invoice_date, p_due_date, true);
  return (select jsonb_build_object(
                   'document_id', d.id, 'document_number', d.document_number,
                   'due_date', d.due_date)
            from erp.document d where d.id = v_id);
end;
$$;

create or replace function public.erp_pay_payment_run(p_proposal_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select erp.pay_payment_run(p_proposal_id)
$$;

create or replace function public.erp_supplier_balances()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'party_id', b.party_id, 'party_code', b.party_code, 'party', b.party_name,
           'currency', b.currency, 'owing_minor', b.owing_minor,
           'overdue_minor', b.overdue_minor, 'paid_minor', b.paid_minor,
           'held_minor', b.held_minor, 'oldest_due_date', b.oldest_due,
           'open_documents', b.open_documents)
         order by b.owing_minor desc), '[]'::jsonb)
    from erp.supplier_balances() b
$$;

create or replace function public.erp_payables_ageing(p_as_at date default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'party_id', a.party_id, 'party', a.party_name, 'currency', a.currency,
           'not_due_minor', a.not_due_minor, 'days_1_30_minor', a.days_1_30_minor,
           'days_31_60_minor', a.days_31_60_minor, 'days_61_90_minor', a.days_61_90_minor,
           'days_90_plus_minor', a.days_90_plus_minor, 'total_minor', a.total_minor)
         order by a.total_minor desc), '[]'::jsonb)
    from erp.payables_ageing(p_as_at) a
$$;

create or replace function public.erp_payment_proposal_lines(p_proposal_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select erp.payment_proposal_lines(p_proposal_id)
$$;

do $grants$
declare f text;
begin
  foreach f in array array[
    'erp_bill_from_receipt(uuid, text, date, date)',
    'erp_pay_payment_run(uuid)',
    'erp_supplier_balances()',
    'erp_payables_ageing(date)',
    'erp_payment_proposal_lines(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end
$grants$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_bill_from_receipt', 'erp.bill_from_receipt',
   'Raises the supplier''s bill from a posted goods receipt; authorises procurement.match, refuses an unposted receipt, and refuses to bill the same receipt twice.'),
  ('erp_pay_payment_run', 'erp.pay_payment_run',
   'Pays an approved payment run: bank credited, payables settled, bills marked paid; authorises finance.post and refuses a run that is unapproved or already paid.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_bill_from_receipt']);
select erp_meta.add_help_actions('/finance', array[
  'erp_pay_payment_run', 'erp_supplier_balances', 'erp_payables_ageing',
  'erp_payment_proposal_lines']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'placeholder-to-be-replaced'
  from (values ('x')) as t(text) where false;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
  ('payment.made', 1, 'posting', 'finance', 'event.payment.made',
   'A supplier was paid from an approved payment run: the bank was credited and the payable settled.',
   '{"type":"object","required":["reference","value_minor","currency"],
     "properties":{"reference":{"type":"string"},"posting_rule":{"type":"string"},
                   "value_minor":{"type":"integer"},"currency":{"type":"string"},
                   "party_id":{"type":"string"},"document_id":{"type":"string"}}}', true)
on conflict (code, version) do update
  set description = excluded.description, payload_schema = excluded.payload_schema,
      is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.payment.made', 'en', 'Supplier paid', 'finance'),
  ('event.payment.made', 'de', 'Lieferant bezahlt', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Bill a receipt'),
    ('The supplier''s bill, raised from a posted goods receipt: the quantities and the prices are what arrived, not what somebody typed.'),
    ('Supplier''s invoice number'),
    ('Invoice date'),
    ('Due date'),
    ('Purchase invoices'),
    ('The supplier''s bill. Registering one clears the goods-received accrual and puts the balance on the supplier.'),
    ('No supplier bills yet. Bill a posted goods receipt from the actions above.'),
    ('Pay an approved run'),
    ('Supplier balances'),
    ('What is owed to each supplier, what is overdue, what has been paid, and what a match exception is holding back.'),
    ('Nothing is owed to a supplier. Registering a supplier bill puts a balance here; paying an approved run clears it.'),
    ('Payables ageing'),
    ('What is owed to suppliers, banded by how overdue it is.'),
    ('Nothing outstanding to suppliers. A registered supplier bill appears here, banded by how close its due date is.'),
    ('Owed to suppliers'),
    ('Supplier'),
    ('Owed'),
    ('Overdue'),
    ('Paid'),
    ('Held'),
    ('Oldest due'),
    ('Open bills'),
    ('Currency'),
    ('Not due'),
    ('1–30'),
    ('31–60'),
    ('61–90'),
    ('90+'),
    ('Total')
  ) as t(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Proof: the supplier journey, end to end
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.supplier_bill_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth1 uuid := gen_random_uuid();
  v_auth2 uuid := gen_random_uuid();
  v_second uuid; v_tok2 text; res jsonb;
  v_entity uuid; v_site uuid; v_uom uuid; v_loc uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_grn2 uuid; v_inv uuid; v_prop uuid;
  v_pay jsonb; v_ok boolean; v_msg text; v_payable bigint; v_grni bigint;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzbill', 'Supplier Bill Suite', 'admin@zzbill.test', 'Bill Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth1, 'admin@zzbill.test'), (v_auth2, 'second@zzbill.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth1)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    res := public.erp_invite_principal('second@zzbill.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok2 := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth2)::text, true);
    perform erp.claim_invitation(v_tok2);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth1)::text, true);

    -- 1. The configuration an organisation is made with.
    return query select 'a new organisation can bill and pay a supplier the day it is made',
      exists (select 1 from erp.document_type t where t.tenant_id = v_tenant and t.code = 'purchase_invoice')
      and exists (select 1 from erp.posting_rule pr where pr.tenant_id = v_tenant
                    and pr.code = 'supplier_payment' and pr.status = 'active'),
      'the purchase invoice type and the supplier payment rule are installed';

    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (v_tenant, v_entity, 'ZMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select l.id into v_loc from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site
      and l.location_type = 'receiving' and l.status = 'active' order by l.code limit 1;
    if v_loc is null then
      insert into erp.location (tenant_id, site_id, code, name, location_type, status)
      values (v_tenant, v_site, 'ZRECV', 'Receiving', 'receiving', 'active') returning id into v_loc;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (v_tenant, 'ZEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZSUP', 'Bill Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (v_tenant, 'ZWID', 'Bill Suite Widget', v_uom, 100, 'active') returning id into v_item;

    -- Ordered, sent, received, posted.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'widgets');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp.transition_document(v_po, 'approve', null);
    perform erp.transition_document(v_po, 'send', null);
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', null);

    select coalesce(sum(g.open_value_minor), 0) into v_grni
      from erp.grni_report() g where g.item_code = 'ZWID';
    return query select 'a posted receipt accrues goods received not invoiced',
      v_grni = 100000, format('%s accrued on a hundred units at a thousand', v_grni);

    -- 2. The bill, from what arrived.
    v_inv := erp.bill_from_receipt(v_grn, 'SUP-INV-1', current_date, current_date + 30, true);
    return query select 'the bill is raised from the receipt, priced at what arrived, and registered',
      (select count(*) from erp.document_line l where l.document_id = v_inv) = 1
      and (select coalesce(sum(l.net_minor), 0) from erp.document_line l where l.document_id = v_inv) = 100000
      and (select d.their_reference from erp.document d where d.id = v_inv) = 'SUP-INV-1'
      and (select s.code from erp.object_state os join erp.state s on s.id = os.current_state_id
            where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_inv) = 'registered',
      'one line, a hundred thousand, registered';

    -- 3. Registering clears the accrual and puts the money on the supplier.
    select coalesce(sum(g.open_value_minor), 0) into v_grni
      from erp.grni_report() g where g.item_code = 'ZWID';
    select coalesce(sum(si.credit_minor - si.debit_minor), 0) into v_payable
      from erp.subledger_item si where si.tenant_id = v_tenant and si.control_kind = 'payable';
    return query select 'registering the bill drains the accrual by exactly what it billed',
      v_grni = 0 and v_payable = 100000
      and exists (select 1 from erp.journal j
                    join erp.journal_line jl on jl.journal_id = j.id
                   where j.tenant_id = v_tenant and j.status = 'posted'
                     and j.source_code like '%purchase_invoice%'),
      format('accrual %s, payables %s', v_grni, v_payable);

    -- 4. An unposted receipt is not billed. Raised after the accrual is
    -- measured, because receiving against an order line moves the outstanding
    -- quantity whether or not the receipt has posted.
    v_grn2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn2, v_pol, 1, null);
    begin
      perform erp.bill_from_receipt(v_grn2, null, null, null, true);
      v_ok := false; v_msg := 'an unposted receipt was billed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_RECEIPT_NOT_POSTED:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a receipt that has not posted cannot be billed', v_ok, v_msg;

    -- 5. Not twice.
    begin
      perform erp.bill_from_receipt(v_grn, null, null, null, true);
      v_ok := false; v_msg := 'the same receipt was billed twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ALREADY_BILLED:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a receipt is billed once', v_ok, v_msg;

    -- 6. The supplier ledger.
    return query select 'the supplier balance and the ageing agree with the control account',
      (select b.owing_minor from erp.supplier_balances() b where b.party_code = 'ZSUP') = 100000
      and (select a.total_minor from erp.payables_ageing(null) a where a.party_id = v_sup) = 100000
      and (select coalesce(sum(a.total_minor), 0) from erp.payables_ageing(null) a) = v_payable,
      'a hundred thousand owed, and the buckets sum to the ledger';

    -- 7. Proposed.
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    return query select 'a payment run finds the bill and nothing holds it',
      (select pp.total_minor from erp.payment_proposal pp where pp.id = v_prop) = 100000
      and (select count(*) from erp.payment_proposal_line l
            where l.payment_proposal_id = v_prop and not l.is_held) = 1
      and jsonb_array_length(erp.payment_proposal_lines(v_prop)) = 1,
      format('total %s on %s line(s)',
             (select pp.total_minor from erp.payment_proposal pp where pp.id = v_prop),
             (select count(*) from erp.payment_proposal_line l where l.payment_proposal_id = v_prop));

    -- 8. Not before it is approved, and not by whoever proposed it.
    begin
      perform erp.pay_payment_run(v_prop);
      v_ok := false; v_msg := 'an unapproved run was paid';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAYMENT_NOT_APPROVED:%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform erp.approve_payment_run(v_prop);
      v_ok := false; v_msg := 'the proposer approved their own run';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_SEGREGATION_OF_DUTIES:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a run is paid only after somebody else has approved it', v_ok, v_msg;

    -- 9. Approved by the second person, then paid.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay := erp.pay_payment_run(v_prop);
    select coalesce(sum(si.credit_minor - si.debit_minor), 0) into v_payable
      from erp.subledger_item si where si.tenant_id = v_tenant and si.control_kind = 'payable';
    return query select 'paying the run credits the bank, settles the payable and marks the bill paid',
      (v_pay ->> 'paid_minor')::bigint = 100000
      and (v_pay ->> 'documents_settled')::integer = 1
      and v_payable = 0
      and (select coalesce(sum(si.credit_minor - si.debit_minor), 0) from erp.subledger_item si
            where si.tenant_id = v_tenant and si.control_kind = 'bank'
              and si.journal_id in (select j.id from erp.journal j
                                     where j.tenant_id = v_tenant and j.source_code = 'payment.made')) = 100000
      and (select s.code from erp.object_state os join erp.state s on s.id = os.current_state_id
            where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_inv) = 'paid'
      and (select pp.status::text from erp.payment_proposal pp where pp.id = v_prop) = 'paid',
      format('paid %s, payables %s', v_pay ->> 'paid_minor', v_payable);

    -- 10. Not twice.
    begin
      perform erp.pay_payment_run(v_prop);
      v_ok := false; v_msg := 'a run was paid twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PAYMENT_ALREADY_PAID:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a payment run is paid once', v_ok, v_msg;

    -- 11. And nothing is offered again.
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    return query select 'a later run finds nothing, because what was paid is settled',
      (select pp.total_minor from erp.payment_proposal pp where pp.id = v_prop) = 0
      and (select count(*) from erp.payment_proposal_line l where l.payment_proposal_id = v_prop) = 0
      and (select b.owing_minor from erp.supplier_balances() b where b.party_code = 'ZSUP') is null,
      'the supplier is square';

    -- 12. And the books still balance.
    return query select 'every journal this journey raised balances',
      not exists (
        select 1 from erp.journal j
          join erp.journal_line jl on jl.journal_id = j.id
         where j.tenant_id = v_tenant
         group by j.id
        having sum(jl.debit_minor) <> sum(jl.credit_minor)),
      'debits equal credits, journal by journal';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzbill');
  detail := 'the organisation, its bills and its payments rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_supplier_bill_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_total  integer;
  v_passed integer;
begin
  create temp table if not exists _supplier_bill_suite on commit drop as
    select * from erp_test.supplier_bill_suite();
  select count(*), count(*) filter (where passed) into v_total, v_passed
    from _supplier_bill_suite;
  if v_total <> c_expected or v_passed <> v_total then
    raise exception E'CLOVEERP_SUPPLIER_BILL_SUITE_FAILED: % of % case(s) passed\n%', v_passed, v_total,
      (select string_agg(format('  [%s] %s — %s', coalesce(passed::text, '?'), case_name, detail), E'\n')
         from _supplier_bill_suite)
      using detail = 'Read the cases above; a count that changed is changed deliberately.';
  end if;
  return format('supplier bill: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_supplier_bill_suite() from public, anon, authenticated;
revoke all on function erp_test.supplier_bill_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_supplier_bill_suite();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
