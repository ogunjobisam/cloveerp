set lock_timeout = '30s';

-- =============================================================================
-- 20261004945000  Freight comes in on our account
-- -----------------------------------------------------------------------------
-- The first half of inbound carriers, the fifth procure-to-pay gap the owner
-- named, on top of a supplier lending its samples (20261004930000). A brand
-- that sells ex works leaves the retailer to collect: the retailer books the
-- carrier, the goods arrive, and the carrier's bill is part of what the goods
-- cost. docs/spec/logistics-target-flow.md §10 had inbound freight out of
-- scope; the owner brought it in on 2 October 2026.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A shipment ran one way, from a site to a customer. Freight on goods coming
-- in had nowhere to be booked, nothing to say it was on its way, and its bill,
-- entered at all, went to carriage outwards as if it were a selling cost. And
-- landed cost (erp.allocate_landed_cost()) raised the cost of stock without a
-- journal, so a charge it carried would have parted stock from the ledger.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A purchase order's freight terms, erp_set_freight_terms(p_order,
--     p_terms): supplier_delivers (the default, as before) or we_collect.
--   * erp_ship_inbound(p_order, p_carrier_code, p_service_code, p_cost_minor,
--     p_expected_arrival, p_tracking_reference, p_weight_g): for an order we
--     collect, an inbound shipment on the shipment document, from the supplier
--     to the order's site, booked with the carrier at the rate card's price or
--     the cost named (logistics.plan). Its weight is the one given, else the
--     order lines' items' net weight. erp.shipment gains direction and
--     origin_party_id.
--   * It arrives with its goods. A goods receipt posted against the order
--     delivers the order's booked inbound shipment, by the system (a derived
--     move: erp.inbound_shipment_is_received()), and names it.
--   * The carrier's bill is Bill from shipment, as outbound (20261004700000),
--     inside the shipping policy's cost tolerance or disputed. As it registers
--     (or its dispute is resolved), its net is capitalised onto the goods the
--     shipment carried (owner: into item cost, IAS 2), by value across the
--     receipt's lines: one journal, freight.capitalised, Dr inventory exactly
--     what lands on stock still held, Dr freight variance the rest (stock
--     already sold, standard-costed stock, and pennies the arithmetic leaves;
--     cost of sales where the chart has no freight variance, as the default
--     chart has not — no account is added),
--     Cr carriage outwards the net its bill posted there. So carriage outwards
--     carries only freight out, the stock carries its freight in, and stock
--     and the ledger agree to the penny.
--   * erp_inbound_shipments(): what is on its way, from whom, for which order,
--     expected when, and whether it is late.
--   * Refusals, registered, and an event: freight.capitalised.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * erp.allocate_landed_cost() stays as it is: nothing in the product calls
--     it, and freight now lands through the bill. Retiring it is a follow-up.
--   * The carrier's own systems (booking, labels, tracking): the second half,
--     20261004960000.
--   * Duty and customs: not freight, and out of scope.
--
-- Proved by erp_test.inbound_freight_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. A shipment runs either way
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.shipment add column if not exists direction text not null default 'outbound';
alter table erp.shipment add column if not exists origin_party_id uuid;

do $cols$
begin
  if not exists (select 1 from pg_constraint where conname = 'shipment_direction_known') then
    alter table erp.shipment add constraint shipment_direction_known check (direction in ('outbound', 'inbound'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'shipment_origin_party_fkey') then
    alter table erp.shipment add constraint shipment_origin_party_fkey
      foreign key (tenant_id, origin_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'shipment_inbound_has_origin') then
    alter table erp.shipment add constraint shipment_inbound_has_origin
      check (direction = 'outbound' or origin_party_id is not null);
  end if;
end
$cols$;

comment on column erp.shipment.direction is
  'outbound: from a site to a customer. inbound: from a supplier to a site, on an order we collect (20261004945000).';
comment on column erp.shipment.origin_party_id is
  'The supplier an inbound shipment is collected from (20261004945000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_FREIGHT_TERMS_UNKNOWN',
  'Setting freight terms other than the supplier delivering or us collecting.',
  'An order''s goods either come at the supplier''s cost, delivered, or at ours, collected; who books and pays the carrier follows.',
  'Choose "The supplier delivers" or "We collect".');

select erp.register_refusal('CLOVEERP_ORDER_NOT_COLLECTED',
  'Booking an inbound shipment for an order the supplier delivers, or one that is not on its way.',
  'We book a carrier only for an order we collect, once the supplier has it; for an order the supplier delivers, the supplier books and pays the carrier.',
  'Set the order''s freight terms to "We collect", send it to the supplier, then book the collection.');

select erp.register_refusal('CLOVEERP_SHIPMENT_WEIGHT_INVALID',
  'Booking a collection with a weight that is not a positive number of grams.',
  'A carrier prices and labels a parcel by its weight; nothing, or less than nothing, cannot be carried.',
  'Weigh the consignment and give its weight in grams, or leave the weight empty to take the items'' own.');

