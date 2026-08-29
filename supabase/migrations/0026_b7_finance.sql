-- =============================================================================
-- ERPWare — B7 (part 5/5): finance structures
-- Spec 4.7 (Finance)
--
-- Four invariants, all of them enforceable rather than aspirational:
--
--   "every journal balances by ledger and currency"
--       A DEFERRABLE constraint trigger, checked at commit. Deferred because
--       lines arrive one at a time and a journal is unbalanced in the middle of
--       being written; checked at commit because it must be impossible for an
--       unbalanced journal to exist afterwards. Per ledger AND per currency:
--       a journal that balances in total but not within each currency is two
--       broken journals wearing a trench coat.
--
--   "every posting traces to an operational event and the rule version that
--    produced it"
--       Columns on every line, and a check that refuses a machine-generated
--       line without them. Manual journals are the deliberate exception and
--       carry a reason instead.
--
--   "a closed period cannot be posted to without an explicit reopening event"
--       A trigger on posting, plus an append-only reopening record. "Explicit
--       event" means there is a row with a name against it, not a status field
--       somebody flipped back.
--
--   "subledger totals equal their control accounts at all times"
--       erp.assert_subledger_reconciles(). The classic month-end discovery
--       that a control account and its subledger have drifted apart is a
--       reconciliation nobody ran until it was too late to find the cause.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Ledgers and periods
-- -----------------------------------------------------------------------------

create type erp.ledger_kind as enum ('statutory', 'group', 'tax', 'management', 'budget');
create type erp.period_status as enum ('future', 'open', 'closing', 'closed', 'permanently_closed');

create table erp.ledger (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  code           text not null,
  name           text not null,
  ledger_kind    erp.ledger_kind not null,
  currency       char(3) not null references erp_ref.currency(code),
  -- The statutory ledger is the one that must balance for filing; others are
  -- parallel views of the same events under different rules.
  is_primary     boolean not null default false,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, entity_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

create unique index ledger_one_primary
  on erp.ledger (tenant_id, entity_id) where is_primary;

create table erp.fiscal_period (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  ledger_id      uuid not null,
  code           text not null,
  fiscal_year    integer not null,
  period_number  smallint not null check (period_number between 1 and 13),
  starts_on      date not null,
  ends_on        date not null,
  status         erp.period_status not null default 'future',
  closed_at      timestamptz,
  closed_by      uuid,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, ledger_id, fiscal_year, period_number),
  foreign key (tenant_id, ledger_id) references erp.ledger (tenant_id, id) on delete cascade,
  constraint fiscal_period_range check (ends_on >= starts_on),
  -- Periods of one ledger cannot overlap, or a posting date belongs to two.
  constraint fiscal_period_no_overlap
    exclude using gist (
      tenant_id with =,
      ledger_id with =,
      daterange(starts_on, ends_on, '[]') with &&
    )
);

create index on erp.fiscal_period (tenant_id, ledger_id, starts_on);

-- Spec 4.7: an explicit reopening event, not a status flipped back.
create table erp.period_reopening (
  id               bigint generated always as identity primary key,
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  fiscal_period_id uuid not null,
  reopened_at      timestamptz not null default clock_timestamp(),
  reopened_by      uuid,
  reason           text not null,
  approval_request_id uuid,
  reclosed_at      timestamptz,
  reclosed_by      uuid,
  foreign key (tenant_id, fiscal_period_id)
    references erp.fiscal_period (tenant_id, id) on delete cascade
);

create index on erp.period_reopening (tenant_id, fiscal_period_id, reopened_at desc);

-- -----------------------------------------------------------------------------
-- Chart of accounts
-- -----------------------------------------------------------------------------

create type erp.account_type as enum (
  'asset', 'liability', 'equity', 'income', 'expense',
  'statistical', 'off_balance_sheet'
);

create type erp.control_account_kind as enum (
  'payable', 'receivable', 'inventory', 'fixed_asset', 'tax', 'bank', 'wip'
);

