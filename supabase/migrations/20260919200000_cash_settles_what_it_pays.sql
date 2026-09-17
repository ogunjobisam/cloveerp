-- Cash settles what it pays.
--
-- A customer paid an invoice in full. The money was banked, the journal was
-- raised, the receivable was settled to the penny — and the invoice stayed
-- issued. Nothing in the product moved it to paid.
--
-- erp.apply_cash() writes the cash, the journal and erp.subledger_item's
-- settled_minor and stops there. The settle transition — issued → paid,
-- finance.post, declared since 20260904150000 — had exactly one caller in the
-- whole repository outside the suites and the state-machine payloads: the
-- demonstration seeder, which fires it by hand after applying cash. So the
-- seeded month looked right and every real organisation's did not. A customer
-- who paid everything they owed had an invoice that never closed, and because
-- paid is terminal and erp.ageing drops a document only when its state is
-- terminal, it sat on the ageing for ever. The v1 Definition of Done asks for
-- an order-to-cash case where AR clears to nil (O2C-01) and one that part-pays
-- (O2C-06); neither could be true of a document.
--
-- ── Where it belongs ─────────────────────────────────────────────────────────
--
-- Inside the cash, not beside it. A settlement that some later sweep performs
-- is a settlement that is wrong between the two, and the only moment anybody
-- knows a document was paid off is the moment the money was applied to it. So
-- erp.apply_cash() does it, in the same transaction, and if the transition
-- refuses the cash refuses with it.
--
-- One receipt can pay several documents — the allocation is oldest first
-- across every company the party owes — so the documents it touched are
-- collected as it goes and each is asked once, after the loop. After, because
-- settled_minor is written inside the loop and what a document owes is the sum
-- over all of its rows: asking halfway through would be asking about a receipt
-- that had not finished arriving.
--
-- The same step is called from the other two routes cash takes, because the
-- defect is the cash's and not the door's:
--
--   erp.apply_cash_to_item()  the settlement statement's route, which matches
--                             one payout line to one open item;
--   erp.pay_payment_run()     the purchase side.
--
-- ── The test for owing nothing ───────────────────────────────────────────────
--
-- There is one computation of what a document owes and this is not a second
-- one. 20260918500000 put it in erp.ageing_balance, which erp.ageing and both
-- ageing screens read and nothing else:
--
--     owed = the rows' net − greatest(0, settled − what the document's own
--                                          settling rows already took off)
--
-- exact for cash that named the document, cash that did not, and any mixture,
-- and the view carries only rows where it is not zero. So the question "does
-- this document owe anything?" is "has it a row in erp.ageing_balance?", asked
-- of the same arithmetic the report and the screens answer with, and an
-- organisation can never be told two different things about one invoice.
--
-- A penny short is a row, so a penny short does not settle. That is the whole
-- of the rounding argument: there is no tolerance anywhere in it.
--
-- A document with no receivable or payable detail at all is not settled
-- either. It has no row for the same reason a paid one has none, and the two
-- are not the same thing: one owes nothing because it was paid, the other
-- because nothing was ever posted for it.
--
-- ── Both sides ───────────────────────────────────────────────────────────────
--
-- The purchase side already moved. erp.pay_payment_run() has marked a bill
-- paid — registered → paid, finance.post — since 20260909212619. But it asked
-- its own question, and the question was wrong:
--
--     sum(credit_minor − debit_minor − settled_minor) over the document <= 0
--
-- The payment run writes both halves of a settlement: a settling row with the
-- payment as a debit, and settled_minor on the item it settled. That sum
-- subtracts the payment twice, so it reaches nil at half the bill. A bill paid
-- in part was marked paid: the document said settled, the creditors account
-- said money was still owed, and the next payment run would have offered the
-- rest of it for payment on a document that claimed to be closed. It is the
-- double count 20260918500000 named and did not have a caller to fix.
--
-- So both sides now ask the same step the same question, and the payment run
-- keeps its own count of the documents it closed.
--
-- ── Permission ───────────────────────────────────────────────────────────────
--
-- settle and pay both require finance.post, and so does applying the cash: the
-- caller has already been authorised for finance.post in the company that is
-- owed before a penny is written. The one gap is scope. erp.authorise() is
-- called by the cash with the company and no site, which any grant satisfies;
-- the transition is authorised with the document's company AND its site, which
-- a grant pinned to a different site does not. A finance clerk scoped to one
-- site can therefore bank a receipt that lands, oldest first, on an invoice
-- raised at another.
--
-- Settling as the system was the alternative and is refused: a definer routine
-- that performs a state transition nobody was authorised for is a hole in the
-- permission model for the sake of a convenience, and this product's rule is
-- that the database refuses regardless of the UI.
--
-- So the cash is applied, the document is left where it is, and the refusal is
-- recorded rather than swallowed: erp.log_access_decision() writes it to
-- erp.access_log against the document, granted false, naming finance.post and
-- saying the cash was applied and the document was not settled. That is the
-- register the product already keeps for exactly this — it is what
-- erp.authorise() itself writes on every refusal — so an administrator asking
-- why an invoice is still open finds the answer where they would look for it.
-- Nothing is caught and discarded: there is no exception handler anywhere in
-- this change.
--
-- ── History is not restated ──────────────────────────────────────────────────
--
-- Invoices that were paid in full before today and are still issued stay
-- issued. Settling them here would stamp today's date and today's actor on a
-- transition that belongs to the day the money arrived, in an append-only
-- state log, on every organisation at once — a migration inventing history
-- nobody performed. They will be settled when the next cash touches them, or
-- by a person on the document screen, where the transition has always been
-- offered. An organisation that wants its back book closed should be swept
-- deliberately, dated, by somebody who holds finance.post.
--
-- ── The seeder ───────────────────────────────────────────────────────────────
--
-- erp.seed_demo_history() applies cash and then looks for fully settled
-- invoices still issued, settles them, and closes seven in ten of the sales
-- orders whose invoice was paid. With the cash settling them itself that loop
-- would find nothing and the demonstration would stop closing orders. So it
-- reads issued or paid, and settles only what is still issued.
--
-- The order close is unchanged in intent and slightly wider in effect: an
-- invoice that is already paid stays in the loop's result for later receipts
-- to the same customer, so an order whose seven-in-ten roll failed gets
-- another roll rather than one. More of the demonstration's orders reach
-- closed and fewer sit at invoiced. Both states were always expected of it —
-- erp_test.demo_configuration_suite() admits either — and an order left open
-- behind a paid invoice was never the point of the demonstration.
--
-- sales_order.close is one of four transitions in the position this one was in
-- and is not fixed here.
--
-- ── Collateral, restated with the reason ─────────────────────────────────────
--
--   docs figures: one migration, one suite, one catalogue check.
--
-- Nothing else moves. The suites that apply cash to a party with no document
-- (erp_test.document_value_and_cash_suite) settle nothing, because there is no
-- document to settle; the suite that part-pays (erp_test.ageing_suite) is a
-- penny short of everything by construction; and the payment run's own suite
-- pays in full, which reached paid before and reaches it now.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The live bodies this migration restates
-- ═════════════════════════════════════════════════════════════════════════════

