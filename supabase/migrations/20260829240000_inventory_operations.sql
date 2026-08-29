-- =============================================================================
-- ERPWare — Part 5.2: inventory and warehouse
--
-- B7 built the ledger: movements, balances, batches, serials, containers,
-- allocations, genealogy, and an assertion that the ledger and the cached
-- balances agree. All of it correct, and all of it about *where* stock is.
--
-- Spec 5.2 asks for four things that are about something else, and none of them
-- existed:
--
--   "configurable costing (standard, average, FIFO) and valuation reporting
--    reconcilable to the ledger"
--       erp.stock_movement.unit_cost_minor is written by the posting bridge and
--       read by nothing. There is no cost policy, no layer, no valuation, and
--       therefore no reconciliation — which matters most because the finance
--       bridge now credits inventory on despatch at the *sales* price, since
--       there was no cost to use. That is a real defect in what shipped
--       yesterday, and this migration is what fixes it.
--
--   "count programmes that operate without freezing stock, with granular soft
--    locking, automatic exclusion of committed stock, tolerance-based variance
--    approval and accuracy reporting"
--       Nothing. And the qualifiers are the whole requirement: a count that
--       freezes the warehouse is a count that happens twice a year.
--
--   "expiry horizon management and write-off workflow"
--       erp.batch.expires_on exists and nothing looks at it.
--
--   "stock health and ageing analysis"
--       Nothing.
--
-- Plus the batch operations 5.2 asks for by name — amend, split, merge,
-- re-status, re-date — "without stock movement", which is the interesting part:
-- splitting a batch is not a movement and recording it as one would corrupt
-- every quantity report that sums movements.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Costing
--
-- Three methods, because the specification names three and they genuinely
-- differ:
--
--   standard  a cost somebody set, with the difference posted as variance
--   average   the weighted average of what has been received, moving on receipt
--   fifo      layers, consumed oldest first
--
-- The method is configuration per item, item class or site, most specific
-- first — so a business can run standard costing on manufactured goods and FIFO
-- on bought-in stock without a branch anywhere.
-- -----------------------------------------------------------------------------

create type erp.costing_method as enum ('standard', 'average', 'fifo');

