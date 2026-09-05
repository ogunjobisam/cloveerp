-- Valuation is the ledger.
--
-- Under average costing the product stores one rounded unit cost per item and
-- values stock as quantity times that. Every receipt re-averages and rounds
-- to a whole penny; the ledger meanwhile was debited with what each receipt
-- actually cost. Receive the same item at two prices and the valuation is a
-- few minor units from the inventory account, and erp.assert_inventory_
-- reconciles() says so. The demonstration was built buying each item at one
-- price to keep it green (20260905010000 says so in its header), which is
-- designing around a correctness defect in a ledger product.
--
-- The fix is not more decimal places. The ledger is a sum of integers, so the
-- valuation must be one too: erp.item_cost.value_minor is the exact value on
-- hand, moved by exactly what each movement posted. A receipt adds the extended
-- cost the journal is debited with. An issue takes its proportional share of
-- the value on hand, rounded once, and the last unit takes whatever remains,
-- so the value can never drift from the postings by construction. The average
-- unit cost is still shown; it is derived from the value, not the other way
-- round. One layer per item under average, many under FIFO: what §5.4 calls
-- "inventory value derived from cost layers".
--
-- For that to hold, the movement must carry the exact cost, not a rounded unit
-- cost the journal multiplies back up. erp.stock_movement.cost_minor is that
-- column. The ledger is append-only, so existing rows keep their unit cost and
-- are read as round(quantity × unit), which is what the ledger was told at the
-- time. New rows are stamped by a BEFORE INSERT trigger from the cost the
-- costing functions just computed for that item, site, quantity and unit
-- (they leave it in a transaction-local setting); a row whose cost nothing
-- computed is stamped round(quantity × unit), explicitly. Seven routines
-- insert costed movements and all seven now carry the exact figure without
-- one of them being restated.
--
-- Four defects in erp.inventory_reconciliation_report() go with it. Its
-- posted-journal filter sat on a LEFT JOIN nothing referenced, so draft lines
-- counted. Its valuation was the whole organisation's, compared against each
-- inventory account in turn, so two companies could never both reconcile. It
-- summed transaction amounts rather than base. And count variances and
-- write-offs moved stock with no journal at all — valuation fell, the account
-- did not. They post now, through a stock_adjustment posting rule the
-- inventory installer ships, to the inventory account and a stock adjustments
-- account, at the movement's exact cost, with the subledger detail row a
-- control account carries (the opening-balance reconciliation compares the
-- two). The new rule is the first the inventory installer adds of its own, and
-- one bootstrap-window case that counted every rule in the organisation
-- against the finance set is re-stated to count the rules the set named.
--
-- Two smaller things found on the way. erp.costing_method_for() compared a
-- policy's item_class with equality while the base pack ships comma-separated
-- lists, so its two costing policies have never matched an item. And the
-- reconciliation reports filtered on a tenant nobody was required to set,
-- which is how they passed over nothing (deferred finding 2); they require one.
--
-- The demonstration builder stops buying at one price.
--
-- And one thing found while writing the suite. Twenty-three suite wrappers
-- count failures as "count(*) filter (where not passed)", which counts a NULL
-- verdict as a pass: a case whose comparison touched a NULL was green without
-- anybody knowing. They are re-emitted counting "not coalesce(passed, false)",
-- and erp.assert_suite_verdicts_strict() refuses the permissive form so it
-- cannot be written again.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The exact value on hand, and the exact cost on the movement
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.item_cost add column if not exists value_minor bigint not null default 0;

comment on column erp.item_cost.value_minor is
  'The exact value on hand under average or standard costing, in minor units: '
  'the sum of what receipts posted less what issues took. The unit cost is '
  'derived from this; valuation reads this.';

-- Existing rows: the value the ledger was told, at this instant.
update erp.item_cost
   set value_minor = round(quantity_on_hand * unit_cost_minor)::bigint
 where method in ('average', 'standard') and value_minor = 0;

alter table erp.stock_movement add column if not exists cost_minor bigint;

comment on column erp.stock_movement.cost_minor is
  'The exact extended cost of this movement, in minor units — what the ledger '
  'posts. Null on rows written before 20260906050000, which are read as '
  'round(quantity × unit_cost_minor).';

-- The costing functions leave the cost they computed here; the movement insert
-- that follows picks it up. Transaction-local, like every other context.
create or replace function erp.note_cost(
  p_item_id uuid, p_site_id uuid, p_quantity numeric, p_unit_cost_minor bigint, p_cost_minor bigint)
returns void
language sql
volatile
set search_path = ''
as $$
  select set_config('erp.last_cost', jsonb_build_object(
    'item', p_item_id, 'site', p_site_id, 'quantity', p_quantity,
    'unit', p_unit_cost_minor, 'cost', p_cost_minor)::text, true)
$$;

create or replace function erp.stamp_movement_cost()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_last jsonb;
begin
  if new.cost_minor is not null then
    return new;
  end if;
  v_last := nullif(current_setting('erp.last_cost', true), '')::jsonb;
  if v_last is not null
     and (v_last ->> 'item')::uuid = new.item_id
     and (v_last ->> 'site')::uuid is not distinct from new.site_id
     and (v_last ->> 'quantity')::numeric = new.quantity
     and (v_last ->> 'unit')::bigint is not distinct from new.unit_cost_minor then
    new.cost_minor := (v_last ->> 'cost')::bigint;
    perform set_config('erp.last_cost', '', true);
  elsif new.unit_cost_minor is not null then
    -- Nothing computed this one; what the ledger will be told, made explicit.
    new.cost_minor := round(new.quantity * new.unit_cost_minor)::bigint;
  end if;
  return new;
end;
$$;

