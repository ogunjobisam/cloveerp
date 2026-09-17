set lock_timeout = '30s';

-- =============================================================================
-- 20260917130000  Stock moves between sites
-- -----------------------------------------------------------------------------
-- A company with two warehouses could not move a pallet from one to the other.
--
-- Everything for it was half here and never joined up. erp_ref.document_type
-- has carried 'transfer_order' — "Stock moving between sites or locations" —
-- since 0025. The base pack has installed its lifecycle since 20260903160000:
-- draft → approved → issued → in transit → received → closed. erp.stock_status
-- has had 'in_transit' since 0023, erp.location_type has had 'transit' since
-- 0002, and erp_ref.location_type has shipped IN_TRANSIT — not countable,
-- holding no available stock — since 20260903110000. Nothing installed the
-- document type, no movement type said "to another site", and the word
-- transfer_order appeared nowhere in src. Six pieces of vocabulary, each
-- written for this, and no mechanism between them.
--
-- ── DECISION 1: IN TRANSIT, NOT A PAIR ───────────────────────────────────────
--
-- erp.stock_movement.site_id is one NOT NULL column and erp.stock_position
-- groups by it, so a single row cannot span two sites. There were two ways to
-- cross:
--
--   a bare pair — one row leaving site A, one row arriving at site B, written
--   together, tied by the document. Two rows, settles instantly, and between
--   despatch and arrival the stock is NOWHERE: not on A's shelf, not on B's,
--   not anywhere a position can be read.
--
--   in transit — the goods leave A's shelf when the lorry is loaded and stand
--   in a place at site A of type 'transit' with status 'in_transit', owned and
--   valued by the company, pickable by nobody and countable by nobody. They
--   leave that place, and site A's books, at the moment they arrive at B.
--
-- This takes in transit, and the lifecycle decided it. A transfer order has an
-- 'in_transit' state between 'issued' and 'received', which under the pair is
-- a state that describes nothing: the stock would already have arrived before
-- the document said it had left. A multi-day move is the ordinary case — that
-- is what a state called "In transit" is for — and a schema that cannot say
-- where the stock is for those days cannot answer the only question anyone
-- asks during them.
--
-- SO: BETWEEN DESPATCH AND ARRIVAL THE STOCK STANDS AT THE DESPATCHING SITE,
-- IN THAT SITE'S TRANSIT LOCATION, WITH STATUS in_transit, AT THE DESPATCHING
-- SITE'S VALUE. It is on site A's quantity and on site A's valuation, and it
-- is not available to pick, not countable, and not allocatable. Three movement
-- rows make the whole journey, not two:
--
--   transfer_despatch  site A, shelf → transit.  Direction 'transfer', within
--                      one site, so nothing is costed: the value has not gone
--                      anywhere yet.
--   transfer_out       site A, transit → nowhere. Direction 'out'. The value
--                      leaves site A here, at the arrival.
--   transfer_in        site B, nowhere → shelf.  Direction 'in'. The value
--                      arrives at site B here, in the same transaction.
--
-- ── DECISION 2: THE STOCK LEDGER MOVES THE VALUATION; THE GENERAL LEDGER DOES
--    NOT MOVE AT ALL ─────────────────────────────────────────────────────────
--
-- The Definition of Done asks for valuation to move between sites with no P&L
-- impact. The honest answer to where it moves is: in the costing store, not in
-- the general ledger, and the second half of that is not a gap.
--
--   * Valuation IS carried per site. erp.item_cost is unique on
--     (tenant, item, site) and erp.stock_valuation_layer carries site_id;
--     erp.receive_cost() and erp.issue_cost() both take a site;
--     erp.stock_valuation_report() returns a row per item and site. So
--     "valuation moves between sites" is a fact this schema can state, prove
--     and report on, and this migration makes it true.
--
--   * Inventory is NOT carried per site in the general ledger. The chart has
--     ONE inventory control account (§8.1 1200, erp.chart_account_code
--     ('inventory')), installed per company and not per site. No installer and
--     no pack creates a site dimension; erp.derive_dimensions() has nothing to
--     derive a site from. A journal for this would be DR 1200 / CR 1200 for
--     the same amount in the same company — a nil entry, telling a reader
--     nothing that the stock ledger did not already say, and inventing
--     per-site accounts the chart does not have would be worse.
--
--     erp_ref.document_type already said so: transfer_order carries
--     affects_finance false, and has since 0025.
--
--   * So THERE IS NO POSTING RULE AND NO JOURNAL, and the movements do NOT go
--     through erp.post_movement_finance() — which posts inventory against
--     5900/6300 Stock adjustments, a P&L account, and would put the whole
--     transfer through profit twice over.
--
-- ── THE VALUE MOVES EXACTLY, AND THAT IS NOT DECORATION ──────────────────────
--
-- erp.assert_inventory_reconciles() refuses any difference between a company's
-- inventory control account and the value of the stock that company holds,
-- summed over its sites. A transfer posts no journal, so the total valuation
-- must not change by a penny or that assertion breaks — for every organisation,
-- for ever, on the first transfer anybody makes.
--
-- round(quantity × unit_cost) is not exact: the unit cost is the rounded
-- display of a value, and erp.issue_cost() says so itself — "the exact
-- proportional share of the value on hand, the last unit taking the remainder".
-- Giving the receiving site quantity × the rounded unit would lose up to half
-- a penny per unit on every transfer. erp.transfer_cost() therefore moves the
-- figure rather than the rate, by whichever of three routes the two sites'
-- costing methods call for — and each of the three is exact:
--
--   FIFO to FIFO — the layers move. Each layer consumed at the despatching
--           site is reopened at the receiving one with the same unit cost and
--           the same received_at, so the goods keep their cost AND their age.
--           It is what FIFO means: a van journey is not a new receipt.
--   to a value on hand — erp.issue_cost() decides what leaves, to the penny,
--           and exactly that is added to the receiving site's value on hand.
--           The average there is recomputed from the value, the way
--           erp.receive_cost() recomputes it; a standard rate is left alone,
--           because arriving stock does not restate what somebody set.
--   to a layer — where the receiving site keeps its value in layers and the
--           despatching site did not, a layer is opened for exactly what left.
--           A rate in whole minor units cannot always state an exact figure
--           over a given quantity, so where it cannot, two layers are opened
--           and the remainder is carried by the units that bear it. The pair
--           is worth precisely what left and nothing is rounded away.
--
-- The three between them cover every pairing of the three costing methods, so
-- there is no combination of two sites for which the value arrives wrong.
--
-- Standard costing has one consequence worth stating plainly: where the two
-- sites carry different standards, the receiving site's value on hand is what
-- arrived and not quantity × its own standard. The alternative is a transfer
-- price variance, which is a P&L movement caused by a lorry, and this schema
-- posts no journal for a transfer to put one in.
--
-- ── WHY THE GENERIC POSTING BRIDGE IS HELD OFF ───────────────────────────────
--
-- erp.transition_document() posts the stock side of any document whose base
-- type declares affects_stock, at the first committed state, through
-- erp.post_document_stock(). For a transfer order the first committed state is
-- 'approved' — before anything has been loaded — and erp.post_document_stock()
-- writes ONE row, in ONE site, at ONE moment, with from and to the same
-- location when the direction is 'transfer'. It cannot say what a transfer
-- does. It is held off for this base type alone, by needle, and the transfer
-- writes its own legs at the two moments goods actually move.
--
-- The document type still names a movement type, because
-- erp.assert_no_dead_configuration() requires one wherever the base type moves
-- stock — and it is not dead: erp.despatch_transfer() reads it for the leg off
-- the shelf.
--
-- ── WHAT IS REFUSED ──────────────────────────────────────────────────────────
--
-- A transfer between two companies. Both sides would have to leave and enter
-- two different sets of books, which is a sale at a price and not a transfer at
-- cost; with no journal it would break each company's inventory
-- reconciliation. CLOVEERP_TRANSFER_CROSSES_COMPANIES says so and says what to
-- do instead.
--
-- ── EXISTING ORGANISATIONS ───────────────────────────────────────────────────
--
-- erp.configure_inventory() is patched so a new organisation installs the
-- lifecycle, the numbering rule and the document type. Existing ones — the
-- demonstration among them — take the same three through the module upgrade
-- register: erp_ref.module_installer.current_version for inventory-operations
-- goes to 4 and erp_ref.module_upgrade_item carries the three objects, so
-- erp.plan_module_upgrade('inventory-operations') offers them and
-- erp.upgrade_module_configuration() applies them.
-- erp.ensure_demo_configuration() takes the upgrade where one is outstanding.
--
-- Proof: erp_test.site_transfer_suite() (12 cases, wrapper pinned) — both
-- sites' quantities before, in transit and after; the stock standing in
-- transit at the despatching site; the valuation moving between sites to the
-- penny; the company's total valuation unchanged; NO P&L ACCOUNT MOVED BY A
-- PENNY and no journal raised at all; approving moving nothing, which is where
-- the generic bridge would have posted; a product kept in cost layers moving
-- its layers rather than an average; a transfer between companies refused;
-- the fixture undone.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The vocabulary: three movement types for one journey
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.movement_type
  (code, name_key, direction, module_code, allows_negative, requires_reason,
   affects_valuation, is_system, description) values
  ('transfer_despatch', 'movement.transfer_despatch', 'transfer', 'inventory',
   false, false, false, false,
   'Off the shelf and onto the lorry. Between two locations at the despatching '
   'site, so the value has not moved: the goods are still that site''s.'),
  ('transfer_out', 'movement.transfer_out', 'out', 'inventory',
   false, false, true, false,
   'Out of the despatching site''s transit place, at the moment the goods reach '
   'the other site. The value leaves this site here.'),
  ('transfer_in', 'movement.transfer_in', 'in', 'inventory',
   false, false, true, false,
   'Onto the receiving site''s shelf, at exactly the value the despatching site '
   'gave up. Not a receipt: nothing is being bought.')
on conflict (code) do nothing;

-- allows_negative is false on all three, deliberately. A site cannot despatch
-- what it does not have; the two authorised exceptions — a count adjustment
-- and an emergency issue — exist for the cases where the shelf disagrees with
-- the system, and neither of those is a lorry.

-- Both locales the product ships. erp.assert_resource_coverage() reads every
-- erp_ref table with a name_key, so a movement type with no German name fails
-- the build the day it is added, which is the point.
insert into erp_ref.resource (key, locale, value) values
  ('movement.transfer_despatch', 'en', 'Transfer despatch'),
  ('movement.transfer_out',      'en', 'Transfer out'),
  ('movement.transfer_in',       'en', 'Transfer in'),
  ('movement.transfer_despatch', 'de', 'Umlagerung Versand'),
  ('movement.transfer_out',      'de', 'Umlagerungsabgang'),
  ('movement.transfer_in',       'de', 'Umlagerungszugang')
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The place the goods stand while they are on the road
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.ensure_transit_location(p_site_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.site%rowtype;
  v_id     uuid;
begin
  select * into s from erp.site where tenant_id = v_tenant and id = p_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503',
      hint = 'The site does not exist in this organisation.';
  end if;

  select l.id into v_id
    from erp.location l
   where l.tenant_id = v_tenant and l.site_id = p_site_id
     and l.location_type = 'transit'::erp.location_type
     and l.status = 'active' and not l.is_blocked
   order by l.code
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  insert into erp.location (
    tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, p_site_id, 'TRANSIT', 'In transit',
          'transit'::erp.location_type, false, 'active'::erp.record_status)
  on conflict (tenant_id, site_id, code) do nothing;

  select l.id into v_id
    from erp.location l
   where l.tenant_id = v_tenant and l.site_id = p_site_id and l.code = 'TRANSIT';

  if v_id is null then
    raise exception
      'CLOVEERP_NO_TRANSIT_PLACE: % has no place to hold goods that have left '
      'the shelf and not yet arrived', s.code
      using errcode = '23503',
            hint = 'Add a location of kind In transit at this site on the Warehouse layout screen.';
  end if;
  return v_id;
end;
$$;

revoke all on function erp.ensure_transit_location(uuid) from public, anon, authenticated;

comment on function erp.ensure_transit_location is
  'The site''s transit place, made if it has none: not pickable, not '
  'countable, and where stock stands between being loaded and arriving '
  'somewhere else.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A transfer order says where the goods are going
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.document.site_id is where the document belongs — for a transfer, the
-- site despatching. The other end is a second site, so it is a second column
-- with the same composite foreign key, and not a key in attributes: a
-- destination with no referential integrity is a destination that can name
-- another organisation's warehouse.

alter table erp.document add column if not exists destination_site_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conname = 'document_destination_site_fkey') then
    alter table erp.document
      add constraint document_destination_site_fkey
      foreign key (tenant_id, destination_site_id)
      references erp.site (tenant_id, id) on delete restrict;
  end if;
end
$fk$;

create index if not exists document_destination_site
  on erp.document (tenant_id, destination_site_id)
  where destination_site_id is not null;

comment on column erp.document.destination_site_id is
  'Where a transfer order is sending the goods. Null on every other kind of '
  'document: site_id already says where those belong. Read by '
  'erp.despatch_transfer(), erp.receive_transfer() and erp.transfer_orders().';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The value moves, to the penny
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.transfer_cost(
  p_item_id      uuid,
  p_from_site_id uuid,
  p_to_site_id   uuid,
  p_quantity     numeric,
  p_currency     character
) returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  -- NOT v_from and v_to. erp.missing_relation_report() looks for a schema-
  -- qualified name after from, join, update, into or delete from, and its
  -- pattern has no word boundary in front — so a variable whose name ends in
  -- "from", declared as an erp type, reads to it as a table that does not
  -- exist. erp.costing_method is a type, and the check was right to be
  -- suspicious of the shape.
  v_method_out erp.costing_method := erp.costing_method_for(p_item_id, p_from_site_id);
  v_method_in  erp.costing_method := erp.costing_method_for(p_item_id, p_to_site_id);
  ic        erp.item_cost%rowtype;
  r         record;
  v_left    numeric := p_quantity;
  v_take    numeric;
  v_total   bigint := 0;
  v_unit    bigint;
  v_rem     numeric;
  v_last    jsonb;
begin
  if p_quantity <= 0 then
    raise exception 'CLOVEERP_COST_NONPOSITIVE: cannot transfer % units', p_quantity
      using errcode = '23514',
            hint = 'A transfer line carries a quantity greater than nought.';
  end if;

  if v_method_out = 'fifo' and v_method_in = 'fifo' then
    -- The layers move. A lorry does not re-cost what it carries, and it does
    -- not make the goods younger either, so received_at travels with them.
    for r in
      select * from erp.stock_valuation_layer l
       where l.tenant_id = v_tenant and l.item_id = p_item_id
         and l.site_id is not distinct from p_from_site_id
         and l.remaining > 0
       order by l.received_at, l.id
       for update
    loop
      exit when v_left <= 0;
      v_take  := least(v_left, r.remaining);
      v_total := v_total + round(v_take * r.unit_cost_minor)::bigint;

      update erp.stock_valuation_layer
         set remaining = remaining - v_take, updated_at = now()
       where id = r.id;

      insert into erp.stock_valuation_layer (
        tenant_id, item_id, site_id, batch_id, received_at,
        quantity, remaining, unit_cost_minor, currency)
      values (v_tenant, p_item_id, p_to_site_id, r.batch_id, r.received_at,
              v_take, v_take, r.unit_cost_minor, r.currency);

      v_left := v_left - v_take;
    end loop;

    if v_left > 0 then
      raise exception
        'CLOVEERP_NO_COST_LAYERS: % of % units have no FIFO layer to move',
        v_left, p_quantity
        using errcode = '23514',
              hint = 'Stock arrived at the despatching site without a valued '
                     'receipt. Value it with an adjustment before moving it.';
    end if;

    return v_total;
  end if;

  -- Average and standard. What leaves is whatever erp.issue_cost() says leaves
  -- — the exact proportional share of the value on hand, the emptying case,
  -- the negative case, all of it — and the figure it noted is the figure, not
  -- quantity times the unit it rounded for display.
  v_unit := erp.issue_cost(p_item_id, p_from_site_id, p_quantity);

  v_last := nullif(current_setting('erp.last_cost', true), '')::jsonb;
  if v_last is null
     or (v_last ->> 'item')::uuid <> p_item_id
     or (v_last ->> 'site')::uuid is distinct from p_from_site_id
     or (v_last ->> 'quantity')::numeric <> p_quantity then
    raise exception
      'CLOVEERP_TRANSFER_COST_UNKNOWN: erp.issue_cost() did not leave the exact '
      'cost of this issue, so what the other site should be given is a guess'
      using errcode = 'P0001',
            hint = 'erp.note_cost() stamps erp.last_cost; a costing function '
                   'that stopped calling it has to be repaired before a '
                   'transfer can move value exactly.';
  end if;
  v_total := (v_last ->> 'cost')::bigint;

  -- Read, so nothing downstream stamps a movement from it by accident.
  perform set_config('erp.last_cost', '', true);

  if v_method_in = 'fifo' then
    -- The receiving site keeps its value in layers and the despatching site
    -- did not, so a layer is opened for exactly what left. A rate in whole
    -- minor units cannot always say an exact figure over a given quantity, so
    -- where it cannot, the remainder is carried by the units that bear it: the
    -- two layers together are worth precisely v_total and nothing is rounded
    -- away. sum(remaining × unit_cost_minor) is what values them.
    v_unit := floor(v_total::numeric / p_quantity)::bigint;
    v_rem  := v_total - (p_quantity * v_unit);
    if v_rem > 0 then
      insert into erp.stock_valuation_layer (
        tenant_id, item_id, site_id, quantity, remaining, unit_cost_minor, currency)
      values (v_tenant, p_item_id, p_to_site_id,
              p_quantity - v_rem, p_quantity - v_rem, v_unit, p_currency);
      insert into erp.stock_valuation_layer (
        tenant_id, item_id, site_id, quantity, remaining, unit_cost_minor, currency)
      values (v_tenant, p_item_id, p_to_site_id, v_rem, v_rem, v_unit + 1, p_currency);
    else
      insert into erp.stock_valuation_layer (
        tenant_id, item_id, site_id, quantity, remaining, unit_cost_minor, currency)
      values (v_tenant, p_item_id, p_to_site_id,
              p_quantity, p_quantity, v_unit, p_currency);
    end if;
    return v_total;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_to_site_id
   for update;

  if not found then
    insert into erp.item_cost (
      tenant_id, item_id, site_id, method, unit_cost_minor, currency,
      quantity_on_hand, value_minor)
    values (v_tenant, p_item_id, p_to_site_id, v_method_in,
            round(v_total / p_quantity)::bigint, p_currency,
            p_quantity, v_total);
  else
    update erp.item_cost
       set quantity_on_hand = quantity_on_hand + p_quantity,
           value_minor      = value_minor + v_total,
           unit_cost_minor  = case
             -- A standard is a rate somebody set; arriving stock does not
             -- change it. The value on hand is what arrived.
             when v_method_in = 'standard' then unit_cost_minor
             when quantity_on_hand + p_quantity = 0 then unit_cost_minor
             else round((value_minor + v_total) / (quantity_on_hand + p_quantity))::bigint
           end,
           updated_at = now()
     where id = ic.id;
  end if;

  return v_total;
end;
$$;

revoke all on function erp.transfer_cost(uuid, uuid, uuid, numeric, character)
  from public, anon, authenticated;

comment on function erp.transfer_cost is
  'Moves what stock is worth from one site to another and returns the exact '
  'figure moved, in minor units. FIFO to FIFO moves the layers, keeping their '
  'cost and their age; otherwise exactly what erp.issue_cost() says left is '
  'added at the far end, to a value on hand or to a layer as that site keeps '
  'its value. The company''s total does not change, which is what lets a '
  'transfer post no journal.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Raising, despatching and receiving
-- ═════════════════════════════════════════════════════════════════════════════

-- The two ends of a transfer are the same company's, and the checks both legs
-- share are asked once.
create or replace function erp.transfer_document(p_document_id uuid)
returns erp.document
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  v_base   text;
  v_to_ent uuid;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503',
      hint = 'The transfer order does not exist in this organisation.';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  v_base := dt.base_type_code;

  if v_base is distinct from 'transfer_order' then
    raise exception
      'CLOVEERP_NOT_A_TRANSFER_ORDER: % is a %, and only a transfer order moves '
      'stock between sites', d.document_number, coalesce(v_base, 'document')
      using errcode = '23514',
            hint = 'Raise a transfer order on the Site transfers screen.';
  end if;

  if d.site_id is null or d.destination_site_id is null then
    raise exception
      'CLOVEERP_TRANSFER_HAS_NO_DESTINATION: % does not say which site it is '
      'going from and which it is going to', d.document_number
      using errcode = '23502',
            hint = 'Raise the transfer order again naming both sites; a transfer with one end is a write-off.';
  end if;

  if d.site_id = d.destination_site_id then
    raise exception
      'CLOVEERP_TRANSFER_TO_ITSELF: % sends stock from a site to the same site',
      d.document_number
      using errcode = '23514',
            hint = 'To move stock between two places at one site, use a warehouse task rather than a transfer order.';
  end if;

  select s.entity_id into v_to_ent from erp.site s
   where s.tenant_id = v_tenant and s.id = d.destination_site_id;

  if v_to_ent is distinct from d.entity_id then
    raise exception
      'CLOVEERP_TRANSFER_CROSSES_COMPANIES: % moves stock from one company to '
      'another', d.document_number
      using errcode = '23514',
            hint = 'Stock leaving one company for another is a sale at a price, '
                   'not a transfer at cost. Raise a sales order on one side and '
                   'a purchase order on the other.';
  end if;

  return d;
end;
$$;

revoke all on function erp.transfer_document(uuid) from public, anon, authenticated;

comment on function erp.transfer_document is
  'The transfer order behind an identifier, refusing anything that is not one: '
  'not a transfer order, no destination, a destination that is the origin, or '
  'two sites belonging to two companies.';

-- The current state of a document, by code.
create or replace function erp.document_state_code(p_document_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select s.code
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = erp.require_tenant_id()
     and os.object_type = 'document' and os.object_id = p_document_id
$$;

revoke all on function erp.document_state_code(uuid) from public, anon, authenticated;

comment on function erp.document_state_code is
  'What state a document is in, as its code. One answer, read from '
  'erp.object_state, which is where the state engine keeps it.';

-- ── Raising ──────────────────────────────────────────────────────────────────

create or replace function erp.raise_transfer_order(
  p_from_site_id  uuid,
  p_to_site_id    uuid,
  p_lines         jsonb default '[]'::jsonb,
  p_required_date date default null,
  p_reference     text default null
) returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from   erp.site%rowtype;
  v_to     erp.site%rowtype;
  v_id     uuid;
  d        erp.document%rowtype;
  ln       jsonb;
  v_no     integer := 0;
  v_added  integer := 0;
  v_qty    numeric;
begin
  select * into v_from from erp.site where tenant_id = v_tenant and id = p_from_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_from_site_id using errcode = '23503',
      hint = 'The despatching site does not exist in this organisation.';
  end if;
  select * into v_to from erp.site where tenant_id = v_tenant and id = p_to_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_to_site_id using errcode = '23503',
      hint = 'The receiving site does not exist in this organisation.';
  end if;

  if p_from_site_id = p_to_site_id then
    raise exception
      'CLOVEERP_TRANSFER_TO_ITSELF: % sends stock from a site to the same site',
      v_from.code
      using errcode = '23514',
            hint = 'To move stock between two places at one site, use a warehouse task rather than a transfer order.';
  end if;

  if v_to.entity_id is distinct from v_from.entity_id then
    raise exception
      'CLOVEERP_TRANSFER_CROSSES_COMPANIES: % and % belong to two companies',
      v_from.code, v_to.code
      using errcode = '23514',
            hint = 'Stock leaving one company for another is a sale at a price, '
                   'not a transfer at cost. Raise a sales order on one side and '
                   'a purchase order on the other.';
  end if;

  -- erp.open_document asks inventory.move, the permission transfer_order
  -- declares. Both ends are asked, because both warehouses are affected.
  v_id := erp.open_document('transfer_order', null, v_from.entity_id,
                            p_from_site_id, p_reference, p_required_date, null);
  perform erp.authorise('inventory.move', v_from.entity_id, p_to_site_id, null,
                        'document', v_id);

  update erp.document
     set destination_site_id = p_to_site_id, updated_at = now()
   where tenant_id = v_tenant and id = v_id;

  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_no := v_no + 1;
    if coalesce(ln ->> 'item_id', '') = '' and coalesce(ln ->> 'quantity', '') = '' then
      continue;
    end if;
    if coalesce(ln ->> 'item_id', '') = '' then
      raise exception 'CLOVEERP_LINE_NEEDS_ITEM: line % has no product', v_no
        using errcode = '23502',
              hint = 'Choose a product on every line, or remove the line.';
    end if;
    v_qty := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    if v_qty <= 0 then
      raise exception 'CLOVEERP_LINE_NEEDS_QUANTITY: line % has no quantity', v_no
        using errcode = '23514',
              hint = 'Put a quantity greater than nought on every line.';
    end if;

    -- No price. Nothing is being bought or sold; the value is whatever the
    -- despatching site's books already say it is.
    perform erp.add_document_line(v_id, (ln ->> 'item_id')::uuid, v_qty, 0,
                                  nullif(ln ->> 'description', ''), p_required_date);
    v_added := v_added + 1;
  end loop;

  select * into d from erp.document where tenant_id = v_tenant and id = v_id;

  return jsonb_build_object(
    'document_id', v_id,
    'document_number', d.document_number,
    'from_site', v_from.code,
    'to_site', v_to.code,
    'lines', v_added,
    'state', erp.document_state_code(v_id));
end;
$$;

revoke all on function erp.raise_transfer_order(uuid, uuid, jsonb, date, text)
  from public, anon, authenticated;

comment on function erp.raise_transfer_order is
  'Opens a transfer order from one site to another with its lines, in one '
  'transaction. Asks inventory.move at both ends. No prices: a transfer moves '
  'goods at what they already cost.';

-- ── Despatching: off the shelf and onto the lorry ────────────────────────────

create or replace function erp.despatch_transfer(p_document_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  dt        erp.document_type%rowtype;
  v_type    text;
  v_state   text;
  v_transit uuid;
  v_from    uuid;
  v_when    timestamptz;
  ln        record;
  v_n       integer := 0;
  v_qty     numeric := 0;
begin
  d := erp.transfer_document(p_document_id);

  perform erp.authorise('inventory.move', d.entity_id, d.site_id, null,
                        'document', p_document_id);
  perform erp.authorise('inventory.move', d.entity_id, d.destination_site_id, null,
                        'document', p_document_id);

  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'CLOVEERP_TRANSFER_ALREADY_DESPATCHED: % has already left the shelf',
      d.document_number
      using errcode = '23505',
            hint = 'Receive it at the other end, or reverse its movements; a transfer is not despatched twice.';
  end if;

  v_state := erp.document_state_code(p_document_id);
  if v_state not in ('approved', 'issued') then
    raise exception
      'CLOVEERP_TRANSFER_NOT_READY: % is %, and goods are loaded against a '
      'transfer order that has been approved', d.document_number,
      coalesce(v_state, 'in no state at all')
      using errcode = '23514',
            hint = 'Approve the transfer order first. A draft nobody has approved is a plan, not an instruction to a warehouse.';
  end if;

  if v_state = 'approved' then
    perform erp.transition_document(p_document_id, 'issued', 'Loading');
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  v_type := coalesce(dt.stock_movement_type, 'transfer_despatch');

  -- A site kept as one place gets its SITE location before its transit one, so
  -- the goods have somewhere to leave from as well as somewhere to stand.
  perform erp.ensure_site_location(d.site_id);
  v_transit := erp.ensure_transit_location(d.site_id);

  -- The document's own date, the way erp.post_document_stock() reads it, so a
  -- transfer dated last week orders with last week.
  v_when := case when coalesce(d.posting_date, d.document_date) >= current_date
                 then clock_timestamp()
                 else (coalesce(d.posting_date, d.document_date)::timestamp
                       + interval '12 hours') at time zone 'UTC'
            end;

  for ln in
    select l.* from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not l.is_cancelled and l.quantity > 0
     order by l.line_no
  loop
    -- The stock-aware resolver, not the configured bay: goods leave from
    -- wherever they are actually standing. Picking the despatch bay blindly
    -- makes every transfer fail on a site that puts its stock away properly.
    v_from := coalesce(ln.location_id,
                       erp.default_posting_location(d.site_id, 'out'::erp.movement_direction,
                                                    ln.item_id, ln.batch_id, ln.quantity));
    if v_from is null then
      raise exception
        'CLOVEERP_NO_DESPATCH_PLACE: % has nowhere for the goods to leave from',
        d.document_number
        using errcode = '23503',
              hint = 'Give the line a location, or add a despatch location to the site on the Warehouse layout screen.';
    end if;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
      container_id, from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, currency, document_id, document_line_id, occurred_at)
    values (
      v_tenant, d.entity_id, d.site_id, v_type, ln.item_id, ln.batch_id,
      ln.serial_id, ln.container_id,
      v_from, 'available'::erp.stock_status,
      v_transit, 'in_transit'::erp.stock_status,
      ln.quantity,
      coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
      coalesce(d.currency, (select e.base_currency from erp.entity e where e.id = d.entity_id)),
      p_document_id, ln.id, v_when);

    v_n   := v_n + 1;
    v_qty := v_qty + ln.quantity;
  end loop;

  if v_n = 0 then
    raise exception
      'CLOVEERP_TRANSFER_HAS_NO_LINES: % says nothing is being moved',
      d.document_number
      using errcode = '23514',
            hint = 'Add a line saying which product and how much, then despatch it.';
  end if;

  perform erp.transition_document(p_document_id, 'in_transit', 'Despatched');

  return jsonb_build_object(
    'document_id', p_document_id,
    'document_number', d.document_number,
    'lines', v_n,
    'quantity', v_qty,
    'state', erp.document_state_code(p_document_id));
end;
$$;

revoke all on function erp.despatch_transfer(uuid) from public, anon, authenticated;

comment on function erp.despatch_transfer is
  'Takes the goods off the despatching site''s shelves and stands them in that '
  'site''s transit place, where they are still that site''s stock and still '
  'that site''s value, and moves the order to In transit. No value moves and '
  'no journal is posted: the goods have not gone anywhere yet.';

-- ── Arriving: off the lorry and onto the other site's shelf ──────────────────

create or replace function erp.receive_transfer(p_document_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_state  text;
  v_to     uuid;
  v_ccy    char(3);
  v_when   timestamptz;
  m        record;
  v_cost   bigint;
  v_unit   bigint;
  v_moved  bigint := 0;
  v_n      integer := 0;
  v_qty    numeric := 0;
begin
  d := erp.transfer_document(p_document_id);

  perform erp.authorise('inventory.move', d.entity_id, d.site_id, null,
                        'document', p_document_id);
  perform erp.authorise('inventory.move', d.entity_id, d.destination_site_id, null,
                        'document', p_document_id);

  if not exists (select 1 from erp.stock_movement mm
                  where mm.tenant_id = v_tenant and mm.document_id = p_document_id
                    and mm.to_status = 'in_transit') then
    raise exception
      'CLOVEERP_TRANSFER_NOT_DESPATCHED: % has not left the despatching site',
      d.document_number
      using errcode = '23514',
            hint = 'Despatch it first; goods cannot arrive somewhere they were never sent from.';
  end if;

  if exists (select 1 from erp.stock_movement mm
              where mm.tenant_id = v_tenant and mm.document_id = p_document_id
                and mm.movement_type = 'transfer_in') then
    raise exception
      'CLOVEERP_TRANSFER_ALREADY_RECEIVED: % has already arrived',
      d.document_number
      using errcode = '23505',
            hint = 'The goods are on the receiving site''s shelves. Count them if the quantity looks wrong.';
  end if;

  v_state := erp.document_state_code(p_document_id);
  if v_state is distinct from 'in_transit' then
    raise exception
      'CLOVEERP_TRANSFER_NOT_IN_TRANSIT: % is %, so there is nothing on the road '
      'to book in', d.document_number, coalesce(v_state, 'in no state at all')
      using errcode = '23514',
            hint = 'Only a transfer order that has been despatched can be received.';
  end if;

  perform erp.ensure_site_location(d.destination_site_id);
  v_to := erp.default_posting_location(d.destination_site_id, 'in'::erp.movement_direction);
  if v_to is null then
    raise exception
      'CLOVEERP_NO_ARRIVAL_PLACE: the receiving site has nowhere for the goods to go'
      using errcode = '23503',
            hint = 'Add a goods-in location to the receiving site on the Warehouse layout screen.';
  end if;

  v_ccy := coalesce(d.currency,
                    (select e.base_currency from erp.entity e where e.id = d.entity_id));

  v_when := case when coalesce(d.posting_date, d.document_date) >= current_date
                 then clock_timestamp()
                 else (coalesce(d.posting_date, d.document_date)::timestamp
                       + interval '12 hours') at time zone 'UTC'
            end;

  -- One arrival per despatch leg, so batches and serials stay distinct all the
  -- way through.
  for m in
    select mm.* from erp.stock_movement mm
     where mm.tenant_id = v_tenant and mm.document_id = p_document_id
       and mm.to_status = 'in_transit' and not mm.is_reversal
     order by mm.id
  loop
    -- The value leaves one site and arrives at the other in one figure, which
    -- is why the company's total does not change and no journal is needed.
    v_cost := erp.transfer_cost(m.item_id, d.site_id, d.destination_site_id,
                                m.quantity, v_ccy);
    v_unit := round(v_cost / m.quantity)::bigint;

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
      container_id, from_location_id, from_status,
      quantity, uom_id, unit_cost_minor, cost_minor, currency,
      document_id, document_line_id, occurred_at)
    values (
      v_tenant, d.entity_id, d.site_id, 'transfer_out', m.item_id, m.batch_id,
      m.serial_id, m.container_id, m.to_location_id, 'in_transit'::erp.stock_status,
      m.quantity, m.uom_id, v_unit, v_cost, v_ccy,
      p_document_id, m.document_line_id, v_when);

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
      container_id, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, cost_minor, currency,
      document_id, document_line_id, occurred_at)
    values (
      v_tenant, d.entity_id, d.destination_site_id, 'transfer_in', m.item_id,
      m.batch_id, m.serial_id, m.container_id, v_to, 'available'::erp.stock_status,
      m.quantity, m.uom_id, v_unit, v_cost, v_ccy,
      p_document_id, m.document_line_id, v_when);

    v_moved := v_moved + v_cost;
    v_qty   := v_qty + m.quantity;
    v_n     := v_n + 1;
  end loop;

  perform erp.transition_document(p_document_id, 'received', 'Arrived');

  return jsonb_build_object(
    'document_id', p_document_id,
    'document_number', d.document_number,
    'lines', v_n,
    'quantity', v_qty,
    'value_moved_minor', v_moved,
    'currency', v_ccy,
    'state', erp.document_state_code(p_document_id));
end;
$$;

revoke all on function erp.receive_transfer(uuid) from public, anon, authenticated;

comment on function erp.receive_transfer is
  'Books the goods off the lorry and onto the receiving site''s shelves: out '
  'of the despatching site''s transit place and its valuation, into the other '
  'site''s, for exactly the same figure. No profit and loss account moves, '
  'because nothing was bought, sold, lost or found.';

-- ── What the screen reads ────────────────────────────────────────────────────

create or replace function erp.transfer_orders(p_limit integer default 100)
returns table (
  document_id      uuid,
  document_number  text,
  state            text,
  from_site        text,
  to_site          text,
  document_date    date,
  required_date    date,
  lines            integer,
  quantity         numeric,
  in_transit       numeric,
  value_moved_minor bigint,
  currency         text
)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select d.id, d.document_number,
         erp.document_state_code(d.id),
         fs.code, ts.code, d.document_date, d.required_date,
         (select count(*)::integer from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled),
         (select coalesce(sum(l.quantity), 0) from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled),
         (select coalesce(sum(case when m.to_status = 'in_transit' then m.quantity
                                   when m.from_status = 'in_transit' then -m.quantity
                                   else 0 end), 0)
            from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id
             and not m.is_reversal),
         (select coalesce(sum(m.cost_minor), 0)::bigint
            from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id
             and m.movement_type = 'transfer_in' and not m.is_reversal),
         coalesce(d.currency, en.base_currency)::text
    from t
    join erp.document d on d.tenant_id = t.tenant_id
    join erp.entity en on en.tenant_id = d.tenant_id and en.id = d.entity_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.site fs on fs.tenant_id = d.tenant_id and fs.id = d.site_id
    left join erp.site ts on ts.tenant_id = d.tenant_id and ts.id = d.destination_site_id
   where dt.base_type_code = 'transfer_order'
   order by d.document_date desc, d.document_number desc
   limit greatest(coalesce(p_limit, 100), 1)
$$;

revoke all on function erp.transfer_orders(integer) from public, anon, authenticated;

comment on function erp.transfer_orders is
  'Every transfer order with both its sites, what it is moving, how much of '
  'that is on the road right now, and what the receiving site was given for '
  'it. Requires an organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_raise_transfer_order(
  p_from_site_id  uuid,
  p_to_site_id    uuid,
  p_lines         jsonb default '[]'::jsonb,
  p_required_date date default null,
  p_reference     text default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.raise_transfer_order(p_from_site_id, p_to_site_id, p_lines,
                                  p_required_date, p_reference)
$$;

revoke all on function public.erp_raise_transfer_order(uuid, uuid, jsonb, date, text)
  from public, anon;

comment on function public.erp_raise_transfer_order(uuid, uuid, jsonb, date, text) is
  'Raises a transfer order sending stock from one site to another, with its '
  'lines. Asks inventory.move at both ends. Runs as the caller.';

create or replace function public.erp_despatch_transfer(p_document_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.despatch_transfer(p_document_id)
$$;

revoke all on function public.erp_despatch_transfer(uuid) from public, anon;

comment on function public.erp_despatch_transfer(uuid) is
  'Loads an approved transfer order: the goods leave the shelf and stand in '
  'the despatching site''s transit place until they arrive. Asks '
  'inventory.move at both ends. Runs as the caller.';

create or replace function public.erp_receive_transfer(p_document_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.receive_transfer(p_document_id)
$$;

revoke all on function public.erp_receive_transfer(uuid) from public, anon;

comment on function public.erp_receive_transfer(uuid) is
  'Books a transfer in at the receiving site: quantity and value both cross, '
  'for the same figure, with no journal. Asks inventory.move at both ends. '
  'Runs as the caller.';

create or replace function public.erp_transfer_orders(p_limit integer default 100)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
    from erp.transfer_orders(p_limit) x
$$;

revoke all on function public.erp_transfer_orders(integer) from public, anon;

comment on function public.erp_transfer_orders(integer) is
  'Every transfer order with both its sites, what is on the road, and what the '
  'receiving site was given for it. Runs as the caller, so row security '
  'decides what is visible.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_transfer_order', 'erp.raise_transfer_order',
   'Opens a transfer order and its lines under inventory.move, asked at BOTH '
   'sites because a transfer commits two warehouses. It writes erp.document '
   'and erp.document_line only; no stock moves until the order is despatched.'),
  ('erp_despatch_transfer', 'erp.despatch_transfer',
   'Moves an approved transfer order''s goods off the despatching site''s '
   'shelves into that site''s transit place, under inventory.move at both '
   'sites. It writes erp.stock_movement and takes the order to In transit. No '
   'value moves and no journal is posted.'),
  ('erp_receive_transfer', 'erp.receive_transfer',
   'Books a despatched transfer in at the receiving site, under inventory.move '
   'at both sites: it writes the two erp.stock_movement legs that cross the '
   'sites and moves exactly the value that left, through erp.transfer_cost(). '
   'It posts no journal, because a transfer changes no company''s total.')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The generic posting bridge is held off for this one base type
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Deployed body, asserted needle. erp.transition_document() has been patched
-- four times since the file that last defined it whole (20260904870000, in
-- upper case), so it is needled rather than re-emitted.

do $bridge$
declare
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_n   text := E'    if bt.affects_stock\n';
  v_r   text := E'    -- A transfer order moves stock twice, in two sites, at two moments of\n'
             || E'    -- its lifecycle: off the shelf when it is loaded, onto the other\n'
             || E'    -- site''s shelf when it arrives. erp.post_document_stock() writes one\n'
             || E'    -- row, in one site, at the first committed state — which for a\n'
             || E'    -- transfer order is "approved", before anything has been loaded. It\n'
             || E'    -- cannot say what a transfer does, so the transfer says it itself:\n'
             || E'    -- erp.despatch_transfer() and erp.receive_transfer() (20260917130000).\n'
             || E'    if bt.affects_stock and dt.base_type_code <> ''transfer_order''\n';
  v_hits integer;
begin
  if position('transfer_order' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: erp.transition_document() already '
      'mentions transfer_order; this migration would hold the bridge off twice';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: expected the stock bridge once in '
      'erp.transition_document(), found %', v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- The four patches this body already carried are still in it. A re-emission
  -- from any file would have dropped every one of them.
  v_def := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  if position('erp.transition_declares_effect(' in v_def) = 0
     or position('erp.require_document_approval(' in v_def) = 0
     or position('erp.advance_orders_for_receipt(' in v_def) = 0
     or position('erp.advance_orders_for_delivery(' in v_def) = 0
     or position('dt.base_type_code <> ''transfer_order''' in v_def) = 0 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: the rewrite dropped a patch the '
      'body already had, or did not take';
  end if;
end
$bridge$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. A new organisation installs it; an existing one upgrades to it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The three objects, written once and used twice: appended to the inventory
-- installer's change set for organisations configured from here on, and
-- registered as inventory-operations version 4 for organisations that already
-- exist. erp.plan_module_upgrade() skips what an organisation already holds,
-- so an organisation whose base pack already installed the lifecycle takes
-- only the numbering rule and the document type.
--
-- The lifecycle is the base pack's, with one addition: the three transitions
-- OUT OF DRAFT carry inventory.move, the permission that raises a transfer
-- order in the first place. erp.assert_document_create_permissions() refuses a
-- document type "that may be raised by nobody who can then move it", and the
-- pack ships its transitions with no permission at all — so a warehouse could
-- have opened a transfer order and then been unable to approve, cancel or
-- query it. The later steps stay open, as the pack has them: the doors that
-- take them ask inventory.move themselves, at both sites.

create or replace function erp.transfer_order_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'transfer_order', 'payload',
      jsonb_build_object(
        'code', 'transfer_order', 'object_type', 'document', 'name', 'Transfer order',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','approved','name','Approved','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',20),
          jsonb_build_object('code','issued','name','Issued','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',30),
          jsonb_build_object('code','in_transit','name','In transit','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',40),
          jsonb_build_object('code','received','name','Received','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',50),
          jsonb_build_object('code','closed','name','Closed','is_initial',false,'is_terminal',true,'is_committed',true,'sort_order',60),
          jsonb_build_object('code','discrepancy','name','Discrepancy','is_initial',false,'is_terminal',false,'is_committed',false,'sort_order',500),
          jsonb_build_object('code','cancelled','name','Cancelled','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',510)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','approved','name','Approved','from','draft','to','approved','required_permission','inventory.move','sort_order',10),
          jsonb_build_object('code','issued','name','Issued','from','approved','to','issued','sort_order',20),
          jsonb_build_object('code','in_transit','name','In transit','from','issued','to','in_transit','sort_order',30),
          jsonb_build_object('code','received','name','Received','from','in_transit','to','received','sort_order',40),
          jsonb_build_object('code','closed','name','Closed','from','received','to','closed','sort_order',50),
          jsonb_build_object('code','draft_to_discrepancy','name','Discrepancy','from','draft','to','discrepancy','required_permission','inventory.move','sort_order',500),
          jsonb_build_object('code','approved_to_discrepancy','name','Discrepancy','from','approved','to','discrepancy','sort_order',500),
          jsonb_build_object('code','issued_to_discrepancy','name','Discrepancy','from','issued','to','discrepancy','sort_order',500),
          jsonb_build_object('code','in_transit_to_discrepancy','name','Discrepancy','from','in_transit','to','discrepancy','sort_order',500),
          jsonb_build_object('code','received_to_discrepancy','name','Discrepancy','from','received','to','discrepancy','sort_order',500),
          jsonb_build_object('code','discrepancy_to_received','name','Resume at received','from','discrepancy','to','received','sort_order',505),
          jsonb_build_object('code','draft_to_cancelled','name','Cancelled','from','draft','to','cancelled','required_permission','inventory.move','sort_order',510),
          jsonb_build_object('code','approved_to_cancelled','name','Cancelled','from','approved','to','cancelled','sort_order',510),
          jsonb_build_object('code','issued_to_cancelled','name','Cancelled','from','issued','to','cancelled','sort_order',510),
          jsonb_build_object('code','in_transit_to_cancelled','name','Cancelled','from','in_transit','to','cancelled','sort_order',510),
          jsonb_build_object('code','received_to_cancelled','name','Cancelled','from','received','to','cancelled','sort_order',510)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'transfer_order', 'payload',
      jsonb_build_object('code','transfer_order','prefix','TRF-','pad_to',6,
                         'reset_period','yearly','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'transfer_order', 'payload',
      jsonb_build_object('code','transfer_order','base_type','transfer_order',
                         'name','Transfer order','numbering_rule','transfer_order',
                         'state_machine','transfer_order',
                         'stock_movement_type','transfer_despatch',
                         'create_permission','inventory.move')))
$$;

revoke all on function erp.transfer_order_pack_items() from public, anon, authenticated;

comment on function erp.transfer_order_pack_items is
  'The lifecycle, the numbering rule and the document type a transfer order '
  'needs, as change-set items. One definition, read by the installer for new '
  'organisations and by the upgrade register for existing ones, so the two '
  'cannot say different things.';

-- ── The installer, for organisations configured from here on ────────────────
--
-- Deployed body, asserted needle. erp.configure_inventory() has been patched
-- three times since the file that last defined it whole (20260904160000, in
-- upper case); appending an item to the array it hands
-- erp.install_module_config() keeps all three.

do $installer$
declare
  v_def text := pg_get_functiondef(
                  'erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  -- The last item in the array is the consignment_consumption rule that
  -- 20260906143000 appended, and its closing run of brackets closes the
  -- account object, the posting lines, the rule, the item, the item array and
  -- erp.install_module_config() in that order. One bracket fewer leaves the
  -- item array as an expression the transfer order's three can be added to.
  v_n   text := E'''description'',''Owed to the consignor''))))));';
  v_r   text := E'''description'',''Owed to the consignor'')))))\n'
             || E'    || erp.transfer_order_pack_items());';
  v_hits integer;
begin
  if position('transfer_order' in v_def) > 0 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: erp.configure_inventory() already '
      'installs a transfer order; this migration would install it twice';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: expected the consignment rule to '
      'close the item array once in erp.configure_inventory(), found %', v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(
             'erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  if position('erp.transfer_order_pack_items()' in v_def) = 0
     or position('stock.ownership_transferred' in v_def) = 0
     or position('stock.adjusted' in v_def) = 0
     or position('purchase_price_variance' in v_def) = 0 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: the rewrite dropped a patch the '
      'body already had, or did not take';
  end if;
end
$installer$;

-- ── The upgrade register, for organisations that already exist ──────────────

update erp_ref.module_installer
   set current_version = 4,
       description = 'Version 2 (20260906050000) added the stock adjustments account and the '
                     'stock_adjustment posting rule; version 3 (20260906143000) the '
                     'consignment_consumption rule; version 4 (20260917130000) the transfer '
                     'order — its lifecycle, its numbering rule and its document type — so '
                     'stock can move between two sites.'
 where install_code = 'inventory-operations';

insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 4, x.value ->> 'kind', x.value ->> 'key',
       x.value -> 'payload', 120 + (x.ordinality::integer * 10)
  from jsonb_array_elements(erp.transfer_order_pack_items()) with ordinality x(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- ── The demonstration takes it ──────────────────────────────────────────────
--
-- Deployed body, asserted needle: erp.ensure_demo_configuration() has been
-- restated and patched repeatedly, and this arm is the same one
-- 20260916090000 added for finance-posting.

do $demo$
declare
  v_def text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_n   text := E'    v_did := v_did || ''"tax posting"''::jsonb;\n  end if;\n';
  v_r   text := E'    v_did := v_did || ''"tax posting"''::jsonb;\n  end if;\n\n'
             || E'  -- Stock can move between sites (20260917130000). An organisation\n'
             || E'  -- configured before that holds the inventory module without the\n'
             || E'  -- transfer order; the register says what is missing and this takes it.\n'
             || E'  if exists (select 1 from erp.module_installation i\n'
             || E'              where i.tenant_id = p_tenant_id and i.install_code = ''inventory-operations'')\n'
             || E'     and exists (select 1 from erp.plan_module_upgrade(''inventory-operations'')) then\n'
             || E'    perform erp.upgrade_module_configuration(''inventory-operations'');\n'
             || E'    v_did := v_did || ''"site transfers"''::jsonb;\n'
             || E'  end if;\n';
  v_hits integer;
begin
  if position('site transfers' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: erp.ensure_demo_configuration() '
      'already takes the transfer upgrade';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: expected the finance upgrade arm '
      'once in erp.ensure_demo_configuration(), found %', v_hits;
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  if position('"site transfers"' in v_def) = 0
     or position('"tax posting"' in v_def) = 0
     or position('entity_tax_registration' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: the rewrite dropped a patch the '
      'body already had, or did not take';
  end if;
end
$demo$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. What is refused, and what to do about it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_TRANSFER_CROSSES_COMPANIES',
  'Moving stock from a site belonging to one company to a site belonging to another.',
  'A transfer moves goods at what they already cost and posts no journal, which only holds while both ends are on the same set of books. Across two companies the goods leave one balance sheet and arrive on another, and each company''s inventory account would then disagree with the stock it holds. That is a sale at a price, and a price is exactly what a transfer order does not carry.',
  'Raise a sales order from the selling company and a purchase order in the buying one, at whatever the two agree; the goods then move with a value on them and both ledgers stay true.');

select erp.register_refusal('CLOVEERP_TRANSFER_TO_ITSELF',
  'Sending stock from a site to the same site.',
  'A transfer order exists to cross between two sites. Between two places at one site nothing leaves anybody''s books, the valuation does not move, and the whole despatch-and-arrive lifecycle describes a journey that does not happen.',
  'Move it with a warehouse task instead — put-away and replenishment both move stock between places at one site.');

select erp.register_refusal('CLOVEERP_TRANSFER_NOT_READY',
  'Loading goods against a transfer order nobody has approved.',
  'A transfer order commits two warehouses: one gives stock up and the other plans around receiving it. A draft is somebody''s intention, and stock leaving a shelf on an intention is how a warehouse loses count of itself.',
  'Approve the transfer order first, then despatch it.');

select erp.register_refusal('CLOVEERP_TRANSFER_NOT_IN_TRANSIT',
  'Booking in a transfer that is not on the road.',
  'Goods are received at the far end of a journey that has started. A transfer order still in draft, approved or issued has not had anything taken off a shelf, so there is nothing standing in the despatching site''s transit place to book in.',
  'Despatch the transfer order first; that is what takes the goods off the shelf and puts them in transit.');

select erp.register_refusal('CLOVEERP_TRANSFER_NOT_DESPATCHED',
  'Booking in a transfer that never left the despatching site.',
  'The arrival is written against the despatch: one leg out of the transit place for each leg into it, carrying the same batch, the same serial and the same quantity. With no despatch there is nothing to carry.',
  'Despatch the transfer order, then receive it.');

select erp.register_refusal('CLOVEERP_TRANSFER_ALREADY_DESPATCHED',
  'Despatching a transfer order whose goods have already left the shelf.',
  'The stock ledger is append-only and a second despatch would take the same goods off the shelf twice, leaving the despatching site short by the whole transfer and the transit place holding twice what is on the lorry.',
  'Receive it at the other end. If the wrong goods were loaded, reverse the movements and raise a new transfer order.');

select erp.register_refusal('CLOVEERP_TRANSFER_ALREADY_RECEIVED',
  'Booking in a transfer that has already arrived.',
  'The goods are on the receiving site''s shelves and its valuation already carries them. Booking them in again would add the quantity and the value a second time, and the despatching site has nothing left in transit to give.',
  'Count the receiving site if the quantity looks wrong; a count adjustment is how a shelf and a system are made to agree.');

select erp.register_refusal('CLOVEERP_TRANSFER_HAS_NO_DESTINATION',
  'Despatching a transfer order that does not say where the goods are going.',
  'Both ends are the point. A transfer with one end is a write-off at the despatching site and an unexplained receipt at whichever site somebody later decides on.',
  'Raise the transfer order again naming both sites.');

select erp.register_refusal('CLOVEERP_TRANSFER_HAS_NO_LINES',
  'Despatching a transfer order with nothing on it.',
  'A transfer order with no lines names no product and no quantity, so there is nothing for the warehouse to pick and nothing for the other site to expect.',
  'Add a line saying which product and how much, then despatch it.');

select erp.register_refusal('CLOVEERP_NOT_A_TRANSFER_ORDER',
  'Despatching or receiving something that is not a transfer order.',
  'Only a transfer order carries two sites. Every other document belongs to one site and moves stock through the ordinary posting bridge.',
  'Open a transfer order on the Site transfers screen.');

select erp.register_refusal('CLOVEERP_NO_TRANSIT_PLACE',
  'Despatching from a site with nowhere to hold goods that have left the shelf and not yet arrived.',
  'Between being loaded and arriving, the stock is still the despatching site''s and has to stand somewhere a position can be read from. A site whose In transit place is blocked has nowhere for it to stand.',
  'Add a location of kind In transit at that site on the Warehouse layout screen, or unblock the one it has.');

select erp.register_refusal('CLOVEERP_NO_DESPATCH_PLACE',
  'Despatching from a site with no place for goods to leave from.',
  'A movement names where the stock came from. With no despatch location and no location on the line, there is no answer to give.',
  'Give the line a location, or add a despatch location to the site on the Warehouse layout screen.');

select erp.register_refusal('CLOVEERP_NO_ARRIVAL_PLACE',
  'Receiving a transfer at a site with nowhere for the goods to go.',
  'A movement names where the stock went. A site with no goods-in location and no locations at all has no answer to give.',
  'Add a goods-in location to the receiving site on the Warehouse layout screen.');

select erp.register_refusal('CLOVEERP_TRANSFER_COST_UNKNOWN',
  'Moving a transfer''s value when the costing records did not say exactly what the goods were worth.',
  'The receiving site has to be given precisely what the despatching site gave up. A transfer raises no accounting entry, so if the two figures differ by even a penny the company''s stock value changes with nothing to explain it, and the check that holds stock value against the inventory account stops agreeing. The quantity times the unit cost is not precise enough: the unit cost shown is a rounded figure. The exact amount is taken from the costing records instead, and this refusal means they did not give one.',
  'Nothing you can set will put this right: it means the part of Clove ERP that works out what stock cost has stopped answering. Report it. Until it is fixed, move the goods by adjusting the count down at one site and up at the other, and value them there.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The words on the screen
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string on Site transfers, rendered through ui(). ' || v.why
  from (values
    ('Site transfers',
     'The screen where stock is moved from one warehouse to another.'),
    ('Moving stock from one of your warehouses to another. The goods leave the first site''s shelves when they are loaded and stand in that site''s transit place, still its stock and still its value, until they are booked in at the other end. Nothing is bought or sold on the way, so no profit or loss account moves.',
     'Said under the heading, because the whole question people ask about a transfer is where the stock is while it is on the road.'),
    ('Raise and move a transfer',
     'The card holding the three steps of a transfer.'),
    ('A transfer order is approved before anything leaves a shelf, despatched when the lorry is loaded, and received when it arrives. The value crosses at the last step, in one figure, so both sites always add up to what the company holds.',
     'Said under that card, because the order of the three steps is the part that is not obvious.'),
    ('Raise a transfer order',
     'The button that opens a transfer between two sites.'),
    ('Send stock to another site',
     'The dialog heading for raising a transfer order.'),
    ('Both sites must belong to the same company. Nothing moves yet: the order is a draft until it is approved.',
     'Said under that dialog, because a transfer between two companies is a sale and is refused.'),
    ('From site',
     'The site the goods are leaving.'),
    ('Where the goods are now.',
     'Said under the despatching site.'),
    ('To site',
     'The site the goods are going to.'),
    ('Where the goods are going. A different site, and the same company.',
     'Said under the receiving site, because those are the two rules.'),
    ('What is being moved',
     'The grid of products and quantities on a transfer order.'),
    ('One row per product. No prices: a transfer moves goods at what they already cost.',
     'Said under that grid, because people expect to be asked for a price and there is not one.'),
    ('Needed by',
     'When the receiving site wants the goods.'),
    ('Optional. When the other site needs them.',
     'Said under that date.'),
    ('Reference',
     'The despatching site''s own note or consignment number.'),
    ('Optional. A consignment note or your own reference.',
     'Said under that reference.'),
    ('Despatch a transfer',
     'The button that takes the goods off the shelf.'),
    ('Load the goods',
     'The dialog heading for despatching.'),
    ('Takes the goods off the despatching site''s shelves and stands them in that site''s transit place. They are still that site''s stock and still its value until they arrive.',
     'Said under that dialog, because where the stock counts during the journey is exactly what a warehouse needs to know.'),
    ('Transfer order',
     'The transfer order a step is being taken on.'),
    ('Receive a transfer',
     'The button that books the goods in at the other end.'),
    ('Book the goods in',
     'The dialog heading for receiving.'),
    ('Books the goods onto the receiving site''s shelves. The quantity and the value both cross here, for the same figure, so the company holds exactly what it held before.',
     'Said under that dialog, because the value crossing is the thing a transfer is for and the thing nobody sees happen.'),
    ('Transfer orders',
     'The table of transfers.'),
    ('Every transfer with both its sites, what it is moving, how much of that is on the road right now, and what the receiving site was given for it.',
     'Said under that table.'),
    ('No transfers yet. Raise one above to move stock from one of your sites to another.',
     'Said when there are no transfers, because an empty table is otherwise indistinguishable from a broken one.'),
    ('Number',
     'The transfer order''s number.'),
    ('From',
     'The despatching site, as a column heading.'),
    ('To',
     'The receiving site, as a column heading.'),
    ('On the road',
     'How much of the transfer is standing in the despatching site''s transit place.'),
    ('Value moved',
     'What the receiving site was given, in money.'),
    ('Stock moving between your own warehouses: raised, approved, despatched, and booked in when it arrives, with the value crossing at the last step.',
     'The tile''s own sentence on the launchpad.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- The tile's label and its guidance. A tile with no help topic ships with a
-- help button saying there is no guidance for this screen, and
-- src/lib/guidance.test.ts fails for it before that can happen.

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.inventory_transfers', 'en', 'Site transfers', 'inventory',
   'Navigation label for the stock screen that moves goods between two of the organisation''s own sites.')
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic
  (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/inventory/transfers', 'nav.inventory_transfers', 'inventory',
   'Moving stock between two of your own warehouses. The goods leave the first site''s shelves when they are loaded and stand in that site''s transit place — still its stock, still its value, and pickable by nobody — until they are booked in at the other end, where the quantity and the value both cross in one figure.',
   '["Raise a transfer order naming the site the goods are leaving, the site they are going to, and what is being moved. No prices: a transfer moves goods at what they already cost.","Approve it. Nothing leaves a shelf until somebody has, because a transfer commits two warehouses.","Despatch it when the lorry is loaded. The stock comes off the shelf and stands in transit at the despatching site.","Receive it when it arrives. The quantity and the valuation both cross to the other site, for the same figure, and no profit or loss account moves."]',
   'Check the receiving site''s stock on hand after the first transfer: what it gained is exactly what the other site gave up, in both quantity and value.',
   '{erp_raise_transfer_order,erp_despatch_transfer,erp_receive_transfer}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The fixture builds its own two sites and its own product. It does not borrow
-- the demonstration's: a suite that leans on seeded data proves the seed as
-- much as the mechanism, and the last one that did tripped a constraint the
-- demo had already satisfied.

create or replace function erp_test.site_transfer_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_ccy char(3);
  v_a       uuid; v_b uuid; v_c uuid;
  v_a_bulk  uuid; v_b_in uuid; v_c_site uuid;
  v_uom     uuid; v_item uuid;
  v_doc     uuid; v_res jsonb; v_fifo_item uuid; v_fifo_doc uuid;
  v_planned integer;
  v_qty_a   numeric; v_qty_b numeric; v_transit numeric;
  v_val_a   bigint; v_val_b bigint; v_val_a0 bigint; v_total0 bigint; v_total1 bigint;
  v_pl0     bigint; v_pl1 bigint; v_journals integer;
  v_ok      boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-site-transfer', 'Site transfer suite',
                              'admin@zz-site-transfer.test', 'Site Transfer Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f0', 'admin@zz-site-transfer.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f0')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency into v_entity, v_ccy
    from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;

  -- ── 1. An organisation that already exists takes it from the register ────
  --
  -- The demonstration, and every organisation configured before today, holds
  -- the inventory module without the transfer order. Put this one back into
  -- that state — the module at version 3, the document type gone — and take
  -- the upgrade the way an administrator takes it, through the register.
  v_cases := v_cases + 1;
  delete from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.code = 'transfer_order';
  update erp.module_installation i set installer_version = 3
   where i.tenant_id = v_tenant and i.install_code = 'inventory-operations';

  select count(*) into v_planned
    from erp.plan_module_upgrade('inventory-operations') p
   where p.object_kind = 'document_type' and p.object_key = 'transfer_order';
  perform erp.upgrade_module_configuration('inventory-operations');

  case_name := 'an organisation that already exists takes the transfer order from the upgrade register';
  passed := v_planned = 1
        and exists (select 1 from erp.document_type dt
                     where dt.tenant_id = v_tenant and dt.code = 'transfer_order'
                       and dt.base_type_code = 'transfer_order'
                       and dt.state_machine_code = 'transfer_order'
                       and dt.stock_movement_type = 'transfer_despatch'
                       and dt.numbering_rule_id is not null)
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 4;
  detail := format('%s document type(s) planned, organisation now at version %s',
                   v_planned,
                   (select i.installer_version from erp.module_installation i
                     where i.tenant_id = v_tenant and i.install_code = 'inventory-operations'));
  return next;

  -- Two sites of this company, and a third belonging to a second company.
  insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
  values (v_tenant, v_entity, 'ZZ-A', 'Alpha depot', 'warehouse'::erp.site_type, 'GB', 'active'::erp.record_status)
  returning id into v_a;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
  values (v_tenant, v_entity, 'ZZ-B', 'Beta depot', 'warehouse'::erp.site_type, 'GB', 'active'::erp.record_status)
  returning id into v_b;

  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_a, 'ZZ-A-BULK', 'Alpha bulk', 'bulk'::erp.location_type, true, 'active'::erp.record_status)
  returning id into v_a_bulk;
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_a, 'ZZ-A-OUT', 'Alpha despatch', 'despatch'::erp.location_type, false, 'active'::erp.record_status);
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_b, 'ZZ-B-IN', 'Beta goods in', 'receiving'::erp.location_type, false, 'active'::erp.record_status)
  returning id into v_b_in;

  select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;

  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'ZZ-TRF-1', 'Transferable widget', v_uom, 'active'::erp.record_status)
  returning id into v_item;

  -- Fifty units at 500 a unit at site A, arriving as a valued receipt so the
  -- costing store has something to move. No document: this is the opening
  -- position, not a purchase.
  perform erp.receive_cost(v_item, v_a, 50, 500, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code)
  values (v_tenant, v_entity, v_a, 'receipt_no_order', v_item,
          v_a_bulk, 'available'::erp.stock_status, 50, v_uom, 500, v_ccy,
          'OPENING');

  select coalesce(sum(v.value_minor), 0)::bigint into v_total0
    from erp.stock_valuation_report() v;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val_a0
    from erp.stock_valuation_report() v where v.site_id = v_a;

  -- What the profit and loss accounts stood at before any of this.
  select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0)::bigint into v_pl0
    from erp.journal_line jl
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
    join erp.journal j on j.tenant_id = jl.tenant_id and j.id = jl.journal_id
   where jl.tenant_id = v_tenant and j.status = 'posted'
     and a.account_type in ('income'::erp.account_type, 'expense'::erp.account_type);

  -- ── 2. A transfer order is raised between two sites ──────────────────────
  v_cases := v_cases + 1;
  v_res := erp.raise_transfer_order(v_a, v_b,
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 20)));
  v_doc := (v_res ->> 'document_id')::uuid;
  case_name := 'a transfer order names both sites, carries its lines and starts in draft';
  passed := v_doc is not null
        and (v_res ->> 'from_site') = 'ZZ-A' and (v_res ->> 'to_site') = 'ZZ-B'
        and (v_res ->> 'lines')::integer = 1
        and (v_res ->> 'state') = 'draft'
        and (select d.destination_site_id from erp.document d where d.id = v_doc) = v_b;
  detail := format('%s from %s to %s, %s line(s), %s',
                   v_res ->> 'document_number', v_res ->> 'from_site',
                   v_res ->> 'to_site', v_res ->> 'lines', v_res ->> 'state');
  return next;

  -- ── 3. Nothing has moved yet ─────────────────────────────────────────────
  --
  -- Approved is a transfer order's FIRST COMMITTED state, which is where
  -- erp.transition_document() posts the stock side of every other document
  -- that moves stock. Read after the transition, because reading before it
  -- would prove nothing about it.
  v_cases := v_cases + 1;
  perform erp.transition_document(v_doc, 'approved', 'suite');
  select coalesce(sum(b.quantity), 0) into v_qty_a
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_a;
  case_name := 'approving moves no stock: the generic posting bridge is held off at the first committed state';
  passed := v_qty_a = 50
        and not exists (select 1 from erp.stock_movement m
                         where m.tenant_id = v_tenant and m.document_id = v_doc)
        and erp.document_state_code(v_doc) = 'approved';
  detail := format('%s on hand at ZZ-A, %s movement(s) against the order', v_qty_a,
                   (select count(*) from erp.stock_movement m
                     where m.tenant_id = v_tenant and m.document_id = v_doc));
  return next;

  -- ── 4. Despatched: off the shelf, into transit, still at site A ──────────
  v_cases := v_cases + 1;
  v_res := erp.despatch_transfer(v_doc);
  select coalesce(sum(b.quantity), 0) into v_qty_a
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = v_a and b.location_id = v_a_bulk;
  select coalesce(sum(b.quantity), 0) into v_transit
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = v_a
     and b.stock_status = 'in_transit'::erp.stock_status;
  select coalesce(sum(b.quantity), 0) into v_qty_b
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_b;
  case_name := 'despatch takes 20 off the shelf into the despatching site''s transit place, and the receiving site has nothing yet';
  passed := v_qty_a = 30 and v_transit = 20 and v_qty_b = 0
        and (v_res ->> 'state') = 'in_transit';
  detail := format('%s on the shelf at ZZ-A, %s in transit at ZZ-A, %s at ZZ-B, order %s',
                   v_qty_a, v_transit, v_qty_b, v_res ->> 'state');
  return next;

  -- ── 5. In transit, the value is still the despatching site's ─────────────
  v_cases := v_cases + 1;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val_a
    from erp.stock_valuation_report() v where v.site_id = v_a;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val_b
    from erp.stock_valuation_report() v where v.site_id = v_b;
  case_name := 'goods on the road are valued at the site that despatched them, not at nothing';
  passed := v_val_a = v_val_a0 and v_val_b = 0;
  detail := format('ZZ-A %s (was %s), ZZ-B %s', v_val_a, v_val_a0, v_val_b);
  return next;

  -- ── 6. Received: both sites' quantities are right ────────────────────────
  v_cases := v_cases + 1;
  v_res := erp.receive_transfer(v_doc);
  select coalesce(sum(b.quantity), 0) into v_qty_a
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_a;
  select coalesce(sum(b.quantity), 0) into v_qty_b
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_b;
  select coalesce(sum(b.quantity), 0) into v_transit
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.stock_status = 'in_transit'::erp.stock_status;
  case_name := 'after the transfer ZZ-A holds 30, ZZ-B holds 20 in its goods-in place, and nothing is left on the road';
  passed := v_qty_a = 30 and v_qty_b = 20 and v_transit = 0
        and (v_res ->> 'state') = 'received'
        and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
              where b.tenant_id = v_tenant and b.location_id = v_b_in) = 20;
  detail := format('ZZ-A %s, ZZ-B %s, in transit %s, order %s',
                   v_qty_a, v_qty_b, v_transit, v_res ->> 'state');
  return next;

  -- ── 7. The valuation moved between the sites, to the penny ───────────────
  v_cases := v_cases + 1;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val_a
    from erp.stock_valuation_report() v where v.site_id = v_a;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val_b
    from erp.stock_valuation_report() v where v.site_id = v_b;
  case_name := 'the valuation moved from ZZ-A to ZZ-B: 10000 out of 25000, exactly';
  passed := v_val_a = 15000 and v_val_b = 10000
        and (v_res ->> 'value_moved_minor')::bigint = 10000;
  detail := format('ZZ-A %s, ZZ-B %s, %s moved', v_val_a, v_val_b,
                   v_res ->> 'value_moved_minor');
  return next;

  -- ── 8. The company holds exactly what it held ────────────────────────────
  v_cases := v_cases + 1;
  select coalesce(sum(v.value_minor), 0)::bigint into v_total1
    from erp.stock_valuation_report() v;
  case_name := 'the company''s total valuation is unchanged, which is what lets a transfer post no journal';
  passed := v_total1 = v_total0;
  detail := format('%s before, %s after', v_total0, v_total1);
  return next;

  -- ── 9. No profit and loss account moved by a penny ───────────────────────
  v_cases := v_cases + 1;
  select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0)::bigint into v_pl1
    from erp.journal_line jl
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
    join erp.journal j on j.tenant_id = jl.tenant_id and j.id = jl.journal_id
   where jl.tenant_id = v_tenant and j.status = 'posted'
     and a.account_type in ('income'::erp.account_type, 'expense'::erp.account_type);
  select count(*)::integer into v_journals
    from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_doc;
  case_name := 'no profit and loss account moved by a penny, and the transfer raised no journal at all';
  passed := v_pl1 = v_pl0 and v_pl1 = 0 and v_journals = 0;
  detail := format('profit and loss %s before, %s after; %s journal(s) against the order',
                   v_pl0, v_pl1, v_journals);
  return next;

  -- ── 10. Two companies is a sale, not a transfer ───────────────────────────
  v_cases := v_cases + 1;
  insert into erp.entity (tenant_id, code, name, base_currency, status)
  values (v_tenant, 'ZZ2', 'Second company', v_ccy, 'active'::erp.record_status)
  returning id into v_c;
  perform erp.ensure_entity_party(v_c);
  insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
  values (v_tenant, v_c, 'ZZ-C', 'Gamma depot', 'warehouse'::erp.site_type, 'GB', 'active'::erp.record_status)
  returning id into v_c_site;
  begin
    perform erp.raise_transfer_order(v_a, v_c_site,
              jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1)));
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_TRANSFER_CROSSES_COMPANIES%';
    v_msg := left(sqlerrm, 90);
  end;
  case_name := 'stock cannot be transferred from one company to another: that is a sale at a price';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 11. A product costed in layers moves its layers ──────────────────────
  --
  -- The other path through erp.transfer_cost(), and the one where the value
  -- is not a single number to be moved but a stack of receipts. Two receipts
  -- at different prices, so a transfer that took the average would be visibly
  -- wrong: 40 units cost 1200 and the oldest 30 of them cost 800.
  v_cases := v_cases + 1;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'ZZ-TRF-2', 'Layered widget', v_uom, 'active'::erp.record_status)
  returning id into v_fifo_item;

  insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
  values (v_tenant, 'zz_fifo', 'Layered widget in layers', 'fifo'::erp.costing_method,
          v_fifo_item, 'active'::erp.record_status);

  perform erp.receive_cost(v_fifo_item, v_a, 30, 20, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_a, 'receipt_no_order', v_fifo_item,
          v_a_bulk, 'available'::erp.stock_status, 30, v_uom, 20, v_ccy, 'OPENING');
  perform erp.receive_cost(v_fifo_item, v_a, 10, 60, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_a, 'receipt_no_order', v_fifo_item,
          v_a_bulk, 'available'::erp.stock_status, 10, v_uom, 60, v_ccy, 'OPENING');

  select coalesce(sum(v.value_minor), 0)::bigint into v_total0
    from erp.stock_valuation_report() v;

  v_res := erp.raise_transfer_order(v_a, v_b,
             jsonb_build_array(jsonb_build_object('item_id', v_fifo_item, 'quantity', 30)));
  v_fifo_doc := (v_res ->> 'document_id')::uuid;
  perform erp.transition_document(v_fifo_doc, 'approved', 'suite');
  perform erp.despatch_transfer(v_fifo_doc);
  v_res := erp.receive_transfer(v_fifo_doc);

  select coalesce(sum(v.value_minor), 0)::bigint into v_total1
    from erp.stock_valuation_report() v;
  select coalesce(sum(l.remaining * l.unit_cost_minor), 0)::bigint into v_val_b
    from erp.stock_valuation_layer l
   where l.tenant_id = v_tenant and l.item_id = v_fifo_item and l.site_id = v_b;
  select coalesce(sum(l.remaining * l.unit_cost_minor), 0)::bigint into v_val_a
    from erp.stock_valuation_layer l
   where l.tenant_id = v_tenant and l.item_id = v_fifo_item and l.site_id = v_a;

  case_name := 'a product kept in cost layers moves the layers: the oldest 30 at 20 each go, the 10 at 60 stay';
  passed := v_val_b = 600 and v_val_a = 600
        and (v_res ->> 'value_moved_minor')::bigint = 600
        and v_total1 = v_total0;
  detail := format('ZZ-B layers %s, ZZ-A layers %s, %s moved, total %s then %s',
                   v_val_b, v_val_a, v_res ->> 'value_moved_minor', v_total0, v_total1);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 12. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-site-transfer')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000f0');
  detail := 'zz-site-transfer rolled back with both its depots, its transfer and its ledger';
  return next;

  if v_cases <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: site_transfer_suite ran % cases, expected 12', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.site_transfer_suite() from public, anon;

create or replace function erp_test.assert_site_transfer_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _site_transfer on commit drop as
    select * from erp_test.site_transfer_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _site_transfer;
  drop table _site_transfer;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SITE_TRANSFER_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: site_transfer_suite ran % cases, expected 12', v_all;
  end if;
  return format('stock moves between sites: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_site_transfer_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 12. Two suites this one moved the goalposts for
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Both are counts, both were right when they were written, and both are now
-- counting something this migration changed. Neither is silenced: each is
-- narrowed or restated to what its own case name says, in the same migration
-- that made the old number wrong.

-- ── The base pack plans one item fewer ──────────────────────────────────────
--
-- erp_test.starter_pack_acceptance_suite() counts what the base pack plans on
-- a new organisation. The pack ships the transfer order's lifecycle, and so
-- now does the inventory installer — so on an organisation that has installed
-- inventory the pack finds that one already there and plans 346 rather than
-- 347. The advisory count is unchanged: an item already held was already
-- being reported that way.

do $acceptance$
declare
  v_sig text := 'erp_test.starter_pack_acceptance_suite()';
  v_def text := pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure);
  v_n   text := $n$    (res ->> 'items')::integer = 347
$n$;
  v_r   text := $r$    -- 346 since 20260917130000: the inventory installer now ships the
    -- transfer order's lifecycle, so the base pack finds one of its own state
    -- machines already installed and plans one item fewer.
    (res ->> 'items')::integer = 346
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % does not count 347 planned items once', v_sig
      using hint = 'A later migration recounted the base pack. Read the suite and patch its count.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('integer = 346' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % did not take its new count', v_sig
      using hint = 'The replacement did not land. Compare the needle with the suite''s definition.';
  end if;