-- Each is the body its own migration wrote whole, with no patch since. Said
-- against the database rather than assumed from the files: a restatement built
-- on a body that has moved is a silent undo.
do $anchors$
declare
  v_cash    text := pg_catalog.pg_get_functiondef('erp.apply_cash(uuid,bigint,character,text,date)'::regprocedure);
  v_item    text := pg_catalog.pg_get_functiondef('erp.apply_cash_to_item(uuid,bigint,text,date)'::regprocedure);
  v_run     text := pg_catalog.pg_get_functiondef('erp.pay_payment_run(uuid)'::regprocedure);

  v_hits integer;
  function_anchor text;
begin
  -- erp.apply_cash(), as 20260906145000 left it.
  foreach function_anchor in array array[
    'CLOVEERP_NO_BANK_ACCOUNT: % is owed this cash and has no bank account for it to land in',
    'v_journals := v_journals || jsonb_build_object(v_entity::text, v_journal);',
    'order by coalesce(si.due_date, si.posting_date), si.id',
    'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
  ] loop
    v_hits := (length(v_cash) - length(replace(v_cash, function_anchor, ''))) / length(function_anchor);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_APPLY_CASH_UNRECOGNISED: erp.apply_cash() carries "%" % time(s), not once', function_anchor, v_hits
        using hint = 'Read the live body with pg_get_functiondef and write the restatement against it under a new migration version.';
    end if;
  end loop;

  -- erp.apply_cash_to_item(), as 20260906137000 left it.
  foreach function_anchor in array array[
    'CLOVEERP_CASH_EXCEEDS_OWING: % is owed on this item and % was received',
    'CLOVEERP_NOT_A_RECEIVABLE: % is not an open receivable item',
    'v_owing := si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0);'
  ] loop
    v_hits := (length(v_item) - length(replace(v_item, function_anchor, ''))) / length(function_anchor);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_APPLY_CASH_TO_ITEM_UNRECOGNISED: erp.apply_cash_to_item() carries "%" % time(s), not once', function_anchor, v_hits
        using hint = 'Read the live body with pg_get_functiondef and write the restatement against it under a new migration version.';
    end if;
  end loop;

  -- erp.pay_payment_run(), as 20260909212619 left it, including the test this
  -- migration replaces: if it is not there, the arithmetic has already moved.
  foreach function_anchor in array array[
    'CLOVEERP_NO_BANK_ACCOUNT: the money has nowhere to leave from',
    'CLOVEERP_PAYMENT_ALREADY_PAID: % was paid already',
    'perform erp.transition_document(si.document_id, ''pay'', ''paid on '' || pp.reference);',
    'and x.document_id = si.document_id), 0) <= 0'
  ] loop
    v_hits := (length(v_run) - length(replace(v_run, function_anchor, ''))) / length(function_anchor);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_PAY_PAYMENT_RUN_UNRECOGNISED: erp.pay_payment_run() carries "%" % time(s), not once', function_anchor, v_hits
        using hint = 'Read the live body with pg_get_functiondef and write the restatement against it under a new migration version.';
    end if;
  end loop;