comment on function erp.stamp_movement_cost is
  'Stamps a new movement with the exact cost erp.receive_cost() or '
  'erp.issue_cost() just computed for the same item, site, quantity and unit '
  'cost; otherwise round(quantity × unit), explicitly.';

drop trigger if exists t_stock_movement_cost on erp.stock_movement;
create trigger t_stock_movement_cost
  before insert on erp.stock_movement
  for each row execute function erp.stamp_movement_cost();

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Receipts add exactly what they cost; issues take their exact share
-- ═════════════════════════════════════════════════════════════════════════════

-- Both bodies below restate the definitions the database carries as read on
-- 5 September (pg_get_functiondef), changed only where the value is tracked
-- and the cost noted. The check first.
do $check$
declare
  v_r text := (select prosrc from pg_catalog.pg_proc where oid = 'erp.receive_cost(uuid,uuid,numeric,bigint,character,uuid,bigint)'::regprocedure);
  v_i text := (select prosrc from pg_catalog.pg_proc where oid = 'erp.issue_cost(uuid,uuid,numeric)'::regprocedure);
begin
  if position('round((ic.unit_cost_minor * greatest(ic.quantity_on_hand, 0)' in v_r) = 0
     or position('return p_unit_cost_minor;' in v_r) = 0
     or position('return round(v_total / p_quantity)::bigint;' in v_i) = 0
     or position('CLOVEERP_NO_COST_LAYERS' in v_i) = 0 then
    raise exception 'CLOVEERP_COSTING_UNRECOGNISED: erp.receive_cost/erp.issue_cost are not the bodies this migration restates';
  end if;
end
$check$;

create or replace function erp.receive_cost(
  p_item_id uuid, p_site_id uuid, p_quantity numeric, p_unit_cost_minor bigint,
  p_currency character, p_batch_id uuid default null, p_movement_id bigint default null)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_method erp.costing_method := erp.costing_method_for(p_item_id, p_site_id);
  ic       erp.item_cost%rowtype;
  v_cost   bigint;
  v_qty    numeric;
begin
  if p_quantity <= 0 then
    raise exception 'CLOVEERP_COST_NONPOSITIVE: cannot receive % units', p_quantity
      using errcode = '23514';
  end if;

  -- What this receipt costs, and what the ledger is debited with.
  v_cost := round(p_quantity * p_unit_cost_minor)::bigint;

  if v_method = 'fifo' then
    insert into erp.stock_valuation_layer (
      tenant_id, item_id, site_id, batch_id, movement_id,
      quantity, remaining, unit_cost_minor, currency)
    values (v_tenant, p_item_id, p_site_id, p_batch_id, p_movement_id,
            p_quantity, p_quantity, p_unit_cost_minor, p_currency);
    perform erp.note_cost(p_item_id, p_site_id, p_quantity, p_unit_cost_minor, v_cost);
    return p_unit_cost_minor;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id
   for update;

  if not found then
    insert into erp.item_cost (
      tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand, value_minor)
    values (v_tenant, p_item_id, p_site_id, v_method,
            p_unit_cost_minor, p_currency, p_quantity, v_cost);
    perform erp.note_cost(p_item_id, p_site_id, p_quantity, p_unit_cost_minor, v_cost);
    return p_unit_cost_minor;
  end if;

  if v_method = 'standard' then
    -- The standard cost does not move. Inventory is debited at standard; the
    -- difference between what was paid and what was assumed is the variance,
    -- which is the entire point of standard costing.
    v_cost := round(p_quantity * ic.unit_cost_minor)::bigint;
    update erp.item_cost
       set quantity_on_hand = quantity_on_hand + p_quantity,
           value_minor = value_minor + v_cost,
           updated_at = now()
     where id = ic.id;
    perform erp.note_cost(p_item_id, p_site_id, p_quantity, ic.unit_cost_minor, v_cost);
    return ic.unit_cost_minor;
  end if;

  -- Average: the value on hand grows by exactly what was paid; the unit cost
  -- shown is derived from it. Rounding happens on the display figure, never on
  -- the value.
  v_qty := greatest(ic.quantity_on_hand, 0) + p_quantity;
  update erp.item_cost
     set value_minor = case when ic.quantity_on_hand < 0 then v_cost else value_minor + v_cost end,
         quantity_on_hand = quantity_on_hand + p_quantity,
         unit_cost_minor = case when v_qty = 0 then p_unit_cost_minor
                                else round((case when ic.quantity_on_hand < 0 then v_cost else value_minor + v_cost end) / v_qty)::bigint end,
         updated_at = now()
   where id = ic.id;

  perform erp.note_cost(p_item_id, p_site_id, p_quantity, p_unit_cost_minor, v_cost);
  return p_unit_cost_minor;
end;
$$;

comment on function erp.receive_cost is
  'Records a receipt into the costing store and returns the unit cost the '
  'movement carries. FIFO opens a layer; standard adds quantity × standard; '
  'average adds exactly what was paid to the value on hand. The exact extended '
  'cost is noted for the movement that follows.';

create or replace function erp.issue_cost(p_item_id uuid, p_site_id uuid, p_quantity numeric)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_method erp.costing_method := erp.costing_method_for(p_item_id, p_site_id);
  ic       erp.item_cost%rowtype;
  r        record;
  v_left   numeric := p_quantity;
  v_take   numeric;
  v_total  bigint := 0;
  v_unit   bigint;
