-- =============================================================================
-- 20260906145000  An approval is net, in its currency, and cash lands in the
--                 company that is owed
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.6, §5.7, §7.4. Phase 9 of the outstanding-work
-- programme, the sixth of seven files; closes deferred findings 17, 22 and 60.
--
-- Finding 17. Two definitions of "what a document is worth" were in use at
-- once: erp.document_value_minor() sums the net, and the approval door summed
-- net plus tax. The same document therefore crossed an approval band at one
-- figure and appeared in every other reading at another, and which of the two
-- an organisation had configured its bands against was a matter of luck. The
-- owner's decision is one definition, net of tax everywhere, so the door now
-- asks the function rather than summing again. Approval bands set against
-- tax-inclusive figures will resolve one step lower than before, which is why
-- this is a change with a date rather than a correction.
--
-- Finding 22. A named approver assignment carries bounds in minor units and
-- nothing said what currency they were in, so a bound written for £10,000 was
-- compared against a €12,000 document as though the two were the same number.
-- Department bands have converted since 20260906082000; named assignments now
-- do the same, through the same rate, and the resolved step records both the
-- assignment's currency and the value converted into it.
--
-- Finding 60. erp.apply_cash() banked every receipt in the first company by
-- code and posted the journal to that company's primary ledger, whatever
-- company the receivable belonged to. A group's second company collected cash
-- into the first company's bank account, and the subledger rows said so. Cash
-- now follows the item: one journal per company owed, in that company's
-- ledger, against that company's bank account. erp.apply_cash_to_item() has
-- always done this; only the bulk form had not.
--
-- Proof: erp_test.document_value_and_cash_suite(); the approval currency,
-- settlement, finance depth, cutover, demo history, second organisation and
-- door isolation suites; the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. One value for a document, and it is the net
-- ═════════════════════════════════════════════════════════════════════════════

do $stamp$
declare
  v_def text;
  v_n   text := E'  select coalesce(sum(l.net_minor + coalesce(l.tax_minor, 0)), 0)::bigint into v_value\n'
             || E'    from erp.document_line l\n'
             || E'   where l.tenant_id = v_tenant and l.document_id = p_document_id\n'
             || E'     and not l.is_cancelled;\n';
  v_r   text := E'  -- One definition of what a document is worth, and it is the one every\n'
             || E'  -- other reading uses: the net. Summing net plus tax here sent the same\n'
             || E'  -- document across a band at one figure and showed it at another\n'
             || E'  -- everywhere else (finding 17).\n'
             || E'  v_value := erp.document_value_minor(p_document_id);\n';