create table erp.account (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  code           text not null,
  name           text not null,
  account_type   erp.account_type not null,
  parent_account_id uuid,
  group_code     text,
  -- A control account is reconciled against a subledger and may not be posted
  -- to directly; the subledger is where the detail lives.
  control_kind   erp.control_account_kind,
  is_postable    boolean not null default true,
  requires_dimensions text[] not null default '{}'::text[],
  currency       char(3) references erp_ref.currency(code),
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, entity_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, parent_account_id)
    references erp.account (tenant_id, id) on delete restrict,
  constraint account_not_own_parent check (parent_account_id is distinct from id)
);

create index on erp.account (tenant_id, entity_id, account_type) where status = 'active';
create index on erp.account (tenant_id, control_kind) where control_kind is not null;

-- -----------------------------------------------------------------------------
-- Analytical dimensions
-- -----------------------------------------------------------------------------

create table erp.dimension (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  name           text not null,
  -- How the value is worked out from the source event, as a declarative
  -- expression over the event payload (B3 interpreter).
  derivation     jsonb,
  is_mandatory_default boolean not null default false,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create table erp.dimension_value (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  dimension_id   uuid not null,
  code           text not null,
  name           text not null,
  parent_value_id uuid,
  valid_from     date,
  valid_to       date,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, dimension_id, code),
  foreign key (tenant_id, dimension_id) references erp.dimension (tenant_id, id) on delete cascade,
  foreign key (tenant_id, parent_value_id)
    references erp.dimension_value (tenant_id, id) on delete restrict
);

-- Which combinations are permitted (spec 4.7). A cost centre that does not
-- exist in a given company is a posting nobody can explain later.
create table erp.dimension_combination_rule (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid,
  code           text not null,
  name           text,
  -- A declarative condition over the proposed dimension set.
  condition      jsonb not null default 'true'::jsonb,
  -- 'permit' narrows to an allow-list; 'forbid' blocks specific pairings.
  effect         text not null default 'forbid' check (effect in ('permit', 'forbid')),
  message        text,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

-- -----------------------------------------------------------------------------
-- Posting rules
--
-- Spec 4.7: "declarative mapping from an operational event to accounts and
-- dimensions, per entity and legislation". A posting rule is configuration, so
-- two tenants can account for the same event differently without a branch.
-- -----------------------------------------------------------------------------

create table erp.posting_rule (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  name           text,
  entity_id      uuid,
  ledger_id      uuid,
  -- The operational event this rule accounts for.
  event_type     text not null,
  condition      jsonb not null default 'true'::jsonb,
  -- The lines to raise: account selectors, dimension derivations, and which
  -- side each takes, as data.
  posting_lines  jsonb not null default '[]'::jsonb,
  version        integer not null default 1,
  status         erp.config_version_status not null default 'draft',
  effective_from date not null default current_date,
  effective_to   date,
  legislation_pack_code text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code, version),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, ledger_id) references erp.ledger (tenant_id, id) on delete cascade,
  constraint posting_rule_range check (effective_to is null or effective_to > effective_from)
);

create index on erp.posting_rule (tenant_id, event_type, status);

-- -----------------------------------------------------------------------------
-- Journals
-- -----------------------------------------------------------------------------

create type erp.journal_status as enum ('draft', 'posted', 'reversed');

create table erp.journal (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  ledger_id      uuid not null,
  fiscal_period_id uuid,
  journal_number text,
  -- Where this came from: an event type, or 'manual'.
  source_code    text not null,
  source_event_id uuid,
  document_id    uuid,
  posting_date   date not null default current_date,
  description    text,
  status         erp.journal_status not null default 'draft',
  posted_at      timestamptz,
  posted_by      uuid,
  reverses_journal_id uuid,
  -- Only manual journals may lack a rule; they carry a reason instead.
  manual_reason  text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, ledger_id) references erp.ledger (tenant_id, id) on delete restrict,
  foreign key (tenant_id, fiscal_period_id)
    references erp.fiscal_period (tenant_id, id) on delete restrict,
  foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete restrict,
  foreign key (tenant_id, reverses_journal_id)
    references erp.journal (tenant_id, id) on delete restrict,
  constraint journal_manual_has_reason
    check (source_code <> 'manual' or manual_reason is not null)
);

create index on erp.journal (tenant_id, ledger_id, posting_date desc);
create index on erp.journal (tenant_id, document_id) where document_id is not null;
create index on erp.journal (tenant_id, source_event_id) where source_event_id is not null;

create table erp.journal_line (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  journal_id     uuid not null,
  line_no        integer not null,
  account_id     uuid not null,

  -- Both in minor units. One of the two is zero on any given line.
  debit_minor    bigint not null default 0 check (debit_minor >= 0),
  credit_minor   bigint not null default 0 check (credit_minor >= 0),
  currency       char(3) not null references erp_ref.currency(code),
  -- The same amounts in the ledger's own currency, for a ledger that reports
  -- in something other than the transaction currency.
  base_debit_minor  bigint not null default 0,
  base_credit_minor bigint not null default 0,
  exchange_rate  numeric(20,10),

  dimensions     jsonb not null default '{}'::jsonb,

  -- Spec 4.7: the posting rule and rule version recorded on every line.
  posting_rule_id      uuid,
  posting_rule_version integer,
  source_event_id      uuid,

  description    text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, journal_id, line_no),
  foreign key (tenant_id, journal_id) references erp.journal (tenant_id, id) on delete cascade,
  foreign key (tenant_id, account_id) references erp.account (tenant_id, id) on delete restrict,
  foreign key (tenant_id, posting_rule_id)
    references erp.posting_rule (tenant_id, id) on delete restrict,
  -- A line is a debit or a credit, not both and not neither.
  constraint journal_line_one_side
    check ((debit_minor > 0) <> (credit_minor > 0))
);

create index on erp.journal_line (tenant_id, journal_id, line_no);
create index on erp.journal_line (tenant_id, account_id);
create index on erp.journal_line using gin (dimensions jsonb_path_ops);

-- -----------------------------------------------------------------------------
-- Invariant: every journal balances, by ledger and by currency
-- -----------------------------------------------------------------------------

create or replace function erp.check_journal_balances()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_journal uuid := coalesce(new.journal_id, old.journal_id);
  v_status  erp.journal_status;
  r         record;
begin
  select j.status into v_status from erp.journal j where j.id = v_journal;

  -- A draft is allowed to be lopsided; that is what draft means. Posting is
  -- the moment it has to be true.
  if v_status is distinct from 'posted' then
    return null;
  end if;

  for r in
    select l.currency,
           sum(l.debit_minor) as debits,
           sum(l.credit_minor) as credits
      from erp.journal_line l
     where l.journal_id = v_journal
     group by l.currency
  loop
    if r.debits <> r.credits then
      raise exception
        'ERPWARE_JOURNAL_UNBALANCED: journal % is out by % in %',
        v_journal, r.debits - r.credits, r.currency
        using errcode = '23514',
              hint = 'A journal must balance within each currency, not merely in total.';
    end if;
  end loop;

  return null;
end;
$$;

-- Deferred to commit: lines arrive one at a time, so the journal is
-- legitimately unbalanced while it is being written. What must never exist is
-- an unbalanced journal after the transaction ends.
create constraint trigger t_journal_line_balances
  after insert or update or delete on erp.journal_line
  deferrable initially deferred
  for each row execute function erp.check_journal_balances();

-- The same check, reached from the journal side when it is posted with no
-- further line activity — a journal whose lines were written while it was
-- draft and which is then simply flipped to posted.
create or replace function erp.check_journal_balance_on_post()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  if new.status is distinct from 'posted' then
    return null;
  end if;

  if not exists (select 1 from erp.journal_line l where l.journal_id = new.id) then
    raise exception 'ERPWARE_JOURNAL_EMPTY: journal % has no lines', new.id
      using errcode = '23514';
  end if;

  for r in
    select l.currency, sum(l.debit_minor) as debits, sum(l.credit_minor) as credits
      from erp.journal_line l where l.journal_id = new.id group by l.currency
  loop
    if r.debits <> r.credits then
      raise exception 'ERPWARE_JOURNAL_UNBALANCED: journal % is out by % in %',
        new.id, r.debits - r.credits, r.currency using errcode = '23514';
    end if;
  end loop;

  return null;