end
$anchors$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The step: a document that owes nothing says so
-- ═════════════════════════════════════════════════════════════════════════════

-- "What does this document owe?" is now asked on every receipt and every line
-- of every payment run, and erp.subledger_item was indexed by control account
-- and by party, never by document. Without this the question is a scan of the
-- organisation's whole subledger, several hundred times over a seeded month.
create index if not exists subledger_item_tenant_document_idx
  on erp.subledger_item (tenant_id, document_id)
  where document_id is not null;

create or replace function erp.settle_paid_document(
  p_document_id uuid, p_reason text default null)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_code      text;
  v_permitted boolean;
  v_guard     boolean;
  v_entity    uuid;
  v_site      uuid;
begin
  if p_document_id is null then
    return false;
  end if;

  -- A document with no receivable or payable detail owes nothing because
  -- nothing was ever posted for it, which is not the same as having been paid.
  if not exists (
    select 1 from erp.subledger_item si
     where si.tenant_id = v_tenant and si.document_id = p_document_id
       and si.control_kind in ('receivable', 'payable'))
  then
    return false;
  end if;

  -- What it owes, from the one computation of what is owed (20260918500000).
  -- erp.ageing_balance carries a row only where that is not zero, so a row is
  -- a penny still outstanding and there is no tolerance in the comparison.
  if exists (
    select 1 from erp.ageing_balance b
     where b.tenant_id = v_tenant and b.document_id = p_document_id)
  then
    return false;
  end if;

  -- The move this document's own lifecycle declares out of where it is:
  -- settle for a sales invoice, pay for a bill, and nothing at all for a
  -- document already paid, credited or cancelled. Read from the state machine
  -- rather than from a list here, so an organisation that promoted its own
  -- lifecycle is answered by its own.
  select t.transition_code, t.permitted, t.guard_passes
    into v_code, v_permitted, v_guard
    from erp.available_transitions('document', p_document_id) t
   where t.transition_code in ('settle', 'pay')
   order by t.transition_code
   limit 1;

  if v_code is null or not coalesce(v_guard, true) then
    return false;
  end if;

  if not coalesce(v_permitted, false) then
    -- The cash is applied and the document is left where it is, because the
    -- caller may post in this company and not at this site. Recorded where
    -- every other refusal of a permission is recorded, so that an invoice
    -- still open after a receipt has an answer somebody can find, rather than
    -- being caught and thrown away.
    select os.entity_id, os.site_id into v_entity, v_site
      from erp.object_state os
     where os.tenant_id = v_tenant and os.object_type = 'document'
       and os.object_id = p_document_id;

    perform erp.log_access_decision(
      'finance.post', false, v_entity, v_site, null, 'document', p_document_id,
      format('cash left nothing owing and the document was not %s: no matching grant', v_code));
    return false;
  end if;

  perform erp.transition_document(
    p_document_id, v_code,
    coalesce(p_reason, 'settled by the cash applied to it'));
  return true;
end;
$$;

comment on function erp.settle_paid_document(uuid, text) is
  'Moves a document to paid when the cash applied to it has left nothing '
  'owing, and returns whether it did. What is owed is read from '
  'erp.ageing_balance, the one computation the report and both ageing screens '
  'read, so a document one penny short is not settled. The move is the one the '
  'document''s own lifecycle declares — settle for an invoice, pay for a bill '
  '— performed as the caller. A caller who may not perform it leaves the '
  'document where it is and the refusal is written to erp.access_log '
  '(20260919200000).';

revoke all on function erp.settle_paid_document(uuid, text) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The three routes cash takes
-- ═════════════════════════════════════════════════════════════════════════════

-- ── The receipt ──────────────────────────────────────────────────────────────

create or replace function erp.apply_cash(
  p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text, p_received_on date)
returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_left   bigint := p_amount_minor;
  r        record;
  v_take   bigint;
  v_bank   uuid;
  v_journal uuid;
  v_event  uuid;
  v_rule   uuid;
  v_rule_version integer;
  v_no     integer;
  -- One journal per company owed, kept by company id. A receipt that settles
  -- two companies' invoices is two journals in two ledgers, because it is two
  -- companies' cash and each one's books have to stand alone.
  v_journals jsonb := '{}'::jsonb;
  v_banks    jsonb := '{}'::jsonb;
  v_events   jsonb := '{}'::jsonb;
  v_entity uuid;
  -- The documents this receipt touched, once each: a receipt that pays
  -- two invoices has two to settle, and one that pays an invoice twice
  -- has one.
  v_docs   uuid[] := '{}'::uuid[];
  v_doc    uuid;
