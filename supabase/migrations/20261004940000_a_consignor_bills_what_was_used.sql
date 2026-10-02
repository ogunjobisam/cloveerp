set lock_timeout = '30s';

-- =============================================================================
-- 20261004940000  A consignor bills what was used
-- -----------------------------------------------------------------------------
-- The gap 20261004930000 flagged and left: stock a supplier owns, taken into
-- the company's ownership where it stands — consigned stock consumed, a sample
-- bought — posts inventory against goods received not invoiced, and nothing
-- let the supplier's bill clear that credit.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * erp.consume_consignment() wrote its ownership transfer naming no
--     document, priced from "the latest priced document the supplier owns".
--     A bill is matched to an order line (erp.invoice_against()), so the 2100
--     credit had nothing a bill could be matched to, and accrued for ever.
--   * erp.grni_report() read a consignment order's line as open from the day
--     its goods arrived, because the receipt fulfils it — goods that are the
--     supplier's and that the ledger, rightly, holds nothing for. And what was
--     consumed, which the ledger does hold, it never showed. The tile and the
--     account parted both ways; erp.assert_grni_reconciles() names it as its
--     cause (2).
--   * A sample bought (erp.settle_samples(…, 'buy', …)) posted on the day its
--     samples arrived, not the day it was bought, because its movement names
--     the receipt and erp.post_movement_finance() dates a movement by its
--     document. A sample received last month and bought today posted into
--     last month, closed or not.
--   * A sample line carries no price, and the bill's three-way arithmetic
--     reads the line's price: a bill would clear goods received not invoiced
--     at its own figure and match whatever it said.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * Consumption names the receipt line the stock arrived on, first in first
--     out, one movement per line, priced at that line's order line (else the
--     line's own price). A quantity no line explains — stock that arrived
--     before this, an opening balance — is consumed as it was, naming nothing.
--   * The line a bill meets is the order line the receipt line fulfils, or
--     the receipt line itself where there is no order (a consignment received
--     without one, a sample). erp.billed_by_consumption() says which lines are
--     billed by what was used rather than what arrived, and
--     erp.consumed_for_billing() says how much was used, net of reversals.
--   * erp.match_three_way() matches such a line against what was used: the
--     price and quantity tolerances, the exception, its approval chain and the
--     exception queue are the ones every bill meets (spec §7, E3).
--   * erp.grni_report() shows such a line open for what was used and not yet
--     billed, from the day it was first used, and no longer shows consigned
--     goods nobody has used.
--   * erp_bill_from_consumption(supplier, site, through, …, p_lines): the
--     supplier's bill for what was used. Without lines it is a self-billing
--     statement — everything used and not yet billed, at the agreed price.
--     With lines it records the supplier's own figures, and the tolerances
--     say matched or exception. Every line goes through erp.invoice_against(),
--     so the bill clears at the agreed price, the order's invoiced quantity
--     follows and the order closes itself as any order does. One bill is one
--     company in one currency.
--   * erp_bill_from_receipt() refuses a receipt whose goods the supplier
--     owns: billing it would bill everything that arrived, used or not.
--   * A change of owner posts on the day it happened, whatever document it
--     names.
--   * A sample bought records its agreed price on its line, and a later
--     purchase of the same line at another price is refused (owner, 2 October
--     2026).
--
-- No table, document type or state machine is added (docs/spec/
-- p2p-target-flow.md §0, §2), and the six-step path is untouched: consignment
-- and samples are not on it.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * Consumption recorded before this names no line and stays unbillable by
--     this door: it is the residue erp.assert_grni_reconciles() already names
--     as cause (2), waivable at the close, and listed by
--     supabase/ops/20260929_grni_residue.sql.
--   * A draft bill still counts towards the order line's invoiced quantity in
--     the report before it registers, as every bill does.
--
-- Proved by erp_test.consumption_billing_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_NOTHING_CONSUMED_TO_BILL',
  'Billing a supplier for what was used when nothing of theirs has been used and not billed.',
  'A bill for consumption settles what was taken into ownership; with nothing taken, it would raise a payable for goods nobody has.',
  'Consume the consigned stock or buy the sample first, or bill a posted goods receipt instead.');

select erp.register_refusal('CLOVEERP_CONSUMPTION_SPANS_COMPANIES',
  'Billing in one bill what was used by more than one company, or in more than one currency.',
  'A bill is one company''s payable in one currency; one spanning two would post one company''s cost in another''s books.',
  'Name the site, so the bill covers what one company used, and raise another for the rest.');

select erp.register_refusal('CLOVEERP_NOT_BILLED_BY_CONSUMPTION',
  'Billing for consumption a line that is not the supplier''s consigned or sample line.',
  'Only stock the supplier owned and the company used is billed this way; any other line is billed from its receipt.',
  'Choose a line from the supplier''s consignment orders, consignment receipts or samples, or bill the goods receipt.');

select erp.register_refusal('CLOVEERP_BILLED_BY_CONSUMPTION',
  'Billing from its receipt goods the supplier still owns.',
  'Consigned goods and samples are the supplier''s until used; billing what arrived would pay for what nobody has used.',
  'Bill what was used with erp_bill_from_consumption.');

select erp.register_refusal('CLOVEERP_SAMPLE_PRICE_DIFFERS',
  'Buying more of a sample line at a price other than the one it was first bought at.',
  'A sample line is billed at one agreed price; two prices on one line would clear goods received not invoiced at the wrong one.',
  'Buy at the price the line was first bought at, and agree any difference on the supplier''s bill.');

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Which lines are billed by what was used, and how much was
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.billed_by_consumption(p_line uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A line a supplier's bill meets for what was used, not for what arrived
  -- (20261004940000): a consignment order's line, or the line of a receipt the
  -- supplier owns that fulfils no order — consignment received without one,
  -- and samples.
  select exists (
    select 1
      from erp.document_line l
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where l.tenant_id = erp.current_tenant_id() and l.id = p_line
       and ((dt.base_type_code = 'purchase_order' and d.order_behaviour_code = 'consignment')
            or (dt.base_type_code = 'receipt'
                and d.stock_owner_party_id is not null
                and d.stock_owner_party_id = d.party_id
                and not exists (select 1 from erp.document_relation rel
                                 where rel.tenant_id = l.tenant_id and rel.from_line_id = l.id
                                   and rel.relation_kind = 'fulfils'))))
$$;

revoke all on function erp.billed_by_consumption(uuid) from public, anon;

comment on function erp.billed_by_consumption(uuid) is
  'Whether a line is billed for what was used rather than what arrived: a consignment order''s line, or '
  'the line of a receipt the supplier owns that fulfils no order (20261004940000).';

create or replace function erp.consumed_for_billing(p_line uuid, p_through date default null)
returns table (quantity numeric, value_minor bigint, first_on date)
language sql
stable
set search_path = ''
as $$
  -- What of a line was taken into the company's ownership at a price, net of
  -- reversals, through a day (20261004940000). The stock came in on receipt
  -- lines: the line itself when it is one, the receipt lines that fulfil it
  -- when it is an order's. A sample kept free changes owner at nothing and is
  -- not here, as nothing is billed for it.
  with rl as (
    select l.id, l.document_id
      from erp.document_line l
     where l.tenant_id = erp.current_tenant_id() and l.id = p_line
    union
    select rel.from_line_id, rel.from_document_id
      from erp.document_relation rel
     where rel.tenant_id = erp.current_tenant_id() and rel.to_line_id = p_line
       and rel.relation_kind = 'fulfils' and rel.from_line_id is not null
  ), m as (
    select case when mv.is_reversal then -1 else 1 end as sign,
           mv.quantity,
           abs(coalesce(mv.cost_minor, round(mv.quantity * mv.unit_cost_minor)::bigint, 0)) as cost,
           (mv.occurred_at at time zone erp.local_timezone(mv.site_id))::date as on_day
      from rl
      join erp.stock_movement mv
        on mv.tenant_id = erp.current_tenant_id()
       and mv.document_id = rl.document_id
       and mv.document_line_id = rl.id
     where mv.movement_type = 'ownership_transfer'
       and coalesce(mv.cost_minor, round(mv.quantity * mv.unit_cost_minor)::bigint, 0) <> 0
  )
  select coalesce(sum(m.sign * m.quantity), 0)::numeric,
         coalesce(sum(m.sign * m.cost), 0)::bigint,
         min(m.on_day) filter (where m.sign > 0)
    from m
   where p_through is null or m.on_day <= p_through
$$;

revoke all on function erp.consumed_for_billing(uuid, date) from public, anon;

comment on function erp.consumed_for_billing(uuid, date) is
  'What of a consignment order''s line, a supplier-owned receipt''s line or a sample line was taken into '
  'the company''s ownership at a price, net of reversals, through a day: the quantity, its value and the '
  'first day (20261004940000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. A change of owner posts on the day it happened
-- ═════════════════════════════════════════════════════════════════════════════

do $dated$
declare
  v_sig constant text := 'erp.post_movement_finance(bigint)';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$   where dd.tenant_id = v_tenant and dd.id = m.document_id;
$o$;
  v_new constant text := $n$   where dd.tenant_id = v_tenant and dd.id = m.document_id
     -- Except a change of owner (20261004940000): it names the receipt the
     -- stock arrived on, and happened when it happened, not when that arrived.
     and m.movement_type <> 'ownership_transfer';
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % dates by its document % time(s), not once', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$dated$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Consumption names the line the stock arrived on
-- ═════════════════════════════════════════════════════════════════════════════

do $check$
declare v_def text := pg_get_functiondef('erp.consume_consignment(uuid,uuid,uuid,numeric,uuid,uuid,text)'::regprocedure);
begin
  if position('The price the consignor will invoice' in v_def) = 0
     or position('document_line_id' in v_def) > 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.consume_consignment() is not the 20260906143000 body this migration restates';
  end if;
end
$check$;

create or replace function erp.consume_consignment(
  p_item_id uuid, p_site_id uuid, p_location_id uuid, p_quantity numeric,
  p_supplier_party_id uuid, p_batch_id uuid default null, p_reason text default 'consumed')
returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_entity  uuid;
  v_company uuid;
  v_held    numeric;
  v_left    numeric;
  v_take    numeric;
  v_price   bigint;
  v_ccy     char(3);
  v_unit    bigint;
  v_uom     uuid;
  v_id      bigint;
  v_first   bigint;
  r         record;
begin
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
  if v_entity is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_id
      using errcode = '23503', hint = 'erp_sites() lists the sites.';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'CLOVEERP_QUANTITY_NONPOSITIVE: nothing is consumed by %', p_quantity
      using errcode = '23514', hint = 'Consume a positive quantity.';
  end if;

  perform erp.authorise('inventory.adjust', v_entity, p_site_id, null, 'item', p_item_id);

  v_company := erp.entity_party_for_site(p_site_id);
  if p_supplier_party_id = v_company then
    raise exception 'CLOVEERP_NOT_CONSIGNED_HERE: the company already owns its own stock'
      using errcode = '23514', hint = 'Name the supplier who owns the consigned position.';
  end if;

  select coalesce(sum(b.quantity), 0) into v_held
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.site_id = p_site_id and b.location_id = p_location_id
     and b.item_id = p_item_id and b.batch_id is not distinct from p_batch_id
     and b.owner_party_id = p_supplier_party_id and b.custody_party_id = v_company
     and b.stock_status = 'available';
  if v_held < p_quantity then
    raise exception 'CLOVEERP_NOT_CONSIGNED_HERE: the supplier owns % of this item here and % was asked for', v_held, p_quantity
      using errcode = '23514',
            hint = 'erp_stock_position() shows the positions by owner; consume what the supplier''s position holds at this location.';
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = p_item_id;
  v_left := p_quantity;

  -- What the supplier's bill will meet (20261004940000): the receipt lines
  -- the stock arrived on at this site, oldest first, each for what of it is
  -- not yet used or sent back, priced at the order line it fulfils, else at
  -- its own price. Samples are settled, not consumed, and are left alone.
  for r in
    select l.id as line_id, d.id as document_id,
           coalesce(nullif(ol.unit_price_minor, 0), nullif(l.unit_price_minor, 0)) as price,
           coalesce(ol.currency, l.currency, d.currency) as currency,
           l.quantity - coalesce((
             select sum(case when mv.is_reversal then -mv.quantity else mv.quantity end)
               from erp.stock_movement mv
              where mv.tenant_id = v_tenant and mv.document_id = d.id and mv.document_line_id = l.id
                and mv.movement_type in ('ownership_transfer', 'return_to_supplier')), 0) as unused
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id
      left join lateral (
        select x.unit_price_minor, x.currency
          from erp.document_relation rel
          join erp.document_line x on x.tenant_id = rel.tenant_id and x.id = rel.to_line_id
         where rel.tenant_id = l.tenant_id and rel.from_line_id = l.id and rel.relation_kind = 'fulfils'
         limit 1) ol on true
     where d.tenant_id = v_tenant
       and dt.base_type_code = 'receipt'
       and d.site_id = p_site_id
       and d.stock_owner_party_id = p_supplier_party_id
       and d.party_id = p_supplier_party_id
       and not coalesce(d.is_cancelled, false)
       and not coalesce(l.is_cancelled, false)
       and l.item_id = p_item_id
       and l.batch_id is not distinct from p_batch_id
       and not erp.is_sample_receipt(d.id)
       and erp.object_current_state('document', d.id) = 'posted'
     order by d.document_date, d.created_at, l.line_no
  loop
    exit when v_left <= 0;
    continue when r.unused <= 0 or r.price is null;
    v_take := least(v_left, r.unused);

    -- The company receives the stock into its books at the price agreed for it.
    v_unit := erp.receive_cost(p_item_id, p_site_id, v_take, r.price, r.currency, p_batch_id, null);

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code,
      owner_party_id, custody_party_id, to_owner_party_id, document_id, document_line_id)
    values (v_tenant, v_entity, p_site_id, 'ownership_transfer', p_item_id, p_batch_id,
            p_location_id, 'available', p_location_id, 'available',
            v_take, v_uom, v_unit, r.currency, left(coalesce(p_reason, 'consumed'), 64),
            p_supplier_party_id, v_company, v_company, r.document_id, r.line_id)
    returning id into v_id;

    perform erp.post_movement_finance(v_id);
    v_first := coalesce(v_first, v_id);
    v_left := v_left - v_take;
  end loop;

  if v_left > 0 then
    -- What no receipt line explains: stock that arrived before consumption
    -- named its line, or an opening balance. Consumed as it always was.
    select l.unit_price_minor, coalesce(l.currency, d.currency) into v_price, v_ccy
      from erp.document d
      join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id
     where d.tenant_id = v_tenant and d.stock_owner_party_id = p_supplier_party_id
       and l.item_id = p_item_id and (p_batch_id is null or l.batch_id = p_batch_id)
       and coalesce(l.unit_price_minor, 0) > 0
     order by d.document_date desc, l.line_no desc limit 1;
    if v_price is null then
      select rp.amount_minor, rp.currency into v_price, v_ccy
        from erp.resolve_purchase_price(p_item_id, p_supplier_party_id, v_left, current_date, p_site_id) rp;
    end if;
    if v_price is null then
      raise exception 'CLOVEERP_CONSIGNMENT_PRICE_UNKNOWN: nothing says what the supplier charges for this item'
        using errcode = '23514',
              hint = 'Receive the stock against a priced consignment order, or load a purchase price for the supplier; the consumption posts at that price.';
    end if;

    v_unit := erp.receive_cost(p_item_id, p_site_id, v_left, v_price, v_ccy, p_batch_id, null);

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code,
      owner_party_id, custody_party_id, to_owner_party_id)
    values (v_tenant, v_entity, p_site_id, 'ownership_transfer', p_item_id, p_batch_id,
            p_location_id, 'available', p_location_id, 'available',
            v_left, v_uom, v_unit, v_ccy, left(coalesce(p_reason, 'consumed'), 64),
            p_supplier_party_id, v_company, v_company)
    returning id into v_id;

    perform erp.post_movement_finance(v_id);
    v_first := coalesce(v_first, v_id);
  end if;

  return v_first;
end;
$$;

revoke all on function erp.consume_consignment(uuid, uuid, uuid, numeric, uuid, uuid, text) from public, anon;

comment on function erp.consume_consignment(uuid, uuid, uuid, numeric, uuid, uuid, text) is
  'Consigned stock taken into the company''s ownership where it stands: the '
  'supplier''s position becomes the company''s, costed as a receipt, and posted — '
  'inventory against goods received not invoiced — because the supplier will '
  'invoice what was used. Each movement names the receipt line the stock arrived '
  'on, oldest first, at the price of the order line it fulfils, so the supplier''s '
  'bill can meet it (erp_bill_from_consumption, 20261004940000); what no line '
  'explains is consumed naming none. Returns the first movement.';

-- ═════════════════════════════════════════════════════════════════════════════
-- E. A sample bought keeps its price on its line
-- ═════════════════════════════════════════════════════════════════════════════

do $sample$
declare
  v_sig constant text := 'erp.settle_samples(uuid,text,numeric,bigint,text)';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    v_price := case when v_outcome = 'buy' then p_price_minor else 0 end;
$o$;
  v_new constant text := $n$    v_price := case when v_outcome = 'buy' then p_price_minor else 0 end;

    -- The price the supplier's bill is matched against (20261004940000): the
    -- line's, recorded as it is first bought, and the same for every purchase
    -- of it after.
    if v_outcome = 'buy' then
      if coalesce(l.unit_price_minor, 0) = 0 then
        update erp.document_line set unit_price_minor = p_price_minor, updated_at = now()
         where tenant_id = v_tenant and id = l.id;
      elsif l.unit_price_minor <> p_price_minor then
        raise exception 'CLOVEERP_SAMPLE_PRICE_DIFFERS: % was bought at % and % was asked',
          coalesce((select i.code from erp.item i where i.id = l.item_id), 'the sample'),
          l.unit_price_minor, p_price_minor
          using errcode = '23514',
                hint = 'Buy at the price the line was first bought at, and agree any difference on the supplier''s bill.';
      end if;
    end if;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % prices the outcome % time(s), not once', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$sample$;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The match reads what was used
-- ═════════════════════════════════════════════════════════════════════════════

do $match$
declare
  v_sig constant text := 'erp.match_three_way(uuid)';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_base := case
              when erp.procurement_policy(d.entity_id, d.site_id) ->> 'invoice_match_mode' = 'two_way'$o$;
  v_new constant text := $n$  v_base := case
              -- Stock the supplier owned until the company used it is billed
              -- for what was used (20261004940000), whatever arrived.
              when erp.billed_by_consumption(ol.id)
                then (select c.quantity from erp.consumed_for_billing(ol.id) c)
              when erp.procurement_policy(d.entity_id, d.site_id) ->> 'invoice_match_mode' = 'two_way'$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % chooses its base % time(s), not once', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$match$;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. A receipt the supplier owns is not billed from the receipt
-- ═════════════════════════════════════════════════════════════════════════════

do $receipt$
declare
  v_sig constant text := 'erp.bill_from_receipt(uuid,text,date,date,boolean,bigint,text)';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform erp.authorise('procurement.match', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);
$o$;
  v_new constant text := $n$  perform erp.authorise('procurement.match', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);

  -- Goods the supplier owns are billed for what was used (20261004940000);
  -- billed from here, everything that arrived would be paid for.
  if rd.stock_owner_party_id is not null then
    raise exception 'CLOVEERP_BILLED_BY_CONSUMPTION: % brought in goods the supplier owns; they are billed for what was used',
      rd.document_number
      using errcode = '23514',
            hint = 'Bill what was used with erp_bill_from_consumption.';
  end if;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % authorises % time(s), not once', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receipt$;

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The report shows what was used and not billed
-- ═════════════════════════════════════════════════════════════════════════════

do $report$
declare
  v_def  text := pg_get_functiondef('erp.grni_report()'::regprocedure);
begin
  if position('What has gone back. Counted from committed credit notes only' in v_def) = 0
     or position('erp.consumed_for_billing' in v_def) > 0
     or position($p$dt.base_type_code = 'purchase_order'$p$ in v_def) = 0 then
    raise exception 'CLOVEERP_GRNI_REPORT_UNRECOGNISED: erp.grni_report() is not the 20260918700000 body this migration replaces';
  end if;
end
$report$;

create or replace function erp.grni_report()
returns table (order_line_id uuid, order_number text, party_name text,
               item_code text, received_quantity numeric, invoiced_quantity numeric,
               open_quantity numeric, open_value_minor bigint,
               received_on date, age_days integer, bucket text)
language sql
stable
security invoker
set search_path = ''
as $$
  with lines as (
    select ol.id, d.document_number, p.name as party_name, i.code as item_code,
           -- A consignment order's goods are the supplier's until used, and
           -- what was used is what the ledger holds (20261004940000).
           case when d.order_behaviour_code = 'consignment'
                then (select c.quantity from erp.consumed_for_billing(ol.id) c)
                else coalesce(ol.quantity_fulfilled, 0)
           end as recvd_gross,
           -- What has gone back. Counted from committed credit notes only: the
           -- relations are written when the note is raised and the journal is
           -- raised when it is issued, so a draft that has posted nothing must
           -- take nothing out of the report or the report would run ahead of
           -- the ledger. A customer return reaches a sales order line and is
           -- filtered out with the rest of them by the base type below.
           -- Consigned goods sent back were never ours and never accrued.
           case when d.order_behaviour_code = 'consignment' then 0
                else coalesce((
             select sum(rr.quantity)
               from erp.document_relation rr
               join erp.document_relation fr
                 on fr.tenant_id = rr.tenant_id
                and fr.from_line_id = rr.to_line_id
                and fr.relation_kind = 'fulfils'
                and fr.to_line_id = ol.id
               join erp.document cn
                 on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
               join erp.object_state os
                 on os.tenant_id = cn.tenant_id
                and os.object_type = 'document' and os.object_id = cn.id
               join erp.state st on st.id = os.current_state_id
              where rr.tenant_id = ol.tenant_id
                and rr.relation_kind = 'returns'
                and rr.to_line_id is not null
                and st.is_committed
                and not coalesce(cn.is_cancelled, false)), 0)
           end as returned,
           coalesce(ol.quantity_invoiced, 0) as invd,
           ol.unit_price_minor,
           case when d.order_behaviour_code = 'consignment'
                then (select c.first_on from erp.consumed_for_billing(ol.id) c)
                else (select min(rd.document_date)
                        from erp.document_relation rel
                        join erp.document rd on rd.id = rel.from_document_id
                        join erp.document_type rdt on rdt.id = rd.document_type_id
                       where rel.to_line_id = ol.id and rdt.base_type_code = 'receipt')
           end as received_on
      from erp.document_line ol
      join erp.document d on d.id = ol.document_id
      join erp.document_type dt on dt.id = d.document_type_id
      left join erp.party p on p.id = d.party_id
      left join erp.item i on i.id = ol.item_id
     where ol.tenant_id = erp.current_tenant_id()
       and dt.base_type_code = 'purchase_order'
       and not ol.is_cancelled
       -- The cheap test first, and it loses nothing: a line whose gross receipts
       -- do not exceed what has been billed cannot be open once what went back
       -- is taken off as well, and what was used of a consignment never
       -- exceeds what arrived.
       and coalesce(ol.quantity_fulfilled, 0) > coalesce(ol.quantity_invoiced, 0)
    union all
    -- The supplier's goods that came with no order — consignment received
    -- without one, samples — open for what was used and not billed, at the
    -- line's agreed price (20261004940000).
    select l.id, d.document_number, p.name, i.code,
           c.quantity, 0, coalesce(l.quantity_invoiced, 0), l.unit_price_minor, c.first_on
      from erp.document_line l
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.party p on p.id = d.party_id
      left join erp.item i on i.id = l.item_id
      cross join lateral erp.consumed_for_billing(l.id) c
     where l.tenant_id = erp.current_tenant_id()
       and d.tenant_id = erp.current_tenant_id()
       and dt.base_type_code = 'receipt'
       and d.stock_owner_party_id is not null
       and d.stock_owner_party_id = d.party_id
       and not coalesce(l.is_cancelled, false)
       and not coalesce(d.is_cancelled, false)
       and not exists (select 1 from erp.document_relation rel
                        where rel.tenant_id = l.tenant_id and rel.from_line_id = l.id
                          and rel.relation_kind = 'fulfils')
       and c.quantity > coalesce(l.quantity_invoiced, 0)
  )
  select id, document_number, party_name, item_code,
         recvd_gross - returned, invd,
         (recvd_gross - returned) - invd,
         round(((recvd_gross - returned) - invd) * unit_price_minor)::bigint,
         received_on,
         (current_date - received_on)::integer,
         case
           when received_on is null then 'unknown'
           when current_date - received_on <= 30 then '0-30'
           when current_date - received_on <= 60 then '31-60'
           when current_date - received_on <= 90 then '61-90'
           else '90+'
         end
    from lines
   where recvd_gross - returned > invd
   order by received_on nulls last
$$;

comment on function erp.grni_report() is
  'Spec 5.3: goods-received-not-invoiced with ageing. What has arrived, has not '
  'gone back, and has not been billed, oldest first — an old balance is either '
  'an invoice nobody sent or a receipt that never happened, and both are worth '
  'knowing about. Returns to a supplier are taken off what arrived from the day '
  'their credit note is issued (20260918700000), so the report and the accrual '
  'account answer the same question. Goods the supplier owns — a consignment '
  'order''s, consignment received without an order, samples — are open for what '
  'was used and not billed, from the day first used (20261004940000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- I. The bill for what was used
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.bill_from_consumption(
  p_supplier uuid, p_site_id uuid default null, p_through date default null,
  p_their_reference text default null, p_invoice_date date default null, p_due_date date default null,
  p_lines jsonb default null, p_register boolean default true,
  p_tax_minor bigint default null, p_tax_code text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_date   date := coalesce(p_invoice_date, current_date);
  v_cands  jsonb;
  v_pick   jsonb;
  v_entity uuid;
  v_site   uuid;
  v_ccy    char(3);
  v_inv    uuid;
  v_name   text;
  e        jsonb;
  r        record;
begin
  -- The supplier's lines billed for what was used (20261004940000), each with
  -- what was used through the day and what is already on a bill.
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_id', x.line_id, 'entity_id', x.entity_id, 'site_id', x.site_id,
           'currency', x.currency, 'open', x.consumed - x.billed)), '[]'::jsonb)
    into v_cands
    from (
      select b.id as line_id, d.entity_id, d.site_id, coalesce(b.currency, d.currency) as currency,
             c.quantity as consumed,
             coalesce((
               select sum(rel.quantity)
                 from erp.document_relation rel
                 join erp.document bd on bd.tenant_id = rel.tenant_id and bd.id = rel.from_document_id
                where rel.tenant_id = v_tenant and rel.to_line_id = b.id
                  and rel.relation_kind = 'invoices'
                  and not coalesce(bd.is_cancelled, false)
                  and erp.document_is_purchase_bill(bd.id)), 0) as billed
        from erp.document_line b
        join erp.document d on d.tenant_id = b.tenant_id and d.id = b.document_id
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        cross join lateral erp.consumed_for_billing(b.id, p_through) c
       where b.tenant_id = v_tenant
         and d.party_id = p_supplier
         and not coalesce(b.is_cancelled, false)
         and not coalesce(d.is_cancelled, false)
         and (p_site_id is null or d.site_id = p_site_id)
         and ((dt.base_type_code = 'purchase_order' and d.order_behaviour_code = 'consignment')
              or (dt.base_type_code = 'receipt' and d.stock_owner_party_id is not null))
         and erp.billed_by_consumption(b.id)) x;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    -- Self-billing: everything used and not yet billed, at the agreed price.
    select coalesce(jsonb_agg(c || jsonb_build_object('quantity', c -> 'open')), '[]'::jsonb)
      into v_pick
      from jsonb_array_elements(v_cands) c
     where (c ->> 'open')::numeric > 0;
  else
    -- The supplier's own figures: each line must be one of theirs billed this
    -- way; whether the figures agree is the match's to say.
    v_pick := '[]'::jsonb;
    for e in select x from jsonb_array_elements(p_lines) x loop
      select c into r from jsonb_array_elements(v_cands) c
       where c ->> 'line_id' = e ->> 'line_id';
      if not found then
        raise exception 'CLOVEERP_NOT_BILLED_BY_CONSUMPTION: % is not a line of this supplier''s billed for what was used',
          coalesce(e ->> 'line_id', 'nothing')
          using errcode = '23503',
                hint = 'Choose a line from the supplier''s consignment orders, consignment receipts or samples, or bill the goods receipt.';
      end if;
      if coalesce((e ->> 'quantity')::numeric, 0) <= 0 then
        raise exception 'CLOVEERP_QUANTITY_NONPOSITIVE: nothing is billed by %', coalesce(e ->> 'quantity', 'nothing')
          using errcode = '23514', hint = 'Bill a positive quantity on each line.';
      end if;
      v_pick := v_pick || jsonb_build_array(r.c || jsonb_build_object(
                  'quantity', (e ->> 'quantity')::numeric,
                  'price', e -> 'unit_price_minor'));
    end loop;
  end if;

  if jsonb_array_length(v_pick) = 0 then
    select pa.name into v_name from erp.party pa where pa.tenant_id = v_tenant and pa.id = p_supplier;
    raise exception 'CLOVEERP_NOTHING_CONSUMED_TO_BILL: nothing of %''s has been used and not billed',
      coalesce(v_name, p_supplier::text)
      using errcode = '23514',
            hint = 'Consume the consigned stock or buy the sample first, or bill a posted goods receipt instead.';
  end if;

  if (select count(distinct (c ->> 'entity_id', c ->> 'currency')) from jsonb_array_elements(v_pick) c) > 1 then
    raise exception 'CLOVEERP_CONSUMPTION_SPANS_COMPANIES: what was used belongs to more than one company or currency'
      using errcode = '23514',
            hint = 'Name the site, so the bill covers what one company used, and raise another for the rest.';
  end if;

  select (c ->> 'entity_id')::uuid, c ->> 'currency' into v_entity, v_ccy
    from jsonb_array_elements(v_pick) c limit 1;
  v_site := coalesce(p_site_id,
                     (select min(c ->> 'site_id')::uuid from jsonb_array_elements(v_pick) c
                      having count(distinct c ->> 'site_id') = 1));

  perform erp.authorise('procurement.match', v_entity, v_site, null, 'party', p_supplier);

  v_inv := erp.open_document('purchase_invoice', p_supplier, v_entity, v_site,
                             p_their_reference, null, v_ccy);

  update erp.document
     set document_date = v_date,
         due_date = coalesce(p_due_date, v_date + 30),
         notes = coalesce(notes, case when p_through is null then 'Billed for what was used'
                                      else format('Billed for what was used through %s', p_through) end),
         updated_at = now()
   where id = v_inv;

  -- Every line through the one route every bill takes: the order's invoiced
  -- quantity follows, the bill clears at the agreed price, and the match
  -- reads what was used.
  for e in select x from jsonb_array_elements(v_pick) x order by x ->> 'line_id' loop
    perform erp.invoice_against(v_inv, (e ->> 'line_id')::uuid, (e ->> 'quantity')::numeric,
                                nullif(e ->> 'price', '')::bigint);
  end loop;

  -- Stated before the register, as erp.bill_from_receipt() does (20260922170000).
  if p_tax_minor is not null then
    perform erp.state_supplier_tax(v_inv, p_tax_minor, p_tax_code, 'billed for what was used');
  end if;

  if coalesce(p_register, true) then
    perform erp.transition_document(v_inv, 'register', 'billed for what was used');
  end if;

  return v_inv;
end;
$$;

revoke all on function erp.bill_from_consumption(uuid, uuid, date, text, date, date, jsonb, boolean, bigint, text) from public, anon;

comment on function erp.bill_from_consumption(uuid, uuid, date, text, date, date, jsonb, boolean, bigint, text) is
  'The supplier''s bill for what was used of stock they owned — consigned stock consumed, samples bought '
  '(20261004940000). Without lines, everything used and not billed at the agreed price; with lines, the '
  'supplier''s own figures, matched against what was used within the procurement tolerances. One company, '
  'one currency. Authorises procurement.match for the company.';

create or replace function public.erp_bill_from_consumption(
  p_supplier uuid, p_site_id uuid default null, p_through date default null,
  p_their_reference text default null, p_invoice_date date default null, p_due_date date default null,
  p_lines jsonb default null, p_tax_minor bigint default null, p_tax_code text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_id uuid;
begin
  v_id := erp.bill_from_consumption(p_supplier, p_site_id, p_through, p_their_reference, p_invoice_date,
                                    p_due_date, p_lines, true, p_tax_minor, p_tax_code);
  return (select jsonb_build_object(
                   'document_id', d.id, 'document_number', d.document_number,
                   'state', erp.object_current_state('document', d.id),
                   'due_date', d.due_date,
                   'lines', (select count(*) from erp.document_line l where l.document_id = d.id),
                   'value_minor', erp.document_value_minor(d.id),
                   'tax_minor', erp.document_tax_minor(d.id),
                   -- Open differences on the lines this bill invoices, by the
                   -- line: the exception names the latest bill on its line,
                   -- which two bills raised in one transaction tie on.
                   'exceptions', (select count(*) from erp.match_exception x
                                   where x.tenant_id = d.tenant_id and x.resolved_at is null
                                     and x.order_line_id in (
                                       select rel.to_line_id from erp.document_relation rel
                                        where rel.tenant_id = d.tenant_id and rel.from_document_id = d.id
                                          and rel.relation_kind = 'invoices')))
            from erp.document d where d.id = v_id);
end;
$$;

revoke all on function public.erp_bill_from_consumption(uuid, uuid, date, text, date, date, jsonb, bigint, text) from public, anon;
grant execute on function public.erp_bill_from_consumption(uuid, uuid, date, text, date, date, jsonb, bigint, text) to authenticated, service_role;

comment on function public.erp_bill_from_consumption(uuid, uuid, date, text, date, date, jsonb, bigint, text) is
  'Bills a supplier for what was used of stock they owned: consigned stock consumed and samples bought '
  '(20261004940000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_bill_from_consumption', 'erp.bill_from_consumption',
   'Raises and registers a supplier''s bill for consigned stock consumed and samples bought, line by line through erp.invoice_against(), clearing goods received not invoiced at the agreed price; authorises procurement.match for the company.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_bill_from_consumption']);

-- ═════════════════════════════════════════════════════════════════════════════
-- J. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.consumption_billing_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_grni_code text;
  v_entity uuid; v_site uuid; v_recv uuid; v_uom uuid; v_ccy char(3);
  v_item uuid; v_item2 uuid; v_item3 uuid; v_sup uuid; v_sup2 uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_grn2 uuid; v_grnl2 uuid; v_smp jsonb; v_smpl uuid;
  v_move bigint; v_bill jsonb; v_bill2 jsonb; v_draft uuid;
  v_g0 bigint; v_g1 bigint; v_g2 bigint; v_rep record; v_n integer; v_ppv bigint;
  v_tie text; v_call text; v_status text;
  v_err text; v_err2 text; v_err3 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, with somebody who only reads';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcbl-' || v_tag, 'Consumption Billing Suite',
      'admin@zzcbl-' || v_tag || '.test', 'Billing Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzcbl-' || v_tag || '.test'),
           (s_read, 'reader@zzcbl-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('reader@zzcbl-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, warehouse, three products and two suppliers';
    select e.id, e.base_currency into v_entity, v_ccy from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity and s.site_type = 'warehouse' order by s.code limit 1;
    select l.id into v_recv from erp.location l
     where l.tenant_id = rb.tenant_id and l.site_id = v_site and l.location_type = 'receiving' order by l.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCFABRIC', 'Consigned Fabric', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCBELT', 'Consigned Belt', v_uom, 'active') returning id into v_item2;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCBAG', 'Sample Bag', v_uom, 'active') returning id into v_item3;
    v_sup := erp_test.cash_payment_supplier('ZCMILL');
    v_sup2 := erp_test.cash_payment_supplier('ZCOTHER');
    v_grni_code := erp.tenant_account_code('goods_received_not_invoiced');

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the door, the refusals and the screen';
    v_cases := v_cases + 1;
    case_name := 'the bill-for-what-was-used door is on the allow-list under its gate and on the Procurement screen''s help, and the five refusals are registered with a next action';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_bill_from_consumption' and a.gate = 'erp.bill_from_consumption')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/procurement' and 'erp_bill_from_consumption' = any (h.actions))
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_NOTHING_CONSUMED_TO_BILL', 'CLOVEERP_CONSUMPTION_SPANS_COMPANIES',
                                 'CLOVEERP_NOT_BILLED_BY_CONSUMPTION', 'CLOVEERP_BILLED_BY_CONSUMPTION',
                                 'CLOVEERP_SAMPLE_PRICE_DIFFERS')
                  and coalesce(f.next_action, '') <> '') = 5;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Consigned goods arrive ───────────────────────────────────────────
    v_step := 'ten metres of fabric received against a consignment order at £9';
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 10, 900, 'on consignment');
    perform erp.set_order_behaviour(v_po, 'consignment');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'consumption billing suite');
    perform erp.transition_document(v_po, 'send', null);
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 10);
    update erp.document_line set location_id = coalesce(location_id, v_recv) where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post', 'consumption billing suite');
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    v_tie := 'ties';
    begin perform erp.assert_grni_reconciles(); exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'consigned goods that arrive and are not used are the supplier''s: goods received not invoiced does not show the order line, and the report, the ledger and the balance sheet agree';
    passed := v_state is null
          and not exists (select 1 from erp.grni_report() g where g.order_line_id = v_pol)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('ledger %s; %s', v_g0, v_tie), 400));
    return next;

    -- ── 3. Four are used ────────────────────────────────────────────────────
    v_step := 'four metres consumed';
    v_move := erp.consume_consignment(v_item, v_site, v_recv, 4, v_sup, null, 'cut for production');
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g1
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    select * into v_rep from erp.grni_report() g where g.order_line_id = v_pol;
    v_tie := 'ties';
    begin perform erp.assert_grni_reconciles(); exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'four metres used: the change of owner names the receipt line at the order''s £9, goods received not invoiced rises by £36, the order line is open for four at £36, and the three figures agree';
    passed := v_state is null
          and exists (select 1 from erp.stock_movement m
                       join erp.document_line rl on rl.id = m.document_line_id and rl.document_id = v_grn
                      where m.id = v_move and m.movement_type = 'ownership_transfer'
                        and m.document_id = v_grn and m.unit_cost_minor = 900 and m.quantity = 4)
          and v_g1 - v_g0 = 3600
          and v_rep.open_quantity = 4 and v_rep.open_value_minor = 3600
          and v_rep.received_on = erp.local_today(v_site)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('grni %s→%s; report %s/%s on %s; %s', v_g0, v_g1,
                                            v_rep.open_quantity, v_rep.open_value_minor, v_rep.received_on, v_tie), 500));
    return next;

    -- ── 4. Not from the receipt ─────────────────────────────────────────────
    v_step := 'the consignment receipt billed from the receipt';
    begin
      perform erp.bill_from_receipt(v_grn);
      v_err := 'billed';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a receipt of goods the supplier owns is not billed from the receipt, which would pay for all ten';
    passed := v_state is null and v_err like 'CLOVEERP_BILLED_BY_CONSUMPTION:%';
    detail := coalesce(v_state, left(v_err, 300));
    return next;

    -- ── 5. Self-billed ──────────────────────────────────────────────────────
    v_step := 'the four metres billed for what was used';
    v_bill := public.erp_bill_from_consumption(v_sup, null, null, 'SELF-1', null, null, null, null, null);
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g2
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    v_tie := 'ties';
    foreach v_call in array array['erp.assert_trial_balance_balances()', 'erp.assert_inventory_reconciles()',
                                  'erp.assert_subledger_reconciles()', 'erp.assert_ageing_equals_control()',
                                  'erp.assert_grni_reconciles()'] loop
      begin execute 'select ' || v_call;
      exception when others then v_tie := v_call || ': ' || left(sqlerrm, 300); end;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'billed for what was used: one line of four at £9, registered with nothing unmatched, goods received not invoiced back where it was, the order line no longer open, and the four ties and goods received not invoiced hold';
    passed := v_state is null
          and v_bill ->> 'state' <> 'draft'
          and (v_bill ->> 'lines')::integer = 1
          and (v_bill ->> 'value_minor')::bigint = 3600
          and (v_bill ->> 'exceptions')::integer = 0
          and exists (select 1 from erp.document_relation rel
                       where rel.from_document_id = (v_bill ->> 'document_id')::uuid
                         and rel.to_line_id = v_pol and rel.relation_kind = 'invoices' and rel.quantity = 4)
          and v_g2 = v_g0
          and not exists (select 1 from erp.grni_report() g where g.order_line_id = v_pol)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('%s; grni %s (was %s); %s', v_bill, v_g2, v_g0, v_tie), 600));
    return next;

    -- ── 6. Nothing left ─────────────────────────────────────────────────────
    v_step := 'billing again with nothing used since';
    begin
      perform public.erp_bill_from_consumption(v_sup, null, null, null, null, null, null, null, null);
      v_err := 'billed';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'with nothing used and not billed, the supplier is not billed again';
    passed := v_state is null and v_err like 'CLOVEERP_NOTHING_CONSUMED_TO_BILL:%';
    detail := coalesce(v_state, left(v_err, 300));
    return next;

    -- ── 7. Their figures, within tolerance ──────────────────────────────────
    v_step := 'three more used, and the mill bills three at £9.40';
    perform erp.consume_consignment(v_item, v_site, v_recv, 3, v_sup, null, 'cut for production');
    set constraints all immediate;
    v_bill := public.erp_bill_from_consumption(v_sup, null, null, 'MILL-0412', null, null,
                jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 3, 'unit_price_minor', 940)),
                null, null);
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g2
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_ppv
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and j.document_id = (v_bill ->> 'document_id')::uuid
       and a.code = erp.tenant_account_code('purchase_price_variance');
    v_tie := 'ties';
    begin perform erp.assert_grni_reconciles(); exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'the mill''s own bill for three at £9.40 is inside the price tolerance: it matches, clears goods received not invoiced at the agreed £27, and the forty pence a metre goes to the price variance';
    passed := v_state is null
          and (v_bill ->> 'exceptions')::integer = 0
          and (v_bill ->> 'value_minor')::bigint = 2820
          and v_g2 = v_g0
          and v_ppv = 120
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('%s; grni %s; variance %s; %s', v_bill, v_g2, v_ppv, v_tie), 600));
    return next;

    -- ── 8. Their figures, more than was used ────────────────────────────────
    v_step := 'two more used, and the mill bills three';
    perform erp.consume_consignment(v_item, v_site, v_recv, 2, v_sup, null, 'cut for production');
    set constraints all immediate;
    v_draft := erp.bill_from_consumption(v_sup, null, null, 'MILL-0413', null, null,
                 jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 3)), false, null, null);
    select x.status::text into v_status from erp.match_exception x
     where x.tenant_id = rb.tenant_id and x.order_line_id = v_pol and x.resolved_at is null
     order by x.created_at desc limit 1;
    perform erp.cancel_document(v_draft, 'billed for more than was used');
    v_bill2 := public.erp_bill_from_consumption(v_sup, null, null, 'MILL-0413A', null, null, null, null, null);
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g2
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    v_tie := 'ties';
    begin perform erp.assert_grni_reconciles(); exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'a bill for three when two were used is a quantity exception, matched against what was used and not what arrived; cancelled, the two are billed and goods received not invoiced clears';
    passed := v_state is null
          and v_status = 'quantity_variance'
          and (v_bill2 ->> 'lines')::integer = 1
          and (v_bill2 ->> 'value_minor')::bigint = 1800
          and (v_bill2 ->> 'exceptions')::integer = 0
          and v_g2 = v_g0
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('exception %s; %s; grni %s; %s', v_status, v_bill2, v_g2, v_tie), 600));
    return next;

    -- ── 9. Consigned without an order ───────────────────────────────────────
    v_step := 'five belts consigned without an order at £7, two used and billed';
    v_grn2 := erp.create_document('goods_receipt', v_entity, v_site, v_sup, current_date, v_ccy, 'ZC-GRN-CONS', '{}'::jsonb);
    update erp.document set stock_owner_party_id = v_sup where id = v_grn2;
    v_grnl2 := erp.add_document_line(v_grn2, v_item2, 5, 700, 'consigned', current_date);
    update erp.document_line set location_id = coalesce(location_id, v_recv) where document_id = v_grn2;
    perform erp.transition_document(v_grn2, 'post', 'consumption billing suite');
    set constraints all immediate;
    v_move := erp.consume_consignment(v_item2, v_site, v_recv, 2, v_sup, null, 'sold on');
    set constraints all immediate;
    select * into v_rep from erp.grni_report() g where g.order_line_id = v_grnl2;
    v_bill := public.erp_bill_from_consumption(v_sup, v_site, current_date, 'MILL-0414', null, null, null, null, null);
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g2
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    v_tie := 'ties';
    begin perform erp.assert_grni_reconciles(); exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'belts consigned on a receipt with no order: the two used name the receipt line, show open on it for £14, and the bill for what was used meets that line and clears it';
    passed := v_state is null
          and exists (select 1 from erp.stock_movement m where m.id = v_move and m.document_line_id = v_grnl2)
          and v_rep.open_quantity = 2 and v_rep.open_value_minor = 1400
          and (v_bill ->> 'value_minor')::bigint = 1400
          and (v_bill ->> 'exceptions')::integer = 0
          and v_g2 = v_g0
          and not exists (select 1 from erp.grni_report() g where g.order_line_id = v_grnl2)
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('report %s/%s; %s; grni %s; %s', v_rep.open_quantity,
                                            v_rep.open_value_minor, v_bill, v_g2, v_tie), 600));
    return next;

    -- ── 10. A sample bought ─────────────────────────────────────────────────
    v_step := 'two sample bags received forty days ago, one bought at £50 today and billed';
    v_smp := public.erp_receive_samples(v_sup, v_site,
               jsonb_build_array(jsonb_build_object('item_id', v_item3, 'quantity', 2)),
               current_date - 10, 'buying', 'MILL-SMP', null);
    update erp.document set document_date = current_date - 40, posting_date = current_date - 40
     where id = (v_smp ->> 'document_id')::uuid;
    select l.id into v_smpl from erp.document_line l where l.document_id = (v_smp ->> 'document_id')::uuid;
    perform public.erp_settle_samples(v_smpl, 'buy', 1, 5000, 'for the archive');
    set constraints all immediate;
    select * into v_rep from erp.grni_report() g where g.order_line_id = v_smpl;
    begin
      perform public.erp_settle_samples(v_smpl, 'buy', 1, 6000, 'the other one');
      v_err := 'bought';
    exception when others then v_err := sqlerrm; end;
    v_bill := public.erp_bill_from_consumption(v_sup, null, null, 'MILL-0415', null, null, null, null, null);
    set constraints all immediate;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_g2
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = v_grni_code;
    v_tie := 'ties';
    foreach v_call in array array['erp.assert_trial_balance_balances()', 'erp.assert_inventory_reconciles()',
                                  'erp.assert_subledger_reconciles()', 'erp.assert_ageing_equals_control()',
                                  'erp.assert_grni_reconciles()'] loop
      begin execute 'select ' || v_call;
      exception when others then v_tie := v_call || ': ' || left(sqlerrm, 300); end;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'a sample received forty days ago and bought today at £50 posts today, keeps its price on its line, shows open for £50, refuses a second purchase at £60, and the bill for what was used clears it with the four ties and goods received not invoiced holding';
    passed := v_state is null
          and exists (select 1 from erp.journal j
                       join erp.stock_movement m on m.movement_uid = (select e.aggregate_id from erp.event e where e.id = j.source_event_id)
                      where j.tenant_id = rb.tenant_id and j.source_code = 'stock.ownership_transferred'
                        and m.document_line_id = v_smpl and j.posting_date = erp.local_today(v_site))
          and (select l.unit_price_minor from erp.document_line l where l.id = v_smpl) = 5000
          and v_rep.open_quantity = 1 and v_rep.open_value_minor = 5000
          and v_err like 'CLOVEERP_SAMPLE_PRICE_DIFFERS:%'
          and (v_bill ->> 'value_minor')::bigint = 5000
          and (v_bill ->> 'exceptions')::integer = 0
          and v_g2 = v_g0
          and v_tie = 'ties';
    detail := coalesce(v_state, left(format('report %s/%s; %s; %s; grni %s; %s', v_rep.open_quantity,
                                            v_rep.open_value_minor, v_err, v_bill, v_g2, v_tie), 700));
    return next;

    -- ── 11. What may not be billed ──────────────────────────────────────────
    v_step := 'another supplier''s line, a quantity of nought, and a reader';
    begin
      perform public.erp_bill_from_consumption(v_sup2, null, null, null, null, null,
                jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 1)), null, null);
      v_err := 'billed';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_bill_from_consumption(v_sup, null, null, null, null, null,
                jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 0)), null, null);
      v_err2 := 'billed';
    exception when others then v_err2 := sqlerrm; end;
    perform erp.consume_consignment(v_item, v_site, v_recv, 1, v_sup, null, 'cut for production');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_bill_from_consumption(v_sup, null, null, null, null, null, null, null, null);
      v_err3 := 'billed';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a line that is another supplier''s, a quantity of nought, and somebody who may only read are each refused by name';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOT_BILLED_BY_CONSUMPTION:%'
          and v_err2 like 'CLOVEERP_QUANTITY_NONPOSITIVE:%'
          and v_err3 like 'CLOVEERP_PERMISSION_DENIED: procurement.match%';
    detail := coalesce(v_state, left(format('%s | %s | %s', v_err, v_err2, v_err3), 700));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzcbl-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzcbl rolled back with its consignment, its samples and its bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CONSUMPTION_BILLING_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.consumption_billing_suite() from public, anon;

comment on function erp_test.consumption_billing_suite() is
  'A consignor bills what was used (20261004940000): consigned goods not used are not goods received not '
  'invoiced; what is used names its receipt line at the agreed price; the bill for what was used, '
  'self-billed or the supplier''s own figures within or outside tolerance, clears it; consignment without '
  'an order and bought samples the same; a sample buy posts on its own day; the four ties and goods '
  'received not invoiced hold; refused by name where it may not be.';

create or replace function erp_test.assert_consumption_billing_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.consumption_billing_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CONSUMPTION_BILLING_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'What a supplier owned and the company used would accrue for ever, or be billed for what nobody used. Read the case that failed.';
  end if;
  if v_total <> 12 then
    raise exception 'CLOVEERP_CONSUMPTION_BILLING_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('consumption billing: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_consumption_billing_suite() from public, anon;

comment on function erp_test.assert_consumption_billing_suite() is
  'Stock a supplier owned and the company used is billed for what was used, and goods received not '
  'invoiced clears (20261004940000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- K. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Billing a supplier for what was used, on the Procurement screen (20261004940000).'
  from (values
    ('Bill what was used'),
    ('The supplier''s bill for consigned stock you used and samples you bought: what was used and not yet billed, at the agreed price.'),
    ('Supplier'),
    ('Site (if more than one company)'),
    ('Used up to'),
    ('Leave empty to bill everything used so far.')
  ) as v(text)
on conflict (key, locale) do nothing;

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
