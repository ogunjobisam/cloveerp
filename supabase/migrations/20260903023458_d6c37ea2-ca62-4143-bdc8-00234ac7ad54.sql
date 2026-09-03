-- Cash application tracked its effect only as a separate contra row, so the
-- original invoice row still looked wholly unpaid to the allocation loop. A
-- second receipt from the same customer would have paid it a second time.
create or replace function erp.apply_cash(
  p_party_id uuid, p_amount_minor bigint, p_currency character,
  p_reference text default null)
returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint)
language plpgsql
set search_path to ''
as $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_left   bigint := p_amount_minor;
  r        record;
  v_take   bigint;
  v_entity uuid;
  v_ledger uuid;
  v_bank   uuid;
  v_journal uuid;
  v_event  uuid;
  v_rule   uuid;
  v_rule_version integer;
  v_no     integer := 0;
begin
  perform erp.authorise('finance.post', null, null, null, 'party', p_party_id);

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  select l.id into v_ledger from erp.ledger l
   where l.tenant_id = v_tenant and l.entity_id = v_entity and l.is_primary;

  select a.id into v_bank from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity
     and a.control_kind = 'bank' and a.status = 'active'
   order by a.code limit 1;

  if v_bank is null then
    raise exception 'ERPWARE_NO_BANK_ACCOUNT: cash has nowhere to land'
      using errcode = '23503';
  end if;

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application'
     and pr.status = 'active'
   order by pr.version desc limit 1;

  if v_rule is null then
    raise exception
      'ERPWARE_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503',
      hint = 'erp.configure_receivables() installs it. B7 refuses a journal '
             'line that cannot name the rule that produced it.';
  end if;

  -- Oldest first, which is the only allocation defensible without an
  -- instruction from the customer. Settled amounts are excluded, so a second
  -- receipt sees only what is genuinely still owed.
  for r in
    select si.id,
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

    if v_journal is null then
      v_event := erp.append_event(
        'document.posted', 'document', p_party_id,
        jsonb_build_object(
          'document_number', coalesce(p_reference, 'cash receipt'),
          'posting_rule', 'cash_application',
          'value_minor', p_amount_minor,
          'currency', p_currency));

      insert into erp.journal (
        tenant_id, entity_id, ledger_id, source_code, source_event_id,
        posting_date, description, status)
      values (v_tenant, v_entity, v_ledger, 'cash.applied', v_event,
              current_date,
              format('Cash received from customer %s', coalesce(p_reference, '')),
              'draft')
      returning id into v_journal;
    end if;

    v_no := v_no + 1;
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate,
      posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no, v_bank, v_take, 0, p_currency,
            v_take, 0, 1, v_rule, v_rule_version, v_event, 'cash received'),
           (v_tenant, v_journal, v_no + 1, r.control_account_id, 0, v_take,
            p_currency, 0, v_take, 1, v_rule, v_rule_version, v_event,
            'applied to receivable');
    v_no := v_no + 1;

    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, v_entity, v_ledger, 'receivable', r.control_account_id,
            p_party_id, v_journal, p_currency, 0, v_take, current_date),
           (v_tenant, v_entity, v_ledger, 'bank', v_bank,
            null, v_journal, p_currency, v_take, 0, current_date);

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

  if v_journal is not null then
    update erp.journal set status = 'posted', posted_at = now(),
           posted_by = erp.current_principal_id()
     where id = v_journal;
  end if;

  if v_left > 0 then
    subledger_item_id := null;
    applied_minor := 0;
    remaining_minor := v_left;
    return next;
  end if;
end;
$function$;

-- Moving an invoice to Paid changed the status and nothing else: the
-- receivable stayed open, so the document said settled while the customer's
-- account said owing. Reaching a paid state now applies the money.
create or replace function erp.transition_document(
  p_document_id uuid, p_transition_code text, p_reason text default null)
returns text
language plpgsql
set search_path to ''
as $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
  v_was_committed boolean;
  v_state_code text;
  v_owing  bigint;
  v_ccy    character;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  select s.is_committed into v_was_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  select s.is_committed, s.code into v_committed, v_state_code
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  if coalesce(v_committed, false) then
    if not coalesce(v_was_committed, false) then
      perform erp.record_meter('documents_posted', 1, v_tenant);
    end if;

    if bt.affects_stock
       and not exists (select 1 from erp.stock_movement m
                        where m.tenant_id = v_tenant and m.document_id = p_document_id)
    then
      perform erp.post_document_stock(p_document_id);
    end if;

    if bt.affects_finance
       and not exists (select 1 from erp.journal j
                        where j.tenant_id = v_tenant and j.document_id = p_document_id)
    then
      perform erp.post_document_finance(p_document_id);
    end if;
  end if;

  -- Paid means the money arrived. What is still open on this document's own
  -- receivable is what arrived, applied through the one function that knows
  -- how to post cash, so the ledger and the status cannot disagree.
  if v_state_code = 'paid' and d.party_id is not null then
    select coalesce(sum(si.debit_minor - si.credit_minor
                        - coalesce(si.settled_minor, 0)), 0), min(si.currency)
      into v_owing, v_ccy
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.document_id = p_document_id
       and si.control_kind = 'receivable';

    if coalesce(v_owing, 0) > 0 then
      perform erp.apply_cash(d.party_id, v_owing, v_ccy,
                             coalesce(d.document_number, 'invoice payment'));
    end if;
  end if;

  return v_to;
end;
$function$;