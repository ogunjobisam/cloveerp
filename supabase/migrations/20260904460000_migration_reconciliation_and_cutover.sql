-- =============================================================================
-- Part 20 depth: migration reconciliation and cutover
--
-- Part 20 had the first half of a migration — a batch is staged, validated,
-- previewed, loaded and rolled back, and every row keeps what it did — for
-- products and business partners. It had none of the second half, which is
-- the half a finance director signs:
--
--   opening balances, dated. Stock at cost, open customer and supplier
--   balances, and the nominal trial balance, each carried in from the system
--   this organisation is leaving, as at one date, through the same movement
--   and journal tables everything else posts to — not through a side door
--   that leaves the stock ledger disagreeing with the nominal ledger on day
--   one;
--
--   reconciliation after load (D31). A batch carries the control totals the
--   legacy extract was taken with, and after loading the product says, per
--   check, what it expected and what it found. A batch that does not agree
--   is visible as such, and nothing built on it can pretend otherwise;
--
--   reversal. An opening load is undone as a unit — reversing movements and a
--   reversing journal, never edits — and refused, by name, once stock has
--   moved or a ledger has had activity since;
--
--   parallel-run comparison. For each domain the product computes its own
--   figure as at a date, the legacy system's figure is recorded against it,
--   and the two are compared within a stated tolerance;
--
--   evidence-gated cutover (D32). A domain is cut over — the legacy system
--   stops being the record for it — only when its loads reconcile, its
--   parallel-run figure is within tolerance, and somebody other than the
--   person who loaded it says so. The evidence is kept with the decision.
--   After cutover the domain refuses new opening loads and refuses to reverse
--   the ones it stands on; a cutover can be reverted, with a reason.
--
-- The four domains are a register, erp_ref.migration_domain: which import
-- object type each is, which function loads it, which function computes its
-- figure, which control account it posts to and what a row must carry. The
-- build checks the register against pg_proc, the same way it checks device
-- task handlers, so a domain cannot name a loader that does not exist.
-- =============================================================================

-- ── The register ─────────────────────────────────────────────────────────────

create table if not exists erp_ref.migration_domain (
  domain_code      text primary key,
  name_key         text not null,
  module_code      text not null,
  -- erp.import_batch.object_type for a batch of this domain's opening
  -- balances. Distinct from every maintainable object type, so the master
  -- data pipeline and this one never claim the same batch.
  object_type      text not null unique,
  loader_function  text not null,
  figure_function  text not null,
  figure_name      text not null,
  -- The purpose of the control account the load posts to, and whose
  -- subledger detail it writes. Null for the nominal ledger, which posts to
  -- the accounts a row names.
  control_purpose  text references erp_ref.chart_account_purpose (purpose),
  -- What a row of this domain carries: [{key, type, required}], where type is
  -- one of text, number, integer, date. Validation reads this before the
  -- domain-specific resolution runs.
  row_keys         jsonb not null,
  seq              smallint not null,
  description      text not null
);

comment on table erp_ref.migration_domain is
  'Specification v1.2 Part 20. The four domains an organisation migrates in, '
  'each with the function that loads its opening balances as at a date, the '
  'function that computes the figure a parallel run compares, and the shape '
  'of a row. Checked against pg_proc by erp.assert_migration_sound().';

select erp_meta.register_table('erp_ref', 'migration_domain', 'product_content',
  'Part 20. The migration domains: loader, figure, control purpose and row shape per domain.');

insert into erp_ref.migration_domain
  (domain_code, name_key, module_code, object_type, loader_function, figure_function,
   figure_name, control_purpose, row_keys, seq, description)
values
  ('stock', 'migration.domain.stock', 'inventory', 'opening_stock',
   'load_opening_stock', 'migration_figure_stock',
   'Stock value at cost, in minor units',
   'inventory',
   '[{"key":"item","type":"text","required":true},
     {"key":"site","type":"text","required":true},
     {"key":"location","type":"text","required":true},
     {"key":"quantity","type":"number","required":true},
     {"key":"unit_cost_minor","type":"integer","required":true},
     {"key":"batch","type":"text","required":false},
     {"key":"expires_on","type":"date","required":false}]',
   1,
   'Stock on hand by product, site and location, at unit cost. Each row becomes an opening_balance movement dated as at the cutover and a cost layer; the batch posts one journal, stock against migration clearing, with a stock subledger row per product.'),
  ('sales_ledger', 'migration.domain.sales_ledger', 'finance', 'opening_sales_ledger',
   'load_opening_sales_ledger', 'migration_figure_sales_ledger',
   'Open customer balances, in minor units',
   'trade_receivable',
   '[{"key":"party","type":"text","required":true},
     {"key":"reference","type":"text","required":true},
     {"key":"amount_minor","type":"integer","required":true},
     {"key":"document_date","type":"date","required":false},
     {"key":"due_date","type":"date","required":false}]',
   2,
   'Open items owed by customers. A positive amount is owed to the organisation; a negative one is a credit the customer holds. Each row becomes a sales ledger subledger item with its reference and due date; the batch posts one journal, trade receivables against migration clearing.'),
  ('purchase_ledger', 'migration.domain.purchase_ledger', 'finance', 'opening_purchase_ledger',
   'load_opening_purchase_ledger', 'migration_figure_purchase_ledger',
   'Open supplier balances, in minor units',
   'trade_payable',
   '[{"key":"party","type":"text","required":true},
     {"key":"reference","type":"text","required":true},
     {"key":"amount_minor","type":"integer","required":true},
     {"key":"document_date","type":"date","required":false},
     {"key":"due_date","type":"date","required":false}]',
   3,
   'Open items owed to suppliers. A positive amount is owed by the organisation; a negative one is a debit note. Each row becomes a purchase ledger subledger item; the batch posts one journal, migration clearing against trade payables.'),
  ('nominal', 'migration.domain.nominal', 'finance', 'opening_nominal',
   'load_opening_nominal', 'migration_figure_nominal',
   'Trial balance debits, in minor units',
   null,
   '[{"key":"account","type":"text","required":true},
     {"key":"debit_minor","type":"integer","required":false},
     {"key":"credit_minor","type":"integer","required":false}]',
   4,
   'The nominal trial balance, excluding the three control accounts the other domains load. Each row is a journal line on the nominal account it names; the net goes to migration clearing, which stands at zero once all four domains agree.')
on conflict (domain_code) do update set
  name_key = excluded.name_key, module_code = excluded.module_code,
  object_type = excluded.object_type, loader_function = excluded.loader_function,
  figure_function = excluded.figure_function, figure_name = excluded.figure_name,
  control_purpose = excluded.control_purpose, row_keys = excluded.row_keys,
  seq = excluded.seq, description = excluded.description;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('migration.domain.stock', 'en', 'Stock', null,
   'Name of the migration domain that carries in opening stock at cost.'),
  ('migration.domain.sales_ledger', 'en', 'Sales ledger', null,
   'Name of the migration domain that carries in open customer balances.'),
  ('migration.domain.purchase_ledger', 'en', 'Purchase ledger', null,
   'Name of the migration domain that carries in open supplier balances.'),
  ('migration.domain.nominal', 'en', 'Nominal ledger', null,
   'Name of the migration domain that carries in the opening trial balance.'),
  ('movement.opening_balance', 'en', 'Opening balance', null,
   'Name of the movement type an opening stock load writes.'),
  ('nav.operations_cutover', 'en', 'Migration and cutover', null,
   'Navigation label for the operations screen showing opening balance loads, their reconciliation, parallel-run figures and each domain''s cutover.')
on conflict (key, locale) do nothing;

-- The movement an opening stock load writes. Inbound, valued, no reason
-- needed because the batch is the reason, and system: nothing keys it by hand.
insert into erp_ref.movement_type
  (code, name_key, direction, module_code, allows_negative, requires_reason, affects_valuation, is_system, description)
values
  ('opening_balance', 'movement.opening_balance', 'in', 'inventory', false, false, true, true,
   'Opening stock carried in from the system this organisation migrated from, dated as at the cutover. Written only by erp.load_opening_stock(); reversed only by erp.reverse_opening_balances().')
on conflict (code) do nothing;

-- ── What a batch of opening balances carries that a master data batch does not

alter table erp.import_batch
  add column if not exists as_at               date,
  add column if not exists currency            char(3),
  add column if not exists control_quantity    numeric(20,6),
  add column if not exists control_total_minor bigint,
  add column if not exists loaded_quantity     numeric(20,6),
  add column if not exists loaded_total_minor  bigint,
  add column if not exists loaded_by           uuid,
  add column if not exists journal_id          uuid references erp.journal (id) on delete set null,
  add column if not exists reversal_journal_id uuid references erp.journal (id) on delete set null,
  add column if not exists reversal_reason     text;

comment on column erp.import_batch.as_at is
  'Part 20. The date the opening balances stand at: every movement and journal '
  'the load writes is dated here, not on the day somebody pressed the button.';
comment on column erp.import_batch.control_total_minor is
  'Part 20. The total the legacy extract was taken with, in minor units. The '
  'reconciliation after load compares what was loaded against it.';

-- What each loaded row left behind: a movement id, a subledger item, a
-- journal line — enough to reverse the row and to show what it became.
alter table erp.import_row add column if not exists loaded_ref jsonb;

-- ── Parallel-run figures ──────────────────────────────────────────────────────

create table if not exists erp.parallel_run_figure (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant (id) on delete cascade,
  domain_code        text not null references erp_ref.migration_domain (domain_code),
  as_at              date not null,
  legacy_value_minor bigint not null,
  our_value_minor    bigint not null,
  difference_minor   bigint generated always as (our_value_minor - legacy_value_minor) stored,
  tolerance_minor    bigint not null default 0 check (tolerance_minor >= 0),
  within_tolerance   boolean not null,
  note               text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  unique (tenant_id, id),
  -- One figure per domain per date. Recording again on the same date replaces
  -- it: the comparison is a statement about that date, not a log of attempts.
  unique (tenant_id, domain_code, as_at)
);

comment on table erp.parallel_run_figure is
  'Specification v1.2 Part 20. For a domain and a date, what the legacy system '
  'said and what this product computed through the domain''s figure function, '
  'with the tolerance the comparison was made within. Evidence a cutover rests on.';

select erp_meta.register_table('erp', 'parallel_run_figure', 'tenant_scoped',
  'Part 20. Parallel-run comparison figures per migration domain and date.');

-- ── Cutover, per domain ───────────────────────────────────────────────────────

create table if not exists erp.domain_cutover (
  tenant_id     uuid not null references erp.tenant (id) on delete cascade,
  domain_code   text not null references erp_ref.migration_domain (domain_code),
  status        text not null check (status in ('cut_over', 'reverted')),
  cut_over_at   timestamptz not null default now(),
  cut_over_by   uuid,
  -- The evidence as it stood when the decision was taken: the batches, their
  -- checks, the figure, the clearing balance. Kept because the tables it was
  -- read from keep moving after cutover and the decision does not.
  evidence      jsonb not null,
  note          text,
  reverted_at   timestamptz,
  reverted_by   uuid,
  revert_reason text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (tenant_id, domain_code)
);

comment on table erp.domain_cutover is
  'Specification v1.2 Part 20, D32. One row per domain an organisation has cut '
  'over, carrying the evidence the decision rested on. Written only by '
  'erp.cut_over_domain(), which refuses without the evidence.';

select erp_meta.register_table('erp', 'domain_cutover', 'tenant_scoped',
  'Part 20. Which migration domains are cut over, on what evidence.');

-- ── Helpers the loaders share ─────────────────────────────────────────────────

-- The domain a batch belongs to, or null for a master data batch.
create or replace function erp.migration_domain_of_batch(p_batch_id uuid)
returns erp_ref.migration_domain
language sql
stable
security invoker
set search_path = ''
as $$
  select d.*
    from erp.import_batch b
    join erp_ref.migration_domain d on d.object_type = b.object_type
   where b.tenant_id = erp.current_tenant_id() and b.id = p_batch_id
$$;

create or replace function erp.domain_is_cut_over(p_domain_code text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from erp.domain_cutover c
     where c.tenant_id = erp.current_tenant_id()
       and c.domain_code = p_domain_code
       and c.status = 'cut_over')
$$;

-- The account a purpose resolves to on this organisation's chart, whichever
-- chart it runs. Migration clearing is the one purpose no installer creates,
-- because it exists only while a migration is in progress: the first loader
-- to need it creates it, postable, and says so in its name.
create or replace function erp.opening_account(p_purpose text)
returns erp.account
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity erp.entity%rowtype;
  v_code   text := erp.chart_account_code(p_purpose);
  acc      erp.account%rowtype;
begin
  select * into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  select * into acc from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity.id
     and a.code = v_code and a.status = 'active';

  if found then return acc; end if;

  if p_purpose = 'clearing' then
    insert into erp.account (
      tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
    values (v_tenant, v_entity.id, v_code, 'Migration clearing', 'asset', true,
            v_entity.base_currency, 'active')
    on conflict (tenant_id, entity_id, code) do update set status = 'active'
    returning * into acc;
    return acc;
  end if;

  raise exception
    'ERPWARE_OPENING_ACCOUNT_MISSING: this organisation has no active nominal '
    'account % for %, and opening balances have nowhere to post', v_code, p_purpose
    using errcode = '23503',
    hint = 'erp.configure_finance() creates the chart these purposes resolve to.';
end;
$$;

-- The one journal a batch posts. Manual, because it is the stated exception
-- to "every line names its posting rule and source event": there is no
-- operational event behind an opening balance, only the fact that the
-- organisation existed before this product did. The reason says which batch.
create or replace function erp.open_opening_journal(p_batch_id uuid, p_description text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  d        erp_ref.migration_domain;
  v_entity uuid;
  v_ledger uuid;
  v_id     uuid;
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id;
  d := erp.migration_domain_of_batch(p_batch_id);

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  select l.id into v_ledger from erp.ledger l
   where l.tenant_id = v_tenant and l.entity_id = v_entity and l.is_primary
     and l.status = 'active';

  if v_ledger is null then
    raise exception 'ERPWARE_NO_LEDGER: this organisation has no primary ledger to '
      'carry opening balances into' using errcode = '23503',
      hint = 'erp.configure_finance() creates it.';
  end if;

  insert into erp.journal (
    tenant_id, entity_id, ledger_id, journal_number, source_code, posting_date,
    description, status, manual_reason)
  values (v_tenant, v_entity, v_ledger, b.code, 'manual', b.as_at,
          p_description, 'draft',
          format('Opening balances: %s as at %s, batch %s', d.domain_code, b.as_at, b.code))
  returning id into v_id;

  return v_id;
end;
$$;

-- ── Staging ───────────────────────────────────────────────────────────────────

create or replace function erp.stage_opening_balances(
  p_domain_code         text,
  p_as_at               date,
  p_rows                jsonb,
  p_control_total_minor bigint,
  p_control_quantity    numeric default null,
  p_code                text default null,
  p_source              text default 'legacy extract'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp_ref.migration_domain;
  v_entity erp.entity%rowtype;
  v_ledger uuid;
  v_id     uuid;
  v_code   text := coalesce(p_code, format('OB-%s-%s', upper(p_domain_code),
                            to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')));
begin
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', null);

  select * into d from erp_ref.migration_domain m where m.domain_code = p_domain_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MIGRATION_DOMAIN: % is not a migration domain', p_domain_code
      using errcode = '23503',
      hint = 'erp_ref.migration_domain lists the four: stock, sales_ledger, purchase_ledger, nominal.';
  end if;

  if erp.domain_is_cut_over(p_domain_code) then
    raise exception
      'ERPWARE_DOMAIN_CUT_OVER: % is cut over, and this product is now the record '
      'for it; there is no legacy system to load opening balances from', p_domain_code
      using errcode = '23514',
      hint = 'erp.revert_cutover() reopens the domain, with a reason.';
  end if;

  if p_as_at is null then
    raise exception 'ERPWARE_OPENING_DATE_MISSING: opening balances stand at a date'
      using errcode = '23514';
  end if;
  if p_as_at > current_date then
    raise exception 'ERPWARE_OPENING_DATE_FUTURE: % is after today, and a balance '
      'cannot be carried in as at a day that has not happened', p_as_at
      using errcode = '23514';
  end if;

  if p_control_total_minor is null then
    raise exception
      'ERPWARE_OPENING_CONTROL_MISSING: a load without the total the extract was '
      'taken with cannot be reconciled afterwards, so it is not staged'
      using errcode = '23514',
      hint = 'Take the control total from the legacy report as at the same date.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'ERPWARE_EMPTY_IMPORT: an import of no rows' using errcode = '23514';
  end if;

  select * into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  select l.id into v_ledger from erp.ledger l
   where l.tenant_id = v_tenant and l.entity_id = v_entity.id and l.is_primary
     and l.status = 'active';

  if v_ledger is null then
    raise exception 'ERPWARE_NO_LEDGER: this organisation has no primary ledger to '
      'carry opening balances into' using errcode = '23503',
      hint = 'erp.configure_finance() creates it.';
  end if;

  -- The date must fall in an accounting period of the ledger, said now rather
  -- than at load, when the rows have already been checked.
  if not exists (select 1 from erp.fiscal_period p
                  where p.tenant_id = v_tenant and p.ledger_id = v_ledger
                    and p_as_at between p.starts_on and p.ends_on) then
    raise exception
      'ERPWARE_OPENING_DATE_OUTSIDE_CALENDAR: no accounting period of the primary '
      'ledger contains %', p_as_at
      using errcode = '23514';
  end if;

  insert into erp.import_batch (
    tenant_id, code, object_type, source, row_count, as_at, currency,
    control_quantity, control_total_minor)
  values (v_tenant, v_code, d.object_type, p_source, jsonb_array_length(p_rows),
          p_as_at, v_entity.base_currency, p_control_quantity, p_control_total_minor)
  returning id into v_id;

  insert into erp.import_row (tenant_id, import_batch_id, row_no, raw)
  select v_tenant, v_id, (e.ordinality)::integer, e.value
    from jsonb_array_elements(p_rows) with ordinality e(value, ordinality);

  return v_id;
end;
$$;

comment on function erp.stage_opening_balances is
  'Part 20. Stages a batch of opening balances for one domain as at a date, '
  'with the control total the extract was taken with. Refuses a domain that '
  'is cut over, a date in the future or outside the ledger''s calendar, and a '
  'batch with no control total, because each would make the reconciliation '
  'after load meaningless.';

-- ── Validation ────────────────────────────────────────────────────────────────

-- Row-level. The generic half reads the register's row shape; the specific
-- half resolves what a row names against this organisation's records, and
-- says which name it could not resolve rather than failing at load.
create or replace function erp.validate_opening_balances(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  d        erp_ref.migration_domain;
  r        record;
  k        record;
  v_find   jsonb;
  v_errors integer := 0;
  v_bad    text;
  v_val    text;
  v_shape  integer;
  v_item   erp.item%rowtype;
  v_site   uuid;
  v_acc    erp.account%rowtype;
  v_entity uuid;
  v_dr     bigint;
  v_cr     bigint;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  d := erp.migration_domain_of_batch(p_batch_id);
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
            order by row_no
  loop
    v_find := '[]'::jsonb;

    -- Keys the register does not name.
    select string_agg(j, ', ') into v_bad
      from jsonb_object_keys(r.raw) j
     where not exists (select 1 from jsonb_array_elements(d.row_keys) rk
                        where rk ->> 'key' = j);
    if v_bad is not null then
      v_find := v_find || jsonb_build_object(
        'severity', 'error', 'message', format('unknown field(s): %s', v_bad));
    end if;

    -- Keys the register requires, and the type of each present. A row that
    -- fails here is not resolved further: the values it would be resolved
    -- with are the ones that are missing or malformed.
    v_shape := jsonb_array_length(v_find);
    for k in select rk ->> 'key' as key, rk ->> 'type' as type,
                    (rk ->> 'required')::boolean as required
               from jsonb_array_elements(d.row_keys) rk
    loop
      v_val := r.raw ->> k.key;
      if k.required and coalesce(v_val, '') = '' then
        v_find := v_find || jsonb_build_object(
          'severity', 'error', 'message', format('%s is required', k.key));
      elsif v_val is not null then
        if k.type = 'number' and v_val !~ '^-?[0-9]+(\.[0-9]+)?$' then
          v_find := v_find || jsonb_build_object(
            'severity', 'error', 'message', format('%s is not a number: %s', k.key, v_val));
        elsif k.type = 'integer' and v_val !~ '^-?[0-9]+$' then
          v_find := v_find || jsonb_build_object(
            'severity', 'error', 'message',
            format('%s is not a whole number of minor units: %s', k.key, v_val));
        elsif k.type = 'date' and v_val !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
          v_find := v_find || jsonb_build_object(
            'severity', 'error', 'message', format('%s is not a date: %s', k.key, v_val));
        end if;
      end if;
    end loop;

    -- What the row names, resolved against this organisation.
    if jsonb_array_length(v_find) = v_shape then
      if d.domain_code = 'stock' then
        select * into v_item from erp.item i
         where i.tenant_id = v_tenant and i.code = r.raw ->> 'item';
        if not found then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('no product has the code %s', r.raw ->> 'item'));
        else
          if v_item.is_batch_controlled and coalesce(r.raw ->> 'batch', '') = '' then
            v_find := v_find || jsonb_build_object('severity', 'error',
              'message', format('%s is batch controlled and the row names no batch', v_item.code));
          end if;
          if v_item.is_serial_controlled then
            v_find := v_find || jsonb_build_object('severity', 'error',
              'message', format('%s is serial controlled; serialised stock is carried in one unit at a time through goods receipt', v_item.code));
          end if;
        end if;
        select s.id into v_site from erp.site s
         where s.tenant_id = v_tenant and s.code = r.raw ->> 'site';
        if v_site is null then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('no site has the code %s', r.raw ->> 'site'));
        elsif not exists (select 1 from erp.location l
                           where l.tenant_id = v_tenant and l.site_id = v_site
                             and l.code = r.raw ->> 'location') then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('site %s has no location %s', r.raw ->> 'site', r.raw ->> 'location'));
        end if;
        if (r.raw ->> 'quantity')::numeric <= 0 then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', 'quantity must be positive; stock that is not there is not loaded');
        end if;
        if (r.raw ->> 'unit_cost_minor')::bigint < 0 then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', 'unit cost cannot be negative');
        end if;

      elsif d.domain_code in ('sales_ledger', 'purchase_ledger') then
        if not exists (select 1 from erp.party p
                        where p.tenant_id = v_tenant and p.code = r.raw ->> 'party') then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('no business partner has the code %s', r.raw ->> 'party'));
        end if;
        if (r.raw ->> 'amount_minor')::bigint = 0 then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', 'an open item of nothing is not open');
        end if;

      elsif d.domain_code = 'nominal' then
        select * into v_acc from erp.account a
         where a.tenant_id = v_tenant and a.entity_id = v_entity
           and a.code = r.raw ->> 'account' and a.status = 'active';
        if not found then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('no active nominal account has the code %s', r.raw ->> 'account'));
        elsif not v_acc.is_postable then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('%s is not postable', v_acc.code));
        elsif v_acc.control_kind in ('receivable', 'payable', 'inventory') then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', format('%s is the %s control account; its balance is loaded through the %s domain, item by item',
              v_acc.code, v_acc.control_kind,
              case v_acc.control_kind when 'receivable' then 'sales_ledger'
                                      when 'payable' then 'purchase_ledger'
                                      else 'stock' end));
        end if;
        v_dr := coalesce((r.raw ->> 'debit_minor')::bigint, 0);
        v_cr := coalesce((r.raw ->> 'credit_minor')::bigint, 0);
        if v_dr < 0 or v_cr < 0 then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', 'debit and credit are each zero or positive; a negative debit is a credit');
        elsif (v_dr > 0) = (v_cr > 0) then
          v_find := v_find || jsonb_build_object('severity', 'error',
            'message', 'a row carries a debit or a credit, not both and not neither');
        end if;
      end if;
    end if;

    update erp.import_row
       set findings = v_find,
           target_id = null,
           action = case when jsonb_array_length(v_find) > 0 then 'reject' else 'insert' end,
           updated_at = now()
     where id = r.id;

    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;

  return v_errors;
end;
$$;

-- ── The four loaders ──────────────────────────────────────────────────────────
--
-- Each takes a batch already checked by erp.load_opening_balances() — status,
-- errors, permission, cutover — and writes the rows. Each returns how many.

create or replace function erp.load_opening_stock(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_item   erp.item%rowtype;
  v_site   erp.site%rowtype;
  v_loc    uuid;
  v_batch  uuid;
  v_qty    numeric;
  v_cost   bigint;
  v_value  bigint;
  v_move   bigint;
  v_journal uuid;
  v_inv    erp.account%rowtype;
  v_clr    erp.account%rowtype;
  v_entity uuid;
  v_ledger uuid;
  v_no     integer := 0;
  v_n      integer := 0;
  v_total  bigint := 0;
  v_qtot   numeric := 0;
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id;

  perform erp.authorise('inventory.adjust', null, null, null, 'import_batch', p_batch_id);

  v_inv := erp.opening_account('inventory');
  v_clr := erp.opening_account('clearing');
  v_journal := erp.open_opening_journal(p_batch_id,
                 format('Opening stock as at %s', b.as_at));
  select j.entity_id, j.ledger_id into v_entity, v_ledger from erp.journal j where j.id = v_journal;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
              and action = 'insert' and not loaded
            order by row_no
  loop
    select * into v_item from erp.item i
     where i.tenant_id = v_tenant and i.code = r.raw ->> 'item';
    select * into v_site from erp.site s
     where s.tenant_id = v_tenant and s.code = r.raw ->> 'site';
    select l.id into v_loc from erp.location l
     where l.tenant_id = v_tenant and l.site_id = v_site.id and l.code = r.raw ->> 'location';

    v_qty  := (r.raw ->> 'quantity')::numeric;
    v_cost := (r.raw ->> 'unit_cost_minor')::bigint;
    v_value := round(v_qty * v_cost)::bigint;
    v_batch := null;

    -- A batch the legacy system knew is carried in as released stock: it was
    -- on the shelf, available, on the day the balance was taken.
    if v_item.is_batch_controlled then
      insert into erp.batch (tenant_id, item_id, batch_number, status, expires_on)
      values (v_tenant, v_item.id, r.raw ->> 'batch', 'unrestricted',
              (r.raw ->> 'expires_on')::date)
      on conflict (tenant_id, item_id, batch_number) do update
        set expires_on = coalesce(excluded.expires_on, erp.batch.expires_on)
      returning id into v_batch;
    end if;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, occurred_at, actor_id, correlation_id)
    values (
      v_tenant, v_site.entity_id, v_site.id, 'opening_balance', v_item.id, v_batch,
      v_loc, 'available', v_qty, v_item.stock_uom_id, v_cost, b.currency,
      'opening_balance', b.as_at::timestamptz + interval '23:59:59',
      erp.current_principal_id(), erp.current_correlation_id())
    returning id into v_move;

    perform erp.receive_cost(v_item.id, v_site.id, v_qty, v_cost, b.currency, v_batch, v_move);

    if v_value > 0 then
      v_no := v_no + 1;
      insert into erp.journal_line (
        tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
        currency, base_debit_minor, base_credit_minor, exchange_rate, description)
      values (v_tenant, v_journal, v_no, v_inv.id, v_value, 0, b.currency,
              v_value, 0, 1, format('Opening stock %s at %s', v_item.code, v_site.code));

      insert into erp.subledger_item (
        tenant_id, entity_id, ledger_id, control_kind, control_account_id,
        item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
      values (v_tenant, v_entity, v_ledger, 'inventory', v_inv.id,
              v_item.id, v_journal, b.currency, v_value, 0, b.as_at);
    end if;

    update erp.import_row
       set loaded = true, before_snapshot = null, updated_at = now(),
           loaded_ref = jsonb_build_object(
             'movement_id', v_move, 'batch_id', v_batch, 'item_id', v_item.id,
             'site_id', v_site.id, 'quantity', v_qty, 'value_minor', v_value)
     where id = r.id;

    v_n := v_n + 1;
    v_total := v_total + v_value;
    v_qtot := v_qtot + v_qty;
  end loop;

  if v_total > 0 then
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate, description)
    values (v_tenant, v_journal, v_no + 1, v_clr.id, 0, v_total, b.currency,
            0, v_total, 1, 'Opening stock, migration clearing');
  end if;

  update erp.journal set status = 'posted', posted_at = now(),
         posted_by = erp.current_principal_id()
   where id = v_journal;

  update erp.import_batch
     set journal_id = v_journal, loaded_total_minor = v_total, loaded_quantity = v_qtot
   where id = p_batch_id;

  return v_n;
end;
$$;

-- Open customer and supplier items share one body: the side is the only
-- difference, and it is the domain's control kind that decides it.
create or replace function erp.load_opening_ledger(p_batch_id uuid, p_domain_code text)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  d        erp_ref.migration_domain;
  r        record;
  v_party  uuid;
  v_amount bigint;
  v_ctl    erp.account%rowtype;
  v_clr    erp.account%rowtype;
  v_journal uuid;
  v_entity uuid;
  v_ledger uuid;
  v_sub    uuid;
  v_no     integer := 0;
  v_n      integer := 0;
  v_net    bigint := 0;   -- positive: the control account is debited on balance
  v_receivable boolean := p_domain_code = 'sales_ledger';
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id;
  select * into d from erp_ref.migration_domain m where m.domain_code = p_domain_code;

  v_ctl := erp.opening_account(d.control_purpose);
  v_clr := erp.opening_account('clearing');
  v_journal := erp.open_opening_journal(p_batch_id,
                 format('Opening %s as at %s', replace(p_domain_code, '_', ' '), b.as_at));
  select j.entity_id, j.ledger_id into v_entity, v_ledger from erp.journal j where j.id = v_journal;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
              and action = 'insert' and not loaded
            order by row_no
  loop
    select p.id into v_party from erp.party p
     where p.tenant_id = v_tenant and p.code = r.raw ->> 'party';
    v_amount := (r.raw ->> 'amount_minor')::bigint;

    -- A customer balance owed to us is a debit on receivables; a supplier
    -- balance we owe is a credit on payables. A negative amount is the other
    -- side in either case.
    v_no := v_no + 1;
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate, description)
    values (v_tenant, v_journal, v_no, v_ctl.id,
            case when (v_amount > 0) = v_receivable then abs(v_amount) else 0 end,
            case when (v_amount > 0) = v_receivable then 0 else abs(v_amount) end,
            b.currency,
            case when (v_amount > 0) = v_receivable then abs(v_amount) else 0 end,
            case when (v_amount > 0) = v_receivable then 0 else abs(v_amount) end,
            1, format('%s %s', r.raw ->> 'party', r.raw ->> 'reference'));

    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      party_id, journal_id, currency, debit_minor, credit_minor, due_date, posting_date)
    values (v_tenant, v_entity, v_ledger, v_ctl.control_kind, v_ctl.id,
            v_party, v_journal, b.currency,
            case when (v_amount > 0) = v_receivable then abs(v_amount) else 0 end,
            case when (v_amount > 0) = v_receivable then 0 else abs(v_amount) end,
            (r.raw ->> 'due_date')::date,
            coalesce((r.raw ->> 'document_date')::date, b.as_at))
    returning id into v_sub;

    update erp.import_row
       set loaded = true, before_snapshot = null, updated_at = now(),
           loaded_ref = jsonb_build_object(
             'subledger_item_id', v_sub, 'party_id', v_party, 'line_no', v_no,
             'amount_minor', v_amount)
     where id = r.id;

    v_n := v_n + 1;
    v_net := v_net + case when (v_amount > 0) = v_receivable then abs(v_amount) else -abs(v_amount) end;
  end loop;

  if v_net <> 0 then
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate, description)
    values (v_tenant, v_journal, v_no + 1, v_clr.id,
            case when v_net < 0 then -v_net else 0 end,
            case when v_net > 0 then v_net else 0 end,
            b.currency,
            case when v_net < 0 then -v_net else 0 end,
            case when v_net > 0 then v_net else 0 end,
            1, format('Opening %s, migration clearing', replace(p_domain_code, '_', ' ')));
  end if;

  update erp.journal set status = 'posted', posted_at = now(),
         posted_by = erp.current_principal_id()
   where id = v_journal;

  -- The loaded total is the sum of the amounts as the extract states them,
  -- signed, which is what a legacy aged balance report totals.
  update erp.import_batch
     set journal_id = v_journal,
         loaded_total_minor = (select coalesce(sum((x.loaded_ref ->> 'amount_minor')::bigint), 0)
                                 from erp.import_row x
                                where x.import_batch_id = p_batch_id and x.loaded)
   where id = p_batch_id;

  return v_n;
end;
$$;

create or replace function erp.load_opening_sales_ledger(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);
  return erp.load_opening_ledger(p_batch_id, 'sales_ledger');
end;
$$;

create or replace function erp.load_opening_purchase_ledger(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);
  return erp.load_opening_ledger(p_batch_id, 'purchase_ledger');
end;
$$;

create or replace function erp.load_opening_nominal(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  acc      erp.account%rowtype;
  v_dr     bigint;
  v_cr     bigint;
  v_clr    erp.account%rowtype;
  v_journal uuid;
  v_entity uuid;
  v_ledger uuid;
  v_no     integer := 0;
  v_n      integer := 0;
  v_net    bigint := 0;   -- debits less credits over the rows
  v_debits bigint := 0;
begin
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id;

  v_clr := erp.opening_account('clearing');
  v_journal := erp.open_opening_journal(p_batch_id,
                 format('Opening trial balance as at %s', b.as_at));
  select j.entity_id, j.ledger_id into v_entity, v_ledger from erp.journal j where j.id = v_journal;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
              and action = 'insert' and not loaded
            order by row_no
  loop
    select * into acc from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = r.raw ->> 'account' and a.status = 'active';
    v_dr := coalesce((r.raw ->> 'debit_minor')::bigint, 0);
    v_cr := coalesce((r.raw ->> 'credit_minor')::bigint, 0);

    v_no := v_no + 1;
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate, description)
    values (v_tenant, v_journal, v_no, acc.id, v_dr, v_cr, b.currency, v_dr, v_cr, 1,
            format('Opening balance %s', acc.code));

    -- A control account outside the three domains — bank, tax, work in
    -- progress — keeps its detail in a subledger too, and the two must agree
    -- from the first day.
    if acc.control_kind is not null then
      insert into erp.subledger_item (
        tenant_id, entity_id, ledger_id, control_kind, control_account_id,
        journal_id, currency, debit_minor, credit_minor, posting_date)
      values (v_tenant, v_entity, v_ledger, acc.control_kind, acc.id,
              v_journal, b.currency, v_dr, v_cr, b.as_at);
    end if;

    update erp.import_row
       set loaded = true, before_snapshot = null, updated_at = now(),
           loaded_ref = jsonb_build_object(
             'account_id', acc.id, 'line_no', v_no, 'debit_minor', v_dr, 'credit_minor', v_cr)
     where id = r.id;

    v_n := v_n + 1;
    v_net := v_net + v_dr - v_cr;
    v_debits := v_debits + v_dr;
  end loop;

  if v_net <> 0 then
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate, description)
    values (v_tenant, v_journal, v_no + 1, v_clr.id,
            case when v_net < 0 then -v_net else 0 end,
            case when v_net > 0 then v_net else 0 end,
            b.currency,
            case when v_net < 0 then -v_net else 0 end,
            case when v_net > 0 then v_net else 0 end,
            1, 'Opening trial balance, migration clearing');
  end if;

  update erp.journal set status = 'posted', posted_at = now(),
         posted_by = erp.current_principal_id()
   where id = v_journal;

  -- The control total of a trial balance is its debit column.
  update erp.import_batch
     set journal_id = v_journal, loaded_total_minor = v_debits
   where id = p_batch_id;

  return v_n;
end;
$$;

-- ── Load: the common gate, then the domain's loader ───────────────────────────

create or replace function erp.load_opening_balances(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  d        erp_ref.migration_domain;
  v_n      integer;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  d := erp.migration_domain_of_batch(p_batch_id);
  if d.domain_code is null then
    raise exception 'ERPWARE_NOT_OPENING_BALANCES: % is a %s batch, not opening balances',
      b.code, b.object_type using errcode = '23514';
  end if;

  if erp.domain_is_cut_over(d.domain_code) then
    raise exception
      'ERPWARE_DOMAIN_CUT_OVER: % is cut over, and this product is now the record '
      'for it; opening balances are not loaded over a live domain', d.domain_code
      using errcode = '23514',
      hint = 'erp.revert_cutover() reopens the domain, with a reason.';
  end if;

  if b.status <> 'previewed' then
    raise exception
      'ERPWARE_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after '
      'somebody has looked at it', b.code, b.status
      using errcode = '23514',
      hint = 'Spec 5.1 asks for validation, preview, staged load and rollback '
             'in that order; the preview is the point at which a person is '
             'given a chance to stop.';
  end if;

  if b.error_count > 0 then
    raise exception
      'ERPWARE_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather '
      'than loading the good half', b.error_count, b.code
      using errcode = '23514';
  end if;

  execute format('select erp.%I($1)', d.loader_function) into v_n using p_batch_id;

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), loaded_by = erp.current_principal_id(),
         updated_at = now()
   where id = p_batch_id;

  return v_n;
end;
$$;

comment on function erp.load_opening_balances is
  'Part 20. Loads a previewed, error-free batch of opening balances through '
  'the loader its domain names in erp_ref.migration_domain, dated as at the '
  'batch''s date. Refuses a domain that is already cut over.';

-- ── Reconciliation after load (D31) ───────────────────────────────────────────

