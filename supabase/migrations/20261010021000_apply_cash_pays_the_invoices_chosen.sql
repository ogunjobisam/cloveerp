set lock_timeout = '30s';

-- =============================================================================
-- 20261010021000  Apply cash pays the invoices chosen
-- -----------------------------------------------------------------------------
-- Found on the order-to-cash re-test on live, 5 October (defect C). Lumen paid
-- £795 for INV-000441, and Apply cash asked only for the customer, the amount,
-- the currency and a reference: erp.apply_cash pays a customer's invoices
-- oldest first and nothing else, so the £795 settled INV-000260, from June,
-- and INV-000441 stayed open behind £40,000 of older debt. The outcome said
-- "£795.00 applied to 1 open invoice" and named none, and RCPT-000001's
-- Related documents were empty: the invoice it paid was only a line's
-- description.
--
-- The owner's decision, 5 October: Apply cash lists the customer's open
-- invoices with the oldest ticked; the person can untick them or tick others;
-- whatever is not applied stays on the customer's account; the outcome names
-- the invoices paid; and the receipt links to the invoices it paid.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.apply_cash gains a form that takes the invoices chosen, and an
--      amount for each if the caller wants one. It is the dated form's body,
--      changed only where a choice was made:
--        - only the invoices named are paid, in the order the cash has always
--          gone, oldest first; an invoice given an amount takes that amount
--          first, so what the person named is what each gets, and the rest
--          goes to the others oldest first;
--        - what is left after them stays on the customer's account, however
--          little: a remainder the person did not apply is theirs, not a
--          settlement difference. Short of an invoice by no more than the
--          tolerance, where the receipt ran out on it and no amount was
--          named, the shortfall is written off as before; short of an amount
--          the person named, the invoice stays open for the rest;
--        - an invoice that is not the customer's, is owed in another currency
--          or owes nothing, an amount above what an invoice owes or at
--          nothing, amounts that together are more than the receipt, or a list
--          that is empty or names an invoice twice, are refused, each with a
--          registered refusal, and nothing is posted.
--      With nothing named it pays exactly as the dated form did, and the dated
--      and undated forms now call it with nothing named, so the demonstration's
--      catch-up, the settlement statement's match and every suite that applies
--      cash are unchanged.
--   B. Every receipt names the invoices it paid: a relation settles, from the
--      receipt to each invoice (20261010020000), written as the cash is
--      applied by Apply cash and by a settlement statement's match
--      (erp.apply_cash_to_item, an anchored edit). Both pages list each other
--      under Related documents.
--   C. public.erp_apply_cash takes p_invoice_ids and p_amounts_minor, both
--      optional, and answers in the same six columns. The four-argument door
--      is dropped and the new one created, so the name stays one door.
--   D. public.erp_open_invoices(party, currency): what Apply cash offers to
--      pay, each open invoice of the customer in that currency, oldest first,
--      with what it owes and when it fell due. Reads only.
--   E. The six refusals are registered, and the form's new words are added.
--   F. erp_test.cash_receipt_suite and erp_test.close_and_cash_screens_suite
--      name the door by its new signature; nothing else in them moves.
--   G. Every receipt there already is, in every organisation, is linked to
--      the invoices its journals settled. The defect is in every
--      organisation, and the link is read from what was posted, never
--      guessed: a receivable row of a cash.applied journal the receipt names.
--   H. erp_test.apply_cash_chooses_invoices_suite proves it, sixteen cases.
--
-- The screen's half: Apply cash lists the customer's open invoices with the
-- oldest ticked to cover the amount, sends the ticked ones, and its outcome
-- names the invoices from the receipt's related documents and links to them
-- (src/lib/modules.tsx, src/components/erp/action.tsx, src/lib/plain-words.ts).
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Who may apply cash (finance.post, in each company the cash reaches), the
-- journals and subledger rows a receipt writes, the receipt's lines, the
-- tolerance, and what happens when nothing is chosen. No table is altered.
--
-- On production: two functions are replaced (the dated erp.apply_cash and
-- erp.apply_cash_to_item) and two added (the form that takes a choice and
-- public.erp_open_invoices); one door is replaced by the same door with two
-- optional arguments; six refusals with their eighteen strings, and three
-- screen strings, are added; two suites are edited and one is added with its
-- assertion. Rows are added to erp.document_relation, one per receipt and
-- invoice it paid, in every organisation. No other row is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The form of erp.apply_cash that takes the invoices chosen
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.apply_cash(
  p_party_id      uuid,
  p_amount_minor  bigint,
  p_currency      character,
  p_reference     text,
  p_received_on   date,
  p_invoice_ids   uuid[],
  p_amounts_minor bigint[])
returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint, document_id uuid)
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
  -- The last item the receipt reached, what it left owing on it and what the
  -- receipt applied in all (20260929300000): the tolerance is decided there.
  v_last        uuid;
  v_last_entity uuid;
  v_last_gross  bigint := 0;
  v_last_short  bigint := 0;
  v_applied     bigint := 0;
  -- What the receipt wrote off within the tolerance, short on its last item or
  -- over after every item, and what it kept on the customer's account: said
  -- on the row they belong to (20260929400000).
  v_short_written bigint := 0;
  v_over_written  bigint := 0;
  v_kept          bigint := 0;
  -- The cash receipt (20260930000000): the organisation's type of one, and
  -- one receipt per company the cash reaches, kept by company id beside the
  -- journals. No type, as on receivables version 1: no receipt, as before.
  v_receipt_type text;
  v_receipts     jsonb := '{}'::jsonb;
  v_receipt      uuid;
  v_diff_journal uuid;
  -- The invoices the person chose (20261010021000). None named, and the
  -- oldest are paid first across everything owed, as always. Named, only
  -- they are paid; an amount named for one is what it may take, kept here
  -- by invoice and spent as its items are reached.
  v_named      boolean := p_invoice_ids is not null;
  v_named_left jsonb := '{}'::jsonb;
  v_cap        bigint;
  v_owing      bigint;
  v_invoice_no text;
  v_who        text;
  c            record;
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

  -- And an amount, as the item route has always asked (20260929300000).
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'CLOVEERP_CASH_AMOUNT_INVALID: a receipt is a positive amount, not %', p_amount_minor
      using errcode = '22023', hint = 'Pass the amount received in minor units.';
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

  -- The choice, before anything is posted (20261010021000). A list the cash
  -- can follow: at least one invoice, each once, and an amount, where any is
  -- given, beside each invoice and more than nothing.
  if (v_named and (cardinality(p_invoice_ids) = 0
                   or array_position(p_invoice_ids, null) is not null
                   or (select count(distinct x) from unnest(p_invoice_ids) x) <> cardinality(p_invoice_ids)
                   or (p_amounts_minor is not null
                       and (cardinality(p_amounts_minor) <> cardinality(p_invoice_ids)
                            or exists (select 1 from unnest(p_amounts_minor) a where a <= 0)))))
     or (not v_named and p_amounts_minor is not null) then
    raise exception
      'CLOVEERP_CASH_INVOICES_NOT_CHOSEN: the invoices to pay are % invoice(s) and % amount(s); each invoice is named once, and an amount, where one is given, is more than nothing and sits beside its invoice',
      coalesce(cardinality(p_invoice_ids), 0), coalesce(cardinality(p_amounts_minor), 0)
      using errcode = '22023',
            hint = 'Tick at least one of the customer''s open invoices on Apply cash, each once. Leave the choice out and the oldest are paid first.';
  end if;

  if v_named then
    v_who := coalesce((select p.code from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id),
                      p_party_id::text);
    for c in
      select u.inv_id, u.amount,
             coalesce((select d.document_number from erp.document d
                        where d.tenant_id = v_tenant and d.id = u.inv_id), u.inv_id::text) as number
        from unnest(p_invoice_ids, p_amounts_minor) with ordinality as u(inv_id, amount, ord)
       order by u.ord
    loop
      -- The customer's: an invoice raised to them, of this organisation.
      if not exists (select 1 from erp.subledger_item si
                      where si.tenant_id = v_tenant and si.document_id = c.inv_id
                        and si.control_kind = 'receivable' and si.party_id = p_party_id
                        and si.debit_minor > 0) then
        raise exception 'CLOVEERP_CASH_INVOICE_NOT_THE_CUSTOMERS: % is not an invoice % owes', c.number, v_who
          using errcode = '23514',
                hint = 'Choose from the customer''s own open invoices, which Apply cash lists once the customer is chosen.';
      end if;
      select sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint into v_owing
        from erp.subledger_item si
       where si.tenant_id = v_tenant and si.document_id = c.inv_id
         and si.control_kind = 'receivable' and si.party_id = p_party_id
         and si.currency = p_currency
         and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0;
      if v_owing is null then
        -- Owed in another currency, or not owed at all.
        if not exists (select 1 from erp.subledger_item si
                        where si.tenant_id = v_tenant and si.document_id = c.inv_id
                          and si.control_kind = 'receivable' and si.party_id = p_party_id
                          and si.currency = p_currency and si.debit_minor > 0) then
          raise exception 'CLOVEERP_CASH_INVOICE_CURRENCY_DIFFERS: % is owed in %, and the cash is in %',
            c.number,
            (select string_agg(distinct si.currency::text, ', ') from erp.subledger_item si
              where si.tenant_id = v_tenant and si.document_id = c.inv_id
                and si.control_kind = 'receivable' and si.party_id = p_party_id and si.debit_minor > 0),
            coalesce(p_currency::text, 'no currency')
            using errcode = '23514',
                  hint = 'Apply the cash in the invoice''s currency, or choose invoices owed in the currency the cash arrived in.';
        end if;
        raise exception 'CLOVEERP_CASH_INVOICE_PAID: % owes nothing now', c.number
          using errcode = '23514',
                hint = 'Choose from the invoices Apply cash lists, which are only those still owing. What is not applied stays on the customer''s account.';
      end if;
      if c.amount is not null and c.amount > v_owing then
        raise exception 'CLOVEERP_CASH_MORE_THAN_THE_INVOICE_OWES: % owes %, and % was named for it',
          c.number, v_owing, c.amount
          using errcode = '23514',
                hint = 'Name no more than the invoice still owes, or leave its amount out and it takes what it owes. What is not applied stays on the customer''s account.';
      end if;
      if c.amount is not null then
        v_named_left := v_named_left || jsonb_build_object(c.inv_id::text, c.amount);
      end if;
    end loop;
    if coalesce((select sum(a) from unnest(p_amounts_minor) a), 0) > p_amount_minor then
      raise exception 'CLOVEERP_CASH_MORE_THAN_THE_RECEIPT: the amounts named total %, more than the % received',
        (select sum(a) from unnest(p_amounts_minor) a), p_amount_minor
        using errcode = '23514',
              hint = 'Make the amounts add up to no more than the receipt, or leave them out and the cash is applied oldest first among the invoices chosen.';
    end if;
  end if;

  -- Cash in a currency the customer owes nothing in has nothing to settle
  -- and no company to be banked in (D9, 20260929300000). It used to post
  -- nothing and say nothing.
  if not exists (
    select 1 from erp.subledger_item si
     where si.tenant_id = v_tenant and si.party_id = p_party_id
       and si.control_kind = 'receivable' and si.currency = p_currency
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0)
  then
    raise exception 'CLOVEERP_CASH_CURRENCY_NOT_BOOKED: % owes nothing in %',
      coalesce((select p.code from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id),
               p_party_id::text),
      coalesce(p_currency::text, 'no currency')
      using errcode = '23514',
            hint = 'Apply it in the currency the customer''s invoices are in; erp_receivables_ageing() says what is owed and in which currency. Money for a customer who owes nothing yet is not taken on account here.';
  end if;

  select dt.code into v_receipt_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'cash_receipt' and dt.status = 'active'
   order by (dt.entity_id is not null), dt.code
   limit 1;

  -- Oldest first, which is the only allocation defensible without an
  -- instruction from the customer, and across every company the party owes:
  -- the oldest invoice is the oldest invoice whoever it was raised by.
  -- Settled amounts are excluded, so a second receipt sees only what is
  -- genuinely still owed. With invoices chosen, only they; and those named
  -- with an amount first, so each takes what was named for it whatever else
  -- is older (20261010021000).
  for r in
    select si.id, si.entity_id, si.ledger_id, si.document_id,
           si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) as owing,
           si.debit_minor - si.credit_minor as gross,
           si.control_account_id,
           coalesce(v_named_left ? si.document_id::text, false) as capped
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.party_id = p_party_id
       and si.control_kind = 'receivable' and si.currency = p_currency
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
       and (not v_named or si.document_id = any (p_invoice_ids))
     order by coalesce(v_named_left ? si.document_id::text, false) desc,
              coalesce(si.due_date, si.posting_date), si.id
  loop
    exit when v_left <= 0;
    -- What this item may take: what it owes, and no more than is left of
    -- the amount named for its invoice (20261010021000).
    v_cap := r.owing;
    if r.capped then
      v_cap := least(v_cap, (v_named_left ->> r.document_id::text)::bigint);
    end if;
    continue when v_cap <= 0;
    perform erp.require_cash_in_ledger_currency(r.ledger_id, p_currency);
    v_take := least(v_left, v_cap);
    if r.capped then
      v_named_left := v_named_left
        || jsonb_build_object(r.document_id::text, (v_named_left ->> r.document_id::text)::bigint - v_take);
    end if;
    v_entity := r.entity_id;
    if r.document_id is not null and not (r.document_id = any (v_docs)) then
      v_docs := v_docs || r.document_id;
    end if;

    -- The bank the money reached is the bank of the company that is owed.
    v_bank := nullif(v_banks ->> v_entity::text, '')::uuid;
    if v_bank is null then
      v_bank := erp.company_bank_account(v_entity);
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

    -- The company's receipt, opened for the first item of that company the
    -- cash reaches, through the door every document is opened by: dated the
    -- day the money arrived, with the customer's reference (20260930000000).
    v_receipt := null;
    if v_receipt_type is not null then
      v_receipt := nullif(v_receipts ->> v_entity::text, '')::uuid;
      if v_receipt is null then
        v_receipt := erp.open_document(v_receipt_type, p_party_id, v_entity, null,
                                       p_reference, null, p_currency);
        update erp.document d
           set document_date = p_received_on,
               attributes = d.attributes || jsonb_build_object('route', 'apply_cash'),
               updated_at = now()
         where d.tenant_id = v_tenant and d.id = v_receipt;
        v_receipts := v_receipts || jsonb_build_object(v_entity::text, v_receipt);
      end if;
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
      party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    -- With a receipt, the settling row names the invoice it settles, as the
    -- settlement statement's always has (D2, 20260930000000). The ageing is
    -- the same either way; this says what paid it.
    values (v_tenant, v_entity, r.ledger_id, 'receivable', r.control_account_id,
            p_party_id, case when v_receipt is not null then r.document_id end,
            v_journal, p_currency, 0, v_take, p_received_on),
           (v_tenant, v_entity, r.ledger_id, 'bank', v_bank,
            null, null, v_journal, p_currency, v_take, 0, p_received_on);

    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_take,
           updated_at = now()
     where id = r.id;

    -- What the cash applied to this item is a line of the receipt, with no
    -- item: the invoice's number and the amount.
    if v_receipt is not null then
      v_invoice_no := (select inv.document_number from erp.document inv
                        where inv.tenant_id = v_tenant and inv.id = r.document_id);
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity,
        unit_price_minor, net_minor, currency)
      values (
        v_tenant, v_receipt,
        coalesce((select max(l.line_no) from erp.document_line l
                   where l.tenant_id = v_tenant and l.document_id = v_receipt), 0) + 10,
        null,
        coalesce(v_invoice_no, 'an open item'),
        1, v_take, v_take, p_currency);

      -- And the receipt names the invoice it paid among its related
      -- documents, and the invoice the receipt (20261010021000).
      if r.document_id is not null then
        insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
        values (v_tenant, v_receipt, r.document_id, 'settles'::erp.document_relation_kind)
        on conflict do nothing;
      end if;
    end if;

    v_last := r.id;
    v_last_entity := v_entity;
    v_last_gross := r.gross;
    v_last_short := r.owing - v_take;
    v_applied := v_applied + v_take;

    subledger_item_id := r.id;
    applied_minor := v_take;
    v_left := v_left - v_take;
    remaining_minor := v_left;
    -- The receipt ends on this item, and short of it by no more than the
    -- tolerance: the rest is written off after the loop, and this row says
    -- so. Decided here, once, and read there (20260929400000). Not short of
    -- an amount the person named: they paid that much, and the invoice
    -- stays open for the rest (20261010021000).
    if v_left = 0 and v_last_short > 0 and not r.capped
       and v_last_short <= erp.settlement_tolerance_minor(v_last_entity, v_last_gross) then
      v_short_written := v_last_short;
    end if;
    written_off_minor := v_short_written;
    on_account_minor := 0;
    document_id := v_receipt;
    return next;
  end loop;

  -- Each company's journal names that company's receipt, if it has one.
  update erp.journal j
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
         document_id = coalesce(j.document_id, nullif(v_receipts ->> j.entity_id::text, '')::uuid)
   where j.tenant_id = v_tenant
     and j.id in (select (jsonb_each_text(v_journals)).value::uuid);

  -- The whole receipt is banked (D8, 20260929300000). The last item the
  -- receipt reached takes the tolerance: short by no more than it, its
  -- residue is written off; a remainder after every item is credited to
  -- settlement differences inside it, and kept on the customer's account
  -- beyond it. Short beyond it, the item stays open for the rest. With
  -- invoices chosen, a remainder is the customer's however small: the person
  -- did not apply it, so it is kept on their account (20261010021000).
  if v_short_written > 0 then
    v_diff_journal := erp.post_settlement_difference(v_last, v_short_written, p_received_on, p_reference);
  elsif v_left > 0 then
    if not v_named and v_left <= erp.settlement_tolerance_minor(v_last_entity, v_applied) then
      v_diff_journal := erp.post_settlement_difference(v_last, -v_left, p_received_on, p_reference);
      v_over_written := v_left;
    else
      v_diff_journal := erp.post_cash_on_account(v_last, v_left, p_received_on, p_reference);
      v_kept := v_left;
    end if;
  end if;

  -- The difference is the last company's, and so is its receipt: the journal
  -- names it, and a remainder the bank took is a line of it, so the lines
  -- total what the bank was debited (20260930000000). A short written off
  -- banks nothing and is not a line.
  v_receipt := nullif(v_receipts ->> v_last_entity::text, '')::uuid;
  if v_receipt is not null and v_diff_journal is not null then
    update erp.journal j set document_id = v_receipt
     where j.tenant_id = v_tenant and j.id = v_diff_journal;
    if v_left > 0 then
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity,
        unit_price_minor, net_minor, currency)
      values (
        v_tenant, v_receipt,
        coalesce((select max(l.line_no) from erp.document_line l
                   where l.tenant_id = v_tenant and l.document_id = v_receipt), 0) + 10,
        null,
        case when v_kept > 0 then 'kept on account'
             else 'over, within the settlement tolerance' end,
        1, v_left, v_left, p_currency);
    end if;
  end if;

  -- And the documents the cash paid off say so. After the loop, because
  -- settled_minor is written inside it and what a document owes is the
  -- sum over all of its rows: asking halfway through would ask about a
  -- receipt that was not finished arriving.
  foreach v_doc in array v_docs loop
    perform erp.settle_paid_document(
      v_doc, format('settled by %s', coalesce(p_reference, 'cash received')));
  end loop;

  -- And each receipt is posted, by the system, now that its lines total what
  -- its journals banked (20260930000000).
  for v_receipt in select (e.value #>> '{}')::uuid from jsonb_each(v_receipts) e loop
    perform erp.post_cash_document(v_receipt);
  end loop;

  -- What was left over after every item, now banked: credited to settlement
  -- differences, or on the customer's account.
  if v_left > 0 then
    subledger_item_id := null;
    applied_minor := 0;
    remaining_minor := v_left;
    written_off_minor := v_over_written;
    on_account_minor := v_kept;
    document_id := nullif(v_receipts ->> v_last_entity::text, '')::uuid;
    return next;
  end if;
end;
$$;

revoke all on function erp.apply_cash(uuid, bigint, character, text, date, uuid[], bigint[]) from public, anon;

comment on function erp.apply_cash(uuid, bigint, character, text, date, uuid[], bigint[]) is
  'Applies a customer''s receipt to the invoices chosen, or with none chosen to what they owe oldest first '
  '(20261010021000). An invoice named with an amount takes that amount first; the rest go oldest first; what is '
  'left stays on the customer''s account. Refuses an invoice that is not the customer''s, is owed in another '
  'currency or owes nothing, an amount above what an invoice owes, amounts above the receipt, and a list that is '
  'empty or names an invoice twice. Opens and posts one cash receipt per company, which names each invoice it paid '
  '(settles). finance.post in each company the cash reaches.';

-- The dated form is this one with nothing chosen; the undated form calls the
-- dated one, as before. Replaced only if it is the body this was written
-- against, and once.
do $dated$
declare
  v_sig constant text := 'erp.apply_cash(uuid,bigint,character,text,date)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261010021000') > 0 then
    raise notice '% already pays with nothing chosen; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '745489e51360b88e80aad55803c6d401' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010021000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  execute $fn$