end;
$$;

create constraint trigger t_journal_balances
  after update of status on erp.journal
  deferrable initially deferred
  for each row execute function erp.check_journal_balance_on_post();

-- -----------------------------------------------------------------------------
-- Invariants: traceable postings, closed periods, unpostable control accounts
-- -----------------------------------------------------------------------------

create or replace function erp.check_journal_line_posting()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_source   text;
  v_account  erp.account%rowtype;
  v_missing  text[];
  d          text;
begin
  select j.source_code into v_source from erp.journal j where j.id = new.journal_id;

  -- Spec 4.7: every posting traces to an operational event and the rule
  -- version that produced it. Manual journals are the stated exception and
  -- carry a reason on the journal instead.
  if v_source <> 'manual'
     and (new.posting_rule_id is null or new.source_event_id is null) then
    raise exception
      'ERPWARE_POSTING_NOT_TRACEABLE: a machine-generated line must name its source event and posting rule'
      using errcode = '23514',
            hint = 'Only a manual journal may post without a rule, and it must carry a reason.';
  end if;

  select * into v_account from erp.account a where a.id = new.account_id;

  if not v_account.is_postable then
    raise exception 'ERPWARE_ACCOUNT_NOT_POSTABLE: % is a summary or control account',
      v_account.code using errcode = '23514';
  end if;

  -- Dimensions the account insists on.
  v_missing := '{}';
  foreach d in array v_account.requires_dimensions loop
    if not (new.dimensions ? d) then
      v_missing := v_missing || d;
    end if;
  end loop;

  if cardinality(v_missing) > 0 then
    raise exception 'ERPWARE_DIMENSION_REQUIRED: % requires %',
      v_account.code, array_to_string(v_missing, ', ') using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger t_journal_line_posting
  before insert or update on erp.journal_line
  for each row execute function erp.check_journal_line_posting();

create or replace function erp.check_period_open()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_period erp.fiscal_period%rowtype;
  v_reopen boolean;
begin
  if new.status is distinct from 'posted' then
    return new;
  end if;

  select p.* into v_period
    from erp.fiscal_period p
   where p.tenant_id = new.tenant_id
     and p.ledger_id = new.ledger_id
     and new.posting_date between p.starts_on and p.ends_on;

  if not found then
    raise exception 'ERPWARE_NO_FISCAL_PERIOD: no period of this ledger contains %',
      new.posting_date using errcode = '23514';
  end if;

  new.fiscal_period_id := v_period.id;

  if v_period.status = 'permanently_closed' then
    raise exception 'ERPWARE_PERIOD_PERMANENTLY_CLOSED: % cannot be reopened', v_period.code
      using errcode = '42501';
  end if;

  if v_period.status = 'closed' then
    -- An explicit reopening event, still open. Not a flag.
    select exists (
      select 1 from erp.period_reopening r
       where r.tenant_id = new.tenant_id
         and r.fiscal_period_id = v_period.id
         and r.reclosed_at is null
    ) into v_reopen;

    if not v_reopen then
      raise exception
        'ERPWARE_PERIOD_CLOSED: % is closed; record a reopening with a reason before posting to it',
        v_period.code
        using errcode = '42501',
              hint = 'erp.reopen_period() records who reopened it and why.';
    end if;
  end if;

  return new;
end;
$$;

create trigger t_journal_period
  before insert or update on erp.journal
  for each row execute function erp.check_period_open();