begin
  if p_quantity <= 0 then
    raise exception 'CLOVEERP_COST_NONPOSITIVE: cannot issue % units', p_quantity
      using errcode = '23514';
  end if;

  if v_method = 'fifo' then
    for r in
      select * from erp.stock_valuation_layer l
       where l.tenant_id = v_tenant and l.item_id = p_item_id
         and l.site_id is not distinct from p_site_id
         and l.remaining > 0
       order by l.received_at, l.id
       for update
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.remaining);
      v_total := v_total + round(v_take * r.unit_cost_minor)::bigint;
      update erp.stock_valuation_layer set remaining = remaining - v_take,
             updated_at = now()
       where id = r.id;
      v_left := v_left - v_take;
    end loop;

    if v_left > 0 then
      -- More is being issued than was ever received at a known cost. Refusing
      -- is the honest answer: valuing the remainder at zero would silently
      -- understate cost of sales, and valuing it at the last layer would
      -- invent a receipt.
      raise exception
        'CLOVEERP_NO_COST_LAYERS: % of % units have no FIFO layer to consume',
        v_left, p_quantity
        using errcode = '23514',
        hint = 'Stock arrived without a valued receipt. Value it with an '
               'adjustment before issuing it.';
    end if;

    -- The exact layer sum is the cost; the unit figure is for the movement row.
    v_unit := round(v_total / p_quantity)::bigint;
    perform erp.note_cost(p_item_id, p_site_id, p_quantity, v_unit, v_total);
    return v_unit;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id
   for update;

  if not found then
    raise exception 'CLOVEERP_NO_COST: % has no cost at this site', p_item_id
      using errcode = '23514',
      hint = 'A standard cost is set; an average cost arrives with the first '
             'valued receipt. Neither has happened for this item.';
  end if;

  if v_method = 'standard' then
    v_total := round(p_quantity * ic.unit_cost_minor)::bigint;
  elsif ic.quantity_on_hand <= p_quantity then
    -- Emptying the position, or going past it: the whole value goes, and
    -- anything beyond what is held is valued at the unit cost shown.
    v_total := ic.value_minor
             + round(greatest(p_quantity - ic.quantity_on_hand, 0) * ic.unit_cost_minor)::bigint;
  else
    -- The proportional share of the value on hand, rounded once. What remains
    -- is exactly value less this, so the last unit out takes the remainder.
    v_total := round(ic.value_minor * p_quantity / ic.quantity_on_hand)::bigint;
  end if;

  update erp.item_cost
     set quantity_on_hand = quantity_on_hand - p_quantity,
         value_minor = value_minor - v_total,
         updated_at = now()
   where id = ic.id;

  v_unit := case when v_method = 'standard' then ic.unit_cost_minor
                 else round(v_total / p_quantity)::bigint end;
  perform erp.note_cost(p_item_id, p_site_id, p_quantity, v_unit, v_total);
  return v_unit;
end;
$$;

comment on function erp.issue_cost is
  'Costs an issue from the costing store and returns the unit cost the movement '
  'carries. FIFO consumes layers oldest first; standard takes quantity × '
  'standard; average takes the exact proportional share of the value on hand, '
  'the last unit taking the remainder. The exact cost is noted for the movement.';

-- What the finance bridge sums: the exact cost where a movement carries one,
-- what the ledger was told at the time where it does not.
create or replace function erp.document_stock_cost_minor(p_document_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor)))::bigint, 0)
    from erp.stock_movement m
   where m.tenant_id = erp.current_tenant_id()
     and m.document_id = p_document_id
     and not m.is_reversal
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Valuation reads the value; the reconciliation compares like with like
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.stock_valuation_report()
returns table(item_id uuid, item_code text, site_id uuid, site_code text,
              method erp.costing_method, quantity numeric, unit_cost_minor bigint,
              value_minor bigint, currency character)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  on_hand as (
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b join t on t.tenant_id = b.tenant_id
     group by b.item_id, b.site_id
    having sum(b.quantity) <> 0
  ),
  valued as (
    select h.item_id, h.site_id, h.qty,
           erp.costing_method_for(h.item_id, h.site_id) as method
      from on_hand h
  )
  select v.item_id, i.code, v.site_id, s.code, v.method, v.qty,
         case v.method
           when 'fifo' then
             coalesce((select round(sum(l.remaining * l.unit_cost_minor) / nullif(sum(l.remaining), 0))::bigint
                         from erp.stock_valuation_layer l, t
                        where l.tenant_id = t.tenant_id and l.item_id = v.item_id
                          and l.site_id is not distinct from v.site_id and l.remaining > 0), 0)
           else
             coalesce((select case when c.quantity_on_hand = 0 then c.unit_cost_minor
                                   else round(c.value_minor / c.quantity_on_hand)::bigint end
                         from erp.item_cost c, t
                        where c.tenant_id = t.tenant_id and c.item_id = v.item_id
                          and c.site_id is not distinct from v.site_id), 0)
         end,
         case v.method
           when 'fifo' then
             coalesce((select round(sum(l.remaining * l.unit_cost_minor))::bigint
                         from erp.stock_valuation_layer l, t
                        where l.tenant_id = t.tenant_id and l.item_id = v.item_id
                          and l.site_id is not distinct from v.site_id and l.remaining > 0), 0)
           else
             -- The exact value on hand. Not quantity times a rounded average.
             coalesce((select c.value_minor from erp.item_cost c, t
                        where c.tenant_id = t.tenant_id and c.item_id = v.item_id
                          and c.site_id is not distinct from v.site_id), 0)
         end,
         coalesce((select e.base_currency from erp.entity e
                    join erp.site ss on ss.entity_id = e.id where ss.id = v.site_id),
                  (select e.base_currency from erp.entity e, t where e.tenant_id = t.tenant_id order by e.code limit 1),
                  'GBP')
    from valued v
    join erp.item i on i.id = v.item_id
    left join erp.site s on s.id = v.site_id
$$;

comment on function erp.stock_valuation_report is
  'Stock on hand and its value per item and site: FIFO from open layers, '
  'average and standard from the exact value on hand. Requires an organisation.';