create or replace function erp.opening_balance_reconciliation(p_batch_id uuid)
returns table (check_code text, expected numeric, actual numeric, difference numeric,
               passes boolean, detail text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  d        erp_ref.migration_domain;
  v_rows   integer;
  v_dr     bigint; v_cr bigint;
  v_status text;
  v_ctl    erp.account%rowtype;
  v_gl     bigint; v_sub bigint;
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;
  d := erp.migration_domain_of_batch(p_batch_id);
  if d.domain_code is null then
    raise exception 'ERPWARE_NOT_OPENING_BALANCES: % is a %s batch, not opening balances',
      b.code, b.object_type using errcode = '23514';
  end if;

  if b.status not in ('loaded', 'rolled_back') then
    check_code := 'loaded'; expected := 1; actual := 0; difference := -1; passes := false;
    detail := format('%s is %s; there is nothing to reconcile until it is loaded', b.code, b.status);
    return next;
    return;
  end if;

  -- Every row the file carried was loaded.
  select count(*) filter (where r.loaded) into v_rows
    from erp.import_row r where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id;
  check_code := 'rows_loaded'; expected := b.row_count; actual := v_rows;
  difference := v_rows - b.row_count; passes := v_rows = b.row_count;
  detail := format('%s of %s rows loaded', v_rows, b.row_count);
  return next;

  -- The total the extract was taken with.
  check_code := 'control_total'; expected := b.control_total_minor;
  actual := coalesce(b.loaded_total_minor, 0);
  difference := coalesce(b.loaded_total_minor, 0) - b.control_total_minor;
  passes := coalesce(b.loaded_total_minor, 0) = b.control_total_minor;
  detail := format('loaded %s against a control total of %s (%s)',
                   coalesce(b.loaded_total_minor, 0), b.control_total_minor, b.currency);
  return next;

  if b.control_quantity is not null then
    check_code := 'control_quantity'; expected := b.control_quantity;
    actual := coalesce(b.loaded_quantity, 0);
    difference := coalesce(b.loaded_quantity, 0) - b.control_quantity;
    passes := coalesce(b.loaded_quantity, 0) = b.control_quantity;
    detail := format('loaded %s units against a control quantity of %s',
                     coalesce(b.loaded_quantity, 0), b.control_quantity);
    return next;
  end if;

  -- The journal posted, dated as at, and balances.
  select j.status::text, coalesce(sum(l.debit_minor), 0), coalesce(sum(l.credit_minor), 0)
    into v_status, v_dr, v_cr
    from erp.journal j left join erp.journal_line l on l.journal_id = j.id
   where j.id = b.journal_id
   group by j.status;
  check_code := 'journal_balances'; expected := v_dr; actual := v_cr;
  difference := coalesce(v_dr, 0) - coalesce(v_cr, 0);
  passes := v_status in ('posted', 'reversed') and v_dr = v_cr;
  detail := case when v_status is null then 'no journal was posted'
                 else format('journal %s is %s: debits %s, credits %s', b.code, v_status, v_dr, v_cr) end;
  return next;

  -- The control account's nominal balance agrees with its subledger detail,
  -- as both stand now. A batch that reconciled at load and no longer does is
  -- a finding, not a memory.
  if d.control_purpose is not null then
    v_ctl := erp.opening_account(d.control_purpose);
    select coalesce(sum(l.debit_minor - l.credit_minor), 0) into v_gl
      from erp.journal_line l join erp.journal j on j.id = l.journal_id
     where l.tenant_id = v_tenant and l.account_id = v_ctl.id
       and j.status in ('posted', 'reversed');
    select coalesce(sum(s.debit_minor - s.credit_minor), 0) into v_sub
      from erp.subledger_item s
     where s.tenant_id = v_tenant and s.control_account_id = v_ctl.id;
    check_code := 'control_account_detail'; expected := v_gl; actual := v_sub;
    difference := v_sub - v_gl; passes := v_gl = v_sub;
    detail := format('%s: nominal %s, subledger detail %s', v_ctl.code, v_gl, v_sub);
    return next;
  end if;
end;
$$;

comment on function erp.opening_balance_reconciliation is
  'Part 20, D31: reconciliation after load. Per check, what the batch expected '
  'and what the product finds — rows loaded, the control total and quantity '
  'the extract was taken with, the journal it posted, and the control '
  'account''s nominal balance against its subledger detail as both stand now.';

-- The balance on migration clearing: what the four domains have not yet
-- explained between them. Zero when they agree.
create or replace function erp.migration_clearing_balance()
returns bigint
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_code   text := erp.chart_account_code('clearing');
  v_bal    bigint;
begin
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  select coalesce(sum(l.debit_minor - l.credit_minor), 0) into v_bal
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id
    join erp.account a on a.id = l.account_id
   where l.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_code
     and j.status in ('posted', 'reversed');
  return v_bal;
end;
$$;

-- Tenant-level: one row per domain, as the migration stands.
create or replace function erp.migration_reconciliation_report()
returns table (domain_code text, batches_loaded integer, rows_loaded integer,
               control_total_minor bigint, loaded_total_minor bigint,
               reconciles boolean, latest_as_at date,
               figure_within_tolerance boolean, cutover_status text, finding text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        record;
  v_bad    text;
  v_fig    erp.parallel_run_figure%rowtype;
  v_clr    bigint := erp.migration_clearing_balance();
begin
  for d in select m.* from erp_ref.migration_domain m order by m.seq
  loop
    domain_code := d.domain_code;
    select count(*)::integer, coalesce(sum(b.row_count), 0)::integer,
           coalesce(sum(b.control_total_minor), 0), coalesce(sum(b.loaded_total_minor), 0),
           max(b.as_at)
      into batches_loaded, rows_loaded, control_total_minor, loaded_total_minor, latest_as_at
      from erp.import_batch b
     where b.tenant_id = v_tenant and b.object_type = d.object_type and b.status = 'loaded';

    select string_agg(format('%s: %s', b.code, c.detail), '; ') into v_bad
      from erp.import_batch b
      cross join lateral erp.opening_balance_reconciliation(b.id) c
     where b.tenant_id = v_tenant and b.object_type = d.object_type and b.status = 'loaded'
       and not c.passes;
    reconciles := batches_loaded > 0 and v_bad is null;

    select f.* into v_fig from erp.parallel_run_figure f
     where f.tenant_id = v_tenant and f.domain_code = d.domain_code
     order by f.as_at desc, f.updated_at desc limit 1;
    figure_within_tolerance := case when v_fig.id is null then null else v_fig.within_tolerance end;

    select coalesce(c.status, 'pending') into cutover_status
      from (select null) x left join erp.domain_cutover c
        on c.tenant_id = v_tenant and c.domain_code = d.domain_code;

    finding := case
      when cutover_status = 'cut_over' then null
      when batches_loaded = 0 then 'no opening balances loaded'
      when v_bad is not null then v_bad
      when v_fig.id is null then 'no parallel-run figure recorded'
      when not v_fig.within_tolerance then
        format('parallel-run figure as at %s is out by %s against a tolerance of %s',
               v_fig.as_at, v_fig.difference_minor, v_fig.tolerance_minor)
      when d.domain_code = 'nominal' and v_clr <> 0 then
        format('migration clearing carries %s; the four domains do not yet agree', v_clr)
      else null end;
    return next;
  end loop;
end;
$$;

comment on function erp.migration_reconciliation_report is
  'Part 20. Per migration domain, what is loaded, whether it reconciles, '
  'whether its latest parallel-run figure is within tolerance, and whether '
  'it is cut over — with the one sentence that stands between it and cutover.';

-- ── Reversal ──────────────────────────────────────────────────────────────────

create or replace function erp.reverse_opening_balances(p_batch_id uuid, p_reason text)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  d        erp_ref.migration_domain;
  r        record;
  j        erp.journal%rowtype;
  v_rev    uuid;
  v_n      integer := 0;
  v_cut    timestamptz;
  v_party  text;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);

  d := erp.migration_domain_of_batch(p_batch_id);
  if d.domain_code is null then
    raise exception 'ERPWARE_NOT_OPENING_BALANCES: % is a %s batch, not opening balances',
      b.code, b.object_type using errcode = '23514';
  end if;

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_REVERSAL_NEEDS_REASON: opening balances are not reversed without one'
      using errcode = '23514';
  end if;

  if b.status <> 'loaded' then
    raise exception 'ERPWARE_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select c.cut_over_at into v_cut from erp.domain_cutover c
   where c.tenant_id = v_tenant and c.domain_code = d.domain_code and c.status = 'cut_over';
  if v_cut is not null then
    raise exception
      'ERPWARE_OPENING_BATCH_CUT_OVER: % was cut over on % on the evidence of this '
      'batch; the domain stands on it', d.domain_code, v_cut::date
      using errcode = '23514',
      hint = 'erp.revert_cutover() first, with a reason, then reverse the batch.';
  end if;

  if d.domain_code = 'stock' then
    perform erp.authorise('inventory.adjust', null, null, null, 'import_batch', p_batch_id);
  end if;

  -- A ledger domain: any activity on a loaded business partner's account
  -- since the load means the open items are no longer only ours to undo.
  if d.control_purpose in ('trade_receivable', 'trade_payable') then
    select p.code into v_party
      from erp.import_row x
      join erp.subledger_item s on s.id = (x.loaded_ref ->> 'subledger_item_id')::uuid
      join erp.subledger_item later
        on later.tenant_id = v_tenant and later.control_kind = s.control_kind
       and later.party_id = s.party_id and later.created_at > b.loaded_at
      join erp.party p on p.id = s.party_id
     where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded
     limit 1;
    if v_party is not null then
      raise exception
        'ERPWARE_OPENING_REVERSAL_BLOCKED: %s has had ledger activity since the '
        'load; reversing the opening items would leave that activity settled '
        'against nothing', v_party
        using errcode = '23514';
    end if;
  end if;

  -- Stock: each movement gets its mirror, in reverse order, and the cost
  -- layer it made is relieved. Stock that has moved since refuses here,
  -- because the mirror would take the position below zero.
  if d.domain_code = 'stock' then
    for r in select x.*, (x.loaded_ref ->> 'movement_id')::bigint as movement_id,
                    (x.loaded_ref ->> 'item_id')::uuid as item_id,
                    (x.loaded_ref ->> 'site_id')::uuid as site_id,
                    (x.loaded_ref ->> 'quantity')::numeric as quantity
               from erp.import_row x
              where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded
              order by x.row_no desc
    loop
      begin
        perform erp.reverse_stock_movement(r.movement_id, left(p_reason, 64));
      exception when check_violation then
        raise exception
          'ERPWARE_OPENING_REVERSAL_BLOCKED: row % (%) — stock has moved since it was '
          'loaded, and reversing the opening balance would leave less than nothing',
          r.row_no, r.raw ->> 'item'
          using errcode = '23514',
          hint = 'Count and adjust the difference instead; the opening load is now history.';
      end;
      if r.quantity > 0 then
        perform erp.issue_cost(r.item_id, r.site_id, r.quantity);
      end if;
      v_n := v_n + 1;
    end loop;
  else
    select count(*) into v_n from erp.import_row x
     where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded;
  end if;

  -- The reversing journal: the mirror of every line, dated today, naming what
  -- it reverses. The original is marked reversed and never touched otherwise.
  select * into j from erp.journal where id = b.journal_id;

  insert into erp.journal (
    tenant_id, entity_id, ledger_id, journal_number, source_code, posting_date,
    description, status, reverses_journal_id, manual_reason)
  values (v_tenant, j.entity_id, j.ledger_id, format('%s-R', b.code), 'manual', current_date,
          format('Reversal of %s', j.description), 'draft', j.id,
          format('Opening balances reversed: %s', p_reason))
  returning id into v_rev;

  insert into erp.journal_line (
    tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
    currency, base_debit_minor, base_credit_minor, exchange_rate, dimensions, description)
  select v_tenant, v_rev, l.line_no, l.account_id, l.credit_minor, l.debit_minor,
         l.currency, l.base_credit_minor, l.base_debit_minor, l.exchange_rate,
         l.dimensions, format('Reversal: %s', l.description)
    from erp.journal_line l where l.journal_id = j.id;

  insert into erp.subledger_item (
    tenant_id, entity_id, ledger_id, control_kind, control_account_id,
    party_id, item_id, journal_id, currency, debit_minor, credit_minor, due_date, posting_date)
  select v_tenant, s.entity_id, s.ledger_id, s.control_kind, s.control_account_id,
         s.party_id, s.item_id, v_rev, s.currency, s.credit_minor, s.debit_minor,
         s.due_date, current_date
    from erp.subledger_item s where s.journal_id = j.id;

  update erp.journal set status = 'posted', posted_at = now(),
         posted_by = erp.current_principal_id()
   where id = v_rev;
  update erp.journal set status = 'reversed', updated_at = now() where id = j.id;

  update erp.import_batch
     set status = 'rolled_back', rolled_back_at = now(), updated_at = now(),
         reversal_journal_id = v_rev, reversal_reason = p_reason
   where id = p_batch_id;

  return v_n;
end;
$$;

comment on function erp.reverse_opening_balances is
  'Part 20: batch reversal. Reversing movements and a reversing journal, never '
  'edits; the original batch, its rows and its journal all stay, marked. '
  'Refused once the domain is cut over on this batch, once stock loaded by it '
  'has moved, or once a loaded business partner has had ledger activity.';

-- ── The master data pipeline learns where these batches go ────────────────────
--
-- erp.validate_import(), erp.load_import() and erp.rollback_import() are the
-- three steps the import screen calls. Each is re-emitted with one change: a
-- batch whose object type is a migration domain is handed to the function
-- above. Everything after the hand-off is the body as it stood.

create or replace function erp.validate_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_find   jsonb;
  v_target uuid;
  v_bad    text;
  v_errors integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- Part 20: opening balances validate against the register's row shape and
  -- this organisation's records, not against maintainable fields.
  if exists (select 1 from erp_ref.migration_domain d where d.object_type = b.object_type) then
    return erp.validate_opening_balances(p_batch_id);
  end if;

  -- The gate this pipeline never had. Staging and loading both authorise
  -- master_data.import; validating and previewing did not, which left two
  -- of the four steps open to any principal who could reach the wrapper.
  perform erp.authorise('master_data.import', null, null, null,
                        'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = b.object_type;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
            order by row_no
  loop
    v_find := '[]'::jsonb;
    v_target := null;

    -- Every row must name the record it is about.
    if coalesce(r.raw ->> 'code', '') = '' then
      v_find := v_find || jsonb_build_object(
        'severity','error','message','no code, so this row names no record');
    else
      execute format('select t.id from erp.%I t where t.tenant_id = $1 and t.code = $2',
                     v_table)
        into v_target using v_tenant, r.raw ->> 'code';
    end if;

    -- Every other key must be a field this product agreed may be written.
    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k <> 'code'
       and not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = b.object_type and m.column_name = k);

    if v_bad is not null then
      v_find := v_find || jsonb_build_object(
        'severity','error','message', format('unknown or protected field(s): %s', v_bad));
    end if;

    update erp.import_row
       set findings = v_find,
           target_id = v_target,
           action = case
                      when jsonb_array_length(v_find) > 0 then 'reject'
                      when v_target is not null then 'update'
                      else 'insert' end,
           updated_at = now()
     where id = r.id;

    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;

  return v_errors;
end;
$$;

create or replace function erp.load_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_new    uuid;
  v_loaded integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- Part 20: opening balances load through their domain's loader.
  if exists (select 1 from erp_ref.migration_domain d where d.object_type = b.object_type) then
    return erp.load_opening_balances(p_batch_id);
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'previewed' then
    raise exception
      'ERPWARE_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after '
      'somebody has looked at it', b.code, b.status
      using errcode = '23514',
      hint = 'Spec 5.1 asks for validation, preview, staged load and rollback '
             'in that order; the preview is the point at which a person is '
             'given a chance to stop.';
  end if;

  if b.error_count > 0 then
    raise exception
      'ERPWARE_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather '
      'than loading the good half', b.error_count, b.code
      using errcode = '23514';
  end if;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
              and action in ('insert', 'update')
            order by row_no
  loop
    if r.action = 'update' then
      update erp.import_row
         set before_snapshot = erp.master_record(b.object_type, r.target_id)
       where id = r.id;
      perform erp.write_master_fields(b.object_type, r.target_id, r.raw - 'code');
      update erp.import_row set loaded = true, updated_at = now() where id = r.id;
    else
      -- Inserting needs the columns an object cannot exist without, which are
      -- object-specific and therefore named here rather than derived.
      if b.object_type = 'party' then
        insert into erp.party (tenant_id, code, name, status)
        values (v_tenant, r.raw ->> 'code',
                coalesce(r.raw ->> 'name', r.raw ->> 'code'), 'draft')
        returning id into v_new;
      elsif b.object_type = 'item' then
        insert into erp.item (tenant_id, code, name, stock_uom_id, lifecycle, status)
        values (v_tenant, r.raw ->> 'code',
                coalesce(r.raw ->> 'name', r.raw ->> 'code'),
                (select u.id from erp.uom u
                  where u.tenant_id = v_tenant and u.is_base
                  order by u.code limit 1),
                'draft', 'draft')
        returning id into v_new;
      else
        raise exception 'ERPWARE_NO_IMPORT_INSERT: % rows can be updated but not created',
          b.object_type using errcode = '23503';
      end if;

      perform erp.write_master_fields(b.object_type, v_new, r.raw - 'code' - 'name');
      update erp.import_row
         set target_id = v_new, loaded = true, before_snapshot = null, updated_at = now()
       where id = r.id;
    end if;

    v_loaded := v_loaded + 1;
  end loop;

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), updated_at = now()
   where id = p_batch_id;

  return v_loaded;