create or replace function erp.apply_cash(
  p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text, p_received_on date)
returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint, document_id uuid)
language sql
set search_path = ''
as $body$
  -- Nothing chosen: the oldest are paid first, across everything the
  -- customer owes, as they always were (20261010021000).
  select x.subledger_item_id, x.applied_minor, x.remaining_minor,
         x.written_off_minor, x.on_account_minor, x.document_id
    from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference, p_received_on,
                        null::uuid[], null::bigint[]) x
$body$
$fn$;
end
$dated$;

revoke all on function erp.apply_cash(uuid, bigint, character, text, date) from public, anon;

comment on function erp.apply_cash(uuid, bigint, character, text, date) is
  'Applies a customer''s receipt, dated the day it arrived, to what they owe oldest first: '
  'erp.apply_cash with no invoice chosen (20261010021000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A settlement statement's receipt names the invoice it settled
-- ─────────────────────────────────────────────────────────────────────────────

do $item$
declare
  v_sig constant text := 'erp.apply_cash_to_item(uuid,bigint,text,date,uuid)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      1, v_take, v_take, si.currency);
  end if;

  -- The difference, inside the tolerance$o$;
  v_new constant text := $n$      1, v_take, v_take, si.currency);

    -- And the receipt names the invoice it settled among its related
    -- documents, and the invoice the receipt (20261010021000).
    if si.document_id is not null then
      insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
      values (v_tenant, p_document_id, si.document_id, 'settles'::erp.document_relation_kind)
      on conflict do nothing;
    end if;
  end if;

  -- The difference, inside the tolerance$n$;