create or replace function erp.inventory_reconciliation_report()
returns table(account_code text, ledger_minor bigint, valuation_minor bigint, difference_minor bigint)
language sql
stable
set search_path = ''
as $$
  -- Spec 5.2: "valuation reporting reconcilable to the ledger". Reconcilable is
  -- a claim, so this is the query that settles it — per inventory control
  -- account, per company, in base currency, over posted journals only.
  with t as (select erp.require_tenant_id() as tenant_id),
  ledger as (
    select a.entity_id, a.code,
           coalesce(sum(l.base_debit_minor) - sum(l.base_credit_minor), 0)::bigint as ledger_minor
      from erp.account a
      join t on t.tenant_id = a.tenant_id
      left join erp.journal_line l
        on l.tenant_id = a.tenant_id and l.account_id = a.id
       and exists (select 1 from erp.journal j where j.id = l.journal_id and j.status = 'posted')
     where a.control_kind = 'inventory' and a.status = 'active'
     group by a.entity_id, a.code
  ),
  valuation as (
    select coalesce(s.entity_id,
                    (select e.id from erp.entity e, t where e.tenant_id = t.tenant_id order by e.code limit 1)) as entity_id,
           sum(v.value_minor)::bigint as valuation_minor
      from erp.stock_valuation_report() v
      left join erp.site s on s.id = v.site_id
     group by 1
  )
  select lg.code,
         lg.ledger_minor,
         coalesce(va.valuation_minor, 0),
         lg.ledger_minor - coalesce(va.valuation_minor, 0)
    from ledger lg
    left join valuation va on va.entity_id = lg.entity_id
   order by lg.code
$$;

comment on function erp.inventory_reconciliation_report is
  'Each inventory control account against the value of the stock its company '
  'holds, in base currency, over posted journals. A non-zero difference is the '
  'finding erp.assert_inventory_reconciles() refuses on.';

-- The stock reconciliation requires an organisation too (deferred finding 2);
-- where it already does, nothing changes.
do $stock$
declare
  v_def text;
  v_n   integer;
begin
  v_def := pg_get_functiondef('erp.stock_reconciliation_report()'::regprocedure);
  select count(*) into v_n from regexp_matches(v_def, 'erp\.current_tenant_id\(\)', 'g');
  if v_n > 0 then
    v_def := replace(v_def, 'erp.current_tenant_id()', 'erp.require_tenant_id()');
    execute v_def;
  elsif position('erp.require_tenant_id()' in v_def) = 0 then
    raise exception 'CLOVEERP_STOCK_RECONCILIATION_UNRECOGNISED: erp.stock_reconciliation_report() scopes by neither erp.current_tenant_id() nor erp.require_tenant_id()';
  end if;
end
$stock$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A policy's class list matches
-- ═════════════════════════════════════════════════════════════════════════════