end;
$$;

create or replace function erp.rollback_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_n      integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- Part 20: opening balances are reversed, not deleted, and the reversal
  -- carries the reason the screen's confirmation stands for.
  if exists (select 1 from erp_ref.migration_domain d where d.object_type = b.object_type) then
    return erp.reverse_opening_balances(p_batch_id, 'Rolled back from the import screen');
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'ERPWARE_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = b.object_type;

  -- Reverse order, so that anything an earlier row depended on is still there
  -- while a later row is undone.
  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id and loaded
            order by row_no desc
  loop
    if r.before_snapshot is null then
      -- This row created the record, so undoing it removes the record. If
      -- something has referenced it since, the delete is refused and the
      -- rollback stops — cascading here would take real work with it.
      begin
        execute format('delete from erp.%I t where t.tenant_id = $1 and t.id = $2', v_table)
          using v_tenant, r.target_id;
      exception when foreign_key_violation then
        raise exception
          'ERPWARE_IMPORT_ROLLBACK_BLOCKED: % has been referenced since it was '
          'imported and cannot be removed', r.raw ->> 'code'
          using errcode = '23503',
          hint = 'Withdraw the record instead; deleting it would take whatever '
                 'now depends on it.';
      end;
    else
      perform erp.write_master_fields(
        b.object_type, r.target_id,
        (select jsonb_object_agg(k, r.before_snapshot -> k)
           from jsonb_object_keys(r.raw - 'code') k));
    end if;
    v_n := v_n + 1;
  end loop;

  update erp.import_batch
     set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;

  return v_n;
end;
$$;

-- ── Parallel-run figures ──────────────────────────────────────────────────────
--
-- Each domain's figure as at a date, computed from the ledgers this product
-- keeps. A reversed pair — a movement and its mirror, a journal and its
-- reversal — is excluded whole, so a load that was reversed and redone counts
-- once at any date, including dates between the load and the reversal.

create or replace function erp.migration_figure_stock(p_as_at date)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(round(sum(
           case when m.to_location_id is not null and m.from_location_id is null
                  then m.quantity * coalesce(m.unit_cost_minor, 0)
                when m.from_location_id is not null and m.to_location_id is null
                  then -m.quantity * coalesce(m.unit_cost_minor, 0)
                else 0 end)), 0)::bigint
    from erp.stock_movement m
   where m.tenant_id = erp.current_tenant_id()
     and m.occurred_at < (p_as_at + 1)::timestamptz
     and not m.is_reversal
     and not exists (select 1 from erp.stock_movement r
                      where r.tenant_id = m.tenant_id and r.reverses_movement_id = m.id)
$$;

create or replace function erp.migration_figure_sales_ledger(p_as_at date)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(sum(s.debit_minor - s.credit_minor), 0)::bigint
    from erp.subledger_item s
    join erp.journal j on j.id = s.journal_id
   where s.tenant_id = erp.current_tenant_id()
     and s.control_kind = 'receivable'
     and s.posting_date <= p_as_at
     and j.status = 'posted' and j.reverses_journal_id is null
$$;

create or replace function erp.migration_figure_purchase_ledger(p_as_at date)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(sum(s.credit_minor - s.debit_minor), 0)::bigint
    from erp.subledger_item s
    join erp.journal j on j.id = s.journal_id
   where s.tenant_id = erp.current_tenant_id()
     and s.control_kind = 'payable'
     and s.posting_date <= p_as_at
     and j.status = 'posted' and j.reverses_journal_id is null
$$;

create or replace function erp.migration_figure_nominal(p_as_at date)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(sum(l.debit_minor), 0)::bigint
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id
    join erp.ledger g on g.id = j.ledger_id
   where l.tenant_id = erp.current_tenant_id()
     and g.is_primary
     and j.posting_date <= p_as_at
     and j.status = 'posted' and j.reverses_journal_id is null
$$;

create or replace function erp.record_parallel_run_figure(
  p_domain_code        text,
  p_as_at              date,
  p_legacy_value_minor bigint,
  p_tolerance_minor    bigint default 0,
  p_note               text default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp_ref.migration_domain;
  v_ours   bigint;
  f        erp.parallel_run_figure%rowtype;
begin
  perform erp.authorise('master_data.import', null, null, null, 'parallel_run_figure', null);

  select * into d from erp_ref.migration_domain m where m.domain_code = p_domain_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MIGRATION_DOMAIN: % is not a migration domain', p_domain_code
      using errcode = '23503';
  end if;
  if p_as_at is null or p_as_at > current_date then
    raise exception 'ERPWARE_OPENING_DATE_FUTURE: a parallel run compares a date that has happened'
      using errcode = '23514';
  end if;
  if p_legacy_value_minor is null then
    raise exception 'ERPWARE_LEGACY_FIGURE_MISSING: the legacy system''s figure is the point of the comparison'
      using errcode = '23514';
  end if;

  execute format('select erp.%I($1)', d.figure_function) into v_ours using p_as_at;

  insert into erp.parallel_run_figure (
    tenant_id, domain_code, as_at, legacy_value_minor, our_value_minor,
    tolerance_minor, within_tolerance, note)
  values (v_tenant, p_domain_code, p_as_at, p_legacy_value_minor, v_ours,
          coalesce(p_tolerance_minor, 0),
          abs(v_ours - p_legacy_value_minor) <= coalesce(p_tolerance_minor, 0), p_note)
  on conflict (tenant_id, domain_code, as_at) do update set
    legacy_value_minor = excluded.legacy_value_minor,
    our_value_minor = excluded.our_value_minor,
    tolerance_minor = excluded.tolerance_minor,
    within_tolerance = excluded.within_tolerance,
    note = excluded.note, updated_at = now()
  returning * into f;

  return jsonb_build_object(
    'figure_id', f.id, 'domain_code', f.domain_code, 'as_at', f.as_at,
    'figure', d.figure_name,
    'legacy_value_minor', f.legacy_value_minor, 'our_value_minor', f.our_value_minor,
    'difference_minor', f.difference_minor, 'tolerance_minor', f.tolerance_minor,
    'within_tolerance', f.within_tolerance);
end;
$$;

comment on function erp.record_parallel_run_figure is
  'Part 20: parallel-run comparison. Records the legacy system''s figure for a '
  'domain as at a date against the figure this product computes through the '
  'domain''s registered function, and whether the two agree within tolerance. '
  'One figure per domain and date; recording again replaces it.';

-- ── Cutover (D32) ─────────────────────────────────────────────────────────────

create or replace function erp.cut_over_domain(p_domain_code text, p_note text default null)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  d        erp_ref.migration_domain;
  v_missing text[] := '{}';
  v_batches jsonb;
  v_loaders uuid[];
  v_latest date;
  v_bad    text;
  v_fig    erp.parallel_run_figure%rowtype;
  v_clr    bigint;
  c        erp.domain_cutover%rowtype;
begin
  perform erp.authorise('administration.configure', null, null, null, 'domain_cutover', null);

  select * into d from erp_ref.migration_domain m where m.domain_code = p_domain_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MIGRATION_DOMAIN: % is not a migration domain', p_domain_code
      using errcode = '23503';
  end if;

  if erp.domain_is_cut_over(p_domain_code) then
    raise exception 'ERPWARE_DOMAIN_ALREADY_CUT_OVER: % is already cut over', p_domain_code
      using errcode = '23514';
  end if;

  -- The evidence, gathered as it stands.
  select jsonb_agg(jsonb_build_object(
           'batch_id', b.id, 'code', b.code, 'as_at', b.as_at,
           'row_count', b.row_count, 'loaded_total_minor', b.loaded_total_minor,
           'control_total_minor', b.control_total_minor, 'loaded_by', b.loaded_by,
           'checks', (select jsonb_agg(jsonb_build_object(
                        'check', chk.check_code, 'expected', chk.expected, 'actual', chk.actual,
                        'passes', chk.passes) order by chk.check_code)
                        from erp.opening_balance_reconciliation(b.id) chk))
           order by b.as_at, b.code),
         array_agg(distinct b.loaded_by), max(b.as_at)
    into v_batches, v_loaders, v_latest
    from erp.import_batch b
   where b.tenant_id = v_tenant and b.object_type = d.object_type and b.status = 'loaded';

  if v_batches is null then
    v_missing := array_append(v_missing, 'no opening balances are loaded');
  else
    select string_agg(format('%s: %s', b.code, chk.detail), '; ') into v_bad
      from erp.import_batch b
      cross join lateral erp.opening_balance_reconciliation(b.id) chk
     where b.tenant_id = v_tenant and b.object_type = d.object_type and b.status = 'loaded'
       and not chk.passes;
    if v_bad is not null then
      v_missing := array_append(v_missing, format('a load does not reconcile — %s', v_bad));
    end if;

    -- The person who loaded is not the person who declares it right.
    if v_me = any (v_loaders) then
      v_missing := array_append(v_missing, 'the cutover is declared by somebody other than the person who loaded the balances');
    end if;

    select f.* into v_fig from erp.parallel_run_figure f
     where f.tenant_id = v_tenant and f.domain_code = p_domain_code
       and f.as_at >= v_latest
     order by f.as_at desc, f.updated_at desc limit 1;
    if v_fig.id is null then
      v_missing := array_append(v_missing, format('no parallel-run figure is recorded on or after %s', v_latest));
    elsif not v_fig.within_tolerance then
      v_missing := array_append(v_missing, format(
        'the parallel-run figure as at %s is out by %s against a tolerance of %s',
        v_fig.as_at, v_fig.difference_minor, v_fig.tolerance_minor));
    end if;
  end if;

  -- The nominal ledger is cut over last, when the four domains agree: the
  -- clearing account they all posted against carries nothing.
  v_clr := erp.migration_clearing_balance();
  if p_domain_code = 'nominal' and v_clr <> 0 then
    v_missing := array_append(v_missing, format(
      'migration clearing carries %s; the stock, sales and purchase ledgers and the trial balance do not yet agree', v_clr));
  end if;

  if cardinality(v_missing) > 0 then
    raise exception 'ERPWARE_CUTOVER_EVIDENCE_MISSING: % — %',
      p_domain_code, array_to_string(v_missing, '; ')
      using errcode = '23514',
      hint = 'D32: a domain is cut over on evidence — loads that reconcile, a parallel-run figure within tolerance, and a second person. erp.migration_reconciliation_report() shows what is missing.';
  end if;

  insert into erp.domain_cutover (
    tenant_id, domain_code, status, cut_over_by, evidence, note)
  values (v_tenant, p_domain_code, 'cut_over', v_me,
          jsonb_build_object(
            'batches', v_batches,
            'figure', jsonb_build_object(
              'as_at', v_fig.as_at, 'legacy_value_minor', v_fig.legacy_value_minor,
              'our_value_minor', v_fig.our_value_minor,
              'difference_minor', v_fig.difference_minor,
              'tolerance_minor', v_fig.tolerance_minor),
            'clearing_balance_minor', v_clr,
            'loaded_by', to_jsonb(v_loaders)),
          p_note)
  on conflict (tenant_id, domain_code) do update set
    status = 'cut_over', cut_over_at = now(), cut_over_by = excluded.cut_over_by,
    evidence = excluded.evidence, note = excluded.note,
    reverted_at = null, reverted_by = null, revert_reason = null, updated_at = now()
  returning * into c;

  return jsonb_build_object(
    'domain_code', c.domain_code, 'status', c.status, 'cut_over_at', c.cut_over_at,
    'evidence', c.evidence);
end;
$$;

comment on function erp.cut_over_domain is
  'Part 20, D32: evidence-gated cutover. Refuses by name unless every loaded '
  'batch of the domain reconciles, a parallel-run figure on or after the '
  'latest load is within tolerance, the caller is not the person who loaded, '
  'and — for the nominal ledger — migration clearing stands at zero. The '
  'evidence is kept with the decision.';

create or replace function erp.revert_cutover(p_domain_code text, p_reason text)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  c        erp.domain_cutover%rowtype;
begin
  perform erp.authorise('administration.configure', null, null, null, 'domain_cutover', null);

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_REVERT_NEEDS_REASON: a cutover is not reverted without one'
      using errcode = '23514';
  end if;

  update erp.domain_cutover
     set status = 'reverted', reverted_at = now(), reverted_by = erp.current_principal_id(),
         revert_reason = p_reason, updated_at = now()
   where tenant_id = v_tenant and domain_code = p_domain_code and status = 'cut_over'
  returning * into c;

  if c.domain_code is null then
    raise exception 'ERPWARE_DOMAIN_NOT_CUT_OVER: % is not cut over', p_domain_code
      using errcode = '23514';
  end if;

  return jsonb_build_object('domain_code', c.domain_code, 'status', c.status,
                            'reverted_at', c.reverted_at, 'revert_reason', c.revert_reason);
end;
$$;

-- ── The register agrees with the catalogue ────────────────────────────────────

create or replace function erp.migration_register_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A loader the register names does not exist with the one argument the
  -- gate passes it.
  select 'loader function does not exist', d.domain_code,
         format('erp.%s(p_batch_id uuid) is named by the register and not by pg_proc', d.loader_function)
    from erp_ref.migration_domain d
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'erp'::regnamespace and p.proname = d.loader_function
        and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_batch_id uuid'
        and p.prorettype = 'integer'::regtype)
  union all
  select 'figure function does not exist', d.domain_code,
         format('erp.%s(p_as_at date) returning bigint is named by the register and not by pg_proc', d.figure_function)
    from erp_ref.migration_domain d
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'erp'::regnamespace and p.proname = d.figure_function
        and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_as_at date'
        and p.prorettype = 'bigint'::regtype)
  union all
  select 'domain names a module that does not exist', d.domain_code, d.module_code
    from erp_ref.migration_domain d
   where not exists (select 1 from erp_ref.module m where m.code = d.module_code)
  union all
  select 'domain object type collides with a maintainable object type', d.domain_code, d.object_type
    from erp_ref.migration_domain d
   where exists (select 1 from erp_meta.maintainable_field m where m.object_type = d.object_type)
  union all
  select 'domain has no base-locale name', d.domain_code, d.name_key
    from erp_ref.migration_domain d
   where not exists (select 1 from erp_ref.resource r where r.key = d.name_key and r.locale = 'en')
  union all
  select 'row shape is not a list of keys', d.domain_code, left(d.row_keys::text, 80)
    from erp_ref.migration_domain d
   where jsonb_typeof(d.row_keys) <> 'array'
      or exists (select 1 from jsonb_array_elements(d.row_keys) k
                  where k ->> 'key' is null
                     or k ->> 'type' not in ('text', 'number', 'integer', 'date')
                     or jsonb_typeof(k -> 'required') <> 'boolean')
  union all
  select 'the opening stock movement type is not registered', 'opening_balance',
         'erp.load_opening_stock() writes movement_type opening_balance'
   where not exists (select 1 from erp_ref.movement_type t where t.code = 'opening_balance')
  union all
  select 'the migration clearing purpose is not on the chart', 'clearing',
         'every loader balances to erp.chart_account_code(''clearing'')'
   where not exists (select 1 from erp_ref.chart_account_purpose p where p.purpose = 'clearing')
  union all
  select 'the import pipeline does not hand opening balances to their loader', f.name,
         format('erp.%s() does not mention %s', f.name, f.needs)
    from (values ('validate_import', 'validate_opening_balances'),
                 ('load_import', 'load_opening_balances'),
                 ('rollback_import', 'reverse_opening_balances')) f(name, needs)
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'erp'::regnamespace and p.proname = f.name
        and p.prosrc like '%' || f.needs || '%')
$$;

comment on function erp.migration_register_report is
  'Part 20. Fails where a migration domain names a loader or figure function '
  'pg_proc does not have with that signature, a module that does not exist, '
  'an object type the master data pipeline already claims, or a row shape '
  'that is not a list of typed keys; and where the import pipeline no longer '
  'hands these batches on. Read by erp.assert_migration_sound().';

create or replace function erp.assert_migration_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_domains integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.migration_register_report();

  if v_count > 0 then
    raise exception 'ERPWARE_MIGRATION_REGISTER_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) into v_domains from erp_ref.migration_domain;
  return format('migration register: %s domain(s), each with a loader, a figure and a row shape', v_domains);
end;
$$;

comment on function erp.assert_migration_sound is
  'Fails where erp_ref.migration_domain disagrees with pg_proc or the chart, '
  'or where the import pipeline no longer hands opening balances to their loader.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('migration_register', 'Migration register sound', 'assertion', 'platform',
   'erp', 'assert_migration_sound', '', 'migration_register_report', '',
   'Every migration domain names a loader and a figure function that exist with the right signature, and the import pipeline hands opening balances to them.',
   true, 63)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- ── Doors ─────────────────────────────────────────────────────────────────────

create or replace function public.erp_migration_domains()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('master_data.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'domain_code', d.domain_code,
      'name', coalesce(erp.text(d.name_key), d.domain_code),
      'module_code', d.module_code,
      'object_type', d.object_type,
      'loader_function', d.loader_function,
      'figure_function', d.figure_function,
      'figure_name', d.figure_name,
      'control_purpose', d.control_purpose,
      'row_keys', d.row_keys,
      'description', d.description,
      'batches_loaded', r.batches_loaded,
      'rows_loaded', r.rows_loaded,
      'control_total_minor', r.control_total_minor,
      'loaded_total_minor', r.loaded_total_minor,
      'reconciles', r.reconciles,
      'latest_as_at', r.latest_as_at,
      'figure_within_tolerance', r.figure_within_tolerance,
      'cutover_status', r.cutover_status,
      'finding', r.finding) order by d.seq)
      from erp_ref.migration_domain d
      join erp.migration_reconciliation_report() r on r.domain_code = d.domain_code),
    '[]'::jsonb);
end;
$$;

create or replace function public.erp_stage_opening_balances(
  p_domain_code         text,
  p_as_at               date,
  p_rows                jsonb,
  p_control_total_minor bigint,
  p_control_quantity    numeric default null,
  p_code                text default null
) returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object(
    'batch_id', erp.stage_opening_balances(p_domain_code, p_as_at, p_rows,
                  p_control_total_minor, p_control_quantity, p_code, 'legacy extract'))
$$;

create or replace function public.erp_opening_batches()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('master_data.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x ->> 'created_at' desc) from (
      select jsonb_build_object(
        'batch_id', b.id, 'code', b.code, 'domain_code', d.domain_code,
        'domain', coalesce(erp.text(d.name_key), d.domain_code),
        'status', b.status, 'as_at', b.as_at, 'currency', b.currency,
        'row_count', b.row_count, 'error_count', b.error_count,
        'control_total_minor', b.control_total_minor, 'loaded_total_minor', b.loaded_total_minor,
        'control_quantity', b.control_quantity, 'loaded_quantity', b.loaded_quantity,
        'loaded_at', b.loaded_at, 'rolled_back_at', b.rolled_back_at,
        'reversal_reason', b.reversal_reason, 'created_at', b.created_at,
        'checks', case when b.status in ('loaded', 'rolled_back') then
                    (select jsonb_agg(jsonb_build_object(
                       'check_code', c.check_code, 'expected', c.expected, 'actual', c.actual,
                       'difference', c.difference, 'passes', c.passes, 'detail', c.detail)
                       order by c.check_code)
                       from erp.opening_balance_reconciliation(b.id) c)
                  else '[]'::jsonb end,
        'findings', coalesce((select jsonb_agg(jsonb_build_object(
                       'row_no', r.row_no, 'findings', r.findings) order by r.row_no)
                       from erp.import_row r
                      where r.import_batch_id = b.id and jsonb_array_length(r.findings) > 0),
                    '[]'::jsonb)) as x
        from erp.import_batch b
        join erp_ref.migration_domain d on d.object_type = b.object_type
       where b.tenant_id = v_tenant) t), '[]'::jsonb);
end;
$$;

create or replace function public.erp_opening_balance_reconciliation(p_batch_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('master_data.read');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'check_code', c.check_code, 'expected', c.expected, 'actual', c.actual,
      'difference', c.difference, 'passes', c.passes, 'detail', c.detail)
      order by c.check_code)
      from erp.opening_balance_reconciliation(p_batch_id) c), '[]'::jsonb);
end;
$$;

create or replace function public.erp_record_parallel_run_figure(
  p_domain_code        text,
  p_as_at              date,
  p_legacy_value_minor bigint,
  p_tolerance_minor    bigint default 0,
  p_note               text default null
) returns jsonb
language sql
set search_path = ''
as $$
  select erp.record_parallel_run_figure(p_domain_code, p_as_at, p_legacy_value_minor,
                                        p_tolerance_minor, p_note)
$$;

create or replace function public.erp_parallel_run_figures()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('finance.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'figure_id', f.id, 'domain_code', f.domain_code,
      'domain', coalesce(erp.text(d.name_key), d.domain_code),
      'figure_name', d.figure_name, 'as_at', f.as_at,
      'legacy_value_minor', f.legacy_value_minor, 'our_value_minor', f.our_value_minor,
      'difference_minor', f.difference_minor, 'tolerance_minor', f.tolerance_minor,
      'within_tolerance', f.within_tolerance, 'note', f.note,
      'recorded_at', f.updated_at) order by f.as_at desc, d.seq)
      from erp.parallel_run_figure f
      join erp_ref.migration_domain d on d.domain_code = f.domain_code
     where f.tenant_id = v_tenant), '[]'::jsonb);
end;
$$;

create or replace function public.erp_cut_over_domain(p_domain_code text, p_note text default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.cut_over_domain(p_domain_code, p_note)
$$;

create or replace function public.erp_revert_cutover(p_domain_code text, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.revert_cutover(p_domain_code, p_reason)
$$;

create or replace function public.erp_domain_cutovers()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('finance.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'domain_code', c.domain_code,
      'domain', coalesce(erp.text(d.name_key), d.domain_code),
      'status', c.status, 'cut_over_at', c.cut_over_at,
      'cut_over_by', (select u.display_name from erp.app_user u where u.id = c.cut_over_by),
      'note', c.note, 'evidence', c.evidence,
      'reverted_at', c.reverted_at, 'revert_reason', c.revert_reason) order by d.seq)
      from erp.domain_cutover c
      join erp_ref.migration_domain d on d.domain_code = c.domain_code
     where c.tenant_id = v_tenant), '[]'::jsonb);
end;
$$;

-- Supabase carries DEFAULT PRIVILEGES on schema public that grant EXECUTE to
-- anon, so a new door is callable without signing in until it is revoked.
revoke all on function
  public.erp_migration_domains(),
  public.erp_stage_opening_balances(text, date, jsonb, bigint, numeric, text),
  public.erp_opening_batches(),
  public.erp_opening_balance_reconciliation(uuid),
  public.erp_record_parallel_run_figure(text, date, bigint, bigint, text),
  public.erp_parallel_run_figures(),
  public.erp_cut_over_domain(text, text),
  public.erp_revert_cutover(text, text),
  public.erp_domain_cutovers()
  from public, anon;