begin
  v_def := pg_get_functiondef('public.erp_stamp_document_approval(uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_STAMP_UNRECOGNISED: public.erp_stamp_document_approval() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$stamp$;

comment on function erp.document_value_minor(uuid) is
  'What a document is worth: the net of its uncancelled lines, in the '
  'document''s own currency. The one definition — approval routing, the '
  'bands and every report read this rather than summing again, because two '
  'sums are two answers.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A named approver's bounds are in a currency
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.approver_assignment
  add column if not exists currency char(3) not null default 'GBP';

comment on column erp.approver_assignment.currency is
  'The currency the bounds are written in. A value in another currency is '
  'converted at the rate in force on the day, as a department band is: '
  'without this a bound for ten thousand pounds admitted twelve thousand '
  'euros as though the numbers were comparable.';

do $chain$
declare
  v_def text;
  v_n1  text := E'       and (aa.lower_bound_minor is null or p_value_minor >= aa.lower_bound_minor)\n'
             || E'       and (aa.upper_bound_minor is null or p_value_minor < aa.upper_bound_minor)\n';
  v_r1  text := E'       and (aa.lower_bound_minor is null\n'
             || E'            or erp.convert_minor(p_value_minor, p_currency, aa.currency, v_on) >= aa.lower_bound_minor)\n'
             || E'       and (aa.upper_bound_minor is null\n'
             || E'            or erp.convert_minor(p_value_minor, p_currency, aa.currency, v_on) < aa.upper_bound_minor)\n';
  v_n2  text := E'      ''source'', ''named_assignment'', ''rule_id'', r.id, ''rule_version'', r.version,\n'
             || E'      ''mode'', r.mode, ''reason'', r.reason);\n';
  v_r2  text := E'      ''source'', ''named_assignment'', ''rule_id'', r.id, ''rule_version'', r.version,\n'
             || E'      ''mode'', r.mode, ''reason'', r.reason,\n'
             || E'      ''assignment_currency'', r.currency,\n'
             || E'      ''lower_bound_minor'', r.lower_bound_minor,\n'
             || E'      ''upper_bound_minor'', r.upper_bound_minor,\n'
             || E'      ''value_in_assignment_currency_minor'',\n'
             || E'        erp.convert_minor(p_value_minor, p_currency, r.currency, v_on));\n';
begin
  v_def := pg_get_functiondef('erp.resolve_approval_chain(text,bigint,character,uuid,uuid,uuid,uuid,date)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_CHAIN_UNRECOGNISED: erp.resolve_approval_chain() is not the body this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$chain$;

-- The writer takes the currency too. Dropped and recreated rather than
-- overloaded: two functions of one name is what makes a positional call
-- ambiguous, and the door calls this positionally.
drop function if exists public.erp_assign_named_approver(text, uuid, text, uuid, text, bigint, bigint, text, date, date);
drop function if exists erp.assign_named_approver(text, uuid, text, uuid, text, bigint, bigint, text, date, date);

create function erp.assign_named_approver(
  p_subject_kind text, p_subject_id uuid, p_object_type text, p_approver_user_id uuid,
  p_mode text default 'prepends',
  p_lower_bound_minor bigint default null, p_upper_bound_minor bigint default null,
  p_reason text default null, p_valid_from date default null, p_valid_to date default null,
  p_currency text default 'GBP')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  if p_subject_kind = 'principal' and p_subject_id = p_approver_user_id then
    raise exception 'CLOVEERP_SELF_APPROVAL: a principal may not be assigned as their own approver'
      using errcode = '23514';
  end if;

  if coalesce(p_currency, '') !~ '^[A-Z]{3}$' then
    raise exception 'CLOVEERP_CURRENCY_UNKNOWN: % is not a three-letter currency', p_currency
      using errcode = '23514',
            hint = 'Write the bounds in a currency: the value of a document in another one is converted at the day''s rate.';
  end if;

  insert into erp.approver_assignment (
    tenant_id, subject_kind, subject_id, object_type, approver_user_id, mode,
    lower_bound_minor, upper_bound_minor, reason, valid_from, valid_to, currency)
  values (
    v_tenant, p_subject_kind::erp.approver_subject_kind, p_subject_id, p_object_type,
    p_approver_user_id, p_mode::erp.approver_assignment_mode,
    p_lower_bound_minor, p_upper_bound_minor, p_reason,
    coalesce(p_valid_from, current_date), p_valid_to, p_currency)
  returning id into v_id;

  return jsonb_build_object('assignment_id', v_id, 'currency', p_currency);
end;
$$;

revoke all on function erp.assign_named_approver(text, uuid, text, uuid, text, bigint, bigint, text, date, date, text) from public, anon;

comment on function erp.assign_named_approver(text, uuid, text, uuid, text, bigint, bigint, text, date, date, text) is
  'Names an approver for a principal, department or role, optionally between '
  'two bounds written in a stated currency. A document in another currency is '
  'converted at the day''s rate before the bounds are read.';

create function public.erp_assign_named_approver(
  p_subject_kind text, p_subject_id uuid, p_object_type text, p_approver_user_id uuid,
  p_mode text default 'prepends',
  p_lower_bound_minor bigint default null, p_upper_bound_minor bigint default null,
  p_reason text default null, p_valid_from date default null, p_valid_to date default null,
  p_currency text default 'GBP')
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.assign_named_approver(p_subject_kind, p_subject_id, p_object_type, p_approver_user_id,
                                   p_mode, p_lower_bound_minor, p_upper_bound_minor, p_reason,
                                   p_valid_from, p_valid_to, p_currency)
$$;

revoke all on function public.erp_assign_named_approver(text, uuid, text, uuid, text, bigint, bigint, text, date, date, text) from public, anon;
grant execute on function public.erp_assign_named_approver(text, uuid, text, uuid, text, bigint, bigint, text, date, date, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_assign_named_approver', 'erp.assign_named_approver',
   'Names an approver for a principal, department or role under administration.configure, with bounds in a stated currency so a value in another is converted rather than compared as a bare number.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The assignment travels through promotion with its currency, or the same
-- configuration would resolve a different chain in a second environment.
do $promoter$
declare
  v_def text;
  v_n   text := E'            p ->> ''reason'', v_from, (p ->> ''valid_to'')::date);\n';
  v_r   text := E'            p ->> ''reason'', v_from, (p ->> ''valid_to'')::date,\n'
             || E'            coalesce(p ->> ''currency'', ''GBP''));\n';
begin
  v_def := pg_get_functiondef('erp.apply_change_set_item'::regproc);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_ARM_UNRECOGNISED: the approver_assignment arm is not the shape this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$promoter$;

do $manifest$
declare
  v_def text;
  v_n   text := E'             ''lower_bound_minor'', aa.lower_bound_minor,\n'
             || E'             ''upper_bound_minor'', aa.upper_bound_minor,\n'
             || E'             ''reason'', aa.reason,\n';
  v_r   text := E'             ''lower_bound_minor'', aa.lower_bound_minor,\n'
             || E'             ''upper_bound_minor'', aa.upper_bound_minor,\n'
             || E'             ''currency'', aa.currency,\n'
             || E'             ''reason'', aa.reason,\n';
begin
  v_def := pg_get_functiondef('erp.configuration_manifest'::regproc);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_MANIFEST_ARM_UNRECOGNISED: the approver_assignment arm is not the shape this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$manifest$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Cash lands in the company that is owed
-- ═════════════════════════════════════════════════════════════════════════════

do $cash$
declare v_def text := pg_get_functiondef('erp.apply_cash(uuid,bigint,character,text,date)'::regprocedure);
begin
  if position(E'  select e.id into v_entity from erp.entity e\n   where e.tenant_id = v_tenant and e.status = ''active'' order by e.code limit 1;' in v_def) = 0
     or position(E'CLOVEERP_NO_BANK_ACCOUNT: cash has nowhere to land' in v_def) = 0 then
    raise exception 'CLOVEERP_APPLY_CASH_UNRECOGNISED: erp.apply_cash() is not the body this migration restates';
  end if;
end
$cash$;

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
    select si.id, si.entity_id, si.ledger_id,
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

  if v_left > 0 then
    subledger_item_id := null;
    applied_minor := 0;
    remaining_minor := v_left;
    return next;
  end if;
end;
$$;

comment on function erp.apply_cash(uuid, bigint, character, text, date) is
  'Applies a receipt against a party''s open receivables, oldest first across '
  'every company the party owes. Each company''s share is posted in that '
  'company''s ledger against its own bank account, because cash banked in '
  'another company''s name is a receipt that reconciles nowhere.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.document_value_and_cash_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_e1 uuid; v_e2 uuid; v_ccy char(3); v_site uuid; v_site2 uuid;
  v_cust uuid; v_item uuid; v_boss uuid;
  v_doc uuid; v_doc2 uuid; v_stamp jsonb; v_step jsonb;
  v_ok boolean; v_msg text; v_hint text;
  v_n integer; v_j integer; v_val bigint;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzvalue', 'Value suite', 'admin@zzvalue.test', 'Value Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f6', 'admin@zzvalue.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f6')::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id, e.base_currency into v_e1, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
    select pr.party_id into v_cust from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
    select v_tenant, 'ZZ-VAL', 'Valued item', 'FG', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_item;

    -- 1. The document's value is its net, and the stamp agrees with the reader.
    v_doc := erp.create_document('sales_order', v_e1, v_site, v_cust, current_date, v_ccy, 'ZZ-SO-VAL', '{}'::jsonb);
    perform erp.add_document_line(v_doc, v_item, 10, 10000, 'ten at a hundred', current_date);
    update erp.document_line set tax_minor = 20000 where document_id = v_doc;
    v_val := erp.document_value_minor(v_doc);
    perform public.erp_stamp_document_approval(v_doc);
    select s.value_minor into v_j from erp.approval_routing_stamp s
     where s.tenant_id = v_tenant and s.object_id = v_doc order by s.resolved_at desc limit 1;
    return query select 'the value the approval is stamped with is the value every other reading gives',
      v_val = 100000 and v_j = v_val,
      format('document_value_minor %s, stamped %s (tax of 20000 excluded from both)', v_val, v_j);

    -- 2. A named assignment's bounds are read in its own currency.
    insert into erp.app_user (tenant_id, email, display_name, kind, status)
    values (v_tenant, 'boss@zzvalue.test', 'The boss', 'person', 'active') returning id into v_boss;
    perform erp.assign_named_approver('principal', v_admin, 'sales_order', v_boss,
      'prepends', 50000, null, 'anything over five hundred pounds', null, null, 'GBP');
    perform erp.load_exchange_rate('EUR', 'GBP', 0.80, current_date, 'spot', 'value suite: a stated reference rate');

    -- 60,000 euro cents is £480 at 0.80 — under the £500 bound, so the boss
    -- is not named; the bare number 60000 would have cleared it.
    v_stamp := erp.resolve_approval_chain('sales_order', 60000, 'EUR'::char(3), null, v_admin, v_e1, v_site);
    v_ok := not exists (select 1 from jsonb_array_elements(v_stamp -> 'steps') st
                         where st ->> 'source' = 'named_assignment');
    -- 70,000 euro cents is £560, over it.
    v_stamp := erp.resolve_approval_chain('sales_order', 70000, 'EUR'::char(3), null, v_admin, v_e1, v_site);
    select st into v_step from jsonb_array_elements(v_stamp -> 'steps') st where st ->> 'source' = 'named_assignment' limit 1;
    return query select 'a named approver''s bounds are read in the currency they were written in',
      v_ok and v_step is not null
      and v_step ->> 'assignment_currency' = 'GBP'
      and (v_step ->> 'value_in_assignment_currency_minor')::bigint = 56000,
      format('€600 did not reach the boss: %s; €700 did, at %s in %s',
             v_ok, v_step ->> 'value_in_assignment_currency_minor', v_step ->> 'assignment_currency');

    -- 3. The writer refuses a currency that is not one.
    begin
      perform erp.assign_named_approver('principal', v_admin, 'purchase_order', v_boss,
        'prepends', 1000, null, 'nonsense', null, null, 'pounds');
      v_ok := false; v_msg := 'a three-letter currency was not required';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_ok := sqlerrm like 'CLOVEERP_CURRENCY_UNKNOWN%' and coalesce(v_hint, '') <> ''; v_msg := left(sqlerrm, 80);
    end;
    return query select 'an assignment in a currency that is not one is refused by name', v_ok, v_msg;

    -- 4. A second company, and a receipt that settles both.
    perform erp.create_entity('ZZ2', 'Second company', null, v_ccy, 'GB');
    select e.id into v_e2 from erp.entity e where e.tenant_id = v_tenant and e.code = 'ZZ2';
    perform erp.configure_finance(extract(year from current_date)::integer, v_ccy, v_e2);
    select s.id into v_site2 from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_e2 limit 1;

    -- One open item in each company, the second company's the older.
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select v_tenant, v_e2, l.id, 'receivable', a.id, v_cust, v_ccy, 40000, 0, current_date - 30, current_date - 30
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = v_tenant and l.entity_id = v_e2 and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     limit 1;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select v_tenant, v_e1, l.id, 'receivable', a.id, v_cust, v_ccy, 60000, 0, current_date - 10, current_date - 10
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = v_tenant and l.entity_id = v_e1 and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     limit 1;

    perform erp.apply_cash(v_cust, 100000, v_ccy, 'ZZ-RECEIPT-1', current_date);

    select count(*) into v_n from erp.journal j
     where j.tenant_id = v_tenant and j.source_code = 'cash.applied' and j.status = 'posted';
    return query select 'a receipt owed to two companies is two journals, each in its own company''s ledger',
      v_n = 2
      and exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id
                   where j.tenant_id = v_tenant and j.source_code = 'cash.applied'
                     and j.entity_id = v_e1 and l.entity_id = v_e1)
      and exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id
                   where j.tenant_id = v_tenant and j.source_code = 'cash.applied'
                     and j.entity_id = v_e2 and l.entity_id = v_e2),
      format('%s cash journals, one per company owed', v_n);

    -- 5. Each company's cash landed in its own bank account.
    return query select 'each company''s share is banked in that company''s own account',
      not exists (
        select 1 from erp.journal_line jl
          join erp.journal j on j.id = jl.journal_id
          join erp.account a on a.id = jl.account_id
         where j.tenant_id = v_tenant and j.source_code = 'cash.applied'
           and a.entity_id is distinct from j.entity_id),
      'no line of a cash journal names an account belonging to another company';

    -- 6. The subledger rows belong to the company that was owed.
    return query select 'the bank and receivable rows the receipt wrote belong to the company that was owed',
      not exists (
        select 1 from erp.subledger_item si
          join erp.journal j on j.id = si.journal_id
         where si.tenant_id = v_tenant and j.source_code = 'cash.applied'
           and si.entity_id is distinct from j.entity_id)
      and (select coalesce(sum(si.settled_minor), 0) from erp.subledger_item si
            where si.tenant_id = v_tenant and si.control_kind = 'receivable'
              and si.party_id = v_cust and si.settled_minor is not null) = 100000,
      'every row sits in the company whose journal wrote it, and the whole receipt is applied';

    -- 7. A company with no bank account refuses by name rather than borrowing one.
    update erp.account set status = 'inactive'
     where tenant_id = v_tenant and entity_id = v_e2 and control_kind = 'bank';
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, currency, debit_minor, credit_minor, posting_date, due_date)
    select v_tenant, v_e2, l.id, 'receivable', a.id, v_cust, v_ccy, 5000, 0, current_date - 40, current_date - 40
      from erp.ledger l join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
     where l.tenant_id = v_tenant and l.entity_id = v_e2 and l.is_primary
       and a.control_kind = 'receivable' and a.status = 'active'
     limit 1;
    begin
      perform erp.apply_cash(v_cust, 5000, v_ccy, 'ZZ-RECEIPT-2', current_date);
      v_ok := false; v_msg := 'cash was banked somewhere else';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_ok := sqlerrm like 'CLOVEERP_NO_BANK_ACCOUNT%' and sqlerrm like '%ZZ2%' and coalesce(v_hint, '') <> '';
      v_msg := left(sqlerrm, 100);
    end;
    return query select 'a company owed cash with no bank account of its own refuses, naming itself', v_ok, v_msg;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 8. Undone.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzvalue'),
    'zzvalue is gone';
end;
$$;

create or replace function erp_test.assert_document_value_and_cash_suite()
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
  create temp table if not exists _document_value_and_cash on commit drop as
    select * from erp_test.document_value_and_cash_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _document_value_and_cash;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DOCUMENT_VALUE_AND_CASH_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DOCUMENT_VALUE_AND_CASH_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('document value and cash: %s/%s cases passed', v_passed, v_total);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_document_value_and_cash_suite();
select erp_test.assert_approval_currency_suite();
select erp_test.assert_settlement_suite();
select erp_test.assert_finance_depth_suite();
select erp_test.assert_migration_cutover_suite();
select erp_test.assert_finance_suite();
select erp_test.assert_demo_history_suite();
select erp_test.assert_second_organisation_suite();
select erp_test.assert_door_isolation_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