do $class$
declare v_def text;
begin
  v_def := pg_get_functiondef('erp.costing_method_for(uuid,uuid)'::regprocedure);
  if position('and (c.item_class is null or c.item_class = v_class)' in v_def) = 0 then
    raise exception 'CLOVEERP_COSTING_POLICY_UNRECOGNISED: erp.costing_method_for() is not the body this migration patches';
  end if;
  v_def := replace(v_def,
    'and (c.item_class is null or c.item_class = v_class)',
    'and (c.item_class is null or v_class = any(string_to_array(replace(c.item_class, '' '', ''''), '','')))');
  execute v_def;
end
$class$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Adjustments reach the ledger
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.chart_account_purpose
  (purpose, name, account_type, control_kind, default_code, statutory_code, installer_creates, note, seq) values
  -- Under the statutory chart a count variance is a material usage variance;
  -- the product does not invent an account the chart does not have.
  ('stock_adjustment', 'Stock adjustments', 'expense', null, '5900', '6300', true,
   'Count variances and write-offs, at the movement''s exact cost. §8.1 has no separate '
   'account for them: they are usage variance, and post to 6300 under the statutory chart.', 125)
on conflict (purpose) do nothing;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('stock.adjusted', 1, 'stock_movement', 'inventory', 'event.stock.adjusted',
        'A count variance or write-off moved stock without a document; its cost reaches the ledger.',
        '{"type":"object","required":["movement_id","cost_minor","reason_code"],
          "properties":{"movement_id":{"type":"integer"},"cost_minor":{"type":"integer"},
                        "reason_code":{"type":"string"},"movement_type":{"type":"string"},
                        "quantity":{"type":"number"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.stock.adjusted', 'en', 'Stock adjusted without a document', 'inventory',
   'Event raised when a count variance or write-off posts to the ledger.')
on conflict (key, locale) do update set value = excluded.value;

create or replace function erp.post_movement_finance(p_movement_id bigint)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  m         erp.stock_movement%rowtype;
  pr        erp.posting_rule%rowtype;
  v_ledger  uuid;
  v_ccy     char(3);
  v_inv     uuid;
  v_inv_kind erp.account.control_kind%type;
  v_adj     uuid;
  v_event   uuid;
  v_journal uuid;
  v_cost    bigint;
  v_in      boolean;
begin
  select * into m from erp.stock_movement where tenant_id = v_tenant and id = p_movement_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_MOVEMENT: %', p_movement_id using errcode = '23503',
      hint = 'The movement to post does not exist in this organisation.';
  end if;

  v_cost := coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor)::bigint, 0);
  if v_cost = 0 then
    return null;
  end if;
  v_in := m.to_location_id is not null and m.from_location_id is null;

  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant and r.event_type = 'stock.adjusted' and r.status = 'active'
     and r.effective_from <= coalesce(m.occurred_at::date, current_date)
     and (r.effective_to is null or r.effective_to > coalesce(m.occurred_at::date, current_date))
   order by r.version desc limit 1;
  if not found then
    raise exception 'CLOVEERP_NO_POSTING_RULE_IN_FORCE: no stock_adjustment posting rule is in force for this organisation'
      using errcode = '23514',
            hint = 'The inventory installer ships the stock_adjustment rule from 20260906050000; an organisation configured before it promotes a change set carrying the rule.';
  end if;

  select l.id, l.currency into v_ledger, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = m.entity_id and l.is_primary and l.status = 'active';
  if v_ledger is null then
    raise exception 'CLOVEERP_NO_LEDGER: the company holding the stock has no primary ledger' using errcode = '23514',
      hint = 'Configure finance for the company before posting adjustments.';
  end if;

  select a.id, a.control_kind into v_inv, v_inv_kind from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = m.entity_id and a.status = 'active'
     and a.code = (select x ->> 'account' from jsonb_array_elements(pr.posting_lines) x where x ->> 'basis' = 'stock_cost' limit 1);
  select a.id into v_adj from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = m.entity_id and a.status = 'active'
     and a.code = (select x ->> 'account' from jsonb_array_elements(pr.posting_lines) x where coalesce((x ->> 'balancing')::boolean, false) limit 1);
  if v_inv is null or v_adj is null then
    raise exception 'CLOVEERP_ACCOUNT_NOT_ON_CHART: the stock_adjustment rule names an account the company does not have'
      using errcode = '23514',
            hint = 'Add the inventory and stock adjustments accounts to the company''s chart, or repoint the rule.';
  end if;

  v_event := erp.append_event('stock.adjusted', 'stock_movement', m.movement_uid,
    jsonb_build_object('movement_id', m.id, 'cost_minor', v_cost, 'reason_code', coalesce(m.reason_code, ''),
                       'movement_type', m.movement_type, 'quantity', m.quantity),
    m.entity_id, m.site_id);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, m.entity_id, v_ledger, 'stock.adjusted', v_event,
          coalesce(m.occurred_at::date, current_date),
          format('Stock %s: %s', m.movement_type, coalesce(m.reason_code, 'adjustment')), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                currency, base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values
    (v_tenant, v_journal, 1, v_inv,
     case when v_in then v_cost else 0 end, case when v_in then 0 else v_cost end, v_ccy,
     case when v_in then v_cost else 0 end, case when v_in then 0 else v_cost end, 1,
     pr.id, pr.version, v_event, 'Inventory adjusted, at cost'),
    (v_tenant, v_journal, 2, v_adj,
     case when v_in then 0 else v_cost end, case when v_in then v_cost else 0 end, v_ccy,
     case when v_in then 0 else v_cost end, case when v_in then v_cost else 0 end, 1,
     pr.id, pr.version, v_event, 'Stock adjustment');

  -- A control account carries its detail in a subledger and the two agree at
  -- all times; the opening-balance loader and the document bridge both write
  -- the row, so this posting does too, keyed by the item the way the loader
  -- keys it. erp.opening_balance_reconciliation() compares the two.
  if v_inv_kind is not null then
    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, m.entity_id, v_ledger, v_inv_kind, v_inv,
            m.item_id, v_journal, v_ccy,
            case when v_in then v_cost else 0 end, case when v_in then 0 else v_cost end,
            coalesce(m.occurred_at::date, current_date));
  end if;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id(),
         updated_at = now()
   where id = v_journal;
  return v_journal;
end;
$$;

comment on function erp.post_movement_finance is
  'Posts a count variance or write-off to the ledger at the movement''s exact '
  'cost: inventory against the stock adjustments account, through the '
  'stock_adjustment posting rule the inventory installer ships. Valuation and '
  'ledger move together.';

-- The installer ships the account and the rule; the two adjustment paths post.
do $installer$
declare
  v_def text;
  v_n   integer;
begin
  -- configure_inventory: the stock adjustments account beside the variance
  -- account, and the posting rule after the delivery rule.
  v_def := pg_get_functiondef('erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  if (select count(*) from regexp_matches(v_def, E'on conflict \\(tenant_id, entity_id, code\\) do update set status = ''active'';\n  end if;', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, E'''description'',''Inventory despatched, at cost''\\)\\)\\)\\)\\)\\);', 'g')) <> 1 then
    raise exception 'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: erp.configure_inventory() is not the body this migration patches';
  end if;
  v_def := replace(v_def,
    E'on conflict (tenant_id, entity_id, code) do update set status = ''active'';\n  end if;',
    E'on conflict (tenant_id, entity_id, code) do update set status = ''active'';\n'
 || E'    insert into erp.account (\n'
 || E'      tenant_id, entity_id, code, name, account_type, is_postable, currency, status)\n'
 || E'    select v_tenant, e.id, ''5900'', ''Stock adjustments'', ''expense'', true,\n'
 || E'           e.base_currency, ''active''\n'
 || E'      from erp.entity e where e.tenant_id = v_tenant and e.status = ''active''\n'
 || E'    on conflict (tenant_id, entity_id, code) do update set status = ''active'';\n'
 || E'  end if;');
  v_def := replace(v_def,
    E'''description'',''Inventory despatched, at cost''))))));',
    E'''description'',''Inventory despatched, at cost'')))),\n\n'
 || E'      jsonb_build_object(''kind'',''posting_rule'',''key'',''stock_adjustment'',''payload'',\n'
 || E'        jsonb_build_object(\n'
 || E'          ''code'',''stock_adjustment'',''name'',''Stock adjustment'',''ledger'',''GL'',\n'
 || E'          ''event_type'',''stock.adjusted'',\n'
 || E'          ''posting_lines'', jsonb_build_array(\n'
 || E'            jsonb_build_object(''account'', erp.chart_account_code(''inventory''),''side'',''debit'',''basis'',''stock_cost'',''rate'',1,\n'
 || E'                               ''description'',''Inventory adjusted, at cost''),\n'
 || E'            jsonb_build_object(''account'', erp.chart_account_code(''stock_adjustment''),''side'',''credit'',''balancing'',true,\n'
 || E'                               ''description'',''Stock adjustment''))))));');
  execute v_def;

  -- post_count: both movement inserts return their id and post.
  v_def := pg_get_functiondef('erp.post_count(uuid)'::regprocedure);
  select count(*) into v_n from regexp_matches(v_def, E'''count_variance''\n      from erp.site s where s.id = t.site_id;', 'g');
  if v_n <> 2 or position(E'v_uom    uuid;\nbegin' in v_def) = 0 then
    raise exception 'CLOVEERP_COUNT_POSTING_UNRECOGNISED: erp.post_count() is not the body this migration patches (% insert tails)', v_n;
  end if;
  v_def := replace(v_def, E'v_uom    uuid;\nbegin', E'v_uom    uuid;\n  v_move   bigint;\nbegin');
  v_def := replace(v_def,
    E'''count_variance''\n      from erp.site s where s.id = t.site_id;',
    E'''count_variance''\n      from erp.site s where s.id = t.site_id\n    returning id into v_move;\n    perform erp.post_movement_finance(v_move);');
  execute v_def;

  -- write_off_stock: the movement posts before its id is returned.
  v_def := pg_get_functiondef('erp.write_off_stock(uuid,uuid,uuid,numeric,text,uuid)'::regprocedure);
  if position(E'returning id into v_id;\n\n  return v_id;' in v_def) = 0 then
    raise exception 'CLOVEERP_WRITE_OFF_UNRECOGNISED: erp.write_off_stock() is not the body this migration patches';
  end if;
  v_def := replace(v_def, E'returning id into v_id;\n\n  return v_id;',
                          E'returning id into v_id;\n\n  perform erp.post_movement_finance(v_id);\n\n  return v_id;');
  execute v_def;
end
$installer$;

-- ═════════════════════════════════════════════════════════════════════════════
-- One case in erp_test.bootstrap_window_suite() compared the count of every
-- active posting rule in the organisation with the count of rules the finance
-- change set named. It held only because the inventory installer re-declares
-- two of finance's rules and adds none of its own; the stock_adjustment rule
-- is the first it adds, and the case fails for the right reason. The case's
-- own words are "every posting rule the set named has to be in
-- erp.posting_rule", so it now counts the rules the set named. Deployed body,
-- asserted needle.
do $bootstrap$
declare
  v_def text := pg_get_functiondef('erp_test.bootstrap_window_suite()'::regprocedure);
  v_old text := E'    (select count(*) from erp.posting_rule pr\n'
             || E'      where pr.tenant_id = v_tenant and pr.status = ''active'')\n'
             || E'      = (select count(*) from erp.change_set_item i\n'
             || E'          where i.change_set_id = v_cs and i.object_kind = ''posting_rule''),';
  v_new text := E'    (select count(*) from erp.posting_rule pr\n'
             || E'      where pr.tenant_id = v_tenant and pr.status = ''active''\n'
             || E'        and pr.code in (select i.object_key from erp.change_set_item i\n'
             || E'                         where i.change_set_id = v_cs and i.object_kind = ''posting_rule''))\n'
             || E'      = (select count(*) from erp.change_set_item i\n'
             || E'          where i.change_set_id = v_cs and i.object_kind = ''posting_rule''),';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp_test.bootstrap_window_suite no longer carries the posting-rule count this migration re-states';
  end if;
  execute replace(v_def, v_old, v_new);
end
$bootstrap$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The demonstration buys at the prices a supplier actually charges
-- ═════════════════════════════════════════════════════════════════════════════

do $demo$
declare v_def text;
begin
  v_def := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  -- Two sites read the demo cost: the purchase order line (patched, the one that
  -- reaches the ledger) and the requisition (left alone, it moves nothing). The
  -- purchase line is the one on its own line with thirteen spaces of indent.
  if (select count(*) from regexp_matches(v_def, E'\n             \\(i\\.attributes -> ''demo'' ->> ''cost_minor''\\)::bigint as cost,', 'g')) <> 1 then
    raise exception 'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: erp.seed_demo_history() is not the body this migration patches';
  end if;
  v_def := replace(v_def,
    E'\n             (i.attributes -> ''demo'' ->> ''cost_minor'')::bigint as cost,',
    E'\n             round((i.attributes -> ''demo'' ->> ''cost_minor'')::numeric * (0.92 + random()::numeric * 0.16))::bigint as cost,');
  execute v_def;
end
$demo$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.costing_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3);
  v_supplier uuid; v_recv uuid; v_bulk uuid;
  v_avg uuid; v_fifo uuid; v_std uuid;
  v_grn uuid;
  v_msg text; v_job text;
  v_n integer; v_diff bigint; v_val bigint; v_ledger bigint;
  v_cost bigint;
begin
  begin
  -- Fixture: an organisation with the demonstration configuration (average
  -- costing by default, the stock_adjustment rule from the patched installer)
  -- and three items: one average, one FIFO, one standard.
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-costing', 'Costing suite', 'admin@zz-costing.test', 'Costing Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000c3', 'admin@zz-costing.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000c3')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency into v_entity, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
  select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
  select l.id into v_bulk from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'bulk' limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-AVG', 'Average-costed item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_avg;
  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-FIFO', 'FIFO-costed item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_fifo;
  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-STD', 'Standard-costed item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_std;
  insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
  values (v_tenant, 'zz_fifo', 'FIFO for one item', 'fifo', v_fifo, 'active'),
         (v_tenant, 'zz_std', 'Standard for one item', 'standard', v_std, 'active');
  insert into erp.item_cost (tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand, value_minor)
  values (v_tenant, v_std, v_site, 'standard', 1200, v_ccy, 0, 0);

  -- 1. Three prices, one average-costed item: valuation equals the account exactly.
  v_cases := v_cases + 1;
  v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-AVG', '{}'::jsonb);
  perform erp.add_document_line(v_grn, v_avg, 10, 1000, 'at 10.00', current_date);
  perform erp.add_document_line(v_grn, v_avg, 10, 1100, 'at 11.00', current_date);
  perform erp.add_document_line(v_grn, v_avg, 10, 1250, 'at 12.50', current_date);
  perform erp.transition_document(v_grn, 'post', 'costing suite');
  set constraints all immediate;
  select c.value_minor into v_val from erp.item_cost c where c.tenant_id = v_tenant and c.item_id = v_avg;
  select sum(r.difference_minor), count(*) filter (where r.difference_minor <> 0) into v_diff, v_n from erp.inventory_reconciliation_report() r;
  case_name := 'three receipt prices under average costing value to the penny of the ledger';
  passed := v_val = 33500 and v_n = 0;
  detail := format('value on hand %s (expected 33500); %s account(s) out of balance', v_val, v_n);
  return next;

  -- 2. A partial issue takes its exact share, and the write-off posts.
  v_cases := v_cases + 1;
  perform erp.write_off_stock(v_avg, v_site, v_recv, 7, 'costing suite write-off');
  set constraints all immediate;
  select c.value_minor into v_val from erp.item_cost c where c.tenant_id = v_tenant and c.item_id = v_avg;
  select m.cost_minor into v_cost from erp.stock_movement m where m.tenant_id = v_tenant and m.item_id = v_avg and m.movement_type = 'scrap' order by m.id desc limit 1;
  select count(*) filter (where r.difference_minor <> 0) into v_n from erp.inventory_reconciliation_report() r;
  case_name := 'a partial issue takes its proportional share and the write-off reaches the ledger';
  passed := v_cost = 7817 and v_val = 33500 - 7817 and v_n = 0
        and exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted' and j.status = 'posted');
  detail := format('write-off cost %s (expected 7817), value left %s, %s account(s) out of balance', v_cost, v_val, v_n);
  return next;

  -- 3. FIFO: layers consumed oldest first, to the penny.
  v_cases := v_cases + 1;
  v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-FIFO', '{}'::jsonb);
  perform erp.add_document_line(v_grn, v_fifo, 10, 1000, 'layer 1', current_date);
  perform erp.add_document_line(v_grn, v_fifo, 10, 1100, 'layer 2', current_date);
  perform erp.add_document_line(v_grn, v_fifo, 10, 1250, 'layer 3', current_date);
  perform erp.transition_document(v_grn, 'post', 'costing suite');
  perform erp.write_off_stock(v_fifo, v_site, v_recv, 15, 'costing suite fifo');
  set constraints all immediate;
  select m.cost_minor into v_cost from erp.stock_movement m where m.tenant_id = v_tenant and m.item_id = v_fifo and m.movement_type = 'scrap' order by m.id desc limit 1;
  select sum(v.value_minor) into v_val from erp.stock_valuation_report() v where v.item_id = v_fifo;
  select count(*) filter (where r.difference_minor <> 0) into v_n from erp.inventory_reconciliation_report() r;
  case_name := 'FIFO issues consume layers oldest first and reconcile to the penny';
  passed := v_cost = 15500 and v_val = 18000 and v_n = 0;
  detail := format('issue cost %s (expected 15500), remaining value %s (expected 18000), %s out of balance', v_cost, v_val, v_n);
  return next;

  -- 4. Standard: inventory at standard, variance to the variance account.
  v_cases := v_cases + 1;
  v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-STD', '{}'::jsonb);
  perform erp.add_document_line(v_grn, v_std, 10, 1000, 'below standard', current_date);
  perform erp.transition_document(v_grn, 'post', 'costing suite');
  set constraints all immediate;
  select sum(v.value_minor) into v_val from erp.stock_valuation_report() v where v.item_id = v_std;
  select count(*) filter (where r.difference_minor <> 0) into v_n from erp.inventory_reconciliation_report() r;
  case_name := 'standard costing values at standard and reconciles, the difference going to variance';
  passed := v_val = 12000 and v_n = 0
        and exists (select 1 from erp.journal_line l join erp.journal j on j.id = l.journal_id
                     join erp.account a on a.id = l.account_id
                    where j.tenant_id = v_tenant and j.document_id = v_grn and a.code = erp.chart_account_code('purchase_price_variance')
                      and (l.credit_minor = 2000 or l.debit_minor = -2000));
  detail := format('value %s (expected 12000), %s out of balance', v_val, v_n);
  return next;

  -- 5. Every movement written since carries its exact cost.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.stock_movement m where m.tenant_id = v_tenant and m.unit_cost_minor is not null and m.cost_minor is null;
  case_name := 'every costed movement carries its exact extended cost';
  passed := v_n = 0;
  detail := format('%s movement(s) without cost_minor', v_n);
  return next;

  -- 6. A policy's comma-separated class list matches.
  v_cases := v_cases + 1;
  insert into erp.costing_policy (tenant_id, code, name, method, item_class, status)
  values (v_tenant, 'zz_classes', 'FIFO for a class list', 'fifo', 'PACK, CONS,SPARE', 'active');
  update erp.item set item_class = 'CONS' where id = v_avg;
  case_name := 'a costing policy with a comma-separated class list matches an item in one of its classes';
  passed := erp.costing_method_for(v_avg, v_site) = 'fifo';
  detail := format('method for a CONS item under the list policy: %s', erp.costing_method_for(v_avg, v_site));
  update erp.item set item_class = 'RAW' where id = v_avg;
  delete from erp.costing_policy where tenant_id = v_tenant and code = 'zz_classes';
  return next;

  -- 7. The demonstration builder buys at varied prices and still reconciles.
  v_cases := v_cases + 1;
  perform erp.seed_demo_history((date_trunc('month', current_date) - interval '13 months')::date, null, 1);
  perform erp.seed_demo_history((date_trunc('month', current_date) - interval '13 months')::date + 5, null, 1);
  set constraints all immediate;
  -- Purchase lines priced away from the catalogue cost: the builder no longer
  -- buys at one price.
  select count(*) filter (where dl.unit_price_minor <> (i.attributes -> 'demo' ->> 'cost_minor')::bigint), count(*)
    into v_n, v_cost
    from erp.document_line dl
    join erp.document d on d.id = dl.document_id
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.item i on i.id = dl.item_id
   where d.tenant_id = v_tenant and dt.code = 'purchase_order';
  select count(*) filter (where r.difference_minor <> 0) into v_diff from erp.inventory_reconciliation_report() r;
  case_name := 'the demonstration buys at varied prices and reconciles to the penny';
  passed := v_n > 0 and v_cost > 0 and v_diff = 0;
  detail := format('%s of %s purchase lines priced away from the catalogue cost; %s account(s) out of balance', v_n, v_cost, v_diff);
  return next;

  -- 8. The reconciliation refuses without an organisation. Both contexts are
  -- cleared: the person's claims and the job context that provision_tenant
  -- leaves behind for the transaction; both are restored afterwards.
  v_cases := v_cases + 1;
  v_msg := null;
  v_job := current_setting('erp.job_tenant_id', true);
  begin
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform erp.assert_inventory_reconciles();
  exception when others then
    v_msg := sqlerrm;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000c3')::text, true);
  perform set_config('erp.job_tenant_id', coalesce(v_job, ''), true);
  case_name := 'the inventory reconciliation refuses to answer for no organisation';
  passed := coalesce(v_msg like 'CLOVEERP_NO_TENANT_CONTEXT:%', false);
  detail := left(coalesce(v_msg, 'passed over nothing'), 200);
  return next;

  -- 9. A value nudged by one penny is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    update erp.item_cost set value_minor = value_minor + 1 where tenant_id = v_tenant and item_id = v_avg;
    begin
      perform erp.assert_inventory_reconciles();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a valuation one penny from the ledger is refused';
  passed := v_msg like '%INVENTORY_DOES_NOT_RECONCILE%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 10. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-costing')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000c3');
  detail := 'zz-costing rolled back with everything it owned';
  return next;

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: costing_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_costing_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _costing on commit drop as
    select * from erp_test.costing_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _costing;
  drop table _costing;
  if v_fail > 0 then
    raise exception E'CLOVEERP_COSTING_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: costing_suite ran % cases, expected 10', v_all;
  end if;
  return format('costing: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. A verdict nobody reached is not a pass
-- ═════════════════════════════════════════════════════════════════════════════
-- Fifty-one wrappers compare the count of passed cases with the total, which
-- a NULL verdict fails. Twenty-three count "not passed", which a NULL verdict
-- slips through. Each of the twenty-three is re-emitted from its own catalogue
-- text with the one expression changed; the count is asserted so a wrapper
-- this file did not expect cannot be rewritten in passing.

do $wrappers$
declare
  r record;
  v_def text;
  v_n integer := 0;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp_test'
       and p.proname like 'assert_%suite%'
       and p.prokind = 'f'
       and pg_get_functiondef(p.oid) ~ 'count\(\*\) filter \(where not (?:[a-z]+\.)?passed\)'
     order by p.proname
  loop
    v_def := regexp_replace(r.def,
      'filter \(where not ((?:[a-z]+\.)?passed)\)',
      'filter (where not coalesce(\1, false))', 'g');
    if v_def = r.def then
      raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp_test.% matched but nothing was replaced', r.proname;
    end if;
    execute v_def;
    v_n := v_n + 1;
  end loop;
  if v_n <> 23 then
    raise exception 'CLOVEERP_UNEXPECTED_WRAPPER_COUNT: % wrapper(s) counted a null verdict as a pass, expected 23', v_n;
  end if;
  raise notice 'null verdicts now fail in % wrapper(s)', v_n;
end
$wrappers$;

create or replace function erp.assert_suite_verdicts_strict()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bad text;
  v_n   integer;
begin
  select count(*), string_agg('erp_test.' || p.proname, ', ' order by p.proname)
    into v_n, v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp_test'
     and p.proname like 'assert_%suite%'
     and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'count\(\*\) filter \(where not (?:[a-z]+\.)?passed\)';
  if v_n > 0 then
    raise exception 'CLOVEERP_NULL_VERDICT_PASSES: % suite wrapper(s) count "not passed", which lets a NULL verdict through: %. Count "not coalesce(passed, false)" or compare the passed count with the total.', v_n, v_bad
      using errcode = 'P0001';
  end if;
  return format('suite verdicts: %s wrapper(s), none counting a null verdict as a pass',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp_test' and p.proname like 'assert_%suite%' and p.prokind = 'f'));
end;
$$;
revoke all on function erp.assert_suite_verdicts_strict() from public, anon, authenticated;
comment on function erp.assert_suite_verdicts_strict() is
  'No erp_test suite wrapper counts failures with a bare "not passed": a NULL verdict must fail, not pass.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('suite_verdicts_strict', 'A null verdict fails its suite', 'assertion', 'platform',
   'assert_suite_verdicts_strict', '', null, '',
   'Every suite wrapper either compares passed cases with the total or counts failures null-safely; a case that reached no verdict cannot be green.', true, 92)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb, seq = excluded.seq;

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

select erp_test.assert_costing_suite();
select erp_test.assert_inventory_suite();
select erp_test.assert_demo_history_suite();
select erp_test.assert_demo_chart_suite();
-- The two suites whose cases this file re-states or reaches into.
select erp_test.assert_bootstrap_window_suite();
select erp_test.assert_migration_cutover_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
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
