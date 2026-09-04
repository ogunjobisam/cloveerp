-- ─────────────────────────────────────────────────────────────────────────────
-- The posting authority is the transition that is actually running.
--
-- 20260904860000 made the finance bridge accept the permission the document's
-- own posting transition requires, instead of demanding finance.post from
-- whoever moved the document. It found that permission by looking for a
-- transition literally named 'post'.
--
-- That is right for a goods receipt and wrong for everything else. A purchase
-- order reaches the ledger under 'send'; there is no transition called 'post'
-- on it at all, so the lookup returned nothing and the fallback demanded
-- finance.post from the buyer:
--
--   erp.transition_document(purchase_order, 'send')
--   ERROR: ERPWARE_PERMISSION_DENIED: finance.post
--
-- Found in Phase 4, walking procure-to-pay as five different people. The fix
-- for the goods receipt had simply moved the same wall one document along.
--
-- erp.transition_document is the only thing that knows which transition is
-- running, so it now says so — set local, so the setting dies with the
-- transaction rather than leaking into the next call — and the bridge reads
-- the transition being performed rather than guessing its name.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.transition_document(p_document_id uuid, p_transition_code text, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
  v_was_committed boolean;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- The context the guards are evaluated against, from the one function that
  -- knows how to build it. It was assembled here and nowhere else, which meant
  -- erp.available_transitions() — the function a screen asks "what may I do
  -- next?" — could only be called with '{}', and reported every value-banded
  -- transition as blocked. The menu and the enforcement now read one
  -- definition.
  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  -- §18.2: what the document was before it moved, so the meter counts the
  -- first commitment and not every committed state after it.
  select s.is_committed into v_was_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  select s.is_committed into v_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  -- Committed means the outside world now believes this, and both ledgers have
  -- to agree at that moment.
  --
  -- Each half is asked separately, because a sales order passes through three
  -- committed states and only the first of them should raise anything. Asking
  -- "has this already posted?" of each ledger is what makes the second and
  -- third transitions quiet instead of a duplicate-posting error.
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
      -- Which transition is doing the posting. The finance bridge accepts the
      -- authority of the event that caused the ledger entry, and only this
      -- function knows which event that is: a goods receipt posts under
      -- 'post', a purchase order under 'send'. Set local, so it dies with the
      -- transaction and cannot leak into the next call.
      perform set_config('erp.posting_transition', p_transition_code, true);
      perform erp.post_document_finance(p_document_id);
    end if;
  end if;

  return v_to;
end;
$function$

;

CREATE OR REPLACE FUNCTION erp.post_document_finance(p_document_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_txn_permission text;
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  dt        erp.document_type%rowtype;
  bt        erp_ref.document_type%rowtype;
  pr        erp.posting_rule%rowtype;
  led       erp.ledger%rowtype;
  acc       erp.account%rowtype;
  v_event   uuid;
  v_journal uuid;
  v_value   bigint;
  v_cost    bigint;
  v_side    text;
  v_dr      bigint := 0;
  v_cr      bigint := 0;
  v_amount  bigint;
  v_line    jsonb;
  v_no      integer := 0;
  v_ccy     char(3);
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- Most documents reach no ledger, and a caller should not have to know which.
  if not bt.affects_finance then
    return null;
  end if;

  if exists (select 1 from erp.journal j
              where j.tenant_id = v_tenant and j.document_id = p_document_id) then
    raise exception
      'ERPWARE_ALREADY_JOURNALLED: % already has a journal; reverse it rather '
      'than posting again', d.document_number
      using errcode = '23505';
  end if;

  if dt.posting_rule_code is null then
    raise exception
      'ERPWARE_NO_POSTING_RULE: % reaches the ledger but names no posting rule',
      dt.code
      using errcode = '23502',
      detail = 'erp_ref.document_type.affects_finance is true for base type '
               || dt.base_type_code;
  end if;

  -- The version in force on the document's own posting date, not today's.
  -- A journal raised for a backdated document must use the rule that was in
  -- force when it happened, or the explanation of the figure is wrong.
  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant
     and r.code = dt.posting_rule_code
     and r.status = 'active'
     and r.effective_from <= coalesce(d.posting_date, d.document_date, current_date)
     and (r.effective_to is null
          or r.effective_to > coalesce(d.posting_date, d.document_date, current_date))
   order by r.version desc limit 1;

  if not found then
    raise exception
      'ERPWARE_NO_POSTING_RULE_IN_FORCE: no active version of % covers %',
      dt.posting_rule_code, coalesce(d.posting_date, d.document_date, current_date)
      using errcode = '23503',
      hint = 'A rule is promoted with an effective date; a document before that '
             'date has no rule and must not be guessed at.';
  end if;

  select * into led from erp.ledger l
   where l.tenant_id = v_tenant and l.id = pr.ledger_id;

  if not found then
    raise exception 'ERPWARE_POSTING_RULE_HAS_NO_LEDGER: % names no ledger', pr.code
      using errcode = '23503';
  end if;

  v_ccy := coalesce(d.currency, led.currency);

  if v_ccy <> led.currency then
    raise exception
      'ERPWARE_NO_TRANSLATION: % is in % and ledger % reports in %',
      d.document_number, v_ccy, led.code, led.currency
      using errcode = '22000',
      hint = 'No rate source is configured. A translated figure nobody can '
             'trace to a rate is worse than a refusal.';
  end if;

  v_value := erp.document_value_minor(p_document_id);
  -- The stock half has already run and valued its movements, so this is the
  -- cost of what actually moved rather than a second opinion about it.
  v_cost  := erp.document_stock_cost_minor(p_document_id);

  if coalesce(v_value, 0) = 0 then
    raise exception 'ERPWARE_ZERO_VALUE: % has no value to post', d.document_number
      using errcode = '23514',
      hint = 'A journal of zeroes balances and says nothing; it is noise in the '
             'ledger and a gap in the audit trail at the same time.';
  end if;

  -- The permission the transition itself required, before falling back to
  -- finance.post.
  --
  -- A goods receipt's `post` transition requires procurement.receive, and
  -- erp.post_document_stock re-checks exactly that. This bridge demanded
  -- finance.post instead — a different permission, from the same person, for
  -- the ledger consequence of the same authorised event. Under the base pack's
  -- role library no role holds both: warehouse_manager has procurement.receive
  -- and not finance.post, finance_clerk the reverse. Measured: zero of the
  -- eighteen seeded roles can post a goods receipt, so the receipt could be
  -- raised by the warehouse and posted by nobody, and procure-to-pay could not
  -- complete on a default organisation.
  --
  -- The control is not lost. Whoever posts still needs a permission that
  -- authorises this document's own posting, checked against the same entity and
  -- site; a manual journal, which has no transition behind it, still needs
  -- finance.post. What changes is that the ledger entry follows the authority
  -- of the business event rather than demanding a second, unrelated one.
  -- The transition actually being performed, which erp.transition_document
  -- names for us. Looking for a transition literally called 'post' was wrong:
  -- a goods receipt posts under 'post', but a purchase order posts under
  -- 'send', so the lookup found nothing and fell back to demanding
  -- finance.post from the buyer.
  select t.required_permission into v_txn_permission
    from erp.transition t
    join erp.state_machine_version smv on smv.id = t.state_machine_version_id
    join erp.state_machine sm on sm.id = smv.state_machine_id
    join erp.document_type doctype on doctype.tenant_id = v_tenant and doctype.code = sm.code
   where sm.tenant_id = v_tenant
     and doctype.id = d.document_type_id
     and t.required_permission is not null
     and t.code = coalesce(nullif(current_setting('erp.posting_transition', true), ''), 'post')
   limit 1;

  if v_txn_permission is null
     or not erp.has_permission(v_txn_permission, d.entity_id, d.site_id) then
    perform erp.authorise('finance.post', d.entity_id, d.site_id, null,
                          'document', p_document_id);
  else
    perform erp.log_access_decision(v_txn_permission, true, d.entity_id, d.site_id,
                                    null, 'document', p_document_id,
                                    'ledger entry follows the posting authority');
  end if;

  -- Spec 4.7: every posting traces to an operational event. B7's own trigger
  -- refuses a machine-generated line without one, so the event is raised here
  -- rather than left for a caller to remember — and it is the event, not the
  -- document id, because a document may be posted to more than one ledger.
  v_event := erp.append_event(
    'document.posted', 'document', p_document_id,
    jsonb_build_object(
      'document_number', d.document_number,
      'document_type', dt.code,
      'posting_rule', pr.code,
      'posting_rule_version', pr.version,
      'ledger', led.code,
      'value_minor', v_value,
      'currency', v_ccy),
    d.entity_id, d.site_id);

  insert into erp.journal (
    tenant_id, entity_id, ledger_id, source_code, source_event_id, document_id,
    posting_date, description, status)
  values (
    v_tenant, d.entity_id, led.id, pr.event_type, v_event, p_document_id,
    coalesce(d.posting_date, d.document_date, current_date),
    format('%s %s', dt.name, d.document_number),
    'draft')
  returning id into v_journal;

  if (select count(*) from jsonb_array_elements(pr.posting_lines) l
       where coalesce((l.value ->> 'balancing')::boolean, false)) > 1 then
    raise exception
      'ERPWARE_POSTING_RULE_AMBIGUOUS: % names more than one balancing line',
      pr.code using errcode = '23514';
  end if;

  -- Non-balancing lines first, so the balancing line knows what it has to
  -- absorb.
  for v_line in
    select l.value from jsonb_array_elements(pr.posting_lines)
                        with ordinality l(value, ord)
     order by coalesce((l.value ->> 'balancing')::boolean, false), l.ord
  loop
    select * into acc from erp.account a
     where a.tenant_id = v_tenant
       and a.entity_id = d.entity_id
       and a.code = (v_line ->> 'account')
       and a.status = 'active';

    if not found then
      raise exception 'ERPWARE_UNKNOWN_ACCOUNT: % names account %, which this '
        'entity does not have', pr.code, v_line ->> 'account'
        using errcode = '23503';
    end if;

    v_no := v_no + 1;

    if coalesce((v_line ->> 'balancing')::boolean, false) then
      -- Whatever is left. Under standard costing this is the purchase price
      -- variance, and expressing it as "the difference" rather than as
      -- arithmetic in the configuration is what keeps the rule readable.
      v_amount := abs(v_dr - v_cr);
      v_side := case when v_dr > v_cr then 'credit' else 'debit' end;
      -- Nothing to absorb. A zero line balances and says nothing, so it is not
      -- written: under average or FIFO costing a receipt's two bases agree and
      -- the same rule raises two lines rather than three.
      if v_amount = 0 then continue; end if;
    else
      v_amount := round(
        case coalesce(v_line ->> 'basis', 'document_value')
          when 'stock_cost' then v_cost
          else v_value
        end * coalesce((v_line ->> 'rate')::numeric, 1))::bigint;
      v_side := v_line ->> 'side';
    end if;

    if v_side = 'debit' then v_dr := v_dr + v_amount;
                        else v_cr := v_cr + v_amount; end if;

    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id,
      debit_minor, credit_minor, currency,
      base_debit_minor, base_credit_minor, exchange_rate,
      dimensions, posting_rule_id, posting_rule_version, source_event_id,
      description)
    values (
      v_tenant, v_journal, v_no, acc.id,
      case when v_side = 'debit'  then v_amount else 0 end,
      case when v_side = 'credit' then v_amount else 0 end,
      v_ccy,
      case when v_side = 'debit'  then v_amount else 0 end,
      case when v_side = 'credit' then v_amount else 0 end,
      1,
      coalesce(v_line -> 'dimensions', '{}'::jsonb),
      pr.id, pr.version, v_event,
      v_line ->> 'description');

    -- A control account carries its detail in a subledger, and the two must
    -- agree at all times. Deriving this from the account rather than from the
    -- rule is what makes that true by construction.
    if acc.control_kind is not null then
      insert into erp.subledger_item (
        tenant_id, entity_id, ledger_id, control_kind, control_account_id,
        party_id, document_id, journal_id, currency,
        debit_minor, credit_minor, due_date, posting_date)
      values (
        v_tenant, d.entity_id, led.id, acc.control_kind, acc.id,
        -- Who owes it, or is owed it. An inventory or bank control account has
        -- no counterparty, and carrying the document's party onto one anyway
        -- would put a customer against a stock balance — detail that looks
        -- like analysis and is noise.
        case when acc.control_kind in ('payable', 'receivable')
             then d.party_id end,
        p_document_id, v_journal, v_ccy,
        case when v_side = 'debit'  then v_amount else 0 end,
        case when v_side = 'credit' then v_amount else 0 end,
        d.due_date,
        coalesce(d.posting_date, d.document_date, current_date));
    end if;
  end loop;

  -- Posting is the moment it has to balance. The deferred constraint trigger
  -- checks at commit; this flip is what arms it.
  update erp.journal
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return v_journal;
end;
$function$

;