begin
  if strpos(v_src, '20261010021000') > 0 then
    raise notice '% already links its receipt; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'cc40e702e94217425ebf35c4285815c8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010021000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$item$;

revoke all on function erp.apply_cash_to_item(uuid, bigint, text, date, uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The door
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.erp_apply_cash(uuid, bigint, character, text);

create or replace function public.erp_apply_cash(
  p_party_id      uuid,
  p_amount_minor  bigint,
  p_currency      character,
  p_reference     text default null,
  p_invoice_ids   uuid[] default null,
  p_amounts_minor bigint[] default null)
returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint, written_off_minor bigint, on_account_minor bigint, document_id uuid)
language sql
set search_path = ''
as $$
  -- The invoices chosen, and an amount for each where one is named; none
  -- chosen, the oldest first (20261010021000).
  select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference, current_date,
                               p_invoice_ids, p_amounts_minor)
$$;

revoke all on function public.erp_apply_cash(uuid, bigint, character, text, uuid[], bigint[]) from public, anon;
grant execute on function public.erp_apply_cash(uuid, bigint, character, text, uuid[], bigint[]) to authenticated, service_role;

comment on function public.erp_apply_cash(uuid, bigint, character, text, uuid[], bigint[]) is
  'Apply cash: a customer''s receipt today, to the invoices chosen (p_invoice_ids, and p_amounts_minor for any '
  'that take a set amount), or with none chosen to what they owe oldest first. What is left stays on their '
  'account. A row per invoice item paid and one for the remainder, each naming the receipt (20261010021000). '
  'finance.post.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. What Apply cash offers to pay
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_open_invoices(p_party_id uuid, p_currency character default 'GBP')
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Each invoice the customer still owes in the currency, once, oldest first:
  -- the order Apply cash pays in when nothing is chosen (20261010021000). An
  -- invoice with no due date fell due when it was posted, as the ageing says.
  select coalesce(jsonb_agg(jsonb_build_object(
           'document_id', o.document_id, 'document_number', o.document_number,
           'owing_minor', o.owing_minor, 'due_date', o.due_date, 'currency', o.currency)
           order by o.due_date, o.first_item), '[]'::jsonb)
    from (select si.document_id, d.document_number, si.currency,
                 sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint as owing_minor,
                 min(coalesce(si.due_date, si.posting_date)) as due_date,
                 min(si.id::text) as first_item
            from erp.subledger_item si
            join erp.document d on d.tenant_id = si.tenant_id and d.id = si.document_id
           where si.tenant_id = erp.current_tenant_id()
             and si.party_id = p_party_id and si.control_kind = 'receivable'
             and si.currency = p_currency
             and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
           group by si.document_id, d.document_number, si.currency) o
$$;

revoke all on function public.erp_open_invoices(uuid, character) from public, anon;
grant execute on function public.erp_open_invoices(uuid, character) to authenticated, service_role;

comment on function public.erp_open_invoices(uuid, character) is
  'The open invoices of a customer in a currency, oldest first, with what each owes and when it fell due: what '
  'Apply cash offers to pay (20261010021000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The refusals, and the form's words
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_CASH_INVOICES_NOT_CHOSEN',
  'Applying cash to a list of invoices that is empty, names one twice, or gives amounts that do not match it.',
  'The person chooses which invoices the cash pays; an empty list, an invoice named twice, or an amount with no invoice beside it is not a choice the cash can follow.',
  'Tick at least one of the customer''s open invoices on Apply cash, each once. Leave the choice out and the oldest are paid first.');
select erp.register_refusal('CLOVEERP_CASH_INVOICE_NOT_THE_CUSTOMERS',
  'Applying a customer''s cash to an invoice that is not theirs.',
  'Cash a customer sent pays only what that customer owes; put against another customer''s invoice it would clear a debt with money that customer never sent.',
  'Choose from the customer''s own open invoices, which Apply cash lists once the customer is chosen.');
select erp.register_refusal('CLOVEERP_CASH_INVOICE_CURRENCY_DIFFERS',
  'Applying cash to an invoice owed in another currency.',
  'An invoice is paid in the currency it was raised in; cash in another currency would settle it at a rate nobody agreed.',
  'Apply the cash in the invoice''s currency, or choose invoices owed in the currency the cash arrived in.');
select erp.register_refusal('CLOVEERP_CASH_INVOICE_PAID',
  'Applying cash to an invoice that owes nothing.',
  'An invoice already paid in full has nothing left for cash to settle.',
  'Choose from the invoices Apply cash lists, which are only those still owing. What is not applied stays on the customer''s account.');
select erp.register_refusal('CLOVEERP_CASH_MORE_THAN_THE_INVOICE_OWES',
  'Applying more to an invoice than it still owes.',
  'Cash applied to an invoice beyond what it owes would pay it twice over; what is over belongs on the customer''s account.',
  'Name no more than the invoice still owes, or leave its amount out and it takes what it owes. What is not applied stays on the customer''s account.');