begin
  -- A receipt has a date, and it is not in the future. Cash that arrives
  -- tomorrow is a forecast, and a forecast in the bank subledger is a lie the
  -- reconciliation would then have to explain.
  if p_received_on is null or p_received_on > current_date then
    raise exception
      'CLOVEERP_CASH_DATE_INVALID: a receipt is dated the day it arrived, which '
      'is % and not after today', coalesce(p_received_on::text, 'null')
      using errcode = '22007',
      hint = 'Pass the date the money reached the bank, or omit it and today is used.';
  end if;

  perform erp.authorise('finance.post', null, null, null, 'party', p_party_id);

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application'
     and pr.status = 'active'
   order by pr.version desc limit 1;

  if v_rule is null then
    raise exception
      'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503',
      hint = 'erp.configure_receivables() installs it. B7 refuses a journal '
             'line that cannot name the rule that produced it.';
  end if;

  -- Oldest first, which is the only allocation defensible without an
  -- instruction from the customer, and across every company the party owes:
  -- the oldest invoice is the oldest invoice whoever it was raised by.
  -- Settled amounts are excluded, so a second receipt sees only what is
  -- genuinely still owed.
  for r in
    select si.id, si.entity_id, si.ledger_id, si.document_id,
           si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) as owing,
           si.control_account_id
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.party_id = p_party_id
       and si.control_kind = 'receivable' and si.currency = p_currency
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
     order by coalesce(si.due_date, si.posting_date), si.id
  loop
    exit when v_left <= 0;
    v_take := least(v_left, r.owing);
    v_entity := r.entity_id;
    if r.document_id is not null and not (r.document_id = any (v_docs)) then
      v_docs := v_docs || r.document_id;
    end if;

    -- The bank the money reached is the bank of the company that is owed.
    v_bank := nullif(v_banks ->> v_entity::text, '')::uuid;
    if v_bank is null then
      select a.id into v_bank from erp.account a
       where a.tenant_id = v_tenant and a.entity_id = v_entity
         and a.control_kind = 'bank' and a.status = 'active'
       order by a.code limit 1;

      if v_bank is null then
        raise exception 'CLOVEERP_NO_BANK_ACCOUNT: % is owed this cash and has no bank account for it to land in',
          coalesce((select e.code from erp.entity e where e.id = v_entity), v_entity::text)
          using errcode = '23503',
                hint = 'Give the company a postable account with control kind bank; cash is not banked in another company''s name.';
      end if;
      v_banks := v_banks || jsonb_build_object(v_entity::text, v_bank);
    end if;

    -- Each company's cash is authorised in that company.
    perform erp.authorise('finance.post', v_entity, null, null, 'party', p_party_id);

    v_journal := nullif(v_journals ->> v_entity::text, '')::uuid;
    if v_journal is null then
      v_event := erp.append_event(
        'document.posted', 'document', p_party_id,
        jsonb_build_object(
          'document_number', coalesce(p_reference, 'cash receipt'),
          'posting_rule', 'cash_application',
          'value_minor', p_amount_minor,
          'currency', p_currency,
          'entity_id', v_entity));

      insert into erp.journal (
        tenant_id, entity_id, ledger_id, source_code, source_event_id,
        posting_date, description, status)
      values (v_tenant, v_entity, r.ledger_id, 'cash.applied', v_event,
              p_received_on,
              format('Cash received from customer %s', coalesce(p_reference, '')),
              'draft')
      returning id into v_journal;

      v_journals := v_journals || jsonb_build_object(v_entity::text, v_journal);
      v_events   := v_events   || jsonb_build_object(v_entity::text, v_event);
    else
      v_event := (v_events ->> v_entity::text)::uuid;
    end if;

    select coalesce(max(jl.line_no), 0) into v_no
      from erp.journal_line jl where jl.journal_id = v_journal;

    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate,
      posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no + 1, v_bank, v_take, 0, p_currency,
            v_take, 0, 1, v_rule, v_rule_version, v_event, 'cash received'),
           (v_tenant, v_journal, v_no + 2, r.control_account_id, 0, v_take,
            p_currency, 0, v_take, 1, v_rule, v_rule_version, v_event,
            'applied to receivable');

    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, v_entity, r.ledger_id, 'receivable', r.control_account_id,
            p_party_id, v_journal, p_currency, 0, v_take, p_received_on),
           (v_tenant, v_entity, r.ledger_id, 'bank', v_bank,
            null, v_journal, p_currency, v_take, 0, p_received_on);

    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_take,
           updated_at = now()
     where id = r.id;

    subledger_item_id := r.id;
    applied_minor := v_take;
    v_left := v_left - v_take;
    remaining_minor := v_left;
    return next;
  end loop;

  update erp.journal
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where tenant_id = v_tenant
     and id in (select (jsonb_each_text(v_journals)).value::uuid);

  -- And the documents the cash paid off say so. After the loop, because
  -- settled_minor is written inside it and what a document owes is the
  -- sum over all of its rows: asking halfway through would ask about a
  -- receipt that was not finished arriving.
  foreach v_doc in array v_docs loop
    perform erp.settle_paid_document(
      v_doc, format('settled by %s', coalesce(p_reference, 'cash received')));
  end loop;

  if v_left > 0 then
    subledger_item_id := null;
    applied_minor := 0;
    remaining_minor := v_left;
    return next;
  end if;