grant execute on function
  public.erp_migration_domains(),
  public.erp_stage_opening_balances(text, date, jsonb, bigint, numeric, text),
  public.erp_opening_batches(),
  public.erp_opening_balance_reconciliation(uuid),
  public.erp_record_parallel_run_figure(text, date, bigint, bigint, text),
  public.erp_parallel_run_figures(),
  public.erp_cut_over_domain(text, text),
  public.erp_revert_cutover(text, text),
  public.erp_domain_cutovers()
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_stage_opening_balances', 'erp.stage_opening_balances',
   'Stages a batch of opening balances for one migration domain as at a date, with the control total the legacy extract was taken with. Gates on master_data.import as staging does; loading gates again on finance.post and, for stock, inventory.adjust.'),
  ('erp_record_parallel_run_figure', 'erp.record_parallel_run_figure',
   'Records the legacy system''s figure for a domain as at a date against the figure this product computes. Gates on master_data.import; one figure per domain and date.'),
  ('erp_cut_over_domain', 'erp.cut_over_domain',
   'Declares a migration domain cut over. Gates on administration.configure and refuses unless every load reconciles, a parallel-run figure is within tolerance and the caller is not the person who loaded — D32''s evidence, kept with the decision.'),
  ('erp_revert_cutover', 'erp.revert_cutover',
   'Reverts a domain''s cutover with a reason, reopening it to opening loads and reversals. Gates on administration.configure.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.migration_cutover_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  a1 uuid := gen_random_uuid();   -- loads everything
  a2 uuid := gen_random_uuid();   -- the second administrator, who cuts over
  op uuid := gen_random_uuid();   -- no rights
  csf uuid; csi uuid;
  v_second uuid; v_op uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_bulk uuid; v_cust uuid; v_sup uuid; v_wid uuid; v_gad uuid;
  v_asat date := date_trunc('month', current_date)::date;
  v_stock uuid; v_bad uuid; v_sales uuid; v_purch uuid; v_nom uuid; v_stock2 uuid;
  v_n integer; v_ok boolean; v_msg text;
  v_inv uuid; v_rec uuid; v_pay uuid; v_clr text;
  v_journal uuid; v_move bigint;
  v_gl bigint; v_sub bigint;
  v_checks integer; v_passes integer;
begin
  select * into r from erp.provision_tenant(
    'zzmig', 'Migration Cutover', 'admin@zzmig.test', 'Migration Admin');
  insert into auth.users (id, email) values
    (a1, 'admin@zzmig.test'), (a2, 'second@zzmig.test'), (op, 'op@zzmig.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzmig.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  csf := erp.configure_finance();
  csi := erp.configure_inventory('average');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'BULK-01', 'Bulk 01', 'bulk', 'active') returning id into v_bulk;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_wid;
  insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, status)
  values (r.tenant_id, 'GAD', 'Gadget', v_uom, true, 'active') returning id into v_gad;

  select a.id into v_inv from erp.account a
   where a.tenant_id = r.tenant_id and a.code = erp.chart_account_code('inventory');
  select a.id into v_rec from erp.account a
   where a.tenant_id = r.tenant_id and a.code = erp.chart_account_code('trade_receivable');
  select a.id into v_pay from erp.account a
   where a.tenant_id = r.tenant_id and a.code = erp.chart_account_code('trade_payable');
  v_clr := erp.chart_account_code('clearing');

  -- ── The register ──────────────────────────────────────────────────────────

  begin
    v_msg := erp.assert_migration_sound(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'every migration domain names a loader and a figure the catalogue has',
    v_ok and v_msg like 'migration register: 4 domain(s)%', v_msg;

  -- ── Staging refuses what cannot be reconciled ─────────────────────────────

  begin
    perform erp.stage_opening_balances('fixed_assets', v_asat, '[{"x":1}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged a domain the register does not have';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_MIGRATION_DOMAIN%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a domain the register does not name is refused', v_ok, v_msg;

  begin
    perform erp.stage_opening_balances('stock', v_asat, '[{"item":"WID"}]'::jsonb, null);
    v_ok := false; v_msg := 'staged without a control total';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_OPENING_CONTROL_MISSING%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a batch with no control total is refused, because it could not be reconciled', v_ok, v_msg;

  begin
    perform erp.stage_opening_balances('stock', current_date + 1, '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged as at tomorrow';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_OPENING_DATE_FUTURE%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a date that has not happened is refused', v_ok, v_msg;

  begin
    perform erp.stage_opening_balances('stock', make_date(1990, 1, 1), '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged outside the calendar';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_OPENING_DATE_OUTSIDE_CALENDAR%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a date outside the ledger''s accounting periods is refused', v_ok, v_msg;

  -- ── Validation finds what a row names wrongly ─────────────────────────────

  v_bad := erp.stage_opening_balances('stock', v_asat, jsonb_build_array(
    jsonb_build_object('item', 'NOPE', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 5, 'unit_cost_minor', 100),
    jsonb_build_object('item', 'GAD', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 5, 'unit_cost_minor', 100),
    jsonb_build_object('item', 'WID', 'site', 'MAIN', 'location', 'NOWHERE', 'quantity', 5, 'unit_cost_minor', 100, 'colour', 'red')),
    1500);
  v_n := erp.validate_import(v_bad);
  return query select 'validation rejects an unknown product, a batch-controlled product with no batch, an unknown location and an unknown field',
    v_n = 3
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 1) like '%no product has the code NOPE%'
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 2) like '%batch controlled%'
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 3) like '%no location NOWHERE%'
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 3) like '%unknown field(s): colour%',
    format('%s rows rejected', v_n);

  perform erp.preview_import(v_bad);
  begin
    perform erp.load_import(v_bad);
    v_ok := false; v_msg := 'loaded a batch with rejected rows';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_IMPORT_HAS_ERRORS%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and a batch with rejected rows does not load', v_ok, v_msg;

  -- ── Opening stock, as at a date ───────────────────────────────────────────

  v_stock := erp.stage_opening_balances('stock', v_asat, jsonb_build_array(
    jsonb_build_object('item', 'WID', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 100, 'unit_cost_minor', 250),
    jsonb_build_object('item', 'GAD', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 40, 'unit_cost_minor', 500,
                       'batch', 'L-2026-01', 'expires_on', (current_date + 365)::text)),
    45000, 140, 'OB-STOCK-1');
  v_n := erp.validate_import(v_stock);

  begin
    perform erp.load_import(v_stock);
    v_ok := false; v_msg := 'loaded before anybody looked';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_IMPORT_NOT_PREVIEWED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'opening balances load only after a preview, like every other import', v_ok and v_n = 0, v_msg;

  perform erp.preview_import(v_stock);
  v_n := erp.load_import(v_stock);
  select m.id into v_move from erp.stock_movement m
   where m.tenant_id = r.tenant_id and m.item_id = v_wid and m.movement_type = 'opening_balance';
  return query select 'opening stock becomes opening_balance movements dated as at, and a released batch',
    v_n = 2
    and (select sum(b.quantity) from erp.stock_balance b
          where b.tenant_id = r.tenant_id and b.item_id = v_wid and b.location_id = v_bulk) = 100
    and (select m.occurred_at::date from erp.stock_movement m where m.id = v_move) = v_asat
    and (select bt.status::text from erp.batch bt
          where bt.tenant_id = r.tenant_id and bt.item_id = v_gad and bt.batch_number = 'L-2026-01') = 'unrestricted'
    and (select c.unit_cost_minor from erp.item_cost c
          where c.tenant_id = r.tenant_id and c.item_id = v_gad) = 500,
    format('%s rows loaded; WID on hand 100, GAD batch released at 500', v_n);

  select b.journal_id into v_journal from erp.import_batch b where b.id = v_stock;
  select coalesce(sum(l.debit_minor - l.credit_minor), 0) into v_gl
    from erp.journal_line l where l.journal_id = v_journal and l.account_id = v_inv;
  select coalesce(sum(s.debit_minor - s.credit_minor), 0) into v_sub
    from erp.subledger_item s where s.journal_id = v_journal and s.control_kind = 'inventory';
  return query select 'the batch posts one journal, stock against migration clearing, dated as at, with stock detail per product',
    (select j.status::text from erp.journal j where j.id = v_journal) = 'posted'
    and (select j.posting_date from erp.journal j where j.id = v_journal) = v_asat
    and (select j.source_code from erp.journal j where j.id = v_journal) = 'manual'
    and v_gl = 45000 and v_sub = 45000
    and erp.migration_clearing_balance() = -45000
    and exists (select 1 from erp.account a where a.tenant_id = r.tenant_id and a.code = v_clr and a.name = 'Migration clearing'),
    format('stock %s, detail %s, clearing %s', v_gl, v_sub, erp.migration_clearing_balance());

  -- ── D31: reconciliation after load ────────────────────────────────────────

  select count(*), count(*) filter (where c.passes) into v_checks, v_passes
    from erp.opening_balance_reconciliation(v_stock) c;
  return query select 'the reconciliation after load passes every check: rows, control total, control quantity, journal, control detail',
    v_checks = 5 and v_passes = 5,
    format('%s of %s checks pass', v_passes, v_checks);

  -- A sales ledger load whose control total disagrees with its rows.
  v_sales := erp.stage_opening_balances('sales_ledger', v_asat, jsonb_build_array(
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9001', 'amount_minor', 20000, 'due_date', (v_asat + 30)::text),
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9002', 'amount_minor', 12000),
    jsonb_build_object('party', 'CUST', 'reference', 'CRN-17', 'amount_minor', -2000)),
    31000, null, 'OB-SALES-1');
  perform erp.validate_import(v_sales); perform erp.preview_import(v_sales);
  v_n := erp.load_import(v_sales);
  select count(*), count(*) filter (where c.passes) into v_checks, v_passes
    from erp.opening_balance_reconciliation(v_sales) c;
  return query select 'a load whose control total disagrees loads, and the reconciliation says by how much',
    v_n = 3 and v_checks = 4 and v_passes = 3
    and exists (select 1 from erp.opening_balance_reconciliation(v_sales) c
                 where c.check_code = 'control_total' and not c.passes and c.difference = -1000)
    and (select b.loaded_total_minor from erp.import_batch b where b.id = v_sales) = 30000
    and erp.migration_figure_sales_ledger(v_asat) = 30000,
    format('%s of %s checks pass; loaded 30000 against a control of 31000', v_passes, v_checks);

  return query select 'the tenant-level report names the batch that does not reconcile',
    (select m.finding from erp.migration_reconciliation_report() m where m.domain_code = 'sales_ledger')
      like 'OB-SALES-1: loaded 30000 against a control total of 31000%'
    and (select m.reconciles from erp.migration_reconciliation_report() m where m.domain_code = 'stock'),
    (select m.finding from erp.migration_reconciliation_report() m where m.domain_code = 'sales_ledger');

  -- ── D32: no evidence, no cutover ──────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.cut_over_domain('sales_ledger');
    v_ok := false; v_msg := 'cut over a domain that does not reconcile';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CUTOVER_EVIDENCE_MISSING: sales_ledger%does not reconcile%OB-SALES-1%'
            and sqlerrm like '%no parallel-run figure%';
    v_msg := left(sqlerrm, 160);
  end;
  return query select 'a domain whose load does not reconcile is not cut over, and the refusal says why', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── Reversal, as a unit ───────────────────────────────────────────────────

  begin
    perform erp.reverse_opening_balances(v_sales, '');
    v_ok := false; v_msg := 'reversed without a reason';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REVERSAL_NEEDS_REASON%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a reversal needs a reason', v_ok, v_msg;

  v_n := erp.rollback_import(v_sales);
  return query select 'reversing the batch posts a reversing journal and leaves the ledger where it was',
    v_n = 3
    and (select b.status::text from erp.import_batch b where b.id = v_sales) = 'rolled_back'
    and (select j.status::text from erp.journal j where j.id = (select b.journal_id from erp.import_batch b where b.id = v_sales)) = 'reversed'
    and (select j.reverses_journal_id from erp.journal j where j.id = (select b.reversal_journal_id from erp.import_batch b where b.id = v_sales))
        = (select b.journal_id from erp.import_batch b where b.id = v_sales)
    and (select coalesce(sum(l.debit_minor - l.credit_minor), 0) from erp.journal_line l
          join erp.journal j on j.id = l.journal_id
         where l.tenant_id = r.tenant_id and l.account_id = v_rec) = 0
    and (select coalesce(sum(s.debit_minor - s.credit_minor), 0) from erp.subledger_item s
          where s.tenant_id = r.tenant_id and s.control_kind = 'receivable') = 0
    and erp.migration_figure_sales_ledger(v_asat) = 0,
    format('%s rows reversed; receivables nominal 0, detail 0, figure as at 0', v_n);

  v_sales := erp.stage_opening_balances('sales_ledger', v_asat, jsonb_build_array(
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9001', 'amount_minor', 20000, 'due_date', (v_asat + 30)::text),
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9002', 'amount_minor', 12000),
    jsonb_build_object('party', 'CUST', 'reference', 'CRN-17', 'amount_minor', -2000)),
    30000, null, 'OB-SALES-2');
  perform erp.validate_import(v_sales); perform erp.preview_import(v_sales);
  v_n := erp.load_import(v_sales);
  return query select 'reloaded with the right control total, the sales ledger reconciles and the figure counts the load once',
    v_n = 3
    and (select m.reconciles from erp.migration_reconciliation_report() m where m.domain_code = 'sales_ledger')
    and erp.migration_figure_sales_ledger(v_asat) = 30000
    and (select count(*) from erp.subledger_item s where s.tenant_id = r.tenant_id
          and s.control_kind = 'receivable' and s.party_id = v_cust) = 9,
    format('figure %s from nine detail rows, six of them a reversed pair', erp.migration_figure_sales_ledger(v_asat));

  -- Stock that has moved since the load cannot be reversed.
  v_stock2 := erp.stage_opening_balances('stock', v_asat, jsonb_build_array(
    jsonb_build_object('item', 'WID', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 10, 'unit_cost_minor', 250)),
    2500, 10, 'OB-STOCK-2');
  perform erp.validate_import(v_stock2); perform erp.preview_import(v_stock2);
  perform erp.load_import(v_stock2);
  perform erp.write_off_stock(v_wid, v_site, v_bulk, 105, 'damaged in the move');
  begin
    perform erp.reverse_opening_balances(v_stock2, 'wrong count');
    v_ok := false; v_msg := 'reversed stock that had since moved';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_OPENING_REVERSAL_BLOCKED: row 1 (WID)%'; v_msg := left(sqlerrm, 90);
  end;
  return query select 'an opening stock load is not reversed once the stock has moved', v_ok, v_msg;

  -- Undo the write-off's effect on the figure for the rest of the suite: it is
  -- dated today, after as-at, so the as-at figure is unchanged already.
  return query select 'the as-at stock figure ignores what happened after the date',
    erp.migration_figure_stock(v_asat) = 47500
    and erp.migration_figure_stock(current_date) = 47500 - 105 * 250,
    format('as at %s: %s; today: %s', v_asat, erp.migration_figure_stock(v_asat), erp.migration_figure_stock(current_date));

  -- ── The parallel run ──────────────────────────────────────────────────────

  res := erp.record_parallel_run_figure('stock', v_asat, 47500, 0, 'stock valuation report, legacy');
  return query select 'a parallel-run figure records what the legacy system said against what this product computes',
    (res ->> 'our_value_minor')::bigint = 47500 and (res ->> 'difference_minor')::bigint = 0
    and (res ->> 'within_tolerance')::boolean,
    format('legacy %s, ours %s', res ->> 'legacy_value_minor', res ->> 'our_value_minor');

  res := erp.record_parallel_run_figure('sales_ledger', v_asat, 30500, 100, 'aged debtors, legacy');
  return query select 'a figure outside tolerance is recorded as such',
    not (res ->> 'within_tolerance')::boolean and (res ->> 'difference_minor')::bigint = -500,
    format('out by %s against a tolerance of %s', res ->> 'difference_minor', res ->> 'tolerance_minor');

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.cut_over_domain('sales_ledger');
    v_ok := false; v_msg := 'cut over outside tolerance';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CUTOVER_EVIDENCE_MISSING: sales_ledger%out by -500 against a tolerance of 100%';
    v_msg := left(sqlerrm, 120);
  end;
  return query select 'and blocks the cutover by name', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.record_parallel_run_figure('sales_ledger', v_asat, 30000, 100, 'aged debtors, legacy, corrected');
  return query select 'recording the figure again for the same date replaces it',
    (res ->> 'within_tolerance')::boolean
    and (select count(*) from erp.parallel_run_figure f
          where f.tenant_id = r.tenant_id and f.domain_code = 'sales_ledger') = 1,
    'one figure per domain and date';

  -- ── Cutover, on evidence, by a second person ──────────────────────────────

  begin
    perform erp.cut_over_domain('stock');
    v_ok := false; v_msg := 'the loader cut over their own load';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CUTOVER_EVIDENCE_MISSING: stock%somebody other than the person who loaded%';
    v_msg := left(sqlerrm, 120);
  end;
  return query select 'the person who loaded the balances cannot declare them right', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  res := erp.cut_over_domain('stock', 'agreed with the stock valuation report');
  return query select 'a second administrator cuts stock over, and the evidence is kept with the decision',
    res ->> 'status' = 'cut_over'
    and jsonb_array_length(res -> 'evidence' -> 'batches') = 2
    and (res -> 'evidence' -> 'figure' ->> 'our_value_minor')::bigint = 47500
    and erp.domain_is_cut_over('stock')
    and (select m.cutover_status from erp.migration_reconciliation_report() m where m.domain_code = 'stock') = 'cut_over',
    format('%s batch(es) in evidence, figure %s', jsonb_array_length(res -> 'evidence' -> 'batches'),
           res -> 'evidence' -> 'figure' ->> 'our_value_minor');

  begin
    perform erp.stage_opening_balances('stock', v_asat, '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged over a cut-over domain';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DOMAIN_CUT_OVER%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a cut-over domain takes no more opening balances', v_ok, v_msg;

  begin
    perform erp.reverse_opening_balances(v_stock, 'second thoughts');
    v_ok := false; v_msg := 'reversed the load a cutover stands on';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_OPENING_BATCH_CUT_OVER%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and the load it stands on is not reversed', v_ok, v_msg;

  res := erp.cut_over_domain('sales_ledger');
  return query select 'the sales ledger cuts over on its corrected figure',
    res ->> 'status' = 'cut_over', res ->> 'cut_over_at';

  -- ── The nominal ledger cuts over last, when clearing is nothing ───────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  -- Clearing so far: stock 47500 credit, sales 30000 credit → 77500 credit.
  -- Trial balance: bank 100000 debit, revenue 157500 credit → net 57500 credit,
  -- so clearing takes 57500 debit and stands at 20000 credit — the purchase
  -- ledger not yet loaded.
  v_nom := erp.stage_opening_balances('nominal', v_asat, jsonb_build_array(
    jsonb_build_object('account', erp.chart_account_code('bank'), 'debit_minor', 100000),
    jsonb_build_object('account', erp.chart_account_code('revenue'), 'credit_minor', 157500),
    jsonb_build_object('account', erp.chart_account_code('trade_receivable'), 'debit_minor', 1)),
    100001, null, 'OB-TB-1');
  v_n := erp.validate_import(v_nom);
  return query select 'a trial balance row on a control account another domain loads is rejected',
    v_n = 1
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_nom and r2.row_no = 3)
        like '%receivable control account; its balance is loaded through the sales_ledger domain%',
    (select r2.findings ->> 0 from erp.import_row r2 where r2.import_batch_id = v_nom and r2.row_no = 3);

  v_nom := erp.stage_opening_balances('nominal', v_asat, jsonb_build_array(
    jsonb_build_object('account', erp.chart_account_code('bank'), 'debit_minor', 100000),
    jsonb_build_object('account', erp.chart_account_code('revenue'), 'credit_minor', 157500)),
    100000, null, 'OB-TB-2');
  perform erp.validate_import(v_nom); perform erp.preview_import(v_nom);
  v_n := erp.load_import(v_nom);
  return query select 'the trial balance loads to the nominal accounts it names, bank detail included, net to clearing',
    v_n = 2
    and (select m.reconciles from erp.migration_reconciliation_report() m where m.domain_code = 'nominal')
    and erp.migration_clearing_balance() = -20000
    and (select count(*) from erp.subledger_item s where s.tenant_id = r.tenant_id and s.control_kind = 'bank') = 1,
    format('clearing %s', erp.migration_clearing_balance());

  perform erp.record_parallel_run_figure('nominal', v_asat, erp.migration_figure_nominal(v_asat), 0);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.cut_over_domain('nominal');
    v_ok := false; v_msg := 'cut the nominal ledger over with clearing carrying a balance';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CUTOVER_EVIDENCE_MISSING: nominal%migration clearing carries -20000%';
    v_msg := left(sqlerrm, 140);
  end;
  return query select 'the nominal ledger is not cut over while migration clearing carries a balance', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_purch := erp.stage_opening_balances('purchase_ledger', v_asat, jsonb_build_array(
    jsonb_build_object('party', 'SUP', 'reference', 'PI-441', 'amount_minor', 25000, 'due_date', (v_asat + 45)::text),
    jsonb_build_object('party', 'SUP', 'reference', 'DN-3', 'amount_minor', -5000)),
    20000, null, 'OB-PURCH-1');
  perform erp.validate_import(v_purch); perform erp.preview_import(v_purch);
  v_n := erp.load_import(v_purch);
  return query select 'the purchase ledger loads, credits payables, and clearing nets to nothing',
    v_n = 2
    and erp.migration_figure_purchase_ledger(v_asat) = 20000
    and (select coalesce(sum(l.credit_minor - l.debit_minor), 0) from erp.journal_line l
          where l.tenant_id = r.tenant_id and l.account_id = v_pay) = 20000
    and erp.migration_clearing_balance() = 0,
    format('payables %s, clearing %s', erp.migration_figure_purchase_ledger(v_asat), erp.migration_clearing_balance());

  perform erp.record_parallel_run_figure('purchase_ledger', v_asat, 20000, 0);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.cut_over_domain('purchase_ledger');
  res := erp.cut_over_domain('nominal', 'trial balance agreed');
  return query select 'with the four domains agreeing, the nominal ledger cuts over and every domain reads cut over',
    res ->> 'status' = 'cut_over'
    and (res -> 'evidence' ->> 'clearing_balance_minor')::bigint = 0
    and (select count(*) from erp.migration_reconciliation_report() m where m.cutover_status = 'cut_over') = 4
    and (select count(*) from erp.migration_reconciliation_report() m where m.finding is not null) = 0,
    'four of four cut over, no finding';

  -- ── Reverting, with a reason ──────────────────────────────────────────────

  begin
    perform erp.revert_cutover('purchase_ledger', '');
    v_ok := false; v_msg := 'reverted without a reason';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REVERT_NEEDS_REASON%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a cutover is not reverted without a reason', v_ok, v_msg;

  res := erp.revert_cutover('purchase_ledger', 'supplier statements disagree; reloading');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v_n := erp.reverse_opening_balances(v_purch, 'reloading from corrected statements');
  return query select 'a reverted domain takes reversals and loads again',
    res ->> 'status' = 'reverted' and v_n = 2
    and not erp.domain_is_cut_over('purchase_ledger')
    and erp.migration_figure_purchase_ledger(v_asat) = 0
    and (select m.finding from erp.migration_reconciliation_report() m where m.domain_code = 'purchase_ledger') = 'no opening balances loaded',
    format('%s rows reversed; purchase ledger back to nothing', v_n);

  -- ── The doors say the same, to the people allowed to read them ────────────

  res := public.erp_migration_domains();
  return query select 'the domains door carries the register and the organisation''s standing per domain',
    jsonb_array_length(res) = 4
    and (select x ->> 'cutover_status' from jsonb_array_elements(res) x where x ->> 'domain_code' = 'stock') = 'cut_over'
    and (select x ->> 'name' from jsonb_array_elements(res) x where x ->> 'domain_code' = 'sales_ledger') = 'Sales ledger'
    and (select jsonb_array_length(x -> 'row_keys') from jsonb_array_elements(res) x where x ->> 'domain_code' = 'stock') = 7,
    format('%s domain(s)', jsonb_array_length(res));

  res := public.erp_opening_batches();
  return query select 'the batches door carries every opening load with its checks',
    jsonb_array_length(res) = 8
    and (select jsonb_array_length(x -> 'checks') from jsonb_array_elements(res) x where x ->> 'code' = 'OB-STOCK-1') = 5,
    format('%s batch(es)', jsonb_array_length(res));

  res := public.erp_invite_principal('op@zzmig.test', 'No rights');
  v_op := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);
  begin
    perform public.erp_cut_over_domain('purchase_ledger');
    v_ok := false; v_msg := 'somebody with no rights cut a domain over';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a person without administration.configure may not cut over', v_ok, v_msg;
  begin
    perform public.erp_stage_opening_balances('stock', v_asat, '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'somebody with no rights staged a load';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor stage opening balances', v_ok, v_msg;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  -- The loads posted journals, and the journal-balance check is a deferred
  -- constraint trigger. Fire it now, while the lines it checks still exist,
  -- rather than at commit after the organisation has gone.
  set constraints all immediate;
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2, op);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from auth.users u where u.id in (a1, a2, op))
    and not exists (select 1 from erp.parallel_run_figure f where f.tenant_id = r.tenant_id)
    and not exists (select 1 from erp.domain_cutover c where c.tenant_id = r.tenant_id),
    'loads, figures and cutovers go with the organisation';
end;
$$;

comment on function erp_test.migration_cutover_suite is
  'Specification v1.2 Part 20, proven adversarially: opening stock, sales, '
  'purchase and nominal balances load as at a date through the movement and '
  'journal tables; a load with the wrong control total loads and reconciles '
  'as wrong; reversal is a reversing journal and is refused once stock has '
  'moved or a cutover stands on it; a parallel-run figure outside tolerance '
  'blocks cutover by name; the loader cannot cut over their own load; the '
  'nominal ledger cuts over last, when migration clearing is nothing.';

create or replace function erp_test.assert_migration_cutover_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _migration_cutover_result on commit drop as
    select * from erp_test.migration_cutover_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _migration_cutover_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_MIGRATION_CUTOVER_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('migration cutover: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_migration_sound();
select erp_test.assert_migration_cutover_suite();