select erp.register_refusal('CLOVEERP_INBOUND_ALREADY_BOOKED',
  'Booking a second collection for an order while one is still booked.',
  'One booked collection carries the order; a second would be a second carrier''s bill for the same goods.',
  'Cancel the booked collection before booking another, or wait for it to arrive.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.freight.capitalised', 'en', 'Freight capitalised', 'finance',
   'Event raised when a carrier''s bill for freight in is added to the cost of the goods it carried.'),
  ('event.freight.capitalised', 'de', 'Fracht aktiviert', 'finance',
   'Ereignis, wenn die Frachtrechnung eines Spediteurs für eingehende Ware den Anschaffungskosten der Ware zugerechnet wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('freight.capitalised', 1, 'document', 'finance', 'event.freight.capitalised',
        'A carrier''s bill for freight in was added to the cost of the goods it carried.',
        '{"type":"object","required":["reference","net_minor","capitalised_minor"],
          "properties":{"reference":{"type":"string"},"shipment":{"type":"string"},
                        "net_minor":{"type":"integer"},"capitalised_minor":{"type":"integer"},
                        "expensed_minor":{"type":"integer"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'freight.capitalised' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.freight.capitalised') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: freight.capitalised is declared already, and not as 20261004945000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. Freight terms, and booking the collection
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.order_freight_terms(p_order uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- Who brings an order's goods (20261004945000): the supplier, by default,
  -- or us.
  select coalesce((select d.attributes ->> 'freight_terms' from erp.document d
                    where d.tenant_id = erp.current_tenant_id() and d.id = p_order), 'supplier_delivers')
$$;

revoke all on function erp.order_freight_terms(uuid) from public, anon;

create or replace function erp.set_freight_terms(p_order uuid, p_terms text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_terms  text := lower(btrim(coalesce(p_terms, '')));
  v_base   text;
begin
  -- Who brings the goods, on an order not yet closed (20261004945000).
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = p_order for update;
  select dt.base_type_code into v_base from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  if d.id is null or v_base is distinct from 'purchase_order' or d.is_cancelled
     or erp.object_current_state('document', d.id) in ('closed', 'cancelled') then
    raise exception 'CLOVEERP_ORDER_NOT_COLLECTED: % is not an open purchase order', coalesce(d.document_number, coalesce(p_order::text, 'nothing'))
      using errcode = '23514',
            hint = 'Set the order''s freight terms to "We collect", send it to the supplier, then book the collection.';
  end if;
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', d.id);
  if v_terms not in ('supplier_delivers', 'we_collect') then
    raise exception 'CLOVEERP_FREIGHT_TERMS_UNKNOWN: an order''s goods are delivered by the supplier or collected by us, not %',
      coalesce(p_terms, 'nothing')
      using errcode = '22023', hint = 'Choose "The supplier delivers" or "We collect".';
  end if;
  update erp.document x
     set attributes = coalesce(x.attributes, '{}'::jsonb) || jsonb_build_object('freight_terms', v_terms),
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = d.id;
  return jsonb_build_object('order_id', d.id, 'order_number', d.document_number, 'freight_terms', v_terms);
end;
$$;

revoke all on function erp.set_freight_terms(uuid, text) from public, anon;

create or replace function public.erp_set_freight_terms(p_order uuid, p_terms text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.set_freight_terms(p_order, p_terms) $$;

revoke all on function public.erp_set_freight_terms(uuid, text) from public, anon;
grant execute on function public.erp_set_freight_terms(uuid, text) to authenticated, service_role;

comment on function public.erp_set_freight_terms(uuid, text) is
  'Sets who brings a purchase order''s goods: the supplier, delivered, or us, collected (20261004945000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_freight_terms', 'erp.set_freight_terms',
   'Sets a purchase order''s freight terms in its attributes; authorises procurement.order in the order''s company and site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

create or replace function erp.ship_inbound(p_order uuid, p_carrier_code text, p_service_code text,
                                            p_cost_minor bigint default null, p_expected_arrival date default null,
                                            p_tracking_reference text default null, p_weight_g bigint default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_ship   uuid;
  v_base   text;
  v_weight numeric;
  sh       erp.shipment%rowtype;
begin
  -- The collection of an order we collect (20261004945000): an inbound
  -- shipment from the supplier to the order's site, opened on the shipment
  -- document and booked with the carrier as an outbound one is.
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = p_order for update;
  select dt.base_type_code into v_base from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  if d.id is null or v_base is distinct from 'purchase_order'
     or erp.order_freight_terms(d.id) <> 'we_collect'
     or erp.object_current_state('document', d.id) not in ('sent', 'partially_received') then
    raise exception 'CLOVEERP_ORDER_NOT_COLLECTED: % is not an order we collect that the supplier has',
      coalesce(d.document_number, coalesce(p_order::text, 'nothing'))
      using errcode = '23514',
            hint = 'Set the order''s freight terms to "We collect", send it to the supplier, then book the collection.';
  end if;
  perform erp.authorise('logistics.plan', d.entity_id, d.site_id, null, 'document', d.id);

  if exists (select 1 from erp.shipment s join erp.shipment_line sl on sl.shipment_id = s.id
              where s.tenant_id = v_tenant and s.direction = 'inbound' and sl.document_id = d.id
                and s.status in ('planned', 'booked')) then
    raise exception 'CLOVEERP_INBOUND_ALREADY_BOOKED: % already has a collection on its way', d.document_number
      using errcode = '23505',
            hint = 'Cancel the booked collection before booking another, or wait for it to arrive.';
  end if;

  -- The consignment's weight: as weighed, where it was, else what its items
  -- weigh. It is on the shipment before the booking, which is what asks a
  -- carrier's system for the label (20261004960000).
  if p_weight_g is not null and p_weight_g <= 0 then
    raise exception 'CLOVEERP_SHIPMENT_WEIGHT_INVALID: % g is not a weight a carrier can carry', p_weight_g
      using errcode = '22023',
            hint = 'Weigh the consignment and give its weight in grams, or leave the weight empty to take the items'' own.';
  end if;
  select coalesce(sum(l.quantity * coalesce(i.net_weight_g, 0)), 0) into v_weight
    from erp.document_line l left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
   where l.tenant_id = v_tenant and l.document_id = d.id and not l.is_cancelled;
  v_weight := coalesce(p_weight_g::numeric, v_weight);

  insert into erp.shipment (tenant_id, entity_id, site_id, reference, status, planned_despatch, direction,
                            origin_party_id, total_weight_g, currency, tracking_reference)
  values (v_tenant, d.entity_id, d.site_id, 'IN-' || d.document_number, 'planned', erp.local_today(d.site_id),
          'inbound', d.party_id, v_weight, d.currency, nullif(btrim(coalesce(p_tracking_reference, '')), ''))
  returning id into v_ship;
  insert into erp.shipment_line (tenant_id, shipment_id, document_id, weight_g)
  values (v_tenant, v_ship, d.id, v_weight);

  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = v_tenant and dt.code = 'shipment' and dt.status = 'active') then
    update erp.shipment s
       set document_id = erp.create_document(
             'shipment', s.entity_id, s.site_id, d.party_id, s.planned_despatch, d.currency,
             null, jsonb_build_object('shipment_id', s.id, 'direction', 'inbound', 'order_id', d.id)),
           updated_at = now()
     where s.tenant_id = v_tenant and s.id = v_ship;
    perform erp.mirror_shipment_status(v_ship);
  end if;

  perform erp.book_shipment(v_ship, p_carrier_code, p_service_code, p_cost_minor);
  if p_expected_arrival is not null then
    update erp.shipment set planned_arrival = p_expected_arrival, updated_at = now()
     where tenant_id = v_tenant and id = v_ship;
  end if;

  select * into sh from erp.shipment where id = v_ship;
  return jsonb_build_object(
    'shipment_id', sh.id, 'document_id', sh.document_id,
    'document_number', (select x.document_number from erp.document x where x.id = sh.document_id),
    'order_number', d.document_number, 'status', sh.status, 'carrier_code', p_carrier_code,
    'service_code', sh.service_code, 'cost_minor', sh.freight_cost_minor, 'currency', sh.currency,
    'expected_arrival', sh.planned_arrival, 'tracking_reference', sh.tracking_reference,
    'weight_g', sh.total_weight_g);
end;
$$;

revoke all on function erp.ship_inbound(uuid, text, text, bigint, date, text, bigint) from public, anon;

comment on function erp.ship_inbound(uuid, text, text, bigint, date, text, bigint) is
  'Books the collection of an order we collect: an inbound shipment from the supplier to the order''s '
  'site, booked with the carrier (20261004945000). Authorises logistics.plan at the site.';

create or replace function public.erp_ship_inbound(p_order uuid, p_carrier_code text, p_service_code text,
                                                   p_cost_minor bigint default null, p_expected_arrival date default null,
                                                   p_tracking_reference text default null, p_weight_g bigint default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.ship_inbound(p_order, p_carrier_code, p_service_code, p_cost_minor, p_expected_arrival,
                              p_tracking_reference, p_weight_g) $$;

revoke all on function public.erp_ship_inbound(uuid, text, text, bigint, date, text, bigint) from public, anon;
grant execute on function public.erp_ship_inbound(uuid, text, text, bigint, date, text, bigint) to authenticated, service_role;

comment on function public.erp_ship_inbound(uuid, text, text, bigint, date, text, bigint) is
  'Books the collection of a purchase order we collect (20261004945000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_ship_inbound', 'erp.ship_inbound',
   'Books an inbound shipment for a purchase order we collect: opens a shipment document and books it with the carrier; authorises logistics.plan at the site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_set_freight_terms', 'erp_ship_inbound']);

-- ═════════════════════════════════════════════════════════════════════════════
-- D. It arrives with its goods
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.inbound_shipment_is_received(p_shipment_document uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- An inbound shipment whose goods a posted receipt brought in
  -- (20261004945000): the fact its delivery is derived from.
  select exists (
    select 1 from erp.shipment s
      join erp.document r on r.tenant_id = s.tenant_id and r.attributes ->> 'inbound_shipment_id' = s.id::text
     where s.tenant_id = erp.current_tenant_id() and s.document_id = p_shipment_document
       and s.direction = 'inbound'
       and erp.object_current_state('document', r.id) = 'posted')
$$;

revoke all on function erp.inbound_shipment_is_received(uuid) from public, anon;

create or replace function erp.arrive_inbound_shipments(p_receipt uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_number text;
  v_n      integer := 0;
begin
  -- A posted receipt against an order we collect delivers the order's booked
  -- collection (20261004945000), the oldest first, and names it. The system's
  -- move, derived from the receipt.
  select d.document_number into v_number from erp.document d where d.tenant_id = v_tenant and d.id = p_receipt;
  for r in
    select distinct on (s.id) s.id, s.document_id, s.planned_despatch
      from erp.document_relation rel
      join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      join erp.shipment_line sl on sl.tenant_id = ol.tenant_id and sl.document_id = ol.document_id
      join erp.shipment s on s.tenant_id = sl.tenant_id and s.id = sl.shipment_id
     where rel.tenant_id = v_tenant and rel.from_document_id = p_receipt and rel.relation_kind = 'fulfils'
       and s.direction = 'inbound' and s.status = 'booked'
     order by s.id, s.planned_despatch
  loop
    update erp.document x
       set attributes = coalesce(x.attributes, '{}'::jsonb) || jsonb_build_object('inbound_shipment_id', r.id),
           updated_at = now()
     where x.tenant_id = v_tenant and x.id = p_receipt
       and not (coalesce(x.attributes, '{}'::jsonb) ? 'inbound_shipment_id');
    update erp.shipment
       set actual_arrival = now(),
           proof_of_delivery = jsonb_build_object('reference', v_number, 'at', now(), 'by', 'the system',
                                                  'because', 'the goods it carried were received on ' || coalesce(v_number, 'a receipt')),
           updated_at = now()
     where tenant_id = v_tenant and id = r.id;
    if r.document_id is not null then
      perform set_config('erp.deriving_move', r.document_id::text || ':deliver', true);
      perform erp.transition_document(r.document_id, 'deliver', 'Arrived with ' || coalesce(v_number, 'its goods'));
      perform set_config('erp.deriving_move', '', true);
    end if;
    perform erp.mirror_shipment_status(r.id);
    v_n := v_n + 1;
    exit;
  end loop;
  return v_n;
end;
$$;

revoke all on function erp.arrive_inbound_shipments(uuid) from public, anon;

comment on function erp.arrive_inbound_shipments(uuid) is
  'Delivers the booked collection of the order a posted receipt fulfils, and names it on the receipt '
  '(20261004945000). Called as the receipt posts.';

-- The fact the delivery is derived from. Edited, not rewritten: one anchor
-- over erp.derived_move_fact() (md5 6a52f8ad…).

do $fact$
declare
  v_sig  constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$             then 'erp.shipment_needs_no_proof'
         end$o$;
  v_new  constant text := $n$             then 'erp.shipment_needs_no_proof'
           -- An inbound shipment's delivery, once a posted receipt brought its
           -- goods in (20261004945000), asked for by
           -- erp.arrive_inbound_shipments().
           when dt.base_type_code = 'shipment' and p_transition_code = 'deliver'
            and erp.object_current_state('document', p_object_id) = 'booked'
            and erp.inbound_shipment_is_received(p_object_id)
             then 'erp.inbound_shipment_is_received'
         end$n$;
begin
  if strpos(v_src, '20261004945000') > 0 then
    raise notice '% already derives an inbound delivery; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6a52f8ad60c050886beb86855003710c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004945000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$fact$;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The freight lands on what it carried
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.item_stock_value(p_item uuid, p_site uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- What an item at a site is worth on the company's books, as
  -- erp.stock_valuation_report() reads it (20261004945000): its FIFO layers
  -- still held, or its stored average value.
  select case erp.costing_method_for(p_item, p_site)
           when 'fifo' then
             coalesce((select round(sum(l.remaining * l.unit_cost_minor))::bigint
                         from erp.stock_valuation_layer l
                        where l.tenant_id = erp.current_tenant_id() and l.item_id = p_item
                          and l.site_id is not distinct from p_site and l.remaining > 0), 0)
           else
             coalesce((select c.value_minor from erp.item_cost c
                        where c.tenant_id = erp.current_tenant_id() and c.item_id = p_item
                          and c.site_id is not distinct from p_site), 0)
         end::bigint
$$;

revoke all on function erp.item_stock_value(uuid, uuid) from public, anon;

create or replace function erp.add_freight_to_receipt_line(p_receipt_line uuid, p_amount_minor bigint)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  l         erp.document_line%rowtype;
  d         erp.document%rowtype;
  v_method  erp.costing_method;
  v_before  bigint;
  v_after   bigint;
  lay       record;
  v_held    numeric;
  v_portion bigint;
  ic        erp.item_cost%rowtype;
begin
  -- A receipt line's share of freight, onto what of it is still held
  -- (20261004945000), returning exactly how much the stock's value rose by,
  -- read as the valuation reads it. FIFO: the line's own layers still held,
  -- each by whole minor units per unit; the rest is a period cost. Average:
  -- onto the item's pool, in proportion to what of the line the pool can
  -- still hold. Standard: nothing; freight is a variance.
  if coalesce(p_amount_minor, 0) <= 0 then return 0; end if;
  select x.* into l from erp.document_line x where x.tenant_id = v_tenant and x.id = p_receipt_line;
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = l.document_id;
  if l.id is null or l.item_id is null or coalesce(l.quantity, 0) <= 0 then return 0; end if;
  v_method := erp.costing_method_for(l.item_id, d.site_id);
  if v_method = 'standard' then return 0; end if;
  v_before := erp.item_stock_value(l.item_id, d.site_id);

  if v_method = 'fifo' then
    for lay in
      select vl.id, vl.remaining
        from erp.stock_valuation_layer vl
        join erp.stock_movement m on m.tenant_id = vl.tenant_id and m.id = vl.movement_id
       where vl.tenant_id = v_tenant and m.document_line_id = l.id and vl.remaining > 0
       order by vl.id
         for update of vl
    loop
      -- This layer's share of the line's freight, by what it still holds.
      v_portion := floor(p_amount_minor * lay.remaining / l.quantity)::bigint;
      update erp.stock_valuation_layer
         set unit_cost_minor = unit_cost_minor + floor(v_portion / lay.remaining)::bigint, updated_at = now()
       where id = lay.id;
    end loop;
  else
    select x.* into ic from erp.item_cost x
     where x.tenant_id = v_tenant and x.item_id = l.item_id and x.site_id is not distinct from d.site_id
       for update;
    if ic.id is not null and ic.quantity_on_hand > 0 then
      v_held := least(l.quantity, ic.quantity_on_hand);
      v_portion := floor(p_amount_minor * v_held / l.quantity)::bigint;
      update erp.item_cost
         set value_minor = value_minor + v_portion,
             unit_cost_minor = round((value_minor + v_portion) / quantity_on_hand)::bigint,
             updated_at = now()
       where id = ic.id;
    end if;
  end if;

  v_after := erp.item_stock_value(l.item_id, d.site_id);
  return greatest(0, v_after - v_before);
end;
$$;

revoke all on function erp.add_freight_to_receipt_line(uuid, bigint) from public, anon;

comment on function erp.add_freight_to_receipt_line(uuid, bigint) is
  'Adds a receipt line''s share of freight to what of it is still held, returning exactly what the '
  'stock''s value rose by (20261004945000).';

create or replace function erp.capitalise_inbound_freight(p_bill uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  b         erp.document%rowtype;
  sh        erp.shipment%rowtype;
  v_net     bigint;
  v_total   numeric;
  r         record;
  v_share   bigint;
  v_spent   bigint := 0;
  v_applied bigint := 0;
  v_lines   jsonb := '[]'::jsonb;
  v_ledger  uuid;
  v_inv     uuid;
  v_var     uuid;
  v_out     uuid;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_no      integer := 0;
  v_shipno  text;
  v_n       integer;
  v_i       integer := 0;
begin
  -- A carrier's bill for freight in, onto the goods it carried
  -- (20261004945000; owner: into item cost). Once per bill. The net its
  -- rule posted to carriage outwards moves: what lands on stock still held
  -- to inventory, the rest to freight variance.
  select x.* into b from erp.document x where x.tenant_id = v_tenant and x.id = p_bill;
  select s.* into sh
    from erp.document_relation rel
    join erp.shipment s on s.tenant_id = rel.tenant_id and s.document_id = rel.to_document_id
   where rel.tenant_id = v_tenant and rel.from_document_id = p_bill and rel.relation_kind = 'invoices'
     and s.direction = 'inbound'
   limit 1;
  if b.id is null or sh.id is null then
    return null;
  end if;
  if exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = p_bill
                and j.source_code = 'freight.capitalised') then
    return null;
  end if;

  v_net := erp.document_value_minor(p_bill);
  if coalesce(v_net, 0) <= 0 then
    return null;
  end if;
  select x.document_number into v_shipno from erp.document x where x.tenant_id = v_tenant and x.id = sh.document_id;

  -- The goods it carried: the lines of the receipts it arrived with, by value.
  select coalesce(sum(l.quantity * l.unit_price_minor), 0), count(*) into v_total, v_n
    from erp.document rc
    join erp.document_line l on l.tenant_id = rc.tenant_id and l.document_id = rc.id and not l.is_cancelled
   where rc.tenant_id = v_tenant and rc.attributes ->> 'inbound_shipment_id' = sh.id::text
     and l.item_id is not null;

  if coalesce(v_total, 0) > 0 then
    for r in
      select l.id, l.quantity * l.unit_price_minor as value
        from erp.document rr
        join erp.document_line l on l.tenant_id = rr.tenant_id and l.document_id = rr.id and not l.is_cancelled
       where rr.tenant_id = v_tenant and rr.attributes ->> 'inbound_shipment_id' = sh.id::text
         and l.item_id is not null
       order by rr.document_number, l.line_no
    loop
      v_i := v_i + 1;
      -- The last line takes what rounding left, so the shares sum to the net.
      v_share := case when v_i = v_n then v_net - v_spent else floor(v_net * r.value / v_total)::bigint end;
      v_spent := v_spent + v_share;
      v_lines := v_lines || jsonb_build_object('line_id', r.id, 'share_minor', v_share,
                                               'capitalised_minor', erp.add_freight_to_receipt_line(r.id, v_share));
    end loop;
    select coalesce(sum((x ->> 'capitalised_minor')::bigint), 0) into v_applied from jsonb_array_elements(v_lines) x;
  end if;

  -- The books: the company's primary ledger, and the three accounts by purpose.
  select lg.id into v_ledger from erp.ledger lg
   where lg.tenant_id = v_tenant and lg.entity_id = b.entity_id and lg.is_primary and lg.status = 'active';
  select a.id into v_inv from erp.account a where a.tenant_id = v_tenant and a.entity_id = b.entity_id
     and a.code = erp.chart_account_code('inventory') and a.status = 'active';
  -- Freight on goods already sold is a cost of sales: freight variance where
  -- the chart keeps one (the statutory chart's 6500), else cost of sales
  -- itself, which every chart has. No account is added.
  select a.id into v_var from erp.account a where a.tenant_id = v_tenant and a.entity_id = b.entity_id
     and a.code = erp.chart_account_code('freight_variance') and a.status = 'active';
  if v_var is null then
    select a.id into v_var from erp.account a where a.tenant_id = v_tenant and a.entity_id = b.entity_id
       and a.code = erp.chart_account_code('cost_of_sales') and a.status = 'active';
  end if;
  select a.id into v_out from erp.account a where a.tenant_id = v_tenant and a.entity_id = b.entity_id
     and a.code = erp.chart_account_code('carriage_outwards') and a.status = 'active';
  if v_ledger is null or v_inv is null or v_var is null or v_out is null then
    raise exception 'CLOVEERP_ACCOUNT_NOT_ON_CHART: % lacks inventory, cost of sales or carriage outwards to capitalise freight',
      coalesce((select e.code from erp.entity e where e.id = b.entity_id), 'the company')
      using errcode = '23514',
            hint = 'Upgrade logistics, which adds carriage outwards, and finance, which installs inventory and cost of sales.';
  end if;
  select pr.id, pr.version into v_rule, v_version from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'carrier_bill' and pr.status = 'active'
   order by pr.version desc limit 1;

  v_event := erp.append_event('freight.capitalised', 'document', p_bill,
    jsonb_build_object('reference', b.document_number, 'shipment', v_shipno, 'net_minor', v_net,
                       'capitalised_minor', v_applied, 'expensed_minor', v_net - v_applied),
    b.entity_id, b.site_id);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date,
                           description, status, document_id)
  values (v_tenant, b.entity_id, v_ledger, 'freight.capitalised', v_event,
          coalesce(b.posting_date, b.document_date, current_date),
          format('Freight on %s, onto the goods it carried', coalesce(v_shipno, 'a collection')), 'draft', p_bill)
  returning id into v_journal;

  if v_applied > 0 then
    v_no := v_no + 1;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no, v_inv, v_applied, 0, b.currency, v_applied, 0, 1,
            v_rule, v_version, v_event, 'Freight in, onto the stock it carried');
    -- The inventory control carries its detail by item, as every stock posting does.
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    select v_tenant, b.entity_id, v_ledger, a.control_kind, v_inv, l.item_id, v_journal, b.currency,
           sum((x ->> 'capitalised_minor')::bigint), 0, coalesce(b.posting_date, b.document_date, current_date)
      from jsonb_array_elements(v_lines) x
      join erp.document_line l on l.id = (x ->> 'line_id')::uuid
      join erp.account a on a.id = v_inv
     where a.control_kind is not null and (x ->> 'capitalised_minor')::bigint > 0
     group by a.control_kind, l.item_id;
  end if;
  if v_net - v_applied > 0 then
    v_no := v_no + 1;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no, v_var, v_net - v_applied, 0, b.currency, v_net - v_applied, 0, 1,
            v_rule, v_version, v_event, 'Freight in on goods already sold, standard-costed or rounding');
  end if;
  v_no := v_no + 1;
  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, v_no, v_out, 0, v_net, b.currency, 0, v_net, 1,
          v_rule, v_version, v_event, 'Freight in is not carriage outwards');

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return jsonb_build_object('bill_id', p_bill, 'shipment', v_shipno, 'net_minor', v_net,
                            'capitalised_minor', v_applied, 'expensed_minor', v_net - v_applied,
                            'journal_id', v_journal, 'lines', v_lines);
end;
$$;

revoke all on function erp.capitalise_inbound_freight(uuid) from public, anon;

comment on function erp.capitalise_inbound_freight(uuid) is
  'Moves a carrier''s bill for freight in from carriage outwards onto the goods it carried: inventory '
  'for what lands on stock still held, freight variance for the rest, once per bill (20261004945000).';

-- The hooks, in erp.transition_document(). Edited, not rewritten: two
-- anchors over the body 20261004910000 left (md5 daddb01e…).

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    perform erp.apply_credit_note_to_bills(p_document_id);
  end if;
$o$,
    $n$    perform erp.apply_credit_note_to_bills(p_document_id);
  end if;

  -- A carrier's bill for freight in lands on the goods it carried as it
  -- registers, or as its dispute is resolved (20261004945000).
  if dt.base_type_code = 'invoice_reference' and p_transition_code in ('register', 'resolve')
     and v_to in ('registered', 'part_paid', 'paid') then
    perform erp.capitalise_inbound_freight(p_document_id);
  end if;
$n$,

    $o$    perform erp.advance_orders_for_receipt(p_document_id);
  end if;$o$,
    $n$    perform erp.advance_orders_for_receipt(p_document_id);
    -- And the collection that brought it arrives (20261004945000).
    perform erp.arrive_inbound_shipments(p_document_id);
  end if;$n$];
  v_hits integer;
begin
  if strpos(v_src, '20261004945000') > 0 then
    raise notice '% already brings freight in; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'daddb01eb0af364fa789f1d3fdab3155' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004945000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$transition$;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. What is on its way
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.inbound_shipments()
returns table(shipment_id uuid, document_id uuid, document_number text, order_id uuid, order_number text,
              supplier text, site_id uuid, carrier text, service_code text, tracking_reference text,
              status text, expected_arrival date, late boolean, cost_minor bigint, currency char(3),
              weight_g numeric)
language sql
stable
set search_path = ''
as $$
  -- The collections booked and not yet arrived (20261004945000), the latest
  -- expected first among the late: from whom, for which order, with which
  -- carrier, expected when, and how heavy.
  select s.id, s.document_id, d.document_number, o.id, o.document_number, p.name, s.site_id,
         c.name, s.service_code, s.tracking_reference, s.status, s.planned_arrival,
         s.planned_arrival < current_date, s.freight_cost_minor, s.currency,
         nullif(s.total_weight_g, 0)
    from erp.shipment s
    left join erp.document d on d.tenant_id = s.tenant_id and d.id = s.document_id
    left join erp.shipment_line sl on sl.tenant_id = s.tenant_id and sl.shipment_id = s.id
    left join erp.document o on o.tenant_id = sl.tenant_id and o.id = sl.document_id
    left join erp.party p on p.tenant_id = s.tenant_id and p.id = s.origin_party_id
    left join erp.carrier c on c.tenant_id = s.tenant_id and c.id = s.carrier_id
   where s.tenant_id = erp.current_tenant_id()
     and s.direction = 'inbound' and s.status in ('planned', 'booked')
   order by (s.planned_arrival < current_date) desc, s.planned_arrival nulls last, d.document_number
$$;

revoke all on function erp.inbound_shipments() from public, anon;

create or replace function public.erp_inbound_shipments()
returns jsonb
language sql
stable
set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from erp.inbound_shipments() s $$;

revoke all on function public.erp_inbound_shipments() from public, anon;
grant execute on function public.erp_inbound_shipments() to authenticated, service_role;

comment on function public.erp_inbound_shipments() is
  'Collections on their way: from whom, for which order, with which carrier, expected when (20261004945000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.inbound_freight_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid; v_carrier text;
  v_po uuid; v_po2 uuid; v_ship jsonb; v_grn uuid; v_bill uuid; v_cap jsonb;
  v_val0 bigint; v_val1 bigint; v_out0 bigint; v_out1 bigint; v_list jsonb; v_row jsonb; v_tie text;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys and ships, with logistics installed to its latest';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzifr-' || v_tag, 'Inbound Freight Suite',
      'admin@zzifr-' || v_tag || '.test', 'Freight Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzifr-' || v_tag || '.test'), (s_buy, 'buyer@zzifr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('buyer@zzifr-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, two products, a supplier and a carrier';
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZFCOAT', 'Collected Coat', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZFSCARF', 'Collected Scarf', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZFBRAND');
    select c.code into v_carrier from erp.carrier c where c.tenant_id = rb.tenant_id and c.status = 'active'
     order by c.code limit 1;
    if v_carrier is null then
      raise exception 'the demonstration configuration installs no carrier';
    end if;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, the refusals, the event and the columns';
    v_cases := v_cases + 1;
    case_name := 'both write doors are on the allow-list under their gates and on the Procurement screen''s help, the four refusals are registered with a next action, freight.capitalised is current in English and German, and a shipment knows its direction';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance a
                where (a.function_name, a.gate) in (('erp_set_freight_terms', 'erp.set_freight_terms'),
                                                    ('erp_ship_inbound', 'erp.ship_inbound'))) = 2
          and exists (select 1 from erp_ref.help_topic h where h.screen_path = '/procurement'
                         and h.actions @> array['erp_set_freight_terms', 'erp_ship_inbound'])
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_FREIGHT_TERMS_UNKNOWN', 'CLOVEERP_ORDER_NOT_COLLECTED',
                                 'CLOVEERP_INBOUND_ALREADY_BOOKED', 'CLOVEERP_SHIPMENT_WEIGHT_INVALID')
                  and coalesce(f.next_action, '') <> '') = 4
          and (select count(*) from erp_ref.resource x
                where x.key = 'event.freight.capitalised' and x.locale in ('en', 'de')) = 2
          and exists (select 1 from information_schema.columns
                       where table_schema = 'erp' and table_name = 'shipment' and column_name = 'direction');
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. An order we collect, booked ──────────────────────────────────────
    v_step := 'ten coats and ten scarves ordered ex works, sent, and the collection booked at £100';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZIF2', false);
    perform erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
    perform public.erp_set_freight_terms(v_po, 'we_collect');
    perform erp.transition_document(v_po, 'send', null);
    v_ship := public.erp_ship_inbound(v_po, v_carrier, 'standard', 10000, current_date + 3, 'TRK-123', 12500);
    v_list := public.erp_inbound_shipments();
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'shipment_id' = v_ship ->> 'shipment_id';
    v_cases := v_cases + 1;
    case_name := 'an order we collect, once sent, books an inbound shipment on the shipment document from the supplier to the order''s site: booked at the cost named, with its tracking reference, expected arrival and the weight given, listed as on its way, with its weight, and not late';
    passed := v_state is null
          and erp.order_freight_terms(v_po) = 'we_collect'
          and v_ship ->> 'status' = 'booked'
          and (v_ship ->> 'cost_minor')::bigint = 10000
          and v_ship ->> 'tracking_reference' = 'TRK-123'
          and (v_ship ->> 'expected_arrival')::date = current_date + 3
          and (v_ship ->> 'weight_g')::numeric = 12500
          and erp.object_current_state('document', (v_ship ->> 'document_id')::uuid) = 'booked'
          and (select s.direction from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = 'inbound'
          and (select s.origin_party_id from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = v_sa
          and v_row is not null and v_row ->> 'order_number' = (select d.document_number from erp.document d where d.id = v_po)
          and not (v_row ->> 'late')::boolean
          and (v_row ->> 'weight_g')::numeric = 12500;
    detail := coalesce(v_state, left(format('%s; listed %s', v_ship, v_row), 600));
    return next;

    -- ── 3. What may not be booked ───────────────────────────────────────────
    v_step := 'a second collection, an order the supplier delivers, terms nobody knows, and the buyer booking';
    begin
      perform public.erp_ship_inbound(v_po, v_carrier, 'standard', 10000, null, null);
      v_err := 'booked';
    exception when others then v_err := sqlerrm; end;
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 9000, 'ZIF3');
    begin
      perform public.erp_ship_inbound(v_po2, v_carrier, 'standard', 10000, null, null);
      v_err2 := 'booked';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_set_freight_terms(v_po2, 'courier');
      v_err3 := 'set';
    exception when others then v_err3 := sqlerrm; end;
    perform public.erp_set_freight_terms(v_po2, 'we_collect');
    begin
      perform public.erp_ship_inbound(v_po2, v_carrier, 'standard', 10000, null, null, 0);
      v_err5 := 'booked';
    exception when others then v_err5 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform public.erp_ship_inbound(v_po2, v_carrier, 'standard', 10000, null, null);
      v_err4 := 'booked';
    exception when others then v_err4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a second collection for one order, a collection for an order the supplier delivers, terms nobody knows, a weight of nothing, and a buyer without logistics.plan are each refused by name';
    passed := v_state is null
          and v_err like 'CLOVEERP_INBOUND_ALREADY_BOOKED:%'
          and v_err2 like 'CLOVEERP_ORDER_NOT_COLLECTED:%'
          and v_err3 like 'CLOVEERP_FREIGHT_TERMS_UNKNOWN:%'
          and v_err4 like 'CLOVEERP_PERMISSION_DENIED: logistics.plan%'
          and v_err5 like 'CLOVEERP_SHIPMENT_WEIGHT_INVALID:%';
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 700));
    return next;

    -- ── 4. It arrives with its goods ────────────────────────────────────────
    v_step := 'the goods received against the order';
    v_grn := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_grn, (select l.id from erp.document_line l where l.document_id = v_po and l.item_id = v_item), 10, null);
    perform erp.receive_against(v_grn, (select l.id from erp.document_line l where l.document_id = v_po and l.item_id = v_item2), 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    v_cases := v_cases + 1;
    case_name := 'the receipt delivers the collection by itself and names it: the shipment reads delivered with the receipt as its proof, and it is no longer on its way';
    passed := v_state is null
          and erp.object_current_state('document', (v_ship ->> 'document_id')::uuid) = 'delivered'
          and (select s.status from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = 'delivered'
          and (select d.attributes ->> 'inbound_shipment_id' from erp.document d where d.id = v_grn) = v_ship ->> 'shipment_id'
          and (select s.proof_of_delivery ->> 'reference' from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid)
              = (select d.document_number from erp.document d where d.id = v_grn)
          and not exists (select 1 from jsonb_array_elements(public.erp_inbound_shipments()) x
                           where x ->> 'shipment_id' = v_ship ->> 'shipment_id');
    detail := coalesce(v_state, format('shipment %s', erp.object_current_state('document', (v_ship ->> 'document_id')::uuid)));
    return next;

    -- ── 5. Half the coats are sold, then the carrier bills ──────────────────
    v_step := 'five coats leave the stock, then the carrier bills £100';
    perform erp.write_off_stock(v_item, v_site,
      (select m.to_location_id from erp.stock_movement m where m.document_id = v_grn and m.item_id = v_item limit 1),
      5, 'sold at the counter', null, null);
    select coalesce(sum(v.value_minor), 0) into v_val0 from erp.stock_valuation_report() v;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_out0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = erp.chart_account_code('carriage_outwards');
    v_bill := erp.bill_from_shipment((v_ship ->> 'shipment_id')::uuid, 'CARR-INV-9', 10000, null, null, null, null);
    select coalesce(sum(v.value_minor), 0) into v_val1 from erp.stock_valuation_report() v;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_out1
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = erp.chart_account_code('carriage_outwards');
    select to_jsonb(e.payload) into v_cap from erp.event e
     where e.tenant_id = rb.tenant_id and e.event_type = 'freight.capitalised' and e.aggregate_id = v_bill;
    v_cases := v_cases + 1;
    case_name := 'the carrier''s £100 bill registers and lands on the goods it carried: carriage outwards is left untouched, the stock''s value rises by exactly what was capitalised, which is the freight on the coats and scarves still held, and the coats already gone go to freight variance';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'registered'
          and v_out1 = v_out0
          and v_cap is not null
          and (v_cap ->> 'net_minor')::bigint = 10000
          and v_val1 - v_val0 = (v_cap ->> 'capitalised_minor')::bigint
          -- Coats are £900 of £1,000 of value: £90 of freight, half still held, so £45; scarves £10, all held.
          and (v_cap ->> 'capitalised_minor')::bigint = 5500
          and (v_cap ->> 'expensed_minor')::bigint = 4500
          and exists (select 1 from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
                       join erp.account a on a.id = jl.account_id
                      where j.document_id = v_bill and j.source_code = 'freight.capitalised'
                        and a.code in (erp.chart_account_code('freight_variance'), erp.chart_account_code('cost_of_sales'))
                        and jl.debit_minor = 4500);
    detail := coalesce(v_state, left(format('bill %s; cap %s; value +%s; 7200 %s→%s',
      erp.object_current_state('document', v_bill), v_cap, v_val1 - v_val0, v_out0, v_out1), 600));
    return next;

    -- ── 6. The ties hold ────────────────────────────────────────────────────
    v_step := 'the whole database reconciled';
    set constraints all immediate;
    begin
      perform erp.assert_whole_database_reconciles();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'after freight lands on the stock, the whole database reconciles: stock to the ledger, payables to the control, and the trial balance';
    passed := v_state is null and v_tie = 'ties';
    detail := coalesce(v_state, v_tie);
    return next;

    -- ── 7. Once ─────────────────────────────────────────────────────────────
    v_step := 'capitalising the same bill again';
    v_cases := v_cases + 1;
    case_name := 'a bill''s freight is capitalised once: asking again does nothing';
    passed := v_state is null
          and erp.capitalise_inbound_freight(v_bill) is null
          and (select count(*) from erp.journal j where j.document_id = v_bill and j.source_code = 'freight.capitalised') = 1;
    detail := coalesce(v_state, 'once');
    return next;

    -- ── 8. Freight out is untouched ─────────────────────────────────────────
    v_step := 'an ordinary bill is not freight in';
    v_cases := v_cases + 1;
    case_name := 'a bill that is not a carrier''s for an inbound shipment is never capitalised';
    passed := v_state is null
          and erp.capitalise_inbound_freight(
                erp.bill_from_receipt(erp_test.return_receipt(v_po2, 1), 'ZIF-INV-8', current_date, current_date + 30, true)) is null;
    detail := coalesce(v_state, 'untouched');
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzifr-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_buy))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzifr rolled back with its collections, receipts and bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_INBOUND_FREIGHT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.inbound_freight_suite() from public, anon;

comment on function erp_test.inbound_freight_suite() is
  'Freight comes in on our account (20261004945000): an order we collect books an inbound shipment, '
  'refused by name where it may not; the receipt delivers it; the carrier''s bill lands on the goods '
  'still held and the rest goes to freight variance, carriage outwards untouched, once; and the whole '
  'database reconciles.';

create or replace function erp_test.assert_inbound_freight_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.inbound_freight_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_INBOUND_FREIGHT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Freight in would miss the goods it carried, or part stock from the ledger. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_INBOUND_FREIGHT_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('inbound freight: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_inbound_freight_suite() from public, anon;

comment on function erp_test.assert_inbound_freight_suite() is
  'Inbound freight is booked, arrives with its goods and lands on them without parting stock from the '
  'ledger (20261004945000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Collections on their way, on the Purchasing screen (20261004945000).'
  from (values
    ('On its way'),
    ('Collections we booked from suppliers, until their goods are received.'),
    ('Nothing is on its way. A collection booked for an order we collect lands here until its goods arrive.'),
    ('Late'),
    ('Expected'),
    ('Tracking'),
    ('Set freight terms'),
    ('Who brings the goods: the supplier, delivered at their cost, or us, collected at ours.'),
    ('Freight terms'),
    ('The supplier delivers'),
    ('We collect'),
    ('Book a collection'),
    ('Books a carrier to collect an order we collect from the supplier. When the goods are received it arrives, and the carrier''s bill lands on them.'),
    ('Carrier'),
    ('Service'),
    ('Cost'),
    ('Leave empty to take the rate card''s price.'),
    ('Expected arrival'),
    ('Tracking reference')
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
select erp.assert_every_transition_is_driven();