end
$acceptance$;

-- ── The upgrade plan is no longer all posting rules ─────────────────────────
--
-- erp_test.module_upgrade_suite() checked that the plan holds EVERY registered
-- upgrade item plus one account per company. That was the same arithmetic as
-- "every registered item" only while every registered item was a posting rule,
-- which the fixture deletes before planning so that all of them are offered.
-- Version 4 registers a lifecycle, a numbering rule and a document type, and
-- an organisation configured today already holds some of them — so the planner
-- rightly leaves those out, and the old sum counted them as missing.
--
-- The case is narrowed to what its own name says: the posting rules, and one
-- account per company. That an existing organisation is offered the transfer
-- order it does not hold is proved directly, on its own fixture, by the first
-- case of erp_test.site_transfer_suite().

do $upgrade$
declare
  v_sig text := 'erp_test.module_upgrade_suite()';
  v_def text := pg_get_functiondef('erp_test.module_upgrade_suite()'::regprocedure);
  v_n   text :=
       E'      v_n = (select count(*) from erp_ref.module_upgrade_item ui where ui.install_code = ''inventory-operations'' and ui.to_version > 1)\n'
    || E'          + (select count(*) from erp_ref.module_upgrade_account ua where ua.install_code = ''inventory-operations'' and ua.to_version > 1)\n'
    || E'            * (select count(*) from erp.entity e where e.tenant_id = v_tenant and e.status = ''active'')\n';
  v_r   text :=
       E'      -- Counted per kind since 20260917130000. The register carries kinds\n'
    || E'      -- this fixture does not undo — version 4 registers the transfer\n'
    || E'      -- order''s lifecycle, numbering rule and document type — and an\n'
    || E'      -- organisation that already holds one is rightly not offered it.\n'
    || E'      (select count(*) from erp.plan_module_upgrade(''inventory-operations'') p where p.object_kind = ''posting_rule'')\n'
    || E'        = (select count(*) from erp_ref.module_upgrade_item ui where ui.install_code = ''inventory-operations'' and ui.to_version > 1 and ui.object_kind = ''posting_rule'')\n'
    || E'      and (select count(*) from erp.plan_module_upgrade(''inventory-operations'') p where p.object_kind = ''account'')\n'
    || E'        = (select count(*) from erp_ref.module_upgrade_account ua where ua.install_code = ''inventory-operations'' and ua.to_version > 1)\n'
    || E'          * (select count(*) from erp.entity e where e.tenant_id = v_tenant and e.status = ''active'')\n';
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_MODULE_UPGRADE_SUITE_UNRECOGNISED: % does not sum the whole plan once', v_sig
      using hint = 'Read the suite: its second case is the one that counts what the plan names.';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position(E'p.object_kind = ''posting_rule'')\n        = (select count(*)' in v_def) = 0
     or position('stock_adjustment' in v_def) = 0 then
    raise exception 'CLOVEERP_MODULE_UPGRADE_SUITE_UNRECOGNISED: % did not take the narrowed count', v_sig
      using hint = 'The replacement did not land. Compare the needle with the suite''s definition.';
  end if;
end
$upgrade$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 13. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_site_transfer_suite();
select erp_test.assert_module_upgrade_suite();
select erp_test.assert_starter_pack_acceptance();
select erp_test.assert_plain_words_suite();

select erp.assert_write_only_columns();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_resource_coverage('en');
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_no_dead_configuration();
select erp.assert_isolation();
