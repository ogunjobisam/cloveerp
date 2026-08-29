-- =============================================================================
-- ERPWare — Part 5.7, the rest of it
--
-- The posting bridge made the general ledger real. What spec 5.7 asks for
-- beyond that is everything a finance function does between a posting and a
-- filing, and none of it existed:
--
--   accounts payable including non-purchase-order approval
--     and payment proposal                                 nothing
--   accounts receivable including cash application,
--     ageing and dunning                                   nothing
--   inventory accounting including accrual, variance,
--     revaluation and provisioning                         partly, via costing
--   fixed assets                                           nothing
--   tax determination and statutory tax reporting          erp.tax_determination
--                                                          exists; nothing
--                                                          determines anything
--   intercompany matching and elimination                  nothing
--   multi-currency with revaluation and translation        refused outright by
--                                                          the posting bridge
--   period close with dependency-tracked tasks and
--     blocking reconciliation checks                       nothing
--
-- Two of these are worth calling out before the code.
--
-- **Multi-currency.** The posting bridge refuses to post a document in a
-- currency the ledger does not report in, with a comment saying a translated
-- figure nobody can trace to a rate is worse than a refusal. That was the right
-- refusal at the time and it is now the thing to fix: rates become configuration
-- with a source and a date, translation records which rate it used, and
-- revaluation is a posting like any other.
--
-- **Period close.** The specification asks for "dependency-tracked tasks and
-- blocking reconciliation checks". Both halves matter and the second is the
-- one that makes it real: a close checklist anybody can tick is a checklist;
-- one where the tick is refused until the reconciliation passes is a control.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exchange rates, and translation that can be explained
-- -----------------------------------------------------------------------------

create table if not exists erp.exchange_rate (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  from_currency char(3) not null references erp_ref.currency(code),
  to_currency   char(3) not null references erp_ref.currency(code),
  rate_type    text not null default 'spot'
                 check (rate_type in ('spot', 'average', 'closing', 'budget', 'fixed')),
  rate         numeric(20,10) not null check (rate > 0),
  valid_from   date not null,
  -- Where it came from. A rate with no source is a number somebody typed, and
  -- the difference matters the first time a figure is questioned.
  source       text not null,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, from_currency, to_currency, rate_type, valid_from),
  constraint exchange_rate_not_self check (from_currency <> to_currency)
);

create or replace function erp.rate_on(
  p_from char(3), p_to char(3), p_on date default null,
  p_type text default 'spot')
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select case when p_from = p_to then 1
              else (select r.rate from erp.exchange_rate r
                     where r.tenant_id = erp.current_tenant_id()
                       and r.from_currency = p_from and r.to_currency = p_to
                       and r.rate_type = p_type
                       and r.valid_from <= coalesce(p_on, current_date)
                     order by r.valid_from desc limit 1)
         end
$$;

comment on function erp.rate_on(char, char, date, text) is
  'The rate in force on a date, from the configured table. Null where there is '
  'none, which every caller must treat as a refusal rather than as one.';

-- -----------------------------------------------------------------------------
-- Accounts payable
--
-- The two things spec 5.7 names: approving an invoice that has no purchase
-- order behind it, and proposing a payment run. Both are places where money
-- leaves, and both are therefore places where the control has to be real.
-- -----------------------------------------------------------------------------

create type erp.payment_proposal_status as enum
  ('draft', 'proposed', 'approved', 'paid', 'cancelled');

create table if not exists erp.payment_proposal (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid not null,
  reference    text not null,
  payment_date date not null,
  currency     char(3) not null references erp_ref.currency(code),
  total_minor  bigint not null default 0,
  status       erp.payment_proposal_status not null default 'draft',
  approval_request_id uuid,
  approved_by  uuid,
  approved_at  timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, reference),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict
);

create table if not exists erp.payment_proposal_line (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  payment_proposal_id uuid not null,
  party_id     uuid not null,
  document_id  uuid,
  subledger_item_id uuid,
  amount_minor bigint not null check (amount_minor > 0),
  discount_minor bigint not null default 0,
  due_date     date,
  is_held      boolean not null default false,
  hold_reason  text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, payment_proposal_id)
    references erp.payment_proposal (tenant_id, id) on delete cascade,
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete restrict,
  foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete restrict
);

create or replace function erp.propose_payment_run(
  p_payment_date date default null,
  p_currency char(3) default null,
  p_include_due_within interval default '7 days'
) returns uuid
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
          -- To the millisecond: two runs proposed in the same second collided
          -- on the unique reference, which is a defect a busy Monday morning
          -- would have found instead of the suite.
          'PAY-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
          coalesce(p_payment_date, current_date), v_ccy, 'draft')
  returning id into v_id;

  for r in
    select si.id as subledger_item_id, si.party_id, si.document_id,
           si.credit_minor - si.debit_minor as amount, si.due_date,
           d.document_number
      from erp.subledger_item si
      left join erp.document d on d.id = si.document_id
     where si.tenant_id = v_tenant
       and si.control_kind = 'payable'
       and si.credit_minor > si.debit_minor
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
                    join erp.document_line ol on ol.id = me.order_line_id
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

comment on function erp.propose_payment_run(date, char, interval) is
  'Spec 5.7: payment proposal. Held lines are listed with the reason rather '
  'than omitted — a run that silently leaves an invoice out is one nobody can '
  'reconcile against the ledger.';

create or replace function erp.approve_payment_run(p_proposal_id uuid)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pp       erp.payment_proposal%rowtype;
begin
  select * into pp from erp.payment_proposal
   where tenant_id = v_tenant and id = p_proposal_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PAYMENT_PROPOSAL: %', p_proposal_id
      using errcode = '23503';
  end if;

  if pp.status <> 'proposed' then
    raise exception 'ERPWARE_PAYMENT_NOT_PROPOSED: % is %', pp.reference, pp.status
      using errcode = '23514';
  end if;

  -- The person who proposed a payment run may not approve it. Money leaving on
  -- one signature is the single control every finance function has.
  if pp.created_by = erp.current_principal_id() then
    raise exception
      'ERPWARE_SEGREGATION_OF_DUTIES: you proposed % and cannot also approve it',
      pp.reference
      using errcode = '42501';
  end if;

  perform erp.authorise('finance.approve_payment', pp.entity_id, null, null,
                        'payment_proposal', p_proposal_id);

  update erp.payment_proposal
     set status = 'approved', approved_by = erp.current_principal_id(),
         approved_at = now(), updated_at = now()
   where id = p_proposal_id;

  return pp.total_minor;
end;
$$;

-- -----------------------------------------------------------------------------
-- Accounts receivable
-- -----------------------------------------------------------------------------

create or replace function erp.receivables_ageing(p_as_at date default null)
returns table (party_id uuid, party_name text, currency char(3),
               current_minor bigint, days_1_30 bigint, days_31_60 bigint,
               days_61_90 bigint, days_over_90 bigint, total_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  with open as (
    select si.party_id, si.currency,
           si.debit_minor - si.credit_minor as amt,
           coalesce(si.due_date, si.posting_date) as due
      from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'receivable'
  )
  select o.party_id, p.name, o.currency,
         sum(o.amt) filter (where o.due >= coalesce(p_as_at, current_date))::bigint,
         sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 1 and 30)::bigint,
         sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 31 and 60)::bigint,
         sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 61 and 90)::bigint,
         sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due > 90)::bigint,
         sum(o.amt)::bigint
    from open o
    join erp.party p on p.id = o.party_id
   group by o.party_id, p.name, o.currency
  having sum(o.amt) <> 0
   order by 9 desc
$$;