end;
$$;

-- ── The settlement statement's route ─────────────────────────────────────────

create or replace function erp.apply_cash_to_item(p_subledger_item_id uuid, p_amount_minor bigint,
                                                  p_reference text, p_received_on date default current_date)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  si       erp.subledger_item%rowtype;
  v_owing  bigint;
  v_bank   uuid;
  v_rule   uuid;
  v_rule_version integer;
  v_event  uuid;
  v_journal uuid;
begin
  if p_received_on is null or p_received_on > current_date then
    raise exception 'CLOVEERP_CASH_DATE_INVALID: a receipt is dated the day it arrived, which is % and not after today',
      coalesce(p_received_on::text, 'null')
      using errcode = '22007', hint = 'Pass the date the money reached the bank.';
  end if;

  select * into si from erp.subledger_item x where x.tenant_id = v_tenant and x.id = p_subledger_item_id for update;
  if not found or si.control_kind <> 'receivable' then
    raise exception 'CLOVEERP_NOT_A_RECEIVABLE: % is not an open receivable item', p_subledger_item_id
      using errcode = '23503', hint = 'Cash settles a receivable subledger item; erp_receivables_ageing() lists them.';
  end if;

  perform erp.authorise('finance.post', si.entity_id, null, null, 'party', si.party_id);

  v_owing := si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0);
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'CLOVEERP_CASH_AMOUNT_INVALID: a receipt is a positive amount, not %', p_amount_minor
      using errcode = '22023', hint = 'Pass the amount received in minor units.';
  end if;
  if p_amount_minor > v_owing then
    raise exception 'CLOVEERP_CASH_EXCEEDS_OWING: % is owed on this item and % was received', v_owing, p_amount_minor
      using errcode = '23514',
            hint = 'Apply what the item owes here and the rest as unallocated cash through erp_apply_cash().';
  end if;

  select a.id into v_bank from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = si.entity_id
     and a.control_kind = 'bank' and a.status = 'active'
   order by a.code limit 1;
  if v_bank is null then
    raise exception 'CLOVEERP_NO_BANK_ACCOUNT: cash has nowhere to land'
      using errcode = '23503', hint = 'The finance installer creates the bank account; run it for this company.';
  end if;

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503', hint = 'erp.configure_receivables() installs it.';
  end if;

  v_event := erp.append_event(
    'document.posted', 'document', coalesce(si.document_id, si.party_id),
    jsonb_build_object('document_number', coalesce(p_reference, 'cash receipt'),
                       'posting_rule', 'cash_application',
                       'value_minor', p_amount_minor, 'currency', si.currency),
    si.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date, description, status)
  values (v_tenant, si.entity_id, si.ledger_id, 'cash.applied', v_event, p_received_on,
          format('Cash received %s', coalesce(p_reference, '')), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_bank, p_amount_minor, 0, si.currency, p_amount_minor, 0, 1,
          v_rule, v_rule_version, v_event, 'cash received'),
         (v_tenant, v_journal, 2, si.control_account_id, 0, p_amount_minor, si.currency, 0, p_amount_minor, 1,
          v_rule, v_rule_version, v_event, 'applied to receivable');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
  values (v_tenant, si.entity_id, si.ledger_id, 'receivable', si.control_account_id,
          si.party_id, si.document_id, v_journal, si.currency, 0, p_amount_minor, p_received_on),
         (v_tenant, si.entity_id, si.ledger_id, 'bank', v_bank,
          null, null, v_journal, si.currency, p_amount_minor, 0, p_received_on);

  update erp.subledger_item
     set settled_minor = coalesce(settled_minor, 0) + p_amount_minor, updated_at = now()
   where id = si.id;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  -- This route names the document it settles, so there is one to ask
  -- about; a statement line matched to an item that carries no document
  -- settles nothing and says nothing, which is right.
  perform erp.settle_paid_document(
    si.document_id, format('settled by %s', coalesce(p_reference, 'cash received')));

  return v_journal;
end;
$$;

-- ── The purchase side ────────────────────────────────────────────────────────

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
    --
    -- What it owes is now asked of the one arithmetic. The sum this used to
    -- take counted a payment twice — once as the settling row it had just
    -- written and once again in settled_minor — so it reached nil at half the
    -- bill, and a bill paid in part was marked paid.
    if erp.settle_paid_document(si.document_id, 'paid on ' || pp.reference) then
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

comment on function erp.apply_cash(uuid, bigint, character, text, date) is
  'Applies a receipt against a party''s open receivables, oldest first across '
  'every company the party owes. Each company''s share is posted in that '
  'company''s ledger against its own bank account, because cash banked in '
  'another company''s name is a receipt that reconciles nowhere. A document '
  'the receipt leaves owing nothing is settled in the same transaction '
  '(20260919200000).';