create or replace function erp.reopen_period(p_fiscal_period_id uuid, p_reason text)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     bigint;
begin
  perform erp.authorise('finance.reopen_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_REOPENING_NEEDS_REASON: a period is not reopened without one'
      using errcode = '23514';
  end if;

  insert into erp.period_reopening (tenant_id, fiscal_period_id, reopened_by, reason)
  values (v_tenant, p_fiscal_period_id, erp.current_principal_id(), p_reason)
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Subledgers
-- -----------------------------------------------------------------------------

create table erp.subledger_item (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  ledger_id      uuid not null,
  control_kind   erp.control_account_kind not null,
  control_account_id uuid not null,
  -- What the detail is about: a supplier, a customer, an item, an asset.
  party_id       uuid,
  item_id        uuid,
  asset_code     text,
  document_id    uuid,
  journal_id     uuid,
  currency       char(3) not null references erp_ref.currency(code),
  debit_minor    bigint not null default 0 check (debit_minor >= 0),
  credit_minor   bigint not null default 0 check (credit_minor >= 0),
  due_date       date,
  settled_minor  bigint not null default 0,
  posting_date   date not null default current_date,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, ledger_id) references erp.ledger (tenant_id, id) on delete restrict,
  foreign key (tenant_id, control_account_id)
    references erp.account (tenant_id, id) on delete restrict,
  foreign key (tenant_id, party_id) references erp.party (tenant_id, id) on delete restrict,
  foreign key (tenant_id, item_id)  references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, journal_id) references erp.journal (tenant_id, id) on delete restrict
);

create index on erp.subledger_item (tenant_id, control_account_id);
create index on erp.subledger_item (tenant_id, party_id, due_date) where party_id is not null;

-- Spec 4.7: subledger totals equal their control accounts at all times.
create or replace function erp.subledger_reconciliation_report()
returns table (
  control_account_id uuid,
  account_code   text,
  control_kind   erp.control_account_kind,
  currency       char(3),
  ledger_balance_minor    bigint,
  subledger_balance_minor bigint,
  difference_minor        bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  with control as (
    select a.id, a.code, a.control_kind
      from erp.account a
     where a.tenant_id = erp.require_tenant_id()
       and a.control_kind is not null
       and a.status = 'active'
  ),
  gl as (
    select l.account_id, l.currency,
           sum(l.debit_minor) - sum(l.credit_minor) as balance
      from erp.journal_line l
      join erp.journal j on j.id = l.journal_id and j.status = 'posted'
     where l.tenant_id = erp.current_tenant_id()
     group by l.account_id, l.currency
  ),
  sl as (
    select s.control_account_id, s.currency,
           sum(s.debit_minor) - sum(s.credit_minor) as balance
      from erp.subledger_item s
     where s.tenant_id = erp.current_tenant_id()
     group by s.control_account_id, s.currency
  )
  select c.id, c.code, c.control_kind,
         coalesce(gl.currency, sl.currency),
         coalesce(gl.balance, 0),
         coalesce(sl.balance, 0),
         coalesce(gl.balance, 0) - coalesce(sl.balance, 0)
    from control c
    left join gl on gl.account_id = c.id
    full outer join sl
      on sl.control_account_id = c.id
     and sl.currency is not distinct from gl.currency
   where coalesce(gl.balance, 0) is distinct from coalesce(sl.balance, 0)
$$;

create or replace function erp.assert_subledger_reconciles()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s (%s, %s): ledger %s, subledger %s, out by %s',
                                     r.account_code, r.control_kind, r.currency,
                                     r.ledger_balance_minor, r.subledger_balance_minor,
                                     r.difference_minor), E'\n')
    into v_count, v_detail
    from erp.subledger_reconciliation_report() r;

  if v_count > 0 then
    raise exception
      E'ERPWARE_SUBLEDGER_DOES_NOT_RECONCILE: % control account(s) disagree with their detail\n%',
      v_count, v_detail;
  end if;

  return 'subledger: every control account equals its detail';
end;
$$;