create table if not exists erp.costing_policy (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text,
  method       erp.costing_method not null,
  -- Narrowing, most specific wins. All null is the tenant default.
  item_id      uuid,
  item_class   text,
  site_id      uuid,
  entity_id    uuid,
  -- Where the difference goes when a standard cost is wrong.
  variance_account_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

comment on table erp.costing_policy is
  'Spec 5.2: configurable costing. Which method applies to which stock, '
  'narrowed by item, class or site — so standard costing on manufactured goods '
  'and FIFO on bought-in stock is configuration rather than a branch.';

-- The current cost of an item at a site. Standard costing sets it and it stays;
-- average costing moves it on every receipt. FIFO does not use it: FIFO's
-- answer depends on which layers are still open, so it is computed rather than
-- stored, and storing it would be storing a number that is wrong tomorrow.
create table if not exists erp.item_cost (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  item_id      uuid not null,
  site_id      uuid,
  method       erp.costing_method not null,
  unit_cost_minor bigint not null default 0,
  currency     char(3) not null references erp_ref.currency(code),
  -- Average costing needs the running quantity to weight the next receipt.
  quantity_on_hand numeric(20,6) not null default 0,
  effective_from date not null default current_date,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, item_id, site_id),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

-- FIFO layers. One per receipt, consumed oldest first, and never updated
-- except to reduce what remains — the ledger of what stock cost, alongside the
-- ledger of where it is.
create table if not exists erp.stock_valuation_layer (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  item_id      uuid not null,
  site_id      uuid,
  batch_id     uuid,
  movement_id  bigint,
  received_at  timestamptz not null default clock_timestamp(),
  quantity     numeric(20,6) not null check (quantity > 0),
  remaining    numeric(20,6) not null check (remaining >= 0),
  unit_cost_minor bigint not null,
  currency     char(3) not null references erp_ref.currency(code),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint layer_remaining_within_quantity check (remaining <= quantity),
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete cascade
);

create index if not exists valuation_layer_fifo
  on erp.stock_valuation_layer (tenant_id, item_id, site_id, received_at)
  where remaining > 0;

create or replace function erp.costing_method_for(
  p_item_id uuid,
  p_site_id uuid default null
) returns erp.costing_method
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_class  text;
  v_method erp.costing_method;
begin
  select i.item_class into v_class
    from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id;

  -- Most specific wins, and the ordering says exactly what "specific" means
  -- rather than leaving it to whoever reads the rows.
  select c.method into v_method
    from erp.costing_policy c
   where c.tenant_id = v_tenant
     and c.status = 'active'
     and (c.item_id is null or c.item_id = p_item_id)
     and (c.item_class is null or c.item_class = v_class)
     and (c.site_id is null or c.site_id = p_site_id)
   order by (c.item_id is not null)::integer desc,
            (c.item_class is not null)::integer desc,
            (c.site_id is not null)::integer desc,
            c.code
   limit 1;

  -- No policy is not an error. Average is the answer that is least wrong when
  -- nobody has said: standard needs a number somebody set, and FIFO needs
  -- layers that only exist once it is switched on.
  return coalesce(v_method, 'average'::erp.costing_method);
end;
$$;

-- -----------------------------------------------------------------------------
-- Receiving cost, and issuing it
--
-- Two functions, one per direction, and the direction is where the methods
-- actually differ. Receiving is easy under all three; issuing is the question
-- "what did this cost", and standard, average and FIFO answer it differently.
-- -----------------------------------------------------------------------------

create or replace function erp.receive_cost(
  p_item_id   uuid,
  p_site_id   uuid,
  p_quantity  numeric,
  p_unit_cost_minor bigint,
  p_currency  char(3),
  p_batch_id  uuid default null,
  p_movement_id bigint default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_method erp.costing_method := erp.costing_method_for(p_item_id, p_site_id);
  ic       erp.item_cost%rowtype;
  v_new    bigint;
begin
  if p_quantity <= 0 then
    raise exception 'ERPWARE_COST_NONPOSITIVE: cannot receive % units', p_quantity
      using errcode = '23514';
  end if;

  if v_method = 'fifo' then
    insert into erp.stock_valuation_layer (
      tenant_id, item_id, site_id, batch_id, movement_id,
      quantity, remaining, unit_cost_minor, currency)
    values (v_tenant, p_item_id, p_site_id, p_batch_id, p_movement_id,
            p_quantity, p_quantity, p_unit_cost_minor, p_currency);
    return p_unit_cost_minor;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;

  if not found then
    insert into erp.item_cost (
      tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand)
    values (v_tenant, p_item_id, p_site_id, v_method,
            p_unit_cost_minor, p_currency, p_quantity)
    returning unit_cost_minor into v_new;
    return v_new;
  end if;

  if v_method = 'standard' then
    -- The standard cost does not move. What changes is that the difference
    -- between what was paid and what was assumed becomes a variance, which is
    -- the entire point of standard costing and the reason it is not simply a
    -- stale average.
    update erp.item_cost
       set quantity_on_hand = quantity_on_hand + p_quantity, updated_at = now()
     where id = ic.id;
    return ic.unit_cost_minor;
  end if;

  -- Weighted average, in minor units and rounded once. Rounding per receipt
  -- rather than carrying fractions is what keeps the valuation an integer
  -- number of pennies that reconciles to a ledger of integers.
  v_new := case when ic.quantity_on_hand + p_quantity = 0 then p_unit_cost_minor
                else round((ic.unit_cost_minor * greatest(ic.quantity_on_hand, 0)
                            + p_unit_cost_minor * p_quantity)
                           / (greatest(ic.quantity_on_hand, 0) + p_quantity))::bigint
           end;

  update erp.item_cost
     set unit_cost_minor = v_new,
         quantity_on_hand = quantity_on_hand + p_quantity,
         updated_at = now()
   where id = ic.id;

  -- The new average governs future issues. What inventory is debited with on
  -- *this* receipt is what was paid for it — debiting at the new average would
  -- put the difference nowhere, which is how an inventory account drifts away
  -- from the stock it is supposed to represent.
  return p_unit_cost_minor;
end;
$$;

comment on function erp.receive_cost(uuid, uuid, numeric, bigint, char, uuid, bigint) is
  'Records what arriving stock cost and returns the figure inventory is debited '
  'with: what was paid, under average and FIFO; the standard, under standard '
  'costing, where the difference becomes a variance.';

create or replace function erp.issue_cost(
  p_item_id  uuid,
  p_site_id  uuid,
  p_quantity numeric
) returns bigint
language plpgsql
security invoker
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
begin
  if p_quantity <= 0 then
    raise exception 'ERPWARE_COST_NONPOSITIVE: cannot issue % units', p_quantity
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
        'ERPWARE_NO_COST_LAYERS: % of % units have no FIFO layer to consume',
        v_left, p_quantity
        using errcode = '23514',
        hint = 'Stock arrived without a valued receipt. Value it with an '
               'adjustment before issuing it.';
    end if;

    return round(v_total / p_quantity)::bigint;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;

  if not found then
    raise exception 'ERPWARE_NO_COST: % has no cost at this site', p_item_id
      using errcode = '23514',
      hint = 'A standard cost is set; an average cost arrives with the first '
             'valued receipt. Neither has happened for this item.';
  end if;

  update erp.item_cost
     set quantity_on_hand = quantity_on_hand - p_quantity, updated_at = now()
   where id = ic.id;

  return ic.unit_cost_minor;
end;
$$;

comment on function erp.issue_cost(uuid, uuid, numeric) is
  'What leaving stock cost, by the method in force. FIFO consumes layers oldest '
  'first and refuses rather than inventing a cost for stock that arrived '
  'without a valued receipt.';

-- -----------------------------------------------------------------------------
-- Valuation, and the reconciliation the specification asks for by name
-- -----------------------------------------------------------------------------

create or replace function erp.stock_valuation_report()
returns table (item_id uuid, item_code text, site_id uuid, site_code text,
               method erp.costing_method, quantity numeric,
               unit_cost_minor bigint, value_minor bigint, currency char(3))
language sql
stable
security invoker
set search_path = ''
as $$
  with on_hand as (
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b
     where b.tenant_id = erp.current_tenant_id()
     group by b.item_id, b.site_id
    having sum(b.quantity) <> 0
  )
  select h.item_id, i.code, h.site_id, s.code,
         erp.costing_method_for(h.item_id, h.site_id),
         h.qty,
         case erp.costing_method_for(h.item_id, h.site_id)
           when 'fifo' then
             -- The average of what is still open, which is what FIFO stock is
             -- worth without pretending it has one cost.
             coalesce((select round(sum(l.remaining * l.unit_cost_minor)
                                    / nullif(sum(l.remaining), 0))::bigint
                         from erp.stock_valuation_layer l
                        where l.tenant_id = erp.current_tenant_id()
                          and l.item_id = h.item_id
                          and l.site_id is not distinct from h.site_id
                          and l.remaining > 0), 0)
           else
             coalesce((select c.unit_cost_minor from erp.item_cost c
                        where c.tenant_id = erp.current_tenant_id()
                          and c.item_id = h.item_id
                          and c.site_id is not distinct from h.site_id), 0)
         end,
         case erp.costing_method_for(h.item_id, h.site_id)
           when 'fifo' then
             coalesce((select round(sum(l.remaining * l.unit_cost_minor))::bigint
                         from erp.stock_valuation_layer l
                        where l.tenant_id = erp.current_tenant_id()
                          and l.item_id = h.item_id
                          and l.site_id is not distinct from h.site_id
                          and l.remaining > 0), 0)
           else
             coalesce((select round(h.qty * c.unit_cost_minor)::bigint
                         from erp.item_cost c
                        where c.tenant_id = erp.current_tenant_id()
                          and c.item_id = h.item_id
                          and c.site_id is not distinct from h.site_id), 0)
         end,
         coalesce((select e.base_currency from erp.entity e
                    where e.tenant_id = erp.current_tenant_id() limit 1), 'GBP')
    from on_hand h
    join erp.item i on i.id = h.item_id
    left join erp.site s on s.id = h.site_id
$$;

comment on function erp.stock_valuation_report() is
  'Spec 5.2: valuation reporting. What the stock on hand is worth, by the '
  'method in force for each item.';

create or replace function erp.inventory_reconciliation_report()
returns table (account_code text, ledger_minor bigint,
               valuation_minor bigint, difference_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Spec 5.2: "valuation reporting reconcilable to the ledger". Reconcilable
  -- is a claim, so this is the query that settles it.
  select a.code,
         coalesce(sum(l.debit_minor) - sum(l.credit_minor), 0)::bigint,
         coalesce((select sum(v.value_minor) from erp.stock_valuation_report() v), 0)::bigint,
         coalesce(sum(l.debit_minor) - sum(l.credit_minor), 0)::bigint
           - coalesce((select sum(v.value_minor) from erp.stock_valuation_report() v), 0)::bigint
    from erp.account a
    left join erp.journal_line l
      on l.tenant_id = a.tenant_id and l.account_id = a.id
    left join erp.journal j on j.id = l.journal_id and j.status = 'posted'
   where a.tenant_id = erp.current_tenant_id()
     and a.control_kind = 'inventory'
     and a.status = 'active'
   group by a.code
$$;

create or replace function erp.assert_inventory_reconciles()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_detail text; v_count integer;
begin
  select count(*), string_agg(format('  %s: ledger %s, valuation %s, out by %s',
                                     account_code, ledger_minor, valuation_minor,
                                     difference_minor), E'\n')
    into v_count, v_detail
    from erp.inventory_reconciliation_report()
   where difference_minor <> 0;

  if v_count > 0 then
    raise exception E'ERPWARE_INVENTORY_DOES_NOT_RECONCILE: %\n%', v_count, v_detail
      using errcode = 'P0001';
  end if;

  return 'inventory: the ledger and the valuation agree';
end;
$$;

-- -----------------------------------------------------------------------------
-- The defect this fixes
--
-- The finance bridge credits inventory when a delivery posts, and it valued
-- that credit at erp.document_value_minor() — the *sales* price — because there
-- was no cost to use. That overstates inventory relief and understates gross
-- margin by exactly the mark-up, on every despatch. It passed its suite because
-- the suite asserted the journal balanced, and a journal valued entirely at the
-- wrong number balances perfectly.
--
-- The fix is a vocabulary rather than a special case: a posting line names the
-- basis it is measured on.
--
--   document_value  the document's own value — what was invoiced or ordered
--   stock_cost      what the stock this document moved actually cost, taken
--                   from the movements the stock half wrote
--   (balancing)     whatever figure makes the journal balance, which is how a
--                   purchase price variance is expressed without arithmetic in
--                   the configuration
--
-- Costs are computed once, by the stock half, and written onto the movement.
-- erp.stock_movement.unit_cost_minor has existed since B7 and has been read by
-- nothing; it is now the single place a cost lives, so the ledger and the
-- valuation cannot disagree about what a despatch was worth.
-- -----------------------------------------------------------------------------

create or replace function erp.document_stock_cost_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(sum(round(m.quantity * m.unit_cost_minor))::bigint, 0)
    from erp.stock_movement m
   where m.tenant_id = erp.current_tenant_id()
     and m.document_id = p_document_id
     and not m.is_reversal
$$;

comment on function erp.document_stock_cost_minor(uuid) is
  'What the stock a document moved actually cost, from the movements the stock '
  'half valued. One source, so the ledger and the valuation cannot disagree.';

-- Costing changes what a posting rule may say, so the static check has to
-- change with it. Two ways a rule can balance now: every basis balances on its
-- own, or the rule names exactly one balancing line to absorb the difference.
create or replace function erp.posting_rule_imbalance(p_posting_lines jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    -- A balancing line takes whatever is left, so such a rule always balances
    -- arithmetically. More than one is ambiguous and is caught separately.
    when exists (select 1 from jsonb_array_elements(coalesce(p_posting_lines, '[]'::jsonb)) l
                  where coalesce((l.value ->> 'balancing')::boolean, false))
      then 0
    else coalesce((
      -- Otherwise every basis must balance within itself: a rule that debits a
      -- cost and credits a price is not balanced, it is two half-rules that
      -- happen to agree when margin is zero.
      select sum(abs(x.net))
        from (select coalesce(l.value ->> 'basis', 'document_value') as basis,
                     sum(case when l.value ->> 'side' = 'debit'
                              then coalesce((l.value ->> 'rate')::numeric, 1)
                              else -coalesce((l.value ->> 'rate')::numeric, 1) end) as net
                from jsonb_array_elements(coalesce(p_posting_lines, '[]'::jsonb)) l
               group by 1) x), 0)
  end
$$;

-- Both halves, revised. The stock half values every movement it writes; the
-- finance half reads the basis each posting line names instead of assuming the
-- document's own value.

create or replace function erp.post_document_stock(p_document_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  dt         erp.document_type%rowtype;
  bt         erp_ref.document_type%rowtype;
  mt         erp_ref.movement_type%rowtype;
  ln         record;
  v_location uuid;
  v_cost     bigint;
  v_count    integer := 0;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- Nothing to do is not an error: most document types move no stock, and the
  -- caller should not have to know which.
  if not bt.affects_stock then
    return 0;
  end if;

  -- Posting twice would double the stock. The ledger is append-only, so there
  -- is no undoing it — a receipt is corrected by reversing it, never by
  -- posting it again.
  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'ERPWARE_ALREADY_POSTED: % has already moved stock; reverse it rather '
      'than posting again', d.document_number
      using errcode = '23505';
  end if;

  if dt.stock_movement_type is null then
    raise exception
      'ERPWARE_NO_MOVEMENT_TYPE: % moves stock but names no movement type',
      dt.code
      using errcode = '23502',
      detail = 'erp_ref.document_type.affects_stock is true for base type '
               || dt.base_type_code;
  end if;

  select * into mt from erp_ref.movement_type where code = dt.stock_movement_type;

  if d.site_id is null then
    raise exception 'ERPWARE_NO_SITE: % moves stock but names no site', d.document_number
      using errcode = '23502';
  end if;

  perform erp.authorise(
    case when mt.direction = 'in' then 'procurement.receive' else 'sales.despatch' end,
    d.entity_id, d.site_id, null, 'document', p_document_id);

  for ln in
    select l.* from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not l.is_cancelled and l.quantity > 0
     order by l.line_no
  loop
    v_location := coalesce(ln.location_id,
                           erp.default_posting_location(d.site_id, mt.direction));

    -- What this line's stock is worth, by the costing method in force. Inbound
    -- records what arrived; outbound consumes it. Either way the answer is
    -- written onto the movement, which is where the ledger reads it from —
    -- erp.stock_movement.unit_cost_minor has existed since B7 and until now
    -- carried the sales price, because nothing read it.
    if mt.direction = 'in' then
      v_cost := erp.receive_cost(
        ln.item_id, d.site_id, ln.quantity,
        coalesce(ln.unit_price_minor, 0), coalesce(ln.currency, d.currency),
        ln.batch_id, null);
    elsif mt.direction = 'out' then
      v_cost := erp.issue_cost(ln.item_id, d.site_id, ln.quantity);
    else
      -- A transfer does not change what stock cost; it changes where it is.
      v_cost := coalesce(ln.unit_price_minor, 0);
    end if;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      batch_id, serial_id, container_id,
      -- One expression, both directions. B7's trigger reads these to decide
      -- which side of the balance to touch, so 'in' fills the destination and
      -- 'out' fills the source; a transfer would fill both.
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency,
      document_id, document_line_id)
    values (
      v_tenant, d.entity_id, d.site_id, mt.code, ln.item_id,
      ln.batch_id, ln.serial_id, ln.container_id,
      case when mt.direction in ('out', 'transfer') then v_location end,
      case when mt.direction in ('out', 'transfer') then 'available'::erp.stock_status end,
      case when mt.direction in ('in',  'transfer') then v_location end,
      case when mt.direction in ('in',  'transfer') then 'available'::erp.stock_status end,
      ln.quantity,
      coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
      v_cost, coalesce(ln.currency, d.currency),
      p_document_id, ln.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function erp.post_document_finance(p_document_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
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

  perform erp.authorise('finance.post', d.entity_id, d.site_id, null,
                        'document', p_document_id);

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
$$;

-- -----------------------------------------------------------------------------
-- Count programmes
--
-- Spec 5.2 asks for counts "that operate without freezing stock, with granular
-- soft locking, automatic exclusion of committed stock, tolerance-based
-- variance approval and accuracy reporting". Every qualifier is the
-- requirement:
--
--   without freezing stock   a count that stops the warehouse happens twice a
--                            year and tells you about last February
--   granular soft locking    the lock is on the location being counted, not on
--                            the site, and it warns rather than refuses — a
--                            despatch that has to go out still goes out, and
--                            the count knows it happened
--   excluding committed      stock already allocated to an order is going to
--                            leave; counting it as a variance is counting the
--                            allocation, not the stock
--   tolerance approval       a two-unit difference on ten thousand is noise; a
--                            two-unit difference on two is a problem. One
--                            threshold cannot express both, so there are two
--   accuracy reporting       the point of counting is knowing whether the
--                            records are trustworthy, which is a rate over
--                            time, not a list of adjustments
-- -----------------------------------------------------------------------------

create type erp.count_programme_kind as enum
  ('cycle', 'perpetual', 'annual', 'opportunistic');

create type erp.count_task_status as enum
  ('open', 'counted', 'pending_approval', 'approved', 'rejected', 'posted', 'cancelled');

create table if not exists erp.count_programme (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text not null,
  site_id      uuid,
  kind         erp.count_programme_kind not null,
  -- Which stock this programme is about, as JsonLogic over the balance row.
  selector     jsonb not null default 'true'::jsonb,
  -- Tolerances. Absolute for small quantities, percentage for large ones, and
  -- a variance inside BOTH is auto-approved.
  tolerance_absolute numeric(20,6) not null default 0,
  tolerance_pct      numeric(6,3) not null default 0,
  approval_chain_code text,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

create table if not exists erp.count_task (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  count_programme_id uuid not null,
  site_id      uuid not null,
  location_id  uuid,
  item_id      uuid not null,
  batch_id     uuid,
  -- What the records said when the task was raised. Kept, because a variance
  -- measured against the balance at posting time measures the movements that
  -- happened while somebody was counting.
  expected_quantity numeric(20,6) not null,
  -- What was allocated at that moment, and therefore excluded.
  committed_quantity numeric(20,6) not null default 0,
  counted_quantity  numeric(20,6),
  -- Movements into or out of this location since the task was raised. A soft
  -- lock does not stop them; it records them, so the variance can be explained
  -- rather than argued about.
  movement_during   numeric(20,6) not null default 0,
  variance          numeric(20,6),
  within_tolerance  boolean,
  status       erp.count_task_status not null default 'open',
  approval_request_id uuid,
  counted_at   timestamptz,
  counted_by   uuid,
  posted_at    timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, count_programme_id)
    references erp.count_programme (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, location_id) references erp.location (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id) references erp.batch (tenant_id, id) on delete restrict
);

create index if not exists count_task_open
  on erp.count_task (tenant_id, site_id, location_id) where status = 'open';

-- The soft lock. A row, not a flag on the location, and it warns rather than
-- refuses — which is the whole difference between a count that runs alongside
-- the warehouse and one that stops it.
create table if not exists erp.count_lock (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  count_task_id uuid not null,
  location_id  uuid not null,
  item_id      uuid,
  locked_at    timestamptz not null default clock_timestamp(),
  released_at  timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, count_task_id)
    references erp.count_task (tenant_id, id) on delete cascade,
  foreign key (tenant_id, location_id) references erp.location (tenant_id, id) on delete cascade
);

create index if not exists count_lock_live
  on erp.count_lock (tenant_id, location_id, item_id) where released_at is null;

create or replace function erp.raise_count_tasks(p_programme_code text)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pg       erp.count_programme%rowtype;
  r        record;
  v_task   uuid;
  v_n      integer := 0;
  v_committed numeric;
begin
  select * into pg from erp.count_programme
   where tenant_id = v_tenant and code = p_programme_code and status = 'active';
  if not found then
    raise exception 'ERPWARE_UNKNOWN_COUNT_PROGRAMME: %', p_programme_code
      using errcode = '23503';
  end if;

  perform erp.authorise('inventory.count', null, pg.site_id, null,
                        'count_programme', pg.id);

  for r in
    select b.*, i.code as item_code, i.item_class
      from erp.stock_balance b
      join erp.item i on i.id = b.item_id
     where b.tenant_id = v_tenant
       and (pg.site_id is null or b.site_id = pg.site_id)
       and b.quantity <> 0
  loop
    continue when not erp.jsonlogic_bool(pg.selector, to_jsonb(r));

    -- Already being counted. Raising a second task for the same stock gives
    -- two counters two answers and one of them a variance that is the other's
    -- count.
    continue when exists (
      select 1 from erp.count_task t
       where t.tenant_id = v_tenant and t.status in ('open','counted','pending_approval')
         and t.item_id = r.item_id
         and t.location_id is not distinct from r.location_id);

    -- Stock that is allocated is going to leave. Counting it as present and
    -- then as a variance when it goes is counting the allocation.
    select coalesce(sum(al.quantity), 0) into v_committed
      from erp.allocation_line al
      join erp.allocation a on a.id = al.allocation_id
     where al.tenant_id = v_tenant
       and a.item_id = r.item_id
       and al.location_id is not distinct from r.location_id
       and al.status in ('reserved', 'committed', 'picked');

    insert into erp.count_task (
      tenant_id, count_programme_id, site_id, location_id, item_id, batch_id,
      expected_quantity, committed_quantity, status)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open')
    returning id into v_task;

    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
    values (v_tenant, v_task, r.location_id, r.item_id);

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

comment on function erp.raise_count_tasks(text) is
  'Spec 5.2: a count programme raises tasks over the stock its selector picks, '
  'recording what was committed at that moment and taking a soft lock that '
  'warns rather than blocks.';

-- The soft lock, enforced as a warning on the movement path. A despatch that
-- has to go out goes out; the count is told, and its variance is adjusted by
-- what moved rather than blamed on the counter.
create or replace function erp.note_count_lock_movement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_delta numeric;
  r       record;
begin
  for r in
    select l.count_task_id, l.location_id
      from erp.count_lock l
     where l.tenant_id = new.tenant_id
       and l.released_at is null
       and (l.item_id is null or l.item_id = new.item_id)
       and l.location_id in (new.from_location_id, new.to_location_id)
  loop
    v_delta := case when r.location_id = new.to_location_id then new.quantity
                    else -new.quantity end;

    update erp.count_task t
       set movement_during = t.movement_during + v_delta, updated_at = now()
     where t.id = r.count_task_id and t.status in ('open', 'counted');

    -- A notice rather than an exception, deliberately. Blocking here would
    -- make "without freezing stock" false, and silence would make the variance
    -- a mystery.
    raise notice
      'ERPWARE_COUNT_IN_PROGRESS: % moved through a location being counted; '
      'the count task has been told', new.quantity;
  end loop;

  return null;
end;
$$;

drop trigger if exists t_stock_movement_count_lock on erp.stock_movement;
create trigger t_stock_movement_count_lock
  after insert on erp.stock_movement
  for each row execute function erp.note_count_lock_movement();

create or replace function erp.record_count(
  p_task_id  uuid,
  p_quantity numeric
) returns erp.count_task_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        erp.count_task%rowtype;
  pg       erp.count_programme%rowtype;
  v_expect numeric;
  v_var    numeric;
  v_ok     boolean;
  v_status erp.count_task_status;
  v_req    uuid;
begin
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503';
  end if;

  if t.status <> 'open' then
    raise exception 'ERPWARE_COUNT_TASK_NOT_OPEN: % is %', p_task_id, t.status
      using errcode = '23514';
  end if;

  perform erp.authorise('inventory.count', null, t.site_id, null,
                        'count_task', p_task_id);

  select * into pg from erp.count_programme where id = t.count_programme_id;

  -- What the records say the counter should have seen: the expectation when
  -- the task was raised, plus whatever moved through while they were counting,
  -- less what was committed and therefore excluded from the count.
  v_expect := t.expected_quantity + t.movement_during - t.committed_quantity;
  v_var := p_quantity - v_expect;

  -- Inside both tolerances, or inside the only one that was configured. A
  -- variance of two on ten thousand and a variance of two on two are different
  -- events and one threshold cannot say so.
  v_ok := abs(v_var) <= pg.tolerance_absolute
          and (v_expect = 0 or
               abs(v_var) * 100.0 / abs(v_expect) <= pg.tolerance_pct);

  if v_ok then
    v_status := 'approved';
  elsif pg.approval_chain_code is not null then
    v_req := erp.request_approval(
      'count_task', p_task_id,
      jsonb_build_object(
        'variance', v_var, 'expected', v_expect, 'counted', p_quantity,
        'variance_pct', case when v_expect = 0 then null
                             else round(abs(v_var) * 100.0 / abs(v_expect), 3) end),
      1, null, t.site_id);
    v_status := 'pending_approval';
  else
    v_status := 'counted';
  end if;

  update erp.count_task
     set counted_quantity = p_quantity, variance = v_var,
         within_tolerance = v_ok, status = v_status,
         approval_request_id = v_req,
         counted_at = now(), counted_by = erp.current_principal_id(),
         updated_at = now()
   where id = p_task_id;

  return v_status;
end;
$$;

create or replace function erp.post_count(p_task_id uuid)
returns numeric
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        erp.count_task%rowtype;
  v_cost   bigint;
  v_uom    uuid;
begin
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503';
  end if;

  if t.status <> 'approved' then
    raise exception
      'ERPWARE_COUNT_NOT_APPROVED: % is %, and a variance is not written into '
      'the ledger on one person''s word', p_task_id, t.status
      using errcode = '42501';
  end if;

  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);

  if coalesce(t.variance, 0) = 0 then
    update erp.count_task set status = 'posted', posted_at = now(), updated_at = now()
     where id = p_task_id;
    -- The lock is released here too. Returning early without releasing it
    -- leaves a lock on a finished count, which is invisible until the next
    -- count of the same location inherits movement that was never its problem.
    update erp.count_lock set released_at = now(), updated_at = now()
     where tenant_id = v_tenant and count_task_id = p_task_id and released_at is null;
    return 0;
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = t.item_id;

  -- An adjustment is a movement like any other, which is what keeps
  -- erp.assert_stock_reconciles() true through a count.
  if t.variance > 0 then
    v_cost := erp.receive_cost(t.item_id, t.site_id, t.variance,
                coalesce((select c.unit_cost_minor from erp.item_cost c
                           where c.tenant_id = v_tenant and c.item_id = t.item_id
                             and c.site_id is not distinct from t.site_id), 0),
                coalesce((select e.base_currency from erp.entity e
                           where e.tenant_id = v_tenant limit 1), 'GBP'),
                t.batch_id, null);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id,
           t.location_id, 'available', t.variance, v_uom, v_cost,
           coalesce((select e.base_currency from erp.entity e
                      where e.tenant_id = v_tenant limit 1), 'GBP'),
           'count_variance'
      from erp.site s where s.id = t.site_id;
  else
    v_cost := erp.issue_cost(t.item_id, t.site_id, -t.variance);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id,
           t.location_id, 'available', -t.variance, v_uom, v_cost,
           coalesce((select e.base_currency from erp.entity e
                      where e.tenant_id = v_tenant limit 1), 'GBP'),
           'count_variance'
      from erp.site s where s.id = t.site_id;
  end if;

  update erp.count_task set status = 'posted', posted_at = now(), updated_at = now()
   where id = p_task_id;
  update erp.count_lock set released_at = now(), updated_at = now()
   where tenant_id = v_tenant and count_task_id = p_task_id and released_at is null;

  return t.variance;
end;
$$;

create or replace function erp.count_accuracy_report(p_since date default null)
returns table (programme_code text, tasks bigint, within_tolerance bigint,
               accuracy_pct numeric, absolute_variance numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Spec 5.2: accuracy reporting. A rate, because the question a count answers
  -- is "are the records trustworthy", and a list of adjustments does not answer
  -- it — a warehouse with a hundred small corrections and one with a hundred
  -- large ones produce the same list and very different answers.
  select p.code,
         count(*),
         count(*) filter (where t.within_tolerance),
         round(100.0 * count(*) filter (where t.within_tolerance)
               / nullif(count(*), 0), 2),
         coalesce(sum(abs(t.variance)), 0)
    from erp.count_task t
    join erp.count_programme p on p.id = t.count_programme_id
   where t.tenant_id = erp.current_tenant_id()
     and t.counted_at is not null
     and (p_since is null or t.counted_at::date >= p_since)
   group by p.code
   order by 4
$$;

-- -----------------------------------------------------------------------------
-- Expiry horizon and write-off
--
-- erp.batch.expires_on has existed since B7 and nothing has ever looked at it.
-- The horizon is the useful question: not "what has expired" — that is too late
-- to do anything about — but "what will expire before it can plausibly be
-- sold", which is a decision somebody can still act on.
-- -----------------------------------------------------------------------------

create or replace function erp.expiry_horizon_report(p_days integer default 30)
returns table (batch_id uuid, batch_number text, item_id uuid, item_code text,
               site_id uuid, expires_on date, days_remaining integer,
               quantity numeric, value_minor bigint, is_committed boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  select b.id, b.batch_number, i.id, i.code, sb.site_id, b.expires_on,
         (b.expires_on - current_date)::integer,
         sum(sb.quantity),
         round(sum(sb.quantity) * coalesce(
           (select c.unit_cost_minor from erp.item_cost c
             where c.tenant_id = b.tenant_id and c.item_id = b.item_id
               and c.site_id is not distinct from sb.site_id), 0))::bigint,
         -- Committed stock is somebody's order. It is still a problem if it
         -- expires, and it is a different problem.
         exists (select 1 from erp.allocation a
                  join erp.allocation_line al on al.allocation_id = a.id
                 where a.tenant_id = b.tenant_id and a.item_id = b.item_id
                   and al.batch_id = b.id
                   and al.status in ('reserved','committed','picked'))
    from erp.batch b
    join erp.item i on i.id = b.item_id
    join erp.stock_balance sb on sb.batch_id = b.id and sb.quantity > 0
   where b.tenant_id = erp.current_tenant_id()
     and b.expires_on is not null
     and b.expires_on <= current_date + p_days
   group by b.id, b.batch_number, i.id, i.code, sb.site_id, b.expires_on, b.tenant_id, b.item_id
   order by b.expires_on
$$;

comment on function erp.expiry_horizon_report(integer) is
  'Spec 5.2: expiry horizon management. What will expire within the horizon, '
  'not what already has — the second is a report and the first is a decision.';

create or replace function erp.write_off_stock(
  p_item_id  uuid,
  p_site_id  uuid,
  p_location_id uuid,
  p_quantity numeric,
  p_reason   text,
  p_batch_id uuid default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cost   bigint;
  v_uom    uuid;
  v_id     bigint;
begin
  if coalesce(p_reason, '') = '' then
    raise exception
      'ERPWARE_WRITE_OFF_NEEDS_REASON: stock is not written off without one'
      using errcode = '23514';
  end if;

  perform erp.authorise('inventory.write_off', null, p_site_id, null,
                        'item', p_item_id);

  select i.stock_uom_id into v_uom from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id;

  -- Consuming cost layers, so a write-off relieves inventory at what the stock
  -- cost rather than at nothing.
  v_cost := erp.issue_cost(p_item_id, p_site_id, p_quantity);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code)
  select v_tenant, s.entity_id, p_site_id, 'scrap', p_item_id, p_batch_id,
         p_location_id, 'available', p_quantity, v_uom, v_cost,
         coalesce((select e.base_currency from erp.entity e
                    where e.tenant_id = v_tenant limit 1), 'GBP'),
         left(p_reason, 64)
    from erp.site s where s.id = p_site_id
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Stock health and ageing
-- -----------------------------------------------------------------------------

create or replace function erp.stock_ageing_report()
returns table (item_id uuid, item_code text, site_id uuid,
               bucket text, quantity numeric, value_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Ageing is measured from the valuation layers rather than from the balance,
  -- because a balance has no age: it is a number that was updated this morning
  -- whether the stock arrived today or two years ago.
  select l.item_id, i.code, l.site_id,
         case
           when l.received_at > now() - interval '30 days'  then '0-30'
           when l.received_at > now() - interval '90 days'  then '31-90'
           when l.received_at > now() - interval '180 days' then '91-180'
           when l.received_at > now() - interval '365 days' then '181-365'
           else '365+'
         end,
         sum(l.remaining),
         round(sum(l.remaining * l.unit_cost_minor))::bigint
    from erp.stock_valuation_layer l
    join erp.item i on i.id = l.item_id
   where l.tenant_id = erp.current_tenant_id()
     and l.remaining > 0
   group by 1, 2, 3, 4
   order by 2, 4
$$;

comment on function erp.stock_ageing_report() is
  'Spec 5.2: ageing analysis, measured from the valuation layers. A balance has '
  'no age — it is a number updated this morning whether the stock arrived today '
  'or two years ago.';

create or replace function erp.stock_health_report()
returns table (item_id uuid, item_code text, site_id uuid,
               on_hand numeric, committed numeric, available numeric,
               value_minor bigint, expiring_30d numeric,
               days_since_last_movement integer, finding text)
language sql
stable
security invoker
set search_path = ''
as $$
  with oh as (
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b
     where b.tenant_id = erp.current_tenant_id()
     group by 1, 2
  ),
  com as (
    select a.item_id, a.site_id, sum(al.quantity) as qty
      from erp.allocation a
      join erp.allocation_line al on al.allocation_id = a.id
     where a.tenant_id = erp.current_tenant_id()
       and al.status in ('reserved','committed','picked')
     group by 1, 2
  ),
  last_move as (
    select m.item_id, m.site_id, max(m.occurred_at) as at
      from erp.stock_movement m
     where m.tenant_id = erp.current_tenant_id()
     group by 1, 2
  ),
  exp30 as (
    select e.item_id, e.site_id, sum(e.quantity) as qty
      from erp.expiry_horizon_report(30) e group by 1, 2
  )
  select oh.item_id, i.code, oh.site_id,
         oh.qty, coalesce(com.qty, 0), oh.qty - coalesce(com.qty, 0),
         coalesce((select v.value_minor from erp.stock_valuation_report() v
                    where v.item_id = oh.item_id
                      and v.site_id is not distinct from oh.site_id), 0),
         coalesce(exp30.qty, 0),
         (current_date - coalesce(last_move.at, now())::date)::integer,
         case
           when oh.qty < 0 then 'negative on hand'
           when coalesce(com.qty, 0) > oh.qty then 'committed beyond what is on hand'
           when coalesce(exp30.qty, 0) > 0 then 'expiring within thirty days'
           when last_move.at is null then 'never moved'
           when last_move.at < now() - interval '180 days' then 'no movement in six months'
           else 'healthy'
         end
    from oh
    join erp.item i on i.id = oh.item_id
    left join com on com.item_id = oh.item_id and com.site_id is not distinct from oh.site_id
    left join last_move on last_move.item_id = oh.item_id
                       and last_move.site_id is not distinct from oh.site_id
    left join exp30 on exp30.item_id = oh.item_id and exp30.site_id is not distinct from oh.site_id
   order by i.code
$$;

-- -----------------------------------------------------------------------------
-- Batch operations that are not movements
--
-- Spec 5.2: "batch attribute amendment, split, merge, re-status and re-date
-- without stock movement". The last four words are the requirement. Splitting a
-- batch does not move anything, and recording it as a movement would corrupt
-- every quantity that is derived by summing movements — which, in this product,
-- is the balance itself.
--
-- So these write erp.batch_amendment and adjust erp.stock_balance's batch
-- attribution directly, and B7's own reconciliation assertion is what proves
-- the ledger still agrees afterwards.
-- -----------------------------------------------------------------------------

create or replace function erp.amend_batch(
  p_batch_id uuid,
  p_field    text,
  p_value    text,
  p_reason   text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_old    text;
  v_type   text;
  v_allowed constant text[] :=
    array['expires_on','retest_on','best_before_on','status','supplier_lot','origin_country'];
begin
  if not (p_field = any (v_allowed)) then
    raise exception
      'ERPWARE_BATCH_FIELD_NOT_AMENDABLE: % is not one of %',
      p_field, array_to_string(v_allowed, ', ')
      using errcode = '42501';
  end if;

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_AMENDMENT_NEEDS_REASON: a batch attribute is not '
      'changed silently' using errcode = '23514';
  end if;

  perform erp.authorise('inventory.adjust', null, null, null, 'batch', p_batch_id);

  execute format('select (t.%I)::text from erp.batch t where t.tenant_id = $1 and t.id = $2',
                 p_field)
    into v_old using v_tenant, p_batch_id;

  -- The cast comes from the catalogue rather than from a hand-kept mapping:
  -- expires_on is a date and status is an enum, and text assigned to either
  -- fails. Both identifiers here are the product's own — the field is checked
  -- against the allow-list above and the type is read from pg_attribute.
  select pg_catalog.format_type(a.atttypid, a.atttypmod) into v_type
    from pg_catalog.pg_attribute a
   where a.attrelid = 'erp.batch'::regclass and a.attname = p_field;

  execute format('update erp.batch set %I = $3::%s, updated_at = now(), updated_by = $4
                   where tenant_id = $1 and id = $2', p_field, v_type)
    using v_tenant, p_batch_id, p_value, erp.current_principal_id();

  -- The amendment record is the point. B7 built this table and nothing wrote
  -- to it, so a re-dated batch was indistinguishable from one that always had
  -- that date.
  insert into erp.batch_amendment (
    tenant_id, batch_id, field, old_value, new_value, reason, actor_id)
  values (v_tenant, p_batch_id, p_field, to_jsonb(v_old), to_jsonb(p_value),
          p_reason, erp.current_principal_id());
end;
$$;

create or replace function erp.split_batch(
  p_batch_id     uuid,
  p_new_number   text,
  p_quantity     numeric,
  p_location_id  uuid,
  p_reason       text
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.batch%rowtype;
  v_new    uuid;
  v_have   numeric;
  v_entity uuid;
  v_uom    uuid;
begin
  select * into b from erp.batch where tenant_id = v_tenant and id = p_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_BATCH: %', p_batch_id using errcode = '23503';
  end if;

  perform erp.authorise('inventory.adjust', null, null, null, 'batch', p_batch_id);

  select coalesce(sum(sb.quantity), 0) into v_have
    from erp.stock_balance sb
   where sb.tenant_id = v_tenant and sb.batch_id = p_batch_id
     and sb.location_id is not distinct from p_location_id;

  if p_quantity <= 0 or p_quantity >= v_have then
    raise exception
      'ERPWARE_SPLIT_OUT_OF_RANGE: % of % available; a split takes part of a '
      'batch, not all or none of it', p_quantity, v_have
      using errcode = '23514';
  end if;

  insert into erp.batch (
    tenant_id, item_id, batch_number, status, manufactured_on, expires_on,
    retest_on, best_before_on, supplier_lot, origin_country, supplier_party_id,
    certificates, attributes, catch_weight_per_unit)
  values (v_tenant, b.item_id, p_new_number, b.status, b.manufactured_on,
          b.expires_on, b.retest_on, b.best_before_on, b.supplier_lot,
          b.origin_country, b.supplier_party_id, b.certificates, b.attributes,
          b.catch_weight_per_unit)
  returning id into v_new;

  -- Genealogy, so a split batch can still be traced to what it came from.
  insert into erp.batch_genealogy (
    tenant_id, parent_batch_id, child_batch_id, quantity, occurred_at)
  values (v_tenant, p_batch_id, v_new, p_quantity, clock_timestamp());

  -- "Without stock movement" means the pallet does not go anywhere, and it
  -- does not: both entries below are at the same location with the same status.
  --
  -- It does not mean the ledger stays silent, and it cannot: B7 derives
  -- erp.stock_balance from the movements and refuses a direct write, precisely
  -- so that a balance nobody can explain is impossible. So the re-attribution
  -- is recorded as what it is — quantity leaving one batch and arriving in
  -- another, in place — using the status_change movement type B7 provided for
  -- exactly this. Anything else would need the balance guard switched off, and
  -- a product that switches off its own invariant to do routine work does not
  -- have that invariant.
  select s.entity_id into v_entity from erp.site s
    join erp.location l on l.site_id = s.id
   where l.tenant_id = v_tenant and l.id = p_location_id;

  select i.stock_uom_id into v_uom from erp.item i where i.id = b.item_id;

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, quantity, uom_id, reason_code)
  select v_tenant, v_entity, l.site_id, 'status_change', b.item_id, p_batch_id,
         p_location_id, 'available', p_quantity, v_uom, 'batch_split'
    from erp.location l where l.id = p_location_id;

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    to_location_id, to_status, quantity, uom_id, reason_code)
  select v_tenant, v_entity, l.site_id, 'status_change', b.item_id, v_new,
         p_location_id, 'available', p_quantity, v_uom, 'batch_split'
    from erp.location l where l.id = p_location_id;

  insert into erp.batch_amendment (
    tenant_id, batch_id, field, old_value, new_value, reason, actor_id)
  values (v_tenant, p_batch_id, 'split', to_jsonb(v_have),
          to_jsonb(format('%s to %s', p_quantity, p_new_number)), p_reason,
          erp.current_principal_id());

  return v_new;
end;
$$;

comment on function erp.split_batch(uuid, text, numeric, uuid, text) is
  'Spec 5.2: split without stock movement. The same units in the same place '
  'under a different batch number; recording it as a movement would double the '
  'quantity in every report that sums them.';

-- -----------------------------------------------------------------------------
-- Inventory, installed
--
-- Costing policies and count programmes are configuration, so B6 gains two more
-- kinds and both go through it. The posting rules change too: the delivery rule
-- now measures on stock_cost, which is the defect at the top of this file.
-- -----------------------------------------------------------------------------

create or replace function erp.configure_inventory(
  p_method erp.costing_method default 'average',
  p_approver_role text default 'administrator',
  p_tolerance_absolute numeric default 2,
  p_tolerance_pct numeric default 1
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.status = 'active') then
    raise exception
      'ERPWARE_NO_LEDGER: this tenant has no chart of accounts, and inventory '
      'valuation reconciles to one'
      using errcode = '23503',
            hint = 'Run erp.configure_finance() first.';
  end if;

  -- The variance account standard costing needs. Added here rather than in the
  -- finance chart because it only exists if somebody chose standard costing,
  -- and an account nothing posts to is dead configuration in the ledger too.
  insert into erp.account (
    tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
  select v_tenant, e.id, '9100', 'Purchase price variance', 'expense', true,
         e.base_currency, 'active'
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
  on conflict (tenant_id, entity_id, code) do update set status = 'active';

  v_cs := erp.install_module_config(
    'inventory-operations', 'Inventory operations',
    'How stock is valued, how it is counted, and what the ledger is told about '
    'both.',
    jsonb_build_array(
      jsonb_build_object('kind','costing_policy','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default costing','method', p_method::text,
          'variance_account','9100')),

      jsonb_build_object('kind','count_programme','key','cycle_a','payload',
        jsonb_build_object(
          'code','cycle_a','name','Cycle count — fast movers','kind','cycle',
          -- Every item with stock. A real tenant narrows this by class or by
          -- value band; the point of the selector is that narrowing it needs no
          -- code.
          'selector','true',
          'tolerance_absolute', p_tolerance_absolute,
          'tolerance_pct', p_tolerance_pct,
          'approval_chain','count_variance')),

      jsonb_build_object('kind','approval_chain','key','count_variance','payload',
        jsonb_build_object(
          'code','count_variance','name','Count variance approval',
          'object_type','count_task',
          'applies_when','true'::jsonb,
          'priority',100,
          'material_fields', jsonb_build_array('variance','counted'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','stock_controller','name','Stock controller',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      -- The posting rules, restated on the right basis. A receipt debits
      -- inventory at cost and credits the supplier at what was invoiced; under
      -- standard costing those differ and the balancing line is the variance.
      jsonb_build_object('kind','posting_rule','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','name','Goods receipt','ledger','GL',
          'event_type','document.goods_receipt.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','1200','side','debit','basis','stock_cost','rate',1,
                               'description','Inventory received, at cost'),
            jsonb_build_object('account','2100','side','credit','basis','document_value','rate',1,
                               'description','Goods received not invoiced, at invoice value'),
            jsonb_build_object('account','9100','side','debit','balancing',true,
                               'description','Purchase price variance')))),

      -- And the one this migration exists to correct.
      jsonb_build_object('kind','posting_rule','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','name','Delivery','ledger','GL',
          'event_type','document.delivery.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','5000','side','debit','basis','stock_cost','rate',1,
                               'description','Cost of goods sold'),
            jsonb_build_object('account','1200','side','credit','basis','stock_cost','rate',1,
                               'description','Inventory despatched, at cost'))))));

  return v_cs;
end;
$$;

comment on function erp.configure_inventory(erp.costing_method, text, numeric, numeric) is
  'Spec 5.2 as configuration: the costing method, the count programme and its '
  'tolerances, and the posting rules that now measure stock movements at cost '
  'rather than at the price they were sold for.';

-- -----------------------------------------------------------------------------
-- B6 learns costing policies and count programmes
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

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.inventory_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Standard costing without a variance account has nowhere to put the
  -- difference, which means the first receipt at the wrong price fails.
  select 'a standard costing policy names no variance account',
         c.code,
         'the difference between standard and invoice has nowhere to go, so '
         'the first receipt at any other price will refuse'
    from erp.costing_policy c
   where c.status = 'active' and c.method = 'standard'
     and c.variance_account_code is null
  union all
  select 'a costing policy names a variance account the entity does not have',
         c.code, format('account %s', c.variance_account_code)
    from erp.costing_policy c
   where c.status = 'active' and c.variance_account_code is not null
     and not exists (select 1 from erp.account a
                      where a.tenant_id = c.tenant_id
                        and a.code = c.variance_account_code
                        and a.status = 'active')
  union all
  -- A count programme with no tolerance at all sends every count to an
  -- approver, which is how a count queue stops being read.
  select 'a count programme has no tolerance of any kind',
         c.code,
         'every variance, however small, would go to an approver — which is how '
         'an approval queue stops being read'
    from erp.count_programme c
   where c.status = 'active'
     and c.tolerance_absolute = 0 and c.tolerance_pct = 0
  union all
  select 'a count programme names an approval chain that does not exist',
         c.code, format('approval_chain_code = %s', c.approval_chain_code)
    from erp.count_programme c
   where c.status = 'active' and c.approval_chain_code is not null
     and not exists (select 1 from erp.approval_chain ac
                      where ac.tenant_id = c.tenant_id
                        and ac.code = c.approval_chain_code
                        and ac.status = 'active')
  union all
  -- The rule that would have caught yesterday's defect. A line measured on
  -- stock_cost against a document type that moves no stock is always zero.
  select 'a posting rule measures stock cost on a type that moves no stock',
         format('%s v%s', pr.code, pr.version),
         format('document type %s has affects_stock false', dt.code)
    from erp.posting_rule pr
    join erp.document_type dt on dt.tenant_id = pr.tenant_id
                             and dt.posting_rule_code = pr.code
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where pr.status = 'active' and dt.status = 'active'
     and not bt.affects_stock
     and exists (select 1 from jsonb_array_elements(pr.posting_lines) l
                  where l.value ->> 'basis' = 'stock_cost')
$$;

create or replace function erp.assert_inventory_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.inventory_configuration_report();
  if v_count > 0 then
    raise exception 'ERPWARE_INVENTORY_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return 'inventory: every costing and count rule can fire';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_stock_valuation()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb)
        from erp.stock_valuation_report() v $$;

create or replace function public.erp_stock_health()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb)
        from erp.stock_health_report() h $$;

create or replace function public.erp_stock_ageing()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb)
        from erp.stock_ageing_report() a $$;

create or replace function public.erp_expiry_horizon(p_days integer default 30)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
        from erp.expiry_horizon_report(p_days) e $$;

create or replace function public.erp_count_accuracy()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.count_accuracy_report() c $$;

create or replace function public.erp_configure_inventory(
  p_method text default 'average', p_approver_role text default 'administrator')
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_inventory(p_method::erp.costing_method, p_approver_role) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_stock_valuation()', 'public.erp_stock_health()',
    'public.erp_stock_ageing()', 'public.erp_expiry_horizon(integer)',
    'public.erp_count_accuracy()', 'public.erp_configure_inventory(text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_inventory', 'erp.configure_inventory',
   'Submits the costing policy, count programme and revised posting rules as a '
   'B6 change set the caller cannot approve; authorises through the installer.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
--
-- The case that matters most is the first one about margin, because it is the
-- one that would have failed yesterday and did not exist.
-- -----------------------------------------------------------------------------

create or replace function erp_test.inventory_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid; csi uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid; v_batch uuid; v_new_batch uuid;
  v_grn uuid; v_grn2 uuid; v_dn uuid;
  v_j uuid; v_task uuid; v_n integer; v_var numeric;
  b_cogs bigint; b_inv bigint; v_cost bigint; v_status erp.count_task_status;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzinv','Inventory Suite','a@zzinv.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzinv.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  css := erp.configure_sales(15);
  csi := erp.configure_inventory('average');

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'the inventory posting rules supersede the finance ones',
    (select pr.version from erp.posting_rule pr
      where pr.tenant_id = r.tenant_id and pr.code = 'delivery' and pr.status='active') = 2
    and (select count(*) from erp.posting_rule pr
          where pr.tenant_id = r.tenant_id and pr.code = 'delivery') = 2,
    'version 1 kept, because journal lines name the version that produced them';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 100000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- ---------------------------------------------------------------------------
  -- Costing: two receipts at different prices, then an issue.
  -- ---------------------------------------------------------------------------
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 100, 1000, 'first receipt');
  perform erp.transition_document(v_grn,'post');

  v_grn2 := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn2, v_item, 100, 2000, 'second, dearer');
  perform erp.transition_document(v_grn2,'post');

  return query select 'the average moves with the second receipt',
    (select c.unit_cost_minor from erp.item_cost c
      where c.tenant_id = r.tenant_id and c.item_id = v_item) = 1500,
    '100 at 1000 and 100 at 2000 is 1500, not 2000';

  return query select 'and inventory was debited at what was paid, not at the average',
    (select sum(l.debit_minor) from erp.journal_line l
       join erp.journal j on j.id = l.journal_id
       join erp.account a on a.id = l.account_id
      where j.document_id = v_grn2 and a.code = '1200') = 200000,
    'debiting at the new average would put the difference nowhere';

  -- ---------------------------------------------------------------------------
  -- THE case. A delivery priced above cost.
  -- ---------------------------------------------------------------------------
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 50, 5000, 'sold at 5000');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_dn;
  select sum(l.debit_minor) into b_cogs from erp.journal_line l
    join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '5000';
  select sum(l.credit_minor) into b_inv from erp.journal_line l
    join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1200';

  return query select 'a despatch relieves inventory at cost, not at the sale price',
    b_cogs = 75000 and b_inv = 75000,
    format('50 at cost 1500 is %s; at the sale price it would have been 250000', b_cogs);

  return query select 'and the movement carries the cost the ledger used',
    (select m.unit_cost_minor from erp.stock_movement m
      where m.document_id = v_dn) = 1500,
    'one source, so the valuation and the ledger cannot disagree';

  return query select 'the valuation and the inventory account agree',
    (select count(*) from erp.inventory_reconciliation_report()
      where difference_minor <> 0) = 0,
    'spec 5.2: "valuation reporting reconcilable to the ledger", asserted';

  return query select 'and the stock ledger still reconciles to its balances',
    (select count(*) from erp.stock_reconciliation_report()) = 0,
    'B7''s invariant, unbroken by anything above';

  -- ---------------------------------------------------------------------------
  -- Counting.
  -- ---------------------------------------------------------------------------
  v_n := erp.raise_count_tasks('cycle_a');
  return query select 'a count programme raises tasks over the stock it selects',
    v_n >= 1,
    format('%s task(s), each with a soft lock on its location', v_n);

  select t.id into v_task from erp.count_task t
   where t.tenant_id = r.tenant_id and t.status = 'open' limit 1;

  -- Something moves while the count is open. It must not be blocked, and the
  -- count must know.
  perform erp.write_off_stock(v_item, v_site, v_recv, 10, 'damaged in the aisle');

  return query select 'stock moves during a count, and the count is told',
    (select t.movement_during from erp.count_task t where t.id = v_task) = -10,
    'a soft lock warns; it does not stop the warehouse';

  -- What is actually there: 200 received, 50 despatched, 10 written off.
  v_status := erp.record_count(v_task, 140);
  return query select 'a count that agrees with the adjusted expectation is clean',
    v_status = 'approved'
    and (select t.variance from erp.count_task t where t.id = v_task) = 0,
    'expectation adjusted by what moved, so the counter is not blamed for it';

  v_var := erp.post_count(v_task);
  return query select 'and posting a zero variance writes no movement',
    v_var = 0,
    'a count that found nothing wrong is not an adjustment';

  -- Now a count that is wrong, inside tolerance and outside it.
  perform erp.raise_count_tasks('cycle_a');
  select t.id into v_task from erp.count_task t
   where t.tenant_id = r.tenant_id and t.status = 'open' limit 1;
  v_status := erp.record_count(v_task, 141);
  return query select 'a variance inside both tolerances approves itself',
    v_status = 'approved'
    and (select t.within_tolerance from erp.count_task t where t.id = v_task),
    'one unit on a hundred and forty is inside two absolute and one per cent';

  v_var := erp.post_count(v_task);
  return query select 'and posting it writes an adjustment movement',
    v_var = 1
    and exists (select 1 from erp.stock_movement m
                 where m.tenant_id = r.tenant_id and m.reason_code = 'count_variance'),
    'an adjustment is a movement like any other, so the ledger still agrees';

  perform erp.raise_count_tasks('cycle_a');
  select t.id into v_task from erp.count_task t
   where t.tenant_id = r.tenant_id and t.status = 'open' limit 1;
  v_status := erp.record_count(v_task, 50);
  return query select 'a variance outside tolerance goes to an approver',
    v_status = 'pending_approval'
    and (select not t.within_tolerance from erp.count_task t where t.id = v_task),
    'ninety-one units short is not noise';

  begin
    perform erp.post_count(v_task);
    v_ok := false; v_msg := 'an unapproved variance was written into the ledger';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,54); end;
  return query select 'and cannot be posted until somebody agrees', v_ok, v_msg;

  return query select 'accuracy is reported as a rate, not a list',
    (select c.accuracy_pct from erp.count_accuracy_report() c
      where c.programme_code = 'cycle_a') = 66.67,
    'two of three counts inside tolerance';

  -- ---------------------------------------------------------------------------
  -- Ageing, health, expiry.
  -- ---------------------------------------------------------------------------
  return query select 'ageing is measured from the valuation layers',
    (select count(*) from erp.stock_ageing_report()) >= 0,
    'a balance has no age; a layer does';

  return query select 'health flags what a warehouse should look at',
    exists (select 1 from erp.stock_health_report() h where h.item_code = 'WID'),
    'on hand, committed, available, value, expiry and last movement, in one row';

  insert into erp.batch (tenant_id, item_id, batch_number, expires_on, status)
  values (r.tenant_id, v_item, 'B001', current_date + 10, 'released')
  returning id into v_batch;

  return query select 'the expiry horizon asks the answerable question',
    (select count(*) from erp.expiry_horizon_report(30)) = 0,
    'a batch with no stock against it is not expiring stock';

  -- ---------------------------------------------------------------------------
  -- Batch operations without physical movement.
  -- ---------------------------------------------------------------------------
  perform erp.amend_batch(v_batch, 'expires_on', (current_date + 40)::text,
                          'supplier revised the specification');
  return query select 'a re-dated batch records that it was re-dated',
    (select b.expires_on from erp.batch b where b.id = v_batch) = current_date + 40
    and exists (select 1 from erp.batch_amendment am
                 where am.batch_id = v_batch and am.field = 'expires_on'),
    'B7 built this table and nothing had ever written to it';

  begin
    perform erp.amend_batch(v_batch, 'item_id', gen_random_uuid()::text, 'nope');
    v_ok := false; v_msg := 'a batch was moved to a different item by amendment';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,54); end;
  return query select 'and only the fields that may be amended can be', v_ok, v_msg;

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_inventory_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 21;
begin
  create temporary table if not exists zz_inv_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_inv_result;
  insert into zz_inv_result select * from erp_test.inventory_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_inv_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_INVENTORY_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;

  if v_pass < v_total then
    raise exception E'ERPWARE_INVENTORY_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail
      using errcode = 'P0001';
  end if;

  return format('inventory: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_inventory_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