comment on function erp.pay_payment_run(uuid) is
  'Pays an approved payment run: the bank is credited, each payable settled, '
  'and a bill that owes nothing is marked paid — owing nothing read from '
  'erp.ageing_balance, so a bill paid in part stays registered '
  '(20260919200000). Held lines are never paid.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The demonstration still closes its orders
-- ═════════════════════════════════════════════════════════════════════════════

-- The seeder settled by hand what the cash now settles itself, and its order
-- close hung off that loop finding something. It reads issued or paid, and
-- settles only what is still issued.
do $seeder$
declare
  v_sig    constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def    text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := $n$           and erp.object_current_state('document', si.document_id) = 'issued'
      loop
        perform erp.transition_document(r.document_id, 'settle', 'demonstration');
$n$;
  v_new    text;
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: % settles a paid invoice by hand % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  v_new := replace(v_def, v_needle,
    $r$           and erp.object_current_state('document', si.document_id) in ('issued', 'paid')
      loop
        -- The cash settles it now (20260919200000). This stands for a document
        -- settled by some route that does not, and for nothing else.
        if erp.object_current_state('document', r.document_id) = 'issued' then
          perform erp.transition_document(r.document_id, 'settle', 'demonstration');
        end if;
$r$);

  -- The patches this body already carries, still there afterwards.
  if position($p$extract(isodow from v_day) = 1$p$ in v_new) = 0            -- 20260918600000
     or position($p$extract(isodow from v_day) = 2$p$ in v_new) = 0         -- 20260918220000
     or position($p$extract(isodow from v_day) = 3$p$ in v_new) = 0         -- 20260918100000
     or position($p$extract(isodow from v_day) = 5$p$ in v_new) = 0         -- 20260918220000
     or position('erp.raise_supplier_credit_note(' in v_new) = 0
     or position('erp.raise_customer_credit_note(' in v_new) = 0
     or position('erp.invoice_against(' in v_new) = 0
     or position('erp.create_receipt_from_order(' in v_new) = 0
     or position('erp.create_delivery_from_order(' in v_new) = 0
     or position($p$and rr.relation_kind = 'returns')$p$ in v_new) = 0      -- 20260918700000
     or position($p$perform erp.transition_document(ln.so_id, 'close', 'demonstration');$p$ in v_new) = 0 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: the patched body of % has lost something it carried', v_sig;
  end if;

  execute v_new;
end
$seeder$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.cash_settlement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_second uuid; v_tok2 text;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_loc uuid; v_uom uuid; v_ccy char(3);
  v_cust uuid; v_supp uuid; v_item uuid;
  v_inv uuid; v_inv2 uuid; v_gross bigint; v_gross2 bigint;
  v_po uuid; v_pol uuid; v_grn uuid; v_bill uuid;
  v_po2 uuid; v_pol2 uuid; v_grn2 uuid; v_bill2 uuid;
  v_prop uuid; v_pay jsonb; v_pay2 jsonb; v_pay3 jsonb;
  v_owed bigint; v_scr bigint; v_bal bigint;
  v_s1 text;
  v_t1 text; v_t2 text; v_t3 text; v_t4 text;