select erp.register_refusal('CLOVEERP_CASH_MORE_THAN_THE_RECEIPT',
  'Applying more to the chosen invoices than the cash received.',
  'A receipt pays out only what reached the bank; amounts that add up to more would settle invoices with money that never arrived.',
  'Make the amounts add up to no more than the receipt, or leave them out and the cash is applied oldest first among the invoices chosen.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Apply cash pays the invoices chosen (20261010021000).'
  from (values
    ('The oldest are ticked, as many as the amount pays. Untick any it should not pay, or tick others: what is not applied stays on the customer''s account.'),
    ('This customer owes nothing in this currency, so there is no invoice for the cash to pay.'),
    ('{invoice}: {owes}, due {due}')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The suites that pin the door's signature name the new one
-- ─────────────────────────────────────────────────────────────────────────────

do $pins$
declare
  r     record;
  v_src text;
  v_def text;
  c_old constant text := '''public.erp_apply_cash(uuid,bigint,character,text)''::regprocedure';
  c_new constant text := '''public.erp_apply_cash(uuid,bigint,character,text,uuid[],bigint[])''::regprocedure';
begin
  for r in
    select * from (values
      ('erp_test.cash_receipt_suite()', 'c8a11e7e4d47c32c3826d5b65b7cdfa1', 2),
      ('erp_test.close_and_cash_screens_suite()', '76ffa842fcc62b7d36e890f5a3e62606', 3)
    ) as t(sig, body_md5, uses)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, c_new) > 0 then
      raise notice '% already names the door by its new signature; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.body_md5 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010021000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if (length(v_def) - length(replace(v_def, c_old, ''))) / length(c_old) <> r.uses then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % names the old door other than % times', r.sig, r.uses;
    end if;
    execute replace(v_def, c_old, c_new);
  end loop;
end
$pins$;

revoke all on function erp_test.cash_receipt_suite() from public, anon;
revoke all on function erp_test.close_and_cash_screens_suite() from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Every receipt there is names the invoices it paid
-- ─────────────────────────────────────────────────────────────────────────────

do $links$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    -- What a receipt paid is what its journals settled: a receivable row of a
    -- cash.applied journal that names the receipt, crediting an invoice.
    insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
    select distinct j.tenant_id, j.document_id, si.document_id, 'settles'::erp.document_relation_kind
      from erp.journal j
      join erp.document rd on rd.tenant_id = j.tenant_id and rd.id = j.document_id
      join erp.document_type rdt on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
      join erp.subledger_item si on si.tenant_id = j.tenant_id and si.journal_id = j.id
     where j.tenant_id = r.id and j.source_code = 'cash.applied' and j.status = 'posted'
       and rdt.base_type_code = 'cash_receipt'
       and si.control_kind = 'receivable' and si.credit_minor > 0
       and si.document_id is not null and si.document_id <> j.document_id
    on conflict do nothing;
    get diagnostics v_n = row_count;
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'receipts: % link(s) to the invoices they paid added in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$links$;

-- ─────────────────────────────────────────────────────────────────────────────
-- H. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.apply_cash_chooses_invoices_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_ccy char(3);
  v_cust uuid; v_other uuid;
  v_old uuid; v_new uuid; v_third uuid; v_fourth uuid; v_theirs uuid;
  v_g_old bigint; v_g_new bigint; v_g_third bigint; v_g_fourth bigint;
  v_rows jsonb; v_rcpt uuid; v_rcpt2 uuid; v_page jsonb; v_list jsonb;
  v_on bigint; v_j0 integer; v_j1 integer;
  v_err text; v_err2 text; v_err3 text; v_err4 text;
  v_rtype text; v_item_row uuid;
begin
  begin
    v_step := 'an organisation configured from now on, that can invoice and bank a receipt';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzaci-' || v_tag, 'Apply Cash Chooses Suite',
      'admin@zzaci-' || v_tag || '.test', 'Apply Cash Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzaci-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'its company, site, unit and product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZAMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZAEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZAWID', 'Apply Cash Widget', v_uom, 'active') returning id into v_item;

    v_step := 'a customer with four invoices, the first a month old, and another customer with one';
    v_old := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZAC', 50000);
    select d.party_id into v_cust from erp.document d where d.id = v_old;
    v_new := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZAC-NEW', '{}'::jsonb);
    perform erp.add_document_line(v_new, v_item, 1, 30000, 'the newer sale');
    perform erp.transition_document(v_new, 'issue', 'apply cash chooses suite');
    v_third := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZAC-THIRD', '{}'::jsonb);
    perform erp.add_document_line(v_third, v_item, 1, 20000, 'the third sale');
    perform erp.transition_document(v_third, 'issue', 'apply cash chooses suite');
    v_fourth := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZAC-FOURTH', '{}'::jsonb);
    perform erp.add_document_line(v_fourth, v_item, 1, 10000, 'the fourth sale');
    perform erp.transition_document(v_fourth, 'issue', 'apply cash chooses suite');
    -- Oldest first is by when each fell due: the first a month ago, the rest
    -- in the order they were raised.
    update erp.subledger_item si set due_date = current_date - 30
     where si.tenant_id = rb.tenant_id and si.document_id = v_old and si.control_kind = 'receivable';
    update erp.subledger_item si set due_date = current_date + 10
     where si.tenant_id = rb.tenant_id and si.document_id = v_new and si.control_kind = 'receivable';
    update erp.subledger_item si set due_date = current_date + 20
     where si.tenant_id = rb.tenant_id and si.document_id = v_third and si.control_kind = 'receivable';
    update erp.subledger_item si set due_date = current_date + 25
     where si.tenant_id = rb.tenant_id and si.document_id = v_fourth and si.control_kind = 'receivable';
    v_theirs := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZAO', 40000);
    select d.party_id into v_other from erp.document d where d.id = v_theirs;
    select dv.gross_minor::bigint into v_g_old from erp.document_view dv where dv.id = v_old;
    select dv.gross_minor::bigint into v_g_new from erp.document_view dv where dv.id = v_new;
    select dv.gross_minor::bigint into v_g_third from erp.document_view dv where dv.id = v_third;
    select dv.gross_minor::bigint into v_g_fourth from erp.document_view dv where dv.id = v_fourth;

    -- ── 1. The door ─────────────────────────────────────────────────────────
    v_step := 'the door';
    v_cases := v_cases + 1;
    case_name := 'the door takes the invoices chosen and an amount for each, both optional, answers in the same six columns as the dated form, and is the only door of its name';
    passed := v_state is null
          and to_regprocedure('public.erp_apply_cash(uuid,bigint,character,text,uuid[],bigint[])') is not null
          and to_regprocedure('public.erp_apply_cash(uuid,bigint,character,text)') is null
          and (select count(*) from pg_catalog.pg_proc p
                 join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'erp_apply_cash') = 1
          and has_function_privilege('authenticated', 'public.erp_apply_cash(uuid,bigint,character,text,uuid[],bigint[])', 'execute')
          and not has_function_privilege('anon', 'public.erp_apply_cash(uuid,bigint,character,text,uuid[],bigint[])', 'execute')
          and pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text,uuid[],bigint[])'::regprocedure)
            = pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text,date)'::regprocedure)
          and pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text,date,uuid[],bigint[])'::regprocedure)
            = pg_catalog.pg_get_function_result('erp.apply_cash(uuid,bigint,character,text)'::regprocedure);
    detail := coalesce(v_state, pg_catalog.pg_get_function_result('public.erp_apply_cash(uuid,bigint,character,text,uuid[],bigint[])'::regprocedure));
    return next;

    -- ── 2. What the form offers ─────────────────────────────────────────────
    v_step := 'the open invoices';
    v_list := public.erp_open_invoices(v_cust, v_ccy);
    v_cases := v_cases + 1;
    case_name := 'erp_open_invoices lists the customer''s open invoices once each, oldest first, with what each owes and when it fell due, and none of another customer''s';
    passed := v_state is null
          and jsonb_array_length(v_list) = 4
          and (v_list -> 0 ->> 'document_id')::uuid = v_old
          and (v_list -> 1 ->> 'document_id')::uuid = v_new
          and (v_list -> 3 ->> 'document_id')::uuid = v_fourth
          and (v_list -> 0 ->> 'owing_minor')::bigint = v_g_old
          and (v_list -> 0 ->> 'due_date')::date = current_date - 30
          and (v_list -> 0 ->> 'document_number') = (select d.document_number from erp.document d where d.id = v_old)
          and not exists (select 1 from jsonb_array_elements(v_list) e where (e ->> 'document_id')::uuid = v_theirs)
          and public.erp_open_invoices(v_cust, 'EUR') = '[]'::jsonb;
    detail := coalesce(v_state, left(v_list::text, 300));
    return next;

    -- ── 3. Refused: another customer's invoice ─────────────────────────────
    v_step := 'another customer''s invoice';
    v_j0 := (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id);
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-THEIRS', array[v_theirs]);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-NOTHING', array[gen_random_uuid()]);
      v_err2 := 'applied';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    v_j1 := (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id);
    v_cases := v_cases + 1;
    case_name := 'an invoice of another customer, or no invoice at all, is refused by name, and nothing is posted';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_INVOICE_NOT_THE_CUSTOMERS:%'
          and v_err2 like 'CLOVEERP_CASH_INVOICE_NOT_THE_CUSTOMERS:%'
          and v_j1 = v_j0
          and erp.object_current_state('document', v_theirs) = 'issued';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_j1 - v_j0));
    return next;

    -- ── 4. Refused: more than an invoice owes ──────────────────────────────
    v_step := 'more than an invoice owes';
    begin
      perform public.erp_apply_cash(v_cust, v_g_new + 5000, v_ccy, 'ZAC-OVER', array[v_new], array[v_g_new + 1]);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'an amount above what the invoice still owes is refused, and nothing is posted';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_MORE_THAN_THE_INVOICE_OWES:%'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id) = v_j0;
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 5. Refused: more than the receipt ──────────────────────────────────
    v_step := 'more than the receipt';
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-RCPT', array[v_new, v_third], array[600, 500]);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'amounts that together are more than the receipt are refused, and nothing is posted';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_MORE_THAN_THE_RECEIPT:%'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id) = v_j0;
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 6. Refused: another currency ───────────────────────────────────────
    v_step := 'another currency';
    begin
      perform public.erp_apply_cash(v_cust, 1000, 'EUR', 'ZAC-EUR', array[v_new]);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'cash in a currency the chosen invoice is not owed in is refused, and nothing is posted';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_INVOICE_CURRENCY_DIFFERS:%'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id) = v_j0;
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 7. Refused: a list the cash cannot follow ──────────────────────────
    v_step := 'a list the cash cannot follow';
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-EMPTY', '{}'::uuid[]);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-TWICE', array[v_new, v_new]);
      v_err2 := 'applied';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-UNEVEN', array[v_new, v_third], array[500]);
      v_err3 := 'applied';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    begin
      perform public.erp_apply_cash(v_cust, 1000, v_ccy, 'ZAC-LOOSE', null, array[500]);
      v_err4 := 'applied';
    exception when others then v_err4 := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'an empty choice, an invoice named twice, amounts that do not sit beside the invoices, and amounts with no invoices are refused, and nothing is posted';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_INVOICES_NOT_CHOSEN:%'
          and v_err2 like 'CLOVEERP_CASH_INVOICES_NOT_CHOSEN:%'
          and v_err3 like 'CLOVEERP_CASH_INVOICES_NOT_CHOSEN:%'
          and v_err4 like 'CLOVEERP_CASH_INVOICES_NOT_CHOSEN:%'
          and (select count(*) from erp.journal j where j.tenant_id = rb.tenant_id) = v_j0;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4));
    return next;

    -- ── 8. The invoice chosen, not the oldest ──────────────────────────────
    v_step := 'the newer invoice chosen';
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_g_new, v_ccy, 'ZAC-CHOSEN', array[v_new]) x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'the invoice chosen is paid in full and the older one is left as it was, though the older one is owed first';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'subledger_item_id')::uuid
              = (select si.id from erp.subledger_item si where si.document_id = v_new
                    and si.control_kind = 'receivable' and si.debit_minor > 0)
          and (v_rows -> 0 ->> 'applied_minor')::bigint = v_g_new
          and erp.object_current_state('document', v_new) = 'paid'
          and erp.object_current_state('document', v_old) = 'issued'
          and erp.object_current_state('document', v_rcpt) = 'posted';
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 9. The receipt and the invoice name each other ─────────────────────
    v_step := 'the related documents';
    v_page := public.erp_document(v_rcpt);
    v_cases := v_cases + 1;
    case_name := 'the receipt lists the invoice it paid among its related documents, settles, and the invoice lists the receipt';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_page -> 'lineage') l
                       where (l ->> 'document_id')::uuid = v_new and l ->> 'relation' = 'settles'
                         and l ->> 'direction' = 'downstream' and (l ->> 'depth')::int = 1)
          and not exists (select 1 from jsonb_array_elements(v_page -> 'lineage') l
                           where (l ->> 'document_id')::uuid = v_old)
          and exists (select 1 from jsonb_array_elements(public.erp_document(v_new) -> 'lineage') l
                       where (l ->> 'document_id')::uuid = v_rcpt and l ->> 'relation' = 'settles'
                         and l ->> 'direction' = 'upstream');
    detail := coalesce(v_state, left((v_page -> 'lineage')::text, 300));
    return next;

    -- ── 10. Amounts named, the rest on account ─────────────────────────────
    v_step := 'two invoices with an amount each';
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, 5000, v_ccy, 'ZAC-AMOUNTS', array[v_fourth, v_third], array[1000, 2000]) x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_on := (select sum((e ->> 'on_account_minor')::bigint) from jsonb_array_elements(v_rows) e);
    v_cases := v_cases + 1;
    case_name := 'two invoices named with an amount each take that amount, oldest first, are part paid, and the rest of the receipt is kept on the customer''s account, on the receipt''s lines';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 3
          and (select sum((e ->> 'applied_minor')::bigint) from jsonb_array_elements(v_rows) e) = 3000
          and (v_rows -> 0 ->> 'applied_minor')::bigint = 2000
          and (v_rows -> 1 ->> 'applied_minor')::bigint = 1000
          and v_on = 2000
          and (select sum((e ->> 'written_off_minor')::bigint) from jsonb_array_elements(v_rows) e) = 0
          and erp.object_current_state('document', v_third) = 'part_paid'
          and erp.object_current_state('document', v_fourth) = 'part_paid'
          and erp.object_current_state('document', v_old) = 'issued'
          and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_rcpt) = 5000
          and (select count(*) from erp.document_relation rel
                where rel.from_document_id = v_rcpt and rel.relation_kind = 'settles') = 2;
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 11. An invoice with no amount, and a little over ───────────────────
    v_step := 'an invoice paid with a little over';
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_g_fourth - 1000 + 50, v_ccy, 'ZAC-OVER50', array[v_fourth]) x;
    v_cases := v_cases + 1;
    case_name := 'an invoice chosen with no amount takes what it still owes, and the 50p over is kept on account, not paid to the older invoice and not written off within the tolerance';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and (v_rows -> 0 ->> 'applied_minor')::bigint = v_g_fourth - 1000
          and (v_rows -> 1 ->> 'on_account_minor')::bigint = 50
          and (v_rows -> 1 ->> 'written_off_minor')::bigint = 0
          and erp.object_current_state('document', v_fourth) = 'paid'
          and erp.object_current_state('document', v_old) = 'issued';
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 12. Paid already, or short by a penny ──────────────────────────────
    v_step := 'a penny short';
    begin
      perform public.erp_apply_cash(v_cust, 100, v_ccy, 'ZAC-PAID', array[v_fourth]);
      v_err := 'applied';
    exception when others then v_err := left(sqlerrm, 200); end;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_g_third - 2000 - 1, v_ccy, 'ZAC-PENNY', array[v_third]) x;
    v_cases := v_cases + 1;
    case_name := 'an invoice already paid is refused; one chosen with no amount and paid a penny short is written off within the tolerance, as before';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_INVOICE_PAID:%'
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'written_off_minor')::bigint = 1
          and erp.object_current_state('document', v_third) = 'paid';
    detail := coalesce(v_state, concat_ws(' / ', v_err, left(coalesce(v_rows::text, 'no rows'), 250)));
    return next;

    -- ── 13. Short of an amount named ───────────────────────────────────────
    v_step := 'short of an amount named';
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_g_old - 1, v_ccy, 'ZAC-PART', array[v_old], array[v_g_old - 1]) x;
    v_cases := v_cases + 1;
    case_name := 'an invoice named with an amount a penny short of what it owes takes that amount and stays open for the penny: nothing is written off';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'applied_minor')::bigint = v_g_old - 1
          and (v_rows -> 0 ->> 'written_off_minor')::bigint = 0
          and erp.object_current_state('document', v_old) = 'part_paid'
          and (public.erp_open_invoices(v_cust, v_ccy) -> 0 ->> 'owing_minor')::bigint = 1;
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 14. Nothing chosen, oldest first ───────────────────────────────────
    v_step := 'nothing chosen';
    v_new := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZAC-LATEST', '{}'::jsonb);
    perform erp.add_document_line(v_new, v_item, 1, 10000, 'the latest sale');
    perform erp.transition_document(v_new, 'issue', 'apply cash chooses suite');
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, 1, v_ccy, 'ZAC-OLDEST') x;
    v_rcpt2 := (v_rows -> 0 ->> 'document_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'with nothing chosen the cash pays the oldest first, as it always did, and its receipt names that invoice';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'applied_minor')::bigint = 1
          and erp.object_current_state('document', v_old) = 'paid'
          and erp.object_current_state('document', v_new) = 'issued'
          and exists (select 1 from erp.document_relation rel
                       where rel.from_document_id = v_rcpt2 and rel.to_document_id = v_old
                         and rel.relation_kind = 'settles');
    detail := coalesce(v_state, left(coalesce(v_rows::text, 'no rows'), 300));
    return next;

    -- ── 15. A settlement statement's receipt ───────────────────────────────
    v_step := 'the route a settlement statement takes';
    select dt.code into v_rtype from erp.document_type dt
     where dt.tenant_id = rb.tenant_id and dt.base_type_code = 'cash_receipt' and dt.status = 'active'
     order by (dt.entity_id is not null), dt.code limit 1;
    v_rcpt := erp.open_document(v_rtype, v_cust, v_entity, null, 'ZAC-STATEMENT', null, v_ccy);
    select si.id into v_item_row from erp.subledger_item si
     where si.document_id = v_new and si.control_kind = 'receivable' and si.debit_minor > 0;
    perform erp.apply_cash_to_item(v_item_row, 2000, 'ZAC-STATEMENT', current_date, v_rcpt);
    v_cases := v_cases + 1;
    case_name := 'cash matched from a settlement statement names the invoice it settled on its receipt too';
    passed := v_state is null
          and exists (select 1 from erp.document_relation rel
                       where rel.from_document_id = v_rcpt and rel.to_document_id = v_new
                         and rel.relation_kind = 'settles')
          and erp.object_current_state('document', v_new) = 'part_paid';
    detail := coalesce(v_state, erp.object_current_state('document', v_new));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := left(v_step || ': ' || sqlerrm, 300);
    end if;
  end;

  -- ── 16. Registered, and undone ────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'each of the six refusals is registered with its next action, the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and (select count(*) from erp_ref.refusal f
              where f.code in ('CLOVEERP_CASH_INVOICES_NOT_CHOSEN', 'CLOVEERP_CASH_INVOICE_NOT_THE_CUSTOMERS',
                               'CLOVEERP_CASH_INVOICE_CURRENCY_DIFFERS', 'CLOVEERP_CASH_INVOICE_PAID',
                               'CLOVEERP_CASH_MORE_THAN_THE_INVOICE_OWES', 'CLOVEERP_CASH_MORE_THAN_THE_RECEIPT')
                and coalesce(f.next_action, '') <> '') = 6
        and not exists (select 1 from erp.tenant where code = 'zzaci-' || v_tag);
  detail := coalesce('the fixture stopped early: ' || v_state,
                     'the organisation rolled back with its invoices, receipts and links');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_APPLY_CASH_CHOOSES_INVOICES_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_state, 'a case was added or lost');
  end if;