comment on function erp.assert_subledger_reconciles() is
  'Spec 4.7: subledger totals equal their control accounts at all times. Run '
  'continuously rather than at month end, because the value of this check is '
  'entirely in how early it fires.';

-- -----------------------------------------------------------------------------
-- Tax determination, recorded on the transaction (spec 4.7)
-- -----------------------------------------------------------------------------

create table erp.tax_determination (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  document_id    uuid,
  document_line_id uuid,
  journal_line_id uuid,
  -- The answer, and everything needed to defend it.
  tax_code       text not null,
  rate_pct       numeric(9,4) not null,
  taxable_minor  bigint not null,
  tax_minor      bigint not null,
  currency       char(3) not null references erp_ref.currency(code),
  jurisdiction   text,
  -- Which pack, which rule, which inputs. A tax answer nobody can reconstruct
  -- is an answer that cannot be defended in an inspection.
  legislation_pack_code text,
  legislation_pack_version integer,
  rule_code      text,
  determination_inputs jsonb not null default '{}'::jsonb,
  rule_evaluation_id bigint,
  determined_at  timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete cascade,
  foreign key (tenant_id, document_line_id)
    references erp.document_line (tenant_id, id) on delete cascade
);

create index on erp.tax_determination (tenant_id, document_id);
create index on erp.tax_determination (tenant_id, entity_id, determined_at desc);

-- -----------------------------------------------------------------------------
-- Reading
-- -----------------------------------------------------------------------------

create view erp.account_balance as
select
  l.tenant_id, j.entity_id, j.ledger_id, l.account_id, a.code as account_code,
  a.account_type, l.currency, j.fiscal_period_id,
  sum(l.debit_minor)  as debit_minor,
  sum(l.credit_minor) as credit_minor,
  sum(l.debit_minor) - sum(l.credit_minor) as balance_minor
from erp.journal_line l
join erp.journal j on j.tenant_id = l.tenant_id and j.id = l.journal_id
join erp.account a on a.tenant_id = l.tenant_id and a.id = l.account_id
where j.status = 'posted'
group by l.tenant_id, j.entity_id, j.ledger_id, l.account_id, a.code,
         a.account_type, l.currency, j.fiscal_period_id;

comment on view erp.account_balance is
  'Balances derived from posted journal lines. Spec 4.10: nothing meaningful is '
  'stored as a mutable total.';

-- Drill-down from any figure to its originating event (spec 5.7).
create or replace function erp.explain_posting(p_journal_line_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'journal', j.id,
    'journal_number', j.journal_number,
    'ledger', lg.code,
    'posting_date', j.posting_date,
    'period', fp.code,
    'account', a.code,
    'account_name', a.name,
    'debit_minor', l.debit_minor,
    'credit_minor', l.credit_minor,
    'currency', l.currency,
    'dimensions', l.dimensions,
    'source', j.source_code,
    'source_event', l.source_event_id,
    'posting_rule', pr.code,
    'posting_rule_version', l.posting_rule_version,
    'document', d.document_number,
    'event_payload', (select e.payload from erp.event e where e.id = l.source_event_id),
    'event_occurred_at', (select e.occurred_at from erp.event e where e.id = l.source_event_id))
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id
    join erp.ledger lg on lg.id = j.ledger_id
    join erp.account a on a.id = l.account_id
    left join erp.fiscal_period fp on fp.id = j.fiscal_period_id
    left join erp.posting_rule pr on pr.id = l.posting_rule_id
    left join erp.document d on d.id = j.document_id
   where l.tenant_id = erp.require_tenant_id()
     and l.id = p_journal_line_id
$$;

comment on function erp.explain_posting(uuid) is
  'Spec 5.7: drill-down from any figure to the originating event. Returns the '
  'posting, the rule version that produced it, and the event payload it was '
  'derived from.';

select erp_meta.register_table('erp', 'period_reopening', 'tenant_scoped_append_only',
  'Spec 4.7: a closed period is reopened by an explicit event, which is evidence.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'period_reopening', 'Append-only evidence carrying its own actor and reason.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