create table if not exists erp.dunning_policy (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text,
  -- Each level: how overdue, what to send, and whether it stops trading.
  levels       jsonb not null default '[]'::jsonb,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create or replace function erp.dunning_worklist(p_policy_code text default null)
returns table (party_id uuid, party_name text, oldest_days integer,
               overdue_minor bigint, level_code text, level_action text,
               blocks_trading boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  with pol as (
    select * from erp.dunning_policy
     where tenant_id = erp.current_tenant_id() and status = 'active'
       and (p_policy_code is null or code = p_policy_code)
     order by code limit 1
  ),
  overdue as (
    select si.party_id,
           max(current_date - coalesce(si.due_date, si.posting_date))::integer as days,
           sum(si.debit_minor - si.credit_minor)::bigint as amt
      from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'receivable'
       and coalesce(si.due_date, si.posting_date) < current_date
     group by si.party_id
    having sum(si.debit_minor - si.credit_minor) > 0
  )
  select o.party_id, p.name, o.days, o.amt,
         lv.value ->> 'code', lv.value ->> 'action',
         coalesce((lv.value ->> 'blocks_trading')::boolean, false)
    from overdue o
    join erp.party p on p.id = o.party_id
    cross join pol
    -- The most severe level whose threshold the debt has passed. Sending the
    -- first letter to somebody ninety days overdue is how a ledger of
    -- uncollectable debt is built politely.
    cross join lateral (
      select l.value from jsonb_array_elements(pol.levels) l
       where o.days >= (l.value ->> 'after_days')::integer
       order by (l.value ->> 'after_days')::integer desc
       limit 1
    ) lv
   order by o.days desc
$$;

comment on function erp.dunning_worklist(text) is
  'Spec 5.7: dunning. The most severe level the debt has reached, not the next '
  'one in sequence — sending the first letter to somebody ninety days overdue '
  'is how a ledger of uncollectable debt is built politely.';

create or replace function erp.apply_cash(
  p_party_id uuid,
  p_amount_minor bigint,
  p_currency char(3),
  p_reference text default null
) returns table (subledger_item_id uuid, applied_minor bigint, remaining_minor bigint)
language plpgsql
security invoker
set search_path = ''
as $$
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

  -- Oldest first, which is the only allocation that is defensible without an
  -- instruction from the customer: it is what the law assumes in most
  -- jurisdictions and what an ageing report will otherwise contradict.
  for r in
    select si.id, si.debit_minor - si.credit_minor as owing, si.control_account_id
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.party_id = p_party_id
       and si.control_kind = 'receivable' and si.currency = p_currency
       and si.debit_minor > si.credit_minor
     order by coalesce(si.due_date, si.posting_date), si.id
  loop
    exit when v_left <= 0;
    v_take := least(v_left, r.owing);

    -- Cash application is a posting, not a note. The first version of this
    -- wrote the subledger row alone and broke B7's reconciliation immediately:
    -- the general ledger still showed the receivable and the detail no longer
    -- did. The journal comes first and the subledger row is its detail, which
    -- is the same order erp.post_document_finance() uses and the reason that
    -- reconciliation holds by construction.
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

    -- Detail for BOTH control accounts the journal touched. Writing only the
    -- receivable side left the bank account with a general ledger balance and
    -- no detail, which erp.assert_subledger_reconciles() found immediately —
    -- and which is the same rule erp.post_document_finance() follows by
    -- deriving the subledger row from the account rather than the rule.
    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, v_entity, v_ledger, 'receivable', r.control_account_id,
            p_party_id, v_journal, p_currency, 0, v_take, current_date),
           (v_tenant, v_entity, v_ledger, 'bank', v_bank,
            -- No party on a bank row: the money is in the account, not owed by
            -- anybody, and the same rule the posting bridge applies.
            null, v_journal, p_currency, v_take, 0, current_date);

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
    -- Cash with nothing to apply it to is a real event and a common one. It is
    -- reported rather than refused, because refusing it loses the money — but
    -- it is deliberately not posted to a suspense account here, because a
    -- suspense balance nobody is told about is worse than an unapplied receipt
    -- somebody can see.
    subledger_item_id := null;
    applied_minor := 0;
    remaining_minor := v_left;
    return next;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Fixed assets
--
-- Two depreciation methods, because those are the two that cover almost all
-- statutory practice, and both computed rather than stored: a depreciation
-- schedule that is written down when the asset is capitalised is one that is
-- wrong the first time the asset is impaired or its life is revised.
-- -----------------------------------------------------------------------------

create type erp.depreciation_method as enum ('straight_line', 'reducing_balance');

create table if not exists erp.fixed_asset (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid not null,
  code         text not null,
  name         text not null,
  asset_class  text,
  site_id      uuid,
  acquired_on  date not null,
  cost_minor   bigint not null check (cost_minor >= 0),
  residual_minor bigint not null default 0,
  currency     char(3) not null references erp_ref.currency(code),
  method       erp.depreciation_method not null default 'straight_line',
  useful_life_months integer not null check (useful_life_months > 0),
  reducing_rate_pct numeric(6,3),
  -- Written down and disposed are different ends. An asset scrapped early has
  -- a loss on disposal; one that has run its life has nothing left to lose.
  disposed_on  date,
  disposal_proceeds_minor bigint,
  source_document_id uuid,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete restrict
);

create or replace function erp.depreciation_to_date(
  p_asset_id uuid, p_as_at date default null)
returns table (months_elapsed integer, depreciation_minor bigint,
               net_book_value_minor bigint, fully_depreciated boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  a        erp.fixed_asset%rowtype;
  v_as_at  date := coalesce(p_as_at, current_date);
  v_months integer;
  v_dep    bigint := 0;
  v_nbv    numeric;
  i        integer;
begin
  select * into a from erp.fixed_asset where tenant_id = v_tenant and id = p_asset_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_ASSET: %', p_asset_id using errcode = '23503';
  end if;

  v_months := greatest(0, (extract(year from age(v_as_at, a.acquired_on)) * 12
                           + extract(month from age(v_as_at, a.acquired_on)))::integer);
  v_months := least(v_months, a.useful_life_months);

  if a.method = 'straight_line' then
    v_dep := round((a.cost_minor - a.residual_minor)::numeric
                   * v_months / a.useful_life_months)::bigint;
  else
    -- Reducing balance, applied monthly and stopped at the residual. A
    -- reducing-balance asset never reaches zero mathematically, so the residual
    -- is what makes it terminate rather than approach.
    v_nbv := a.cost_minor;
    for i in 1 .. v_months loop
      exit when v_nbv <= a.residual_minor;
      v_nbv := v_nbv * (1 - coalesce(a.reducing_rate_pct, 25) / 100.0 / 12);
    end loop;
    v_nbv := greatest(v_nbv, a.residual_minor);
    v_dep := (a.cost_minor - v_nbv)::bigint;
  end if;

  months_elapsed := v_months;
  depreciation_minor := v_dep;
  net_book_value_minor := a.cost_minor - v_dep;
  fully_depreciated := v_months >= a.useful_life_months
                       or a.cost_minor - v_dep <= a.residual_minor;
  return next;
end;
$$;

comment on function erp.depreciation_to_date(uuid, date) is
  'Spec 5.7: fixed assets. Computed rather than scheduled — a schedule written '
  'down at capitalisation is wrong the first time a life is revised.';

create or replace function erp.fixed_asset_register(p_as_at date default null)
returns table (code text, name text, asset_class text, acquired_on date,
               cost_minor bigint, depreciation_minor bigint,
               net_book_value_minor bigint, fully_depreciated boolean,
               disposed_on date)
language sql
stable
security invoker
set search_path = ''
as $$
  select a.code, a.name, a.asset_class, a.acquired_on, a.cost_minor,
         d.depreciation_minor, d.net_book_value_minor, d.fully_depreciated,
         a.disposed_on
    from erp.fixed_asset a
    cross join lateral erp.depreciation_to_date(a.id, p_as_at) d
   where a.tenant_id = erp.current_tenant_id()
     and a.status = 'active'
   order by a.code
$$;

-- -----------------------------------------------------------------------------
-- Tax determination
--
-- erp.tax_determination has existed since B7 with columns for the jurisdiction,
-- the legislation pack and version, the rule code and the rule evaluation that
-- produced it — a design that says a tax answer must be explainable. Nothing
-- has ever written one.
--
-- The determination goes through B3's decision-point engine, which is what
-- erp_ref.decision_point's single row, 'tax.determination', has been waiting
-- for since B5 seeded it.
-- -----------------------------------------------------------------------------

create or replace function erp.determine_tax(
  p_document_line_id uuid
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  e        erp.entity%rowtype;
  v_ship_to char(2);
  v_facts  jsonb;
  o        record;
  v_rate   numeric;
  v_code   text;
  v_id     uuid;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_document_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_document_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;
  select * into e from erp.entity where tenant_id = v_tenant and id = d.entity_id;

  select p.country_code into v_ship_to from erp.party p where p.id = d.party_id;

  -- Exactly the facts the decision point declares, and no others.
  -- erp_ref.decision_point.input_schema for tax.determination sets
  -- additionalProperties false and B3's linter refuses a rule reading anything
  -- outside it — which is how the first version of this was caught, having
  -- invented its own vocabulary of from_country, to_country and is_domestic.
  -- The contract was written in B5 and this is the first code to honour it.
  v_facts := jsonb_build_object(
    'supply_type', case
        when coalesce(v_ship_to, e.country_code) = e.country_code then 'domestic'
        else 'export'
      end,
    'item_class', coalesce(
      (select i.item_class from erp.item i where i.id = l.item_id), 'standard'),
    'customer_registered', exists (
      select 1 from erp.party p2
       where p2.tenant_id = v_tenant and p2.id = d.party_id
         and coalesce(p2.tax_identifier, '') <> ''),
    'net_minor', l.net_minor);

  -- B3's decision point is declared requires_match, so the engine raises rather
  -- than returning an unmatched row. Caught and re-raised under this module's
  -- own name, because "no rule matched at tax.determination" is the engine's
  -- account of what happened and "this supply has no tax treatment" is the
  -- one a person can act on.
  begin
    select * into o from erp.evaluate_rules('tax.determination', v_facts,
                                            d.document_date, d.entity_id, d.site_id);
  exception when others then
    raise exception
      'ERPWARE_TAX_UNDETERMINED: no rule covers this supply'
      using errcode = '23503',
      detail = v_facts::text,
      hint = 'A guessed rate is a filing error with a number on it. Configure '
             'a rule set on the tax.determination decision point.';
  end;

  if not coalesce(o.matched, false) then
    raise exception
      'ERPWARE_TAX_UNDETERMINED: no rule covers this supply'
      using errcode = '23503', detail = v_facts::text;
  end if;

  v_rate := (o.outcome ->> 'rate_pct')::numeric;
  -- 'code', not 'tax_code': the outcome schema names it, and inventing a
  -- second name would put the answer somewhere the contract does not describe.
  v_code := o.outcome ->> 'code';

  insert into erp.tax_determination (
    tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
    taxable_minor, tax_minor, currency, jurisdiction, rule_code,
    determination_inputs, rule_evaluation_id, determined_at)
  values (v_tenant, d.entity_id, l.document_id, p_document_line_id,
          v_code, v_rate, l.net_minor,
          round(l.net_minor * v_rate / 100.0)::bigint,
          coalesce(l.currency, d.currency),
          e.country_code,
          o.rule_code, v_facts, null, now())
  returning id into v_id;

  update erp.document_line
     set tax_code = v_code, tax_rate_pct = v_rate,
         tax_minor = round(l.net_minor * v_rate / 100.0)::bigint,
         updated_at = now()
   where id = p_document_line_id;

  return v_id;
end;
$$;

comment on function erp.determine_tax(uuid) is
  'Spec 5.7: tax determination through B3''s rule engine, recording the rule '
  'that decided and the facts it saw. erp_ref.decision_point has carried '
  'tax.determination since B5 and nothing had ever evaluated it.';

create or replace function erp.tax_report(
  p_from date, p_to date, p_entity_id uuid default null)
returns table (jurisdiction text, tax_code text, rate_pct numeric,
               taxable_minor bigint, tax_minor bigint, currency char(3),
               transactions bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Statutory reporting: by jurisdiction and code, because that is the shape
  -- of every return, and traceable to the determinations behind it.
  select td.jurisdiction, td.tax_code, td.rate_pct,
         sum(td.taxable_minor)::bigint, sum(td.tax_minor)::bigint,
         td.currency, count(*)
    from erp.tax_determination td
    join erp.document d on d.id = td.document_id
   where td.tenant_id = erp.current_tenant_id()
     and d.document_date between p_from and p_to
     and (p_entity_id is null or td.entity_id = p_entity_id)
   group by td.jurisdiction, td.tax_code, td.rate_pct, td.currency
   order by 1, 3 desc
$$;

-- -----------------------------------------------------------------------------
-- Intercompany matching
--
-- Two entities of the same tenant trading with each other. The pair must agree
-- and must be eliminated on consolidation, and the useful report is the one
-- that shows where they do not — because the interesting case is always the
-- one where one side has posted and the other has not.
-- -----------------------------------------------------------------------------

create or replace function erp.intercompany_position()
returns table (from_entity text, to_entity text, currency char(3),
               receivable_minor bigint, payable_minor bigint,
               difference_minor bigint, matched boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  with pairs as (
    select si.entity_id, e2.id as counterparty_entity_id, si.currency,
           sum(si.debit_minor - si.credit_minor)
             filter (where si.control_kind = 'receivable') as recv,
           sum(si.credit_minor - si.debit_minor)
             filter (where si.control_kind = 'payable') as pay
      from erp.subledger_item si
      join erp.party p on p.id = si.party_id
      -- A party that IS another entity of this tenant. The link is the party's
      -- code matching an entity's, which is how intercompany counterparties are
      -- set up when they are set up at all.
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.code = p.code
     where si.tenant_id = erp.current_tenant_id()
     group by si.entity_id, e2.id, si.currency
  )
  select e1.code, e2.code, pr.currency,
         coalesce(pr.recv, 0)::bigint, coalesce(pr.pay, 0)::bigint,
         (coalesce(pr.recv, 0) - coalesce(pr.pay, 0))::bigint,
         coalesce(pr.recv, 0) = coalesce(pr.pay, 0)
    from pairs pr
    join erp.entity e1 on e1.id = pr.entity_id
    join erp.entity e2 on e2.id = pr.counterparty_entity_id
   order by 6 desc
$$;

-- -----------------------------------------------------------------------------
-- Currency revaluation
--
-- A balance in a foreign currency is worth a different amount every day. The
-- revaluation posts the difference; it does not restate the original entries,
-- because the original entries are what happened.
-- -----------------------------------------------------------------------------

create or replace function erp.revaluation_report(p_as_at date default null)
returns table (account_code text, currency char(3), balance_minor bigint,
               rate_used numeric, revalued_minor bigint, difference_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select a.code, l.currency,
         sum(l.debit_minor - l.credit_minor)::bigint,
         erp.rate_on(l.currency, led.currency, p_as_at, 'closing'),
         round(sum(l.debit_minor - l.credit_minor)
               * erp.rate_on(l.currency, led.currency, p_as_at, 'closing'))::bigint,
         round(sum(l.debit_minor - l.credit_minor)
               * erp.rate_on(l.currency, led.currency, p_as_at, 'closing'))::bigint
           - sum(l.base_debit_minor - l.base_credit_minor)::bigint
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id and j.status = 'posted'
    join erp.ledger led on led.id = j.ledger_id
    join erp.account a on a.id = l.account_id
   where l.tenant_id = erp.current_tenant_id()
     and l.currency <> led.currency
   group by a.code, l.currency, led.currency
  having erp.rate_on(l.currency, led.currency, p_as_at, 'closing') is not null
$$;

-- -----------------------------------------------------------------------------
-- Period close
--
-- Spec 5.7: "period close with dependency-tracked tasks and blocking
-- reconciliation checks". Both halves, and the second is what makes it a
-- control: a close checklist anybody can tick is a checklist; one where the
-- tick is refused until the reconciliation passes is a control.
-- -----------------------------------------------------------------------------

create table if not exists erp.close_task_template (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text not null,
  seq          integer not null default 100,
  -- What must be finished first. Codes rather than ids, so a template can be
  -- promoted between environments.
  depends_on   text[] not null default '{}'::text[],
  -- The assertion that must pass before this can be completed. Named rather
  -- than described: a check somebody has to remember to run is not a check.
  blocking_check text,
  owner_role_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create table if not exists erp.close_task (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  fiscal_period_id uuid not null,
  code         text not null,
  name         text not null,
  seq          integer not null default 100,
  depends_on   text[] not null default '{}'::text[],
  blocking_check text,
  status       text not null default 'open'
                 check (status in ('open', 'blocked', 'complete', 'waived')),
  completed_at timestamptz,
  completed_by uuid,
  waiver_reason text,
  check_output text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, fiscal_period_id, code),
  foreign key (tenant_id, fiscal_period_id)
    references erp.fiscal_period (tenant_id, id) on delete cascade
);

create or replace function erp.open_period_close(p_fiscal_period_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_n      integer;
begin
  perform erp.authorise('finance.close_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  insert into erp.close_task (
    tenant_id, fiscal_period_id, code, name, seq, depends_on, blocking_check)
  select v_tenant, p_fiscal_period_id, t.code, t.name, t.seq, t.depends_on,
         t.blocking_check
    from erp.close_task_template t
   where t.tenant_id = v_tenant and t.status = 'active'
  on conflict (tenant_id, fiscal_period_id, code) do nothing;

  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception
      'ERPWARE_NO_CLOSE_TEMPLATE: nothing to do at close, which is not the same '
      'as nothing to check'
      using errcode = '23503',
      hint = 'erp.configure_period_close() installs the tasks.';
  end if;

  update erp.fiscal_period set status = 'closing', updated_at = now()
   where tenant_id = v_tenant and id = p_fiscal_period_id;

  return v_n;
end;
$$;

create or replace function erp.complete_close_task(
  p_task_id uuid,
  p_waiver_reason text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        erp.close_task%rowtype;
  v_open   text;
  v_out    text;
begin
  select * into t from erp.close_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CLOSE_TASK: %', p_task_id using errcode = '23503';
  end if;

  perform erp.authorise('finance.close_period', null, null, null,
                        'close_task', p_task_id);

  -- Dependencies. Ticking a task whose predecessor is open is how a close is
  -- signed off in an order nobody intended.
  select string_agg(d.code, ', ') into v_open
    from erp.close_task d
   where d.tenant_id = v_tenant and d.fiscal_period_id = t.fiscal_period_id
     and d.code = any (t.depends_on)
     and d.status not in ('complete', 'waived');

  if v_open is not null then
    raise exception 'ERPWARE_CLOSE_DEPENDENCY_OPEN: % must be finished first', v_open
      using errcode = '23514';
  end if;

  -- The blocking check. Run here, not remembered: the whole difference between
  -- a checklist and a control is that this cannot be ticked past.
  if t.blocking_check is not null then
    begin
      execute format('select %s', t.blocking_check) into v_out;
    exception when others then
      if coalesce(p_waiver_reason, '') = '' then
        raise exception
          'ERPWARE_CLOSE_CHECK_FAILED: % — %', t.blocking_check, sqlerrm
          using errcode = '23514',
          hint = 'Fix it, or waive the task with a reason that will be read at '
                 'audit.';
      end if;
      v_out := 'FAILED: ' || sqlerrm;
    end;
  end if;

  update erp.close_task
     set status = case when p_waiver_reason is null then 'complete' else 'waived' end,
         completed_at = now(), completed_by = erp.current_principal_id(),
         waiver_reason = p_waiver_reason, check_output = v_out,
         updated_at = now()
   where id = p_task_id;

  return coalesce(v_out, 'complete');
end;
$$;

create or replace function erp.close_period(p_fiscal_period_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_open   text;
begin
  perform erp.authorise('finance.close_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  select string_agg(t.code, ', ') into v_open
    from erp.close_task t
   where t.tenant_id = v_tenant and t.fiscal_period_id = p_fiscal_period_id
     and t.status not in ('complete', 'waived');

  if v_open is not null then
    raise exception 'ERPWARE_CLOSE_TASKS_OPEN: % still open', v_open
      using errcode = '23514';
  end if;

  update erp.fiscal_period set status = 'closed', closed_at = now(),
         closed_by = erp.current_principal_id(), updated_at = now()
   where tenant_id = v_tenant and id = p_fiscal_period_id;
end;
$$;

create or replace function erp.close_status(p_fiscal_period_id uuid)
returns table (code text, name text, seq integer, status text,
               blocking_check text, blocked_by text, check_passes boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        record;
  v_out    text;
begin
  for t in
    select * from erp.close_task ct
     where ct.tenant_id = v_tenant and ct.fiscal_period_id = p_fiscal_period_id
     order by ct.seq, ct.code
  loop
    code := t.code; name := t.name; seq := t.seq; status := t.status;
    blocking_check := t.blocking_check;

    select string_agg(d.code, ', ') into blocked_by
      from erp.close_task d
     where d.tenant_id = v_tenant and d.fiscal_period_id = p_fiscal_period_id
       and d.code = any (t.depends_on)
       and d.status not in ('complete', 'waived');

    -- Shown before it is needed, so a close can be worked rather than
    -- discovered one refusal at a time.
    if t.blocking_check is null then
      check_passes := null;
    else
      begin
        execute format('select %s', t.blocking_check) into v_out;
        check_passes := true;
      exception when others then check_passes := false;
      end;
    end if;

    return next;
  end loop;
end;
$$;

comment on function erp.close_status(uuid) is
  'Spec 5.7: the close, worked rather than discovered. Every task with its '
  'dependencies and whether its blocking check would pass right now.';

-- -----------------------------------------------------------------------------
-- Installed
-- -----------------------------------------------------------------------------

create or replace function erp.configure_tax(
  p_home_country char(2) default 'GB',
  p_standard_rate numeric default 20
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_cs uuid;
begin
  -- Tax rules go through B6 like everything else, and here that is not a
  -- preference: erp.guard_live_configuration() refuses a direct write to
  -- erp.rule_set once the environment is live. The first version of this
  -- installed the rules directly and was correctly refused.
  v_cs := erp.install_module_config(
    'tax', 'Tax determination',
    'Which rate applies to which supply, and the rule that says so.',
    jsonb_build_array(
      jsonb_build_object('kind','rule_set','key','vat','payload',
        jsonb_build_object(
          'decision_point','tax.determination',
          'code','vat', 'name','Value added tax',
          'rules', jsonb_build_array(
            -- Order matters and the engine stops on the first match, so the
            -- narrow cases come first.
            jsonb_build_object(
              'seq',10,'code','export_zero','name','Export, zero rated',
              'condition', jsonb_build_object('==', jsonb_build_array(
                jsonb_build_object('var','supply_type'), 'export')),
              'outcome', jsonb_build_object('code','Z','rate_pct',0)),
            jsonb_build_object(
              'seq',20,'code','domestic_standard','name','Domestic standard rate',
              'condition', jsonb_build_object('==', jsonb_build_array(
                jsonb_build_object('var','supply_type'), 'domestic')),
              'outcome', jsonb_build_object('code','S',
                                            'rate_pct',p_standard_rate)))))));

  return v_cs;
end;
$$;

comment on function erp.configure_tax(char, numeric) is
  'Spec 5.7: tax determination as promoted rules on B3''s decision point. Not '
  'optional: B6 refuses a direct write to a rule set in a live environment, '
  'which is exactly the control a tax rate should be under.';

create or replace function erp.configure_period_close()
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'period-close', 'Period close',
    'What has to be true before a period is closed, in the order it has to '
    'become true, with the checks that cannot be ticked past.',
    jsonb_build_array(
      jsonb_build_object('kind','close_task','key','stock_reconciles','payload',
        jsonb_build_object(
          'code','stock_reconciles','name','Stock ledger reconciles',
          'seq',10, 'blocking_check','erp.assert_stock_reconciles()')),
      jsonb_build_object('kind','close_task','key','inventory_valued','payload',
        jsonb_build_object(
          'code','inventory_valued','name','Inventory valuation agrees with the ledger',
          'seq',20, 'depends_on', jsonb_build_array('stock_reconciles'),
          'blocking_check','erp.assert_inventory_reconciles()')),
      jsonb_build_object('kind','close_task','key','subledgers_reconcile','payload',
        jsonb_build_object(
          'code','subledgers_reconcile','name','Subledgers agree with their control accounts',
          'seq',30, 'blocking_check','erp.assert_subledger_reconciles()')),
      jsonb_build_object('kind','close_task','key','grni_reviewed','payload',
        jsonb_build_object(
          'code','grni_reviewed','name','Goods received not invoiced reviewed',
          'seq',40, 'depends_on', jsonb_build_array('subledgers_reconcile'))),
      jsonb_build_object('kind','close_task','key','trial_balance','payload',
        jsonb_build_object(
          'code','trial_balance','name','Trial balance reviewed and signed',
          'seq',90,
          'depends_on', jsonb_build_array('inventory_valued','subledgers_reconcile','grni_reviewed')))));

  return v_cs;
end;
$$;

create or replace function erp.configure_receivables(
  p_first_reminder_days integer default 7,
  p_final_days integer default 45,
  p_stop_days integer default 90
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_cs uuid;
begin
  v_cs := erp.install_module_config(
    'receivables', 'Receivables',
    'When a customer is chased, how, and at what point they stop being sold to.',
    jsonb_build_array(
      -- Cash application is a posting, and B7 refuses a machine-generated
      -- journal line that cannot name the rule that produced it. That refusal
      -- is right: a line nobody can trace to a rule is a line nobody can
      -- explain. So the rule exists, and is promoted like every other.
      jsonb_build_object('kind','posting_rule','key','cash_application','payload',
        jsonb_build_object(
          'code','cash_application','name','Cash application','ledger','GL',
          'event_type','cash.applied',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','1000','side','debit','rate',1,
                               'description','Cash received'),
            jsonb_build_object('account','1100','side','credit','rate',1,
                               'description','Applied to the receivable')))),

      jsonb_build_object('kind','dunning_policy','key','standard','payload',
        jsonb_build_object(
          'code','standard','name','Standard dunning',
          'levels', jsonb_build_array(
            jsonb_build_object('code','reminder','after_days',p_first_reminder_days,
                               'action','statement and reminder','blocks_trading',false),
            jsonb_build_object('code','final','after_days',p_final_days,
                               'action','final demand','blocks_trading',false),
            jsonb_build_object('code','stop','after_days',p_stop_days,
                               'action','account stopped and passed to collection',
                               'blocks_trading',true))))));

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- B6 learns close tasks and dunning policies
-- -----------------------------------------------------------------------------

create or replace function erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    -- Spec 5.7: "declarative posting rules from operational events". Declarative
    -- means configuration, and configuration in this product is promoted rather
    -- than edited — otherwise the rule that decides which account a receipt
    -- lands in would be the one thing in finance nobody had to get approved.
    --
    -- Rules are versioned in place: a new version supersedes the last rather
    -- than replacing it, because a journal line records the rule version that
    -- produced it and that reference must stay resolvable for ever.
    when 'posting_rule' then
      if i.operation = 'remove' then
        update erp.posting_rule pr set status = 'withdrawn', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';
      else
        select coalesce(max(pr.version), 0) + 1 into v_vnum
          from erp.posting_rule pr
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');

        -- Supersede the version in force, and only move its end date if it
        -- actually started earlier.
        --
        -- This is the defect 0019 found in every other activation path,
        -- arriving here through a door that did not exist when 0019 was
        -- written. Setting effective_to = v_from on a version that started on
        -- the same day produces an empty window, which posting_rule_range
        -- refuses. Invisible in normal use, because changes are made on later
        -- days than the versions they replace — and immediate the moment two
        -- change sets touch the same rule in one sitting, which is exactly
        -- what installing finance and then inventory does.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = case when pr.effective_from < v_from then v_from
                                   else pr.effective_to end,
               updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';

        insert into erp.posting_rule (
          tenant_id, code, name, entity_id, ledger_id, event_type, condition,
          posting_lines, version, status, effective_from, legislation_pack_code)
        values (
          v_tenant, p ->> 'code', p ->> 'name', v_entity,
          (select l.id from erp.ledger l
            where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')
              and (v_entity is null or l.entity_id = v_entity)
            order by l.code limit 1),
          p ->> 'event_type',
          coalesce(p -> 'condition', 'true'::jsonb),
          coalesce(p -> 'posting_lines', '[]'::jsonb),
          v_vnum, 'active', v_from, p ->> 'legislation_pack');

        -- A rule that does not balance would raise a journal that cannot post,
        -- and it would do so at month end rather than here. Refusing at
        -- promotion is the whole point of promoting it.
        perform erp.assert_posting_rule_balances(p ->> 'code', v_vnum);
      end if;

    -- Spec 5.1: what a good record looks like is a tenant's opinion, and an
    -- opinion that decides whether a record is fit to trade on belongs in the
    -- same promotion pipeline as everything else. Replaced rather than
    -- versioned: nothing records "the quality rule version that scored this",
    -- so a superseded version would be a row nobody could ever read.
    when 'data_quality_rule' then
      if i.operation = 'remove' then
        update erp.data_quality_rule q set status = 'inactive', updated_at = now()
         where q.tenant_id = v_tenant
           and q.object_type = (p ->> 'object_type')
           and q.code = (p ->> 'code');
      else
        insert into erp.data_quality_rule (
          tenant_id, object_type, code, name, kind, condition, weight,
          severity, message, entity_id, status)
        values (v_tenant, p ->> 'object_type', p ->> 'code', p ->> 'name',
                coalesce(p ->> 'kind', 'completeness'),
                coalesce(p -> 'condition', 'true'::jsonb),
                coalesce((p ->> 'weight')::integer, 1),
                coalesce(p ->> 'severity', 'warning'),
                coalesce(p ->> 'message', p ->> 'name'),
                v_entity, 'active')
        on conflict (tenant_id, object_type, code) do update
          set name = excluded.name, kind = excluded.kind,
              condition = excluded.condition, weight = excluded.weight,
              severity = excluded.severity, message = excluded.message,
              status = 'active', updated_at = now();
      end if;

    -- Which fields cannot change without somebody agreeing. Promoted for the
    -- same reason the approval chains themselves are: a control that its own
    -- subject can switch off is not a control.
    when 'field_approval_rule' then
      if i.operation = 'remove' then
        update erp.field_approval_rule f set status = 'inactive', updated_at = now()
         where f.tenant_id = v_tenant
           and f.object_type = (p ->> 'object_type')
           and f.field_name = (p ->> 'field_name');
      else
        if not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = (p ->> 'object_type')
                          and m.column_name = (p ->> 'field_name')) then
          raise exception
            'ERPWARE_PROMOTION_UNGOVERNABLE_FIELD: %.% is not a maintainable field',
            p ->> 'object_type', p ->> 'field_name'
            using errcode = '23503',
                  hint = 'A rule guarding a field nothing can change is a control '
                         'that will never fire.';
        end if;

        insert into erp.field_approval_rule (
          tenant_id, object_type, field_name, condition, approval_chain_code,
          sensitivity, reason_required, status)
        values (v_tenant, p ->> 'object_type', p ->> 'field_name',
                coalesce(p -> 'condition', 'true'::jsonb),
                p ->> 'approval_chain',
                coalesce((p ->> 'sensitivity')::integer, 100),
                coalesce((p ->> 'reason_required')::boolean, false),
                'active')
        on conflict (tenant_id, object_type, field_name) do update
          set condition = excluded.condition,
              approval_chain_code = excluded.approval_chain_code,
              sensitivity = excluded.sensitivity,
              reason_required = excluded.reason_required,
              status = 'active', updated_at = now();
      end if;

    -- Which stock is valued how. Promoted rather than written, because
    -- switching an item from FIFO to average changes what every future issue
    -- costs and therefore what the accounts say.
    when 'costing_policy' then
      if i.operation = 'remove' then
        update erp.costing_policy c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.costing_policy (
          tenant_id, code, name, method, item_class, entity_id, site_id,
          variance_account_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                (p ->> 'method')::erp.costing_method,
                p ->> 'item_class', v_entity, v_site,
                p ->> 'variance_account', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, method = excluded.method,
              item_class = excluded.item_class,
              variance_account_code = excluded.variance_account_code,
              status = 'active', updated_at = now();
      end if;

    -- What gets counted, how often, and how wrong a count may be before
    -- somebody has to look at it. A tolerance a warehouse can set for itself
    -- is not a tolerance.
    when 'count_programme' then
      if i.operation = 'remove' then
        update erp.count_programme c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.count_programme (
          tenant_id, code, name, site_id, kind, selector,
          tolerance_absolute, tolerance_pct, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_site,
                (p ->> 'kind')::erp.count_programme_kind,
                coalesce(p -> 'selector', 'true'::jsonb),
                coalesce((p ->> 'tolerance_absolute')::numeric, 0),
                coalesce((p ->> 'tolerance_pct')::numeric, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, kind = excluded.kind,
              selector = excluded.selector,
              tolerance_absolute = excluded.tolerance_absolute,
              tolerance_pct = excluded.tolerance_pct,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much more than was ordered may arrive, and what to do with it.
    when 'receipt_tolerance' then
      if i.operation = 'remove' then
        update erp.receipt_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.receipt_tolerance (
          tenant_id, code, name, item_class, over_pct, under_pct, over_action, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'over_pct')::numeric, 0),
                coalesce((p ->> 'under_pct')::numeric, 100),
                coalesce(p ->> 'over_action', 'accept'), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              over_pct = excluded.over_pct, under_pct = excluded.under_pct,
              over_action = excluded.over_action,
              status = 'active', updated_at = now();
      end if;

    -- How far an invoice may differ from the receipt before somebody looks.
    -- The most contested numbers in a finance function, and therefore exactly
    -- the ones that should be promoted rather than typed.
    when 'match_tolerance' then
      if i.operation = 'remove' then
        update erp.match_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.match_tolerance (
          tenant_id, code, name, item_class, quantity_pct, price_pct,
          price_absolute_minor, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'quantity_pct')::numeric, 0),
                coalesce((p ->> 'price_pct')::numeric, 0),
                coalesce((p ->> 'price_absolute_minor')::bigint, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              quantity_pct = excluded.quantity_pct, price_pct = excluded.price_pct,
              price_absolute_minor = excluded.price_absolute_minor,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What may be spent, and what happens when it would be exceeded.
    when 'budget' then
      if i.operation = 'remove' then
        update erp.budget b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.code = (p ->> 'code');
      else
        insert into erp.budget (
          tenant_id, entity_id, code, name, fiscal_year, selector, amount_minor,
          currency, on_exceed, approval_chain_code, status)
        select v_tenant,
               coalesce(v_entity, (select e.id from erp.entity e
                                    where e.tenant_id = v_tenant and e.status = 'active'
                                    order by e.code limit 1)),
               p ->> 'code', p ->> 'name',
               coalesce((p ->> 'fiscal_year')::integer,
                        extract(year from v_from)::integer),
               coalesce(p -> 'selector', 'true'::jsonb),
               (p ->> 'amount_minor')::bigint,
               coalesce(p ->> 'currency',
                        (select e.base_currency from erp.entity e
                          where e.tenant_id = v_tenant limit 1)),
               coalesce(p ->> 'on_exceed', 'block'),
               p ->> 'approval_chain', 'active'
        on conflict (tenant_id, code, fiscal_year) do update
          set name = excluded.name, selector = excluded.selector,
              amount_minor = excluded.amount_minor,
              on_exceed = excluded.on_exceed,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much risk of running out is acceptable, how far ahead the plan is
    -- fixed, and how orders are sized. Every one of those is a number a
    -- business argues about for a fortnight and then nobody revisits, which is
    -- precisely what promotion is for.
    when 'planning_policy' then
      if i.operation = 'remove' then
        update erp.planning_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.planning_policy (
          tenant_id, code, name, reorder_method, safety_stock_basis,
          service_level_pct, lot_sizing, fixed_lot_size, rounding_multiple,
          demand_time_fence_days, planning_time_fence_days, sourcing_rules, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'reorder_method')::erp.reorder_method, 'reorder_point'),
                coalesce(p ->> 'safety_stock_basis', 'statistical'),
                coalesce((p ->> 'service_level_pct')::numeric, 95),
                coalesce(p ->> 'lot_sizing', 'lot_for_lot'),
                (p ->> 'fixed_lot_size')::numeric,
                (p ->> 'rounding_multiple')::numeric,
                coalesce((p ->> 'demand_time_fence_days')::integer, 0),
                coalesce((p ->> 'planning_time_fence_days')::integer, 0),
                coalesce(p -> 'sourcing_rules', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, reorder_method = excluded.reorder_method,
              safety_stock_basis = excluded.safety_stock_basis,
              service_level_pct = excluded.service_level_pct,
              lot_sizing = excluded.lot_sizing,
              fixed_lot_size = excluded.fixed_lot_size,
              rounding_multiple = excluded.rounding_multiple,
              demand_time_fence_days = excluded.demand_time_fence_days,
              planning_time_fence_days = excluded.planning_time_fence_days,
              sourcing_rules = excluded.sourcing_rules,
              status = 'active', updated_at = now();
      end if;

    -- The margin floor, and whether anybody may go under it. Promoted because
    -- it is the number a sales force will ask to have moved.
    when 'pricing_policy' then
      if i.operation = 'remove' then
        update erp.pricing_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.pricing_policy (
          tenant_id, code, name, entity_id, min_margin_pct, allow_below_cost,
          approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_entity,
                coalesce((p ->> 'min_margin_pct')::numeric, 0),
                coalesce((p ->> 'allow_below_cost')::boolean, false),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name,
              min_margin_pct = excluded.min_margin_pct,
              allow_below_cost = excluded.allow_below_cost,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What is inspected and how much of it. Promoted because a sampling rule
    -- is exactly the sort of thing that gets loosened quietly under delivery
    -- pressure and should have to be argued for.
    when 'inspection_plan' then
      if i.operation = 'remove' then
        update erp.inspection_plan ip set status = 'inactive', updated_at = now()
         where ip.tenant_id = v_tenant and ip.code = (p ->> 'code');
      else
        insert into erp.inspection_plan (
          tenant_id, code, name, item_class, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce(p ->> 'trigger_point', 'receipt'),
                coalesce(p -> 'sampling_rule', '{}'::jsonb),
                coalesce(p -> 'characteristics', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              trigger_point = excluded.trigger_point,
              sampling_rule = excluded.sampling_rule,
              characteristics = excluded.characteristics,
              status = 'active', updated_at = now();
      end if;

    -- Which carriers may be used and what they charge. A tariff that anybody
    -- can edit is one where the cheapest carrier is whoever last touched it.
    when 'carrier' then
      if i.operation = 'remove' then
        update erp.carrier c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.carrier (tenant_id, code, name, services, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'services', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
      end if;

    -- What has to be true before a period closes. Promoted, because a close
    -- checklist that the people being checked can shorten is not a control.
    when 'close_task' then
      if i.operation = 'remove' then
        update erp.close_task_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = (p ->> 'code');
      else
        insert into erp.close_task_template (
          tenant_id, code, name, seq, depends_on, blocking_check,
          owner_role_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'seq')::integer, 100),
                coalesce((select array_agg(d #>> '{}')
                            from jsonb_array_elements(coalesce(p -> 'depends_on',
                                                               '[]'::jsonb)) d),
                         '{}'::text[]),
                p ->> 'blocking_check', p ->> 'owner_role', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, seq = excluded.seq,
              depends_on = excluded.depends_on,
              blocking_check = excluded.blocking_check,
              owner_role_code = excluded.owner_role_code,
              status = 'active', updated_at = now();
      end if;

    -- When a customer is chased and when they stop being sold to. The second
    -- is a commercial decision that finance owns and sales will ask to move,
    -- which is exactly what promotion is for.
    when 'dunning_policy' then
      if i.operation = 'remove' then
        update erp.dunning_policy dp set status = 'inactive', updated_at = now()
         where dp.tenant_id = v_tenant and dp.code = (p ->> 'code');
      else
        insert into erp.dunning_policy (tenant_id, code, name, levels, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'levels', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, levels = excluded.levels,
              status = 'active', updated_at = now();
      end if;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier, close_task, dunning_policy';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.finance_depth_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A close task naming a check that does not exist would refuse for ever, or
  -- worse, be waived every month because "it always fails".
  select 'a close task names a check that does not exist',
         t.code, format('blocking_check = %s', t.blocking_check)
    from erp.close_task_template t
   where t.status = 'active' and t.blocking_check is not null
     and not exists (
       select 1 from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname || '.' || p.proname || '()' = t.blocking_check)
  union all
  select 'a close task depends on one that does not exist',
         t.code, format('depends_on = %s', array_to_string(t.depends_on, ', '))
    from erp.close_task_template t
    cross join lateral unnest(t.depends_on) d(code)
   where t.status = 'active'
     and not exists (select 1 from erp.close_task_template t2
                      where t2.tenant_id = t.tenant_id and t2.code = d.code
                        and t2.status = 'active')
  union all
  -- A dunning level that never fires, because a more severe one starts sooner.
  select 'a dunning level is unreachable',
         format('%s.%s', dp.code, lv.value ->> 'code'),
         'a later level starts sooner, so this one is never the most severe '
         'the debt has reached'
    from erp.dunning_policy dp
    cross join lateral jsonb_array_elements(dp.levels) lv
   where dp.status = 'active'
     and exists (select 1 from jsonb_array_elements(dp.levels) lv2
                  where (lv2.value ->> 'after_days')::integer
                        <= (lv.value ->> 'after_days')::integer
                    and (lv2.value ->> 'code') <> (lv.value ->> 'code')
                    and (lv2.value ->> 'after_days')::integer
                        = (lv.value ->> 'after_days')::integer)
  union all
  -- An asset with a reducing-balance method and no rate depreciates at the
  -- built-in default, which nobody chose.
  select 'a reducing-balance asset names no rate',
         a.code, 'it would depreciate at the built-in default, which nobody chose'
    from erp.fixed_asset a
   where a.status = 'active' and a.method = 'reducing_balance'
     and a.reducing_rate_pct is null
  union all
  -- A rate with no source is a number somebody typed.
  select 'an exchange rate has no source',
         format('%s/%s %s', r.from_currency, r.to_currency, r.valid_from),
         'a rate that cannot be traced to where it came from is one that '
         'cannot be defended'
    from erp.exchange_rate r
   where coalesce(trim(r.source), '') = ''
$$;

create or replace function erp.assert_finance_depth_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.finance_depth_report();
  if v_count > 0 then
    raise exception 'ERPWARE_FINANCE_DEPTH_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return 'finance: every close check runs and every rate has a source';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_receivables_ageing(p_as_at date default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb)
        from erp.receivables_ageing(p_as_at) a $$;

create or replace function public.erp_dunning_worklist()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
        from erp.dunning_worklist() d $$;

create or replace function public.erp_fixed_asset_register(p_as_at date default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb)
        from erp.fixed_asset_register(p_as_at) f $$;

create or replace function public.erp_tax_report(p_from date, p_to date)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
        from erp.tax_report(p_from, p_to) t $$;

create or replace function public.erp_close_status(p_fiscal_period_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.close_status(p_fiscal_period_id) c $$;

create or replace function public.erp_intercompany_position()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
        from erp.intercompany_position() i $$;

create or replace function public.erp_configure_period_close()
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_period_close() $$;

create or replace function public.erp_configure_receivables()
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_receivables() $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_receivables_ageing(date)', 'public.erp_dunning_worklist()',
    'public.erp_fixed_asset_register(date)', 'public.erp_tax_report(date, date)',
    'public.erp_close_status(uuid)', 'public.erp_intercompany_position()',
    'public.erp_configure_period_close()', 'public.erp_configure_receivables()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_period_close', 'erp.configure_period_close',
   'Submits the close task template as a B6 change set the caller cannot '
   'approve; a checklist the people being checked can shorten is not a control.'),
  ('erp_configure_receivables', 'erp.configure_receivables',
   'Submits the dunning policy as a B6 change set the caller cannot approve; '
   'the point at which an account is stopped is a commercial decision.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.finance_depth_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid; csi uuid; csc uuid; csr uuid; cspc uuid; cst uuid;
  v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid; v_cust uuid; v_item uuid;
  v_grn uuid; v_pinv uuid; v_pol uuid; v_dn uuid; v_inv uuid;
  v_asset uuid; v_prop uuid; v_period uuid; v_task uuid;
  v_rs uuid; v_rsv uuid;
  v_total bigint; v_n integer; v_out text; dep record; ag record; dw record;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzfdep','Finance Depth','a@zzfdep.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzfdep.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  css := erp.configure_sales(15);
  csi := erp.configure_inventory('average');
  csc := erp.configure_procurement_controls();
  csr := erp.configure_receivables(7, 45, 90);
  cspc := erp.configure_period_close();

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform erp.approve_change_set(csc); perform erp.promote_change_set(csc);
  perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
  perform erp.approve_change_set(cspc); perform erp.promote_change_set(cspc);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'the close checklist installs as promoted configuration',
    (select count(*) from erp.close_task_template t
      where t.tenant_id = r.tenant_id and t.status='active') = 5,
    'a checklist the people being checked can shorten is not a control';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.party (tenant_id,code,name,country_code,status)
  values (r.tenant_id,'SUP','Supplier','GB','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,country_code,status)
  values (r.tenant_id,'CUST','Customer','GB','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor',100000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- ---------------------------------------------------------------------------
  -- Exchange rates.
  -- ---------------------------------------------------------------------------
  insert into erp.exchange_rate (tenant_id, from_currency, to_currency,
                                 rate_type, rate, valid_from, source)
  values (r.tenant_id, 'EUR', 'GBP', 'spot', 0.85, current_date - 1, 'ECB daily fixing'),
         (r.tenant_id, 'EUR', 'GBP', 'closing', 0.87, current_date, 'ECB month end');

  return query select 'a rate is found by date and type, and a missing one is null',
    erp.rate_on('EUR','GBP', current_date, 'spot') = 0.85
    and erp.rate_on('EUR','GBP', current_date, 'closing') = 0.87
    and erp.rate_on('USD','GBP') is null,
    'null is a refusal, and every caller has to treat it as one';

  return query select 'and a rate to itself is one without a row',
    erp.rate_on('GBP','GBP') = 1,
    'the alternative is a table row per currency saying nothing';

  -- ---------------------------------------------------------------------------
  -- Payables: a purchase, an invoice, and a payment run.
  -- ---------------------------------------------------------------------------
  v_grn := erp.open_document('purchase_order', v_sup, null, v_site);
  v_pol := erp.add_document_line(v_grn, v_item, 100, 1000, 'widgets');
  perform erp.transition_document(v_grn,'submit');
  perform erp.transition_document(v_grn,'approve');
  perform erp.transition_document(v_grn,'send');

  declare v_rcpt uuid;
  begin
    v_rcpt := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.receive_against(v_rcpt, v_pol, 100);
    perform erp.transition_document(v_rcpt,'post');
  end;

  v_pinv := erp.open_document('purchase_invoice', v_sup, null, v_site);
  perform erp.invoice_against(v_pinv, v_pol, 100, 1000);
  update erp.document set due_date = current_date + 3 where id = v_pinv;
  perform erp.transition_document(v_pinv,'register');

  return query select 'registering a purchase invoice clears goods-received-not-invoiced',
    (select sum(l.debit_minor) from erp.journal_line l
       join erp.journal j on j.id = l.journal_id
       join erp.account a on a.id = l.account_id
      where j.document_id = v_pinv and a.code = '2100') = 100000,
    'the receipt credited it and nothing had ever debited it';

  return query select 'and the goods-received-not-invoiced account now reconciles',
    (select g.difference_minor from erp.grni_reconciliation() g) = 0,
    'two independent derivations of the same figure';

  v_prop := erp.propose_payment_run(current_date, 'GBP', '7 days');
  return query select 'a payment run picks up what is due',
    (select pp.total_minor from erp.payment_proposal pp where pp.id = v_prop) = 100000,
    'one invoice, due in three days';

  begin
    perform erp.approve_payment_run(v_prop);
    v_ok := false; v_msg := 'the proposer approved their own payment run';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,52); end;
  return query select 'and the person who proposed it cannot approve it', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  v_total := erp.approve_payment_run(v_prop);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  return query select 'somebody else can', v_total = 100000,
    'money leaving on one signature is the control every finance function has';

  -- A disputed invoice is held with the reason on the line.
  declare v_pinv2 uuid; v_pol2 uuid; v_rcpt2 uuid; v_prop2 uuid; v_po2 uuid;
  begin
    -- A second order, because B7 refuses a line added to one already sent —
    -- correctly, and the first version of this case tried to.
    v_po2 := erp.open_document('purchase_order', v_sup, null, v_site);
    v_pol2 := erp.add_document_line(v_po2, v_item, 50, 1000, 'second order');
    perform erp.transition_document(v_po2,'submit');
    perform erp.transition_document(v_po2,'approve');
    perform erp.transition_document(v_po2,'send');

    v_rcpt2 := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.receive_against(v_rcpt2, v_pol2, 50);
    perform erp.transition_document(v_rcpt2,'post');

    v_pinv2 := erp.open_document('purchase_invoice', v_sup, null, v_site);
    -- Billed at a price the receipt does not agree with, which raises a match
    -- exception that nobody has resolved.
    perform erp.invoice_against(v_pinv2, v_pol2, 50, 1500);
    update erp.document set due_date = current_date where id = v_pinv2;
    perform erp.transition_document(v_pinv2,'register');

    v_prop2 := erp.propose_payment_run(current_date, 'GBP', '7 days');
    return query select 'an invoice with an unresolved match exception is held',
      exists (select 1 from erp.payment_proposal_line pl
               where pl.payment_proposal_id = v_prop2 and pl.document_id = v_pinv2
                 and pl.is_held and pl.hold_reason like '%match exception%'),
      'paying an invoice that does not agree with the receipt is what matching is for';

    return query select 'and it is listed with its reason rather than omitted',
      (select pp.total_minor from erp.payment_proposal pp where pp.id = v_prop2)
        < (select sum(pl.amount_minor) from erp.payment_proposal_line pl
            where pl.payment_proposal_id = v_prop2),
      'a run that silently leaves an invoice out is one nobody can reconcile';
  end;

  -- ---------------------------------------------------------------------------
  -- Receivables: ageing, dunning, cash application.
  -- ---------------------------------------------------------------------------
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 40, 2500, 'delivered');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  v_inv := erp.invoice_from_delivery(v_dn);
  update erp.document set due_date = current_date - 50 where id = v_inv;
  perform erp.transition_document(v_inv,'issue');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  select * into ag from erp.receivables_ageing() where party_id = v_cust;
  return query select 'receivables age into buckets from the due date',
    ag.days_31_60 = 100000 and ag.total_minor = 100000,
    format('fifty days overdue: %s in the 31-60 bucket', ag.days_31_60);

  select * into dw from erp.dunning_worklist() where party_id = v_cust;
  return query select 'dunning picks the most severe level the debt has reached',
    dw.level_code = 'final',
    format('%s days overdue reaches %s, not the first reminder',
           dw.oldest_days, dw.level_code);

  return query select 'and that level does not yet stop the account',
    not dw.blocks_trading,
    'stopping is ninety days, and this is fifty';

  declare v_applied bigint;
  begin
    select sum(ca.applied_minor) into v_applied
      from erp.apply_cash(v_cust, 60000, 'GBP', 'BACS-1') ca;
    return query select 'cash applies oldest first and is itself a subledger row',
      v_applied = 60000
      and (select ag2.total_minor from erp.receivables_ageing() ag2
            where ag2.party_id = v_cust) = 40000,
      'marking the original settled would leave the ledger holding a balance '
      'the subledger no longer shows';
  end;

  return query select 'and the subledger still agrees with its control account',
    (select count(*) from erp.subledger_reconciliation_report()) = 0,
    'the reconciliation B7 built and this could have broken';

  -- ---------------------------------------------------------------------------
  -- Fixed assets.
  -- ---------------------------------------------------------------------------
  insert into erp.fixed_asset (
    tenant_id, entity_id, code, name, asset_class, acquired_on, cost_minor,
    residual_minor, currency, method, useful_life_months)
  values (r.tenant_id, r.entity_id, 'FA-1', 'Forklift', 'plant',
          current_date - interval '12 months', 1200000, 200000, 'GBP',
          'straight_line', 60)
  returning id into v_asset;

  select * into dep from erp.depreciation_to_date(v_asset);
  return query select 'straight-line depreciation is computed, not scheduled',
    dep.months_elapsed = 12 and dep.depreciation_minor = 200000
    and dep.net_book_value_minor = 1000000,
    format('a fifth of a million over five years: %s after %s months',
           dep.depreciation_minor, dep.months_elapsed);

  return query select 'and it is not fully depreciated a year into five',
    not dep.fully_depreciated,
    'the flag is derived from the life, not from a status somebody set';

  -- ---------------------------------------------------------------------------
  -- Tax determination, through B3.
  -- ---------------------------------------------------------------------------
  begin
    perform erp.determine_tax(
      (select l.id from erp.document_line l where l.document_id = v_inv limit 1));
    v_ok := false; v_msg := 'tax was determined with no rule configured';
  exception when sqlstate '23503' then
    v_ok := (sqlerrm like '%UNDETERMINED%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'tax with no rule is refused, not guessed', v_ok, v_msg;

  -- Through B6, because B6 refuses a direct write to a rule set in a live
  -- environment — which is exactly the control a tax rate should be under.
  cst := erp.configure_tax('GB', 20);
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.approve_change_set(cst); perform erp.promote_change_set(cst);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'tax rules install as promoted configuration',
    (select count(*) from erp.rule ru
       join erp.rule_set_version rv on rv.id = ru.rule_set_version_id
       join erp.rule_set rs on rs.id = rv.rule_set_id
      where rs.tenant_id = r.tenant_id and rs.decision_point_code = 'tax.determination') = 2,
    'export zero-rated first, domestic standard second';

  declare v_td uuid; v_line uuid;
  begin
    select l.id into v_line from erp.document_line l where l.document_id = v_inv limit 1;
    v_td := erp.determine_tax(v_line);
    return query select 'a determination records the rule that decided and what it saw',
      (select td.rate_pct from erp.tax_determination td where td.id = v_td) = 20
      and (select td.rule_code from erp.tax_determination td where td.id = v_td)
          = 'domestic_standard'
      and (select td.determination_inputs ? 'supply_type'
             from erp.tax_determination td where td.id = v_td),
      'erp_ref.decision_point has carried tax.determination since B5 and '
      'nothing had ever evaluated it';

    return query select 'and the tax lands on the line and in the return',
      (select l.tax_minor from erp.document_line l where l.id = v_line) = 20000
      and (select t.tax_minor from erp.tax_report(current_date - 1, current_date + 1) t
            where t.tax_code = 'S') = 20000,
      'twenty per cent of a hundred thousand';
  end;

  -- ---------------------------------------------------------------------------
  -- Period close.
  -- ---------------------------------------------------------------------------
  select p.id into v_period from erp.fiscal_period p
    join erp.ledger l on l.id = p.ledger_id
   where p.tenant_id = r.tenant_id and l.code = 'GL'
     and current_date between p.starts_on and p.ends_on;

  v_n := erp.open_period_close(v_period);
  return query select 'opening a close raises the tasks from the template',
    v_n = 5
    and (select p.status::text from erp.fiscal_period p where p.id = v_period) = 'closing',
    'five tasks, three of them with a check that cannot be ticked past';

  select ct.id into v_task from erp.close_task ct
   where ct.fiscal_period_id = v_period and ct.code = 'inventory_valued';

  begin
    perform erp.complete_close_task(v_task);
    v_ok := false; v_msg := 'a task was ticked before its dependency';
  exception when sqlstate '23514' then
    v_ok := (sqlerrm like '%DEPENDENCY_OPEN%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'a task cannot be ticked before what it depends on',
    v_ok, v_msg;

  select ct.id into v_task from erp.close_task ct
   where ct.fiscal_period_id = v_period and ct.code = 'stock_reconciles';
  v_out := erp.complete_close_task(v_task);
  return query select 'and one whose blocking check passes completes with its output',
    v_out is not null
    and (select ct.status from erp.close_task ct where ct.id = v_task) = 'complete',
    left(coalesce(v_out, ''), 40);

  begin
    perform erp.close_period(v_period);
    v_ok := false; v_msg := 'a period closed with tasks open';
  exception when sqlstate '23514' then
    v_ok := (sqlerrm like '%TASKS_OPEN%'); v_msg := left(sqlerrm,52);
  end;
  return query select 'and the period will not close with tasks open', v_ok, v_msg;

  return query select 'the close can be worked rather than discovered',
    (select count(*) from erp.close_status(v_period) cs
      where cs.check_passes is not null) = 3,
    'every task shows whether its check would pass right now';

  -- ---------------------------------------------------------------------------
  -- Configuration assertions.
  -- ---------------------------------------------------------------------------
  return query select 'every close check runs and every rate has a source',
    (select count(*) from erp.finance_depth_report()) = 0,
    'a check that always fails is one that is always waived';

  update erp.close_task_template set blocking_check = 'erp.assert_nothing_at_all()'
   where tenant_id = r.tenant_id and code = 'grni_reviewed';
  return query select 'a close task naming a check that does not exist fails the build',
    (select count(*) from erp.finance_depth_report()
      where finding = 'a close task names a check that does not exist') = 1,
    'it would refuse for ever, or be waived every month';
  update erp.close_task_template set blocking_check = null
   where tenant_id = r.tenant_id and code = 'grni_reviewed';

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_finance_depth_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 28;
begin
  create temporary table if not exists zz_fdep_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_fdep_result;
  insert into zz_fdep_result select * from erp_test.finance_depth_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_fdep_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_FINANCE_DEPTH_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_FINANCE_DEPTH_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('finance depth: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_finance_depth_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