end;
$$;

revoke all on function erp_test.apply_cash_chooses_invoices_suite() from public, anon;

comment on function erp_test.apply_cash_chooses_invoices_suite() is
  'Apply cash pays the invoices chosen (20261010021000): the door and what it offers to pay; another customer''s '
  'invoice, more than an invoice owes, more than the receipt, another currency, a paid invoice and a list it cannot '
  'follow are refused; the invoice chosen is paid and not the older one; amounts named are taken and the rest kept '
  'on account; a penny short is written off only where no amount was named; nothing chosen pays oldest first; and '
  'every receipt, from Apply cash or a settlement statement, names the invoices it paid.';

create or replace function erp_test.assert_apply_cash_chooses_invoices_suite()
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
    from erp_test.apply_cash_chooses_invoices_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_APPLY_CASH_CHOOSES_INVOICES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Apply cash would pay an invoice nobody chose, more than was received or owed, or leave a receipt naming nothing. Read the case that failed.';
  end if;
  if v_total <> 16 then
    raise exception 'CLOVEERP_APPLY_CASH_CHOOSES_INVOICES_SUITE_SHRANK: % case(s), expected 16', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('apply cash chooses invoices: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_apply_cash_chooses_invoices_suite() from public, anon;

comment on function erp_test.assert_apply_cash_chooses_invoices_suite() is
  'Apply cash pays only the invoices chosen, within the receipt and what each owes, keeps the rest on account, and '
  'every receipt names the invoices it paid (20261010021000).';

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
select erp.assert_invoker_doors_executable();
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