begin
  begin
    v_step := 'an organisation that can invoice, bill, bank a receipt and pay a supplier';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzstl-' || v_tag, 'Cash Settlement Suite',
      'admin@zzstl-' || v_tag || '.test', 'Cash Settlement Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzstl-' || v_tag || '.test'),
           (a2, 'second@zzstl-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    -- A payment run is approved by somebody other than whoever proposed it, so
    -- the fixture needs two people before it can pay a supplier at all.
    v_step := 'a second administrator, because a payment run is not approved by its proposer';
    res := public.erp_invite_principal('second@zzstl-' || v_tag || '.test', 'Cash Settlement Second');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok2 := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, customer, supplier and product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZSMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select l.id into v_loc from erp.location l
     where l.tenant_id = rb.tenant_id and l.site_id = v_site
       and l.location_type = 'receiving' and l.status = 'active' order by l.code limit 1;
    if v_loc is null then
      insert into erp.location (tenant_id, site_id, code, name, location_type, status)
      values (rb.tenant_id, v_site, 'ZSRECV', 'Goods in', 'receiving', 'active') returning id into v_loc;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZSEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZSCUST', 'Cash Settlement Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZSSUP', 'Cash Settlement Supplier', 'active') returning id into v_supp;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_supp, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZSWID', 'Cash Settlement Widget', v_uom, 'active') returning id into v_item;

    -- ── 1. An invoice paid in full ──────────────────────────────────────────
    v_step := 'an invoice issued and paid in full';
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                 current_date, v_ccy, 'ZSTL-INV-1', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 100000, 'a sale the customer pays in full');
    perform erp.transition_document(v_inv, 'issue', 'cash settlement suite');
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_inv;
    perform erp.apply_cash(v_cust, v_gross, v_ccy, 'ZSTL-RECEIPT-1', current_date);
    v_s1 := erp.object_current_state('document', v_inv);

    v_cases := v_cases + 1;
    case_name := 'a customer who pays an invoice in full leaves an invoice that is paid, where it used to stay issued for ever';
    passed := v_state is null and v_gross > 0 and v_s1 = 'paid';
    detail := coalesce(v_state, format('%s of %s received, the invoice is %s', v_gross, v_gross, v_s1));
    return next;

    -- ── 2. And the subledger says nothing is owed on it ─────────────────────
    select coalesce(sum(b.outstanding_minor), 0) into v_owed
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.document_id = v_inv;
    select coalesce(sum(si.debit_minor - si.credit_minor), 0) into v_bal
      from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv
       and si.control_kind = 'receivable';

    v_cases := v_cases + 1;
    case_name := 'and the subledger owes nothing on it: the receipt and the invoice net to nil, by the same arithmetic the ageing reads';
    passed := v_state is null and v_owed = 0 and v_bal = 0;
    detail := coalesce(v_state, format('%s outstanding, %s net on the receivable rows', v_owed, v_bal));
    return next;

    -- ── 3. And the ageing has stopped carrying it ───────────────────────────
    v_cases := v_cases + 1;
    case_name := 'and neither the ageing report nor the receivables screen carries it any longer';
    passed := v_state is null
          and not exists (select 1 from erp.ageing a
                           where a.tenant_id = rb.tenant_id and a.id = v_inv)
          and not exists (select 1 from erp.receivables_ageing() s where s.party_id = v_cust);
    detail := coalesce(v_state, format('%s report row(s) and %s screen row(s) for a customer who owes nothing',
      (select count(*) from erp.ageing a where a.tenant_id = rb.tenant_id and a.id = v_inv),
      (select count(*) from erp.receivables_ageing() s where s.party_id = v_cust)));
    return next;

    -- ── 4. A penny short is not paid ────────────────────────────────────────
    v_step := 'a second invoice, paid all but a penny';
    v_inv2 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZSTL-INV-2', '{}'::jsonb);
    perform erp.add_document_line(v_inv2, v_item, 1, 50000, 'a sale the customer nearly pays');
    perform erp.transition_document(v_inv2, 'issue', 'cash settlement suite');
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    perform erp.apply_cash(v_cust, v_gross2 - 1, v_ccy, 'ZSTL-RECEIPT-2', current_date);
    v_s1 := erp.object_current_state('document', v_inv2);
    select coalesce(sum(b.outstanding_minor), 0) into v_owed
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.document_id = v_inv2;
    select coalesce(sum(s.total_minor), 0) into v_scr
      from erp.receivables_ageing() s where s.party_id = v_cust;

    v_cases := v_cases + 1;
    case_name := 'an invoice one penny short of paid is not settled, and the penny is still on the ageing and on the screen';
    passed := v_state is null and v_s1 = 'issued' and v_owed = 1 and v_scr = 1;
    detail := coalesce(v_state, format('%s of %s received; the invoice is %s, owing %s, screen %s',
                                       v_gross2 - 1, v_gross2, v_s1, v_owed, v_scr));
    return next;

    -- ── 5. And the penny pays it ────────────────────────────────────────────
    v_step := 'the last penny of the second invoice';
    perform erp.apply_cash(v_cust, 1, v_ccy, 'ZSTL-RECEIPT-3', current_date);
    v_s1 := erp.object_current_state('document', v_inv2);
    select coalesce(sum(s.total_minor), 0) into v_scr
      from erp.receivables_ageing() s where s.party_id = v_cust;

    v_cases := v_cases + 1;
    case_name := 'and the penny settles it: the customer owes nothing and no invoice of theirs is open';
    passed := v_state is null and v_s1 = 'paid' and v_scr = 0;
    detail := coalesce(v_state, format('the invoice is %s and the screen totals %s', v_s1, v_scr));
    return next;

    -- ── 6. The purchase side, paid in full ──────────────────────────────────
    v_step := 'a purchase order, a receipt and a bill';
    v_po := erp.open_document('purchase_order', v_supp, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 10, 1000, 'widgets');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'cash settlement suite');
    perform erp.transition_document(v_po, 'send', null);
    v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    v_bill := erp.bill_from_receipt(v_grn, 'ZSTL-BILL-1', current_date, current_date + 30, true);
    select dv.gross_minor::bigint into v_owed from erp.document_view dv where dv.id = v_bill;

    v_step := 'a payment run that pays the bill in full';
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_s1 := erp.object_current_state('document', v_bill);

    v_cases := v_cases + 1;
    case_name := 'a bill paid in full is paid, and the payment run counts it, as it has since the run was built';
    passed := v_state is null and v_s1 = 'paid'
          and (v_pay ->> 'documents_settled')::integer = 1
          and v_owed > 0 and (v_pay ->> 'paid_minor')::bigint = v_owed;
    detail := coalesce(v_state, format('the bill is %s; the run paid %s and closed %s document(s)',
                                       v_s1, v_pay ->> 'paid_minor', v_pay ->> 'documents_settled'));
    return next;

    -- ── 7. And a bill paid in part is not ───────────────────────────────────
    -- The run used to subtract the payment twice — once as the settling row it
    -- had just written, once again in settled_minor — so it reached nil at
    -- half the bill and marked a part-paid bill paid.
    v_step := 'a second bill, with a penny held back from the run that pays it';
    v_po2 := erp.open_document('purchase_order', v_supp, v_entity, v_site);
    v_pol2 := erp.add_document_line(v_po2, v_item, 10, 1000, 'more widgets');
    perform erp.transition_document(v_po2, 'submit', null);
    perform erp_test.approve_document(v_po2, 'cash settlement suite');
    perform erp.transition_document(v_po2, 'send', null);
    v_grn2 := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn2, v_pol2, 10, null);
    perform erp.transition_document(v_grn2, 'post', null);
    v_bill2 := erp.bill_from_receipt(v_grn2, 'ZSTL-BILL-2', current_date, current_date + 30, true);

    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    update erp.payment_proposal_line
       set amount_minor = amount_minor - 1
     where tenant_id = rb.tenant_id and payment_proposal_id = v_prop and not is_held;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay2 := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_s1 := erp.object_current_state('document', v_bill2);
    select coalesce(sum(b.outstanding_minor), 0) into v_owed
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.document_id = v_bill2;

    v_cases := v_cases + 1;
    case_name := 'a bill paid all but a penny stays registered and still owes the penny, where the run used to count the payment twice and call it paid';
    passed := v_state is null and v_s1 = 'registered' and v_owed = 1
          and (v_pay2 ->> 'documents_settled')::integer = 0;
    detail := coalesce(v_state, format('the bill is %s, owing %s; the run closed %s document(s)',
                                       v_s1, v_owed, v_pay2 ->> 'documents_settled'));
    return next;

    -- ── 8. And the penny pays it ────────────────────────────────────────────
    v_step := 'the penny that closes the second bill';
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay3 := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_s1 := erp.object_current_state('document', v_bill2);

    v_cases := v_cases + 1;
    case_name := 'and the run that pays the penny closes it: what a bill owes is the same question on the second payment as on the first';
    passed := v_state is null and v_s1 = 'paid'
          and (v_pay3 ->> 'paid_minor')::bigint = 1
          and (v_pay3 ->> 'documents_settled')::integer = 1;
    detail := coalesce(v_state, format('the bill is %s; the run paid %s and closed %s document(s)',
                                       v_s1, v_pay3 ->> 'paid_minor', v_pay3 ->> 'documents_settled'));
    return next;

    -- ── 9. The four ties ────────────────────────────────────────────────────
    v_step := 'the four ties, over an organisation that has invoiced, banked, billed and paid';
    v_t1 := erp.assert_trial_balance_balances();
    v_t2 := erp.assert_inventory_reconciles();
    v_t3 := erp.assert_subledger_reconciles();
    v_t4 := erp.assert_ageing_equals_control();

    v_cases := v_cases + 1;
    case_name := 'the four ties still hold: the trial balance, the inventory valuation, the subledgers and the ageing';
    passed := v_state is null
          and coalesce(v_t1, '') <> '' and coalesce(v_t2, '') <> ''
          and coalesce(v_t3, '') <> '' and coalesce(v_t4, '') <> '';
    detail := coalesce(v_state, format('%s; %s; %s; %s',
                                       left(coalesce(v_t1, 'nothing'), 60),
                                       left(coalesce(v_t2, 'nothing'), 60),
                                       left(coalesce(v_t3, 'nothing'), 60),
                                       left(coalesce(v_t4, 'nothing'), 60)));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzstl-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state, 'zzstl rolled back with its invoices, its receipts, its bills and its payment runs');
  return next;

  -- The count guard says what stopped the fixture. Without it the wrapper never
  -- sees a row, the message this suite caught into v_state never reaches the
  -- build log, and every break costs a run to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CASH_SETTLEMENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.cash_settlement_suite() from public, anon;

create or replace function erp_test.assert_cash_settlement_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 10;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _cash_settlement on commit drop as
    select * from erp_test.cash_settlement_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _cash_settlement;
  drop table _cash_settlement;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CASH_SETTLEMENT_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_CASH_SETTLEMENT_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('cash settles what it pays: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_cash_settlement_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_dead_configuration();

select erp_test.assert_cash_settlement_suite();
-- The two suites that apply cash by another route, proved here rather than
-- left to the catalogue: one banks a receipt against a party with no document
-- at all, the other part-pays and must still be part-paid.
select erp_test.assert_document_value_and_cash_suite();
select erp_test.assert_ageing_tie_suite();
-- And the supplier journey, whose bill is paid in full by the run this
-- migration restates.
select erp_test.assert_supplier_bill_suite();
