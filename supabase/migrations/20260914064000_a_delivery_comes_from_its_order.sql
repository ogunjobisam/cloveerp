-- A delivery comes from its order.
--
-- Writing the user guide for the companies being onboarded, the order to cash
-- chapter stopped at despatch. Each finding was checked against the functions
-- as they stand after every patch before this file was written, and each was
-- true:
--
--   1. Nothing raises a delivery from a sales order. erp.convert_document
--      (20260910225559, patched by 20260914060000) converts a requisition into
--      a purchase order and a quotation into a sales order, and refuses
--      everything else. erp.pick_document (20260910165931) reserves and picks
--      and raises nothing. The New delivery form asked for the customer, the
--      site and every line again, typed.
--
--   2. A sales order line does not know what has been delivered.
--      erp.refresh_order_line_progress (20260829250000, never patched) counts a
--      line's quantity_fulfilled from goods receipts only, and nothing calls it
--      for a sales order. The one place a delivery was tied to an order, the
--      demonstration (20260905010000), links the two documents with no lines
--      and no quantity per line, and moves the order through pick and despatch
--      by hand.
--
--   3. public.erp_link_documents authorises procurement.order, so the one
--      person who despatches could not even link a delivery to its order by
--      hand. It is left as it is: the delivery below writes its own links, as
--      erp.convert_document writes its own.
--
--   4. The Despatch module said a delivery "is confirmed or failed on its own
--      document page". A delivery's lifecycle (erp.configure_sales) has two
--      moves out of draft, post and cancel, and that is all its page offers.
--
-- What this file does, in order:
--
--   1. What is left to deliver. erp.deliverable_lines(order) answers, for each
--      line of a sales order that carries a product and a quantity and is not
--      cancelled: what was ordered, what posted deliveries delivered
--      (quantity_fulfilled), what is on deliveries raised from it that are not
--      cancelled, posted or not, and what is left: the ordered quantity less
--      the greater of the last two. A draft delivery holds its quantity, so two
--      drafts cannot both take the same goods; a line fulfilled some other way
--      (a drop-ship, 20260906131000) has nothing left. Read as the caller.
--
--   2. The door. public.erp_create_delivery_from_order(p_order_id, p_lines,
--      p_transition) runs erp.create_delivery_from_order as the caller:
--        * refuses an order nobody may see (CLOVEERP_UNKNOWN_DOCUMENT), then
--          authorises sales.despatch for the order's company and site;
--        * refuses a document that is not a sales order
--          (CLOVEERP_NOT_A_SALES_ORDER), and an order that is not confirmed or
--          being picked (CLOVEERP_ORDER_NOT_READY_TO_DELIVER): a draft is not
--          agreed, one waiting on its approval is not approved, and one already
--          despatched, invoiced, closed or cancelled takes no new delivery;
--        * locks the order row, so two people cannot both take what is left;
--        * takes every line at what is left, or the lines p_lines names, each
--          at the quantity given or at what is left when none is given. A line
--          that is not an open product line of the order is refused
--          (CLOVEERP_NOT_A_LINE_OF_THE_ORDER), a quantity over what is left is
--          refused (CLOVEERP_MORE_THAN_LEFT_TO_DELIVER), and a delivery of
--          nothing is refused (CLOVEERP_NOTHING_TO_DELIVER);
--        * opens a draft delivery of the organisation's delivery type
--          (CLOVEERP_NO_DELIVERY_TYPE where there is none) for the order's
--          customer, company, site, currency, required date and customer
--          reference, with the order's number as our reference and its delivery
--          address;
--        * adds each line through erp.add_document_line with the order line's
--          product, price and description, then its unit, discount, net value,
--          analysis, and stock identity: the location and batch the order line
--          is pinned to, or where one committed pick holds the whole quantity at
--          one location and batch, that one. Posting finds the stock otherwise;
--        * links each delivery line to its order line ('fulfils', from the
--          delivery to the order, with the quantity), which links the two
--          documents in both directions for lineage;
--        * with p_transition 'auto', moves the delivery on as Create and move on
--          does (erp.onward_transition, 20260914060000): out of draft that is
--          post. Any other code is performed as given.
--
--   3. Delivered quantities are counted on the order. erp.refresh_order_line_
--      progress keeps counting goods receipts exactly as it did, and adds what
--      posted deliveries linked to the line delivered. Posting a delivery
--      (erp.transition_document, patched as 20260910165931 patched it for
--      receipts) asks erp.advance_orders_for_delivery: each sales order the
--      delivery is linked to has the linked lines refreshed, and once every
--      open product line is delivered in full, the order is moved to
--      despatched by the moves its own lifecycle declares from where it
--      stands — despatch from picking, or pick then despatch from confirmed —
--      each through erp.transition_document, so each is authorised and guarded
--      as if a person pressed it. A delivery that is not raised from an order
--      carries no line links and moves nothing. Where the order cannot move
--      (its lifecycle has no such path, a guard, a permission), the delivery
--      still posts and the order stays where it is for somebody to move. A
--      part delivery leaves the order where it is.
--
--   4. public.erp_deliverable_lines(p_order_id) lists the lines with something
--      left, so the desk's form arrives holding them.
--
-- The desk offers "Create a delivery from this order" on a sales order's page
-- and on the sales order step of Sales, and "Create a delivery from an order"
-- on the Sales and Despatch bars; the form arrives holding the open lines at
-- what is left, editable. The Despatch copy no longer promises a confirm or a
-- fail the delivery page does not have.
--
-- Proof: erp_test.delivery_from_order_suite(), seventeen cases, pinned by its
-- wrapper.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What is left to deliver
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.deliverable_lines(p_order_id uuid)
returns table (
  line_id                uuid,
  line_no                integer,
  item_id                uuid,
  ordered_quantity       numeric,
  delivered_quantity     numeric,
  on_deliveries_quantity numeric,
  open_quantity          numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  select dl.id,
         dl.line_no,
         dl.item_id,
         dl.quantity,
         dl.quantity_fulfilled,
         coalesce(x.on_deliveries, 0),
         greatest(dl.quantity - greatest(dl.quantity_fulfilled, coalesce(x.on_deliveries, 0)), 0)
    from erp.document_line dl
    left join lateral (
      -- Every delivery raised from the line that is not cancelled, posted or
      -- not: a draft holds what it carries.
      select sum(rel.quantity) as on_deliveries
        from erp.document_relation rel
        join erp.document dd
          on dd.tenant_id = rel.tenant_id and dd.id = rel.from_document_id
        join erp.document_type ddt
          on ddt.tenant_id = dd.tenant_id and ddt.id = dd.document_type_id
        left join erp.object_state dos
          on dos.tenant_id = dd.tenant_id and dos.object_type = 'document' and dos.object_id = dd.id
        left join erp.state ds on ds.id = dos.current_state_id
       where rel.tenant_id = dl.tenant_id
         and rel.to_line_id = dl.id
         and rel.relation_kind = 'fulfils'
         and ddt.base_type_code = 'delivery'
         and not (dd.is_cancelled or coalesce(ds.code = 'cancelled', false))
    ) x on true
   where dl.tenant_id = erp.current_tenant_id()
     and dl.document_id = p_order_id
     and not dl.is_cancelled
     and dl.item_id is not null
     and dl.quantity > 0
   order by dl.line_no
$$;

comment on function erp.deliverable_lines(uuid) is
  'For each open product line of a sales order: what was ordered, what posted '
  'deliveries delivered, what deliveries raised from it that are not cancelled '
  'hold, posted or not, and what is left: ordered less the greater of the two. '
  'Reads as the caller; lists nothing outside the caller''s organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Delivered quantities are counted on the order line
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Restated whole: nothing has patched it since 20260829250000. The receipt
-- count and the invoiced count are as they were; what posted deliveries linked
-- to the line delivered is added to the fulfilled count. A purchase order line
-- has no delivery linked to it, so it counts exactly what it counted.

create or replace function erp.refresh_order_line_progress(p_order_line_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  update erp.document_line ol
     set quantity_fulfilled = coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document rd on rd.id = rel.from_document_id
             join erp.document_type rdt on rdt.id = rd.document_type_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled), 0)
         -- What posted deliveries raised from the line delivered
         -- (20260914064000). A draft delivery holds its quantity against what
         -- is left (erp.deliverable_lines) and delivers nothing until it posts.
         + coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document dd
               on dd.tenant_id = rel.tenant_id and dd.id = rel.from_document_id
             join erp.document_type ddt
               on ddt.tenant_id = dd.tenant_id and ddt.id = dd.document_type_id
             join erp.object_state dos
               on dos.tenant_id = dd.tenant_id and dos.object_type = 'document' and dos.object_id = dd.id
             join erp.state ds on ds.id = dos.current_state_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and rel.relation_kind = 'fulfils'
              and ddt.base_type_code = 'delivery'
              and not dd.is_cancelled
              and ds.is_committed), 0),
         quantity_invoiced = coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document id2 on id2.id = rel.from_document_id
             join erp.document_type idt on idt.id = id2.document_type_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and idt.base_type_code in ('invoice_reference', 'credit_reference')
              and not id2.is_cancelled), 0),
         updated_at = now()
   where ol.tenant_id = v_tenant and ol.id = p_order_line_id;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A delivery is created from its order
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.create_delivery_from_order(
  p_order_id   uuid,
  p_lines      jsonb default null,
  p_transition text  default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant     uuid := erp.require_tenant_id();
  d            erp.document%rowtype;
  ol           erp.document_line%rowtype;
  l            record;
  v_base       text;
  v_state      text;
  v_state_name text;
  v_type       text;
  v_unknown    text;
  v_asked      integer;
  v_qty        numeric;
  v_plan_lines uuid[] := '{}'::uuid[];
  v_plan_qty   numeric[] := '{}'::numeric[];
  v_total      numeric := 0;
  v_dn         uuid;
  v_line       uuid;
  v_loc        uuid;
  v_batch      uuid;
  v_pick_loc   uuid;
  v_pick_batch uuid;
  v_moved      text := null;
  i            integer;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: no such sales order in this organisation'
      using errcode = '23503',
            hint = 'Choose the sales order from the list of orders that can still be despatched.';
  end if;

  -- Creating a delivery is despatching: the permission its lifecycle's post
  -- and cancel ask for, and the permission a delivery is created under.
  perform erp.authorise('sales.despatch', d.entity_id, d.site_id, null, 'document', p_order_id);

  select dt.base_type_code into v_base
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if v_base is distinct from 'sales_order' then
    raise exception 'CLOVEERP_NOT_A_SALES_ORDER: % is a %, and a delivery is created from a sales order',
      d.document_number, coalesce(v_base, 'document')
      using errcode = '23514',
            hint = 'Choose a confirmed sales order. Goods that answer no order leave on a delivery raised with New delivery.';
  end if;

  select s.code, s.name into v_state, v_state_name
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_order_id;

  if d.is_cancelled or coalesce(v_state, '') not in ('confirmed', 'picking') then
    raise exception 'CLOVEERP_ORDER_NOT_READY_TO_DELIVER: % is %, and a delivery is created from an order that is confirmed or being picked',
      d.document_number,
      case when d.is_cancelled then 'cancelled' else lower(coalesce(v_state_name, 'not started')) end
      using errcode = '23514',
            hint = 'Submit the order and have it approved first. An order already despatched, invoiced, closed or cancelled takes no new delivery.';
  end if;

  -- One delivery at a time from one order, so two people cannot both take what
  -- is left.
  perform 1 from erp.document where tenant_id = v_tenant and id = p_order_id for update;

  select dt.code into v_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'delivery' and dt.status = 'active'
   order by (dt.entity_id = d.entity_id) desc nulls last, (dt.entity_id is null) desc, dt.code
   limit 1;

  if v_type is null then
    raise exception 'CLOVEERP_NO_DELIVERY_TYPE: this organisation has no delivery document type in use'
      using errcode = '23503',
            hint = 'Install sales on the Configuration screen, which adds the delivery type, then create the delivery.';
  end if;

  -- The lines asked for are lines of this order.
  if p_lines is not null and jsonb_typeof(p_lines) <> 'array' then
    raise exception 'CLOVEERP_NOT_A_LINE_OF_THE_ORDER: the lines to deliver are not a list of the order''s lines'
      using errcode = '22023',
            hint = 'Send a list of the order''s lines, each with its line_id and, to deliver less than is left, a quantity.';
  end if;

  if p_lines is not null then
    select string_agg(coalesce(e ->> 'line_id', 'a line with no line_id'), ', ')
      into v_unknown
      from jsonb_array_elements(p_lines) e
     where not exists (
       select 1
         from erp.document_line dl
        where dl.tenant_id = v_tenant
          and dl.document_id = p_order_id
          and dl.id::text = e ->> 'line_id'
          and not dl.is_cancelled
          and dl.item_id is not null
          and dl.quantity > 0);

    if v_unknown is not null then
      raise exception 'CLOVEERP_NOT_A_LINE_OF_THE_ORDER: % is not an open product line of %', v_unknown, d.document_number
        using errcode = '23503',
              hint = 'Choose lines of the order the delivery is created from. A cancelled line, or one with no product, is not delivered.';
    end if;
  end if;

  -- What goes, line by line, before anything is written.
  for l in
    select x.line_id, x.line_no, x.open_quantity
      from erp.deliverable_lines(p_order_id) x
     order by x.line_no
  loop
    if p_lines is null then
      v_qty := l.open_quantity;
    else
      select count(*),
             sum(coalesce(nullif(btrim(e ->> 'quantity'), '')::numeric, l.open_quantity))
        into v_asked, v_qty
        from jsonb_array_elements(p_lines) e
       where e ->> 'line_id' = l.line_id::text;

      if v_asked = 0 then
        continue;
      end if;
    end if;

    if coalesce(v_qty, 0) <= 0 then
      continue;
    end if;

    if v_qty > l.open_quantity then
      raise exception 'CLOVEERP_MORE_THAN_LEFT_TO_DELIVER: line % of % has % left to deliver, and % was asked for',
        l.line_no, d.document_number, trim_scale(l.open_quantity), trim_scale(v_qty)
        using errcode = '23514',
              hint = 'Deliver what is left, or less. What is already on a delivery, posted or not, is not left to deliver.';
    end if;

    v_plan_lines := v_plan_lines || l.line_id;
    v_plan_qty := v_plan_qty || v_qty;
    v_total := v_total + v_qty;
  end loop;

  if cardinality(v_plan_lines) = 0 then
    raise exception 'CLOVEERP_NOTHING_TO_DELIVER: % has nothing to deliver: every line has been delivered or is on a delivery already, or no line was chosen',
      d.document_number
      using errcode = '23514',
            hint = 'Post or cancel the deliveries already raised from the order, or choose a line with something left on it.';
  end if;

  -- The delivery: the order's customer, company, site and terms.
  v_dn := erp.open_document(v_type, d.party_id, d.entity_id, d.site_id,
                            d.their_reference, d.required_date, d.currency);

  update erp.document
     set party_role_id    = d.party_role_id,
         address_snapshot = d.address_snapshot,
         our_reference    = d.document_number,
         notes            = format('Delivery for sales order %s', d.document_number),
         updated_at       = now()
   where tenant_id = v_tenant and id = v_dn;

  for i in 1 .. cardinality(v_plan_lines) loop
    select * into ol from erp.document_line where tenant_id = v_tenant and id = v_plan_lines[i];

    -- Where the goods are: the location and batch the order line is pinned to,
    -- or the one location and batch a committed pick holds the whole quantity
    -- at. Otherwise posting finds the stock where it stands.
    v_loc := ol.location_id;
    v_batch := ol.batch_id;
    if v_loc is null then
      select case when count(distinct aln.location_id) = 1
                   and count(distinct coalesce(aln.batch_id::text, '')) = 1
                   and coalesce(sum(aln.quantity), 0) >= v_plan_qty[i]
                  then (array_agg(aln.location_id))[1] end,
             case when count(distinct aln.location_id) = 1
                   and count(distinct coalesce(aln.batch_id::text, '')) = 1
                   and coalesce(sum(aln.quantity), 0) >= v_plan_qty[i]
                  then (array_agg(aln.batch_id))[1] end
        into v_pick_loc, v_pick_batch
        from erp.allocation al
        join erp.allocation_line aln
          on aln.tenant_id = al.tenant_id and aln.allocation_id = al.id
       where al.tenant_id = v_tenant
         and al.document_line_id = ol.id
         and al.status in ('committed', 'picked')
         and aln.status in ('committed', 'picked');

      if v_pick_loc is not null and (v_batch is null or v_batch is not distinct from v_pick_batch) then
        v_loc := v_pick_loc;
        v_batch := coalesce(v_batch, v_pick_batch);
      end if;
    end if;

    v_line := erp.add_document_line(v_dn, ol.item_id, v_plan_qty[i],
                                    coalesce(ol.unit_price_minor, 0),
                                    ol.description, ol.required_date);

    update erp.document_line
       set uom_id       = ol.uom_id,
           discount_pct = coalesce(ol.discount_pct, 0),
           net_minor    = round(v_plan_qty[i] * coalesce(ol.unit_price_minor, 0)
                                * (1 - coalesce(ol.discount_pct, 0) / 100.0))::bigint,
           dimensions   = coalesce(ol.dimensions, '{}'::jsonb),
           location_id  = v_loc,
           batch_id     = v_batch,
           container_id = ol.container_id,
           updated_at   = now()
     where tenant_id = v_tenant and id = v_line;

    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    values (v_tenant, v_dn, p_order_id, 'fulfils', v_line, ol.id, v_plan_qty[i]);
  end loop;

  if coalesce(p_transition, '') <> '' then
    if p_transition = 'auto' then
      -- The move forward, as Create and move on asks it (20260914060000): out
      -- of draft, post.
      v_moved := erp.onward_transition('document', v_dn,
                   erp.document_transition_context(v_dn, null));
    else
      v_moved := p_transition;
    end if;

    if v_moved is not null then
      perform erp.transition_document(v_dn, v_moved,
                                      format('Created from sales order %s', d.document_number));
    end if;
  end if;

  return jsonb_build_object(
    'document_id', v_dn,
    'document_number', (select dn.document_number from erp.document dn
                         where dn.tenant_id = v_tenant and dn.id = v_dn),
    'order_document_number', d.document_number,
    'lines', cardinality(v_plan_lines),
    'quantity', v_total,
    'moved_on', v_moved,
    'order_state', erp.object_current_state('document', p_order_id));
end;
$$;

comment on function erp.create_delivery_from_order(uuid, jsonb, text) is
  'Creates a draft delivery from a sales order that is confirmed or being '
  'picked, under sales.despatch: its customer, company, site and terms, each '
  'open line at what is left (or the lines and quantities p_lines names) with '
  'the order line''s product, price, description, unit and stock identity, '
  'each linked back to its order line. Refuses a document that is not a sales '
  'order, an order in any other state, a line of another order, more than is '
  'left, and nothing at all, by name. p_transition ''auto'' moves the delivery '
  'on (post). Runs as the caller.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Posting a delivery moves its order on
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.advance_orders_for_delivery(p_delivery_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_number text;
  r        record;
  v_line   uuid;
  v_full   boolean;
  v_path   text[];
  v_step   text;
  v_moved  integer := 0;
begin
  select dn.document_number into v_number
    from erp.document dn
   where dn.tenant_id = v_tenant and dn.id = p_delivery_id;

  for r in
    select distinct rel.to_document_id as order_id
      from erp.document_relation rel
      join erp.document od
        on od.tenant_id = rel.tenant_id and od.id = rel.to_document_id
      join erp.document_type odt
        on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_delivery_id
       and rel.relation_kind = 'fulfils'
       and rel.to_line_id is not null
       and odt.base_type_code = 'sales_order'
       and not od.is_cancelled
  loop
    -- Delivered quantities are derived; refresh the lines this delivery
    -- answers before reading them.
    for v_line in
      select distinct rel.to_line_id
        from erp.document_relation rel
       where rel.tenant_id = v_tenant
         and rel.from_document_id = p_delivery_id
         and rel.to_document_id = r.order_id
         and rel.relation_kind = 'fulfils'
         and rel.to_line_id is not null
    loop
      perform erp.refresh_order_line_progress(v_line);
    end loop;

    select coalesce(bool_and(dl.quantity_fulfilled >= dl.quantity), false)
      into v_full
      from erp.document_line dl
     where dl.tenant_id = v_tenant
       and dl.document_id = r.order_id
       and not dl.is_cancelled
       and dl.item_id is not null
       and dl.quantity > 0;

    -- A part delivery leaves the order where it is.
    if not v_full then
      continue;
    end if;

    -- The way to despatched the order's own lifecycle declares from where it
    -- stands: one move, or one move and then another. Read from the version
    -- the order runs under, as erp.perform_transition reads it.
    v_path := null;
    select array[t.code] into v_path
      from erp.object_state os
      join erp.transition t
        on t.tenant_id = os.tenant_id
       and t.state_machine_version_id = os.state_machine_version_id
       and t.from_state_id = os.current_state_id
      join erp.state ts on ts.tenant_id = t.tenant_id and ts.id = t.to_state_id
     where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = r.order_id
       and ts.code = 'despatched'
       and not t.is_automatic
     order by t.sort_order, t.code
     limit 1;

    if v_path is null then
      select array[t1.code, t2.code] into v_path
        from erp.object_state os
        join erp.transition t1
          on t1.tenant_id = os.tenant_id
         and t1.state_machine_version_id = os.state_machine_version_id
         and t1.from_state_id = os.current_state_id
        join erp.state s1 on s1.tenant_id = t1.tenant_id and s1.id = t1.to_state_id
        join erp.transition t2
          on t2.tenant_id = t1.tenant_id
         and t2.state_machine_version_id = t1.state_machine_version_id
         and t2.from_state_id = t1.to_state_id
        join erp.state s2 on s2.tenant_id = t2.tenant_id and s2.id = t2.to_state_id
       where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = r.order_id
         and s2.code = 'despatched'
         and not s1.is_terminal
         and not t1.is_automatic
         and not t2.is_automatic
       order by s1.sort_order, t1.sort_order, t1.code, t2.sort_order, t2.code
       limit 1;
    end if;

    -- Already despatched or beyond, or a lifecycle with no way there.
    if v_path is null then
      continue;
    end if;

    -- Each move as a person pressing it would make it: authorised, guarded,
    -- recorded. The delivery has posted whatever the order does; an order that
    -- cannot move stays where it stands for somebody who may move it.
    begin
      foreach v_step in array v_path loop
        perform erp.transition_document(r.order_id, v_step,
                                        format('Delivered in full by %s', v_number));
      end loop;
      v_moved := v_moved + 1;
    exception when others then
      raise warning 'sales order % was delivered in full by %, and stays where it is: %',
        r.order_id, v_number, sqlerrm;
    end;
  end loop;

  return v_moved;
end;
$$;

comment on function erp.advance_orders_for_delivery(uuid) is
  'Called when a delivery posts. Refreshes the delivered quantities of the '
  'sales order lines the delivery is linked to, and moves each order delivered '
  'in full to despatched by the moves its lifecycle declares from where it '
  'stands, each through erp.transition_document. A part delivery, or an order '
  'that cannot move, is left where it is.';

-- The transition asks, for a delivery, as 20260910165931 made it ask for a
-- receipt.

do $patch$
declare
  v_sig text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_old text := $p$  -- An order that has been received in full should not still read "Sent".
  if coalesce(v_committed, false) and dt.base_type_code = 'receipt' then
    perform erp.advance_orders_for_receipt(p_document_id);
  end if;
$p$;
  v_new text := $q$  -- An order that has been received in full should not still read "Sent".
  if coalesce(v_committed, false) and dt.base_type_code = 'receipt' then
    perform erp.advance_orders_for_receipt(p_document_id);
  end if;

  -- A sales order delivered in full should not still read "Confirmed"
  -- (20260914064000). Only a delivery created from its order carries the line
  -- links this follows; any other delivery moves nothing.
  if coalesce(v_committed, false) and dt.base_type_code = 'delivery' then
    perform erp.advance_orders_for_delivery(p_document_id);
  end if;
$q$;
begin
  if position('erp.advance_orders_for_delivery(' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % already asks erp.advance_orders_for_delivery()', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not advance receipts the way the 20260910165931 body does', v_sig;
  end if;

  execute replace(v_def, v_old, v_new);

  if position('perform erp.advance_orders_for_delivery(p_document_id);' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('perform erp.advance_orders_for_receipt(p_document_id);' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without both advances', v_sig;
  end if;
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The doors
-- ═════════════════════════════════════════════════════════════════════════════

create function public.erp_create_delivery_from_order(
  p_order_id   uuid,
  p_lines      jsonb default null,
  p_transition text  default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.create_delivery_from_order(p_order_id, p_lines, p_transition)
$$;

comment on function public.erp_create_delivery_from_order(uuid, jsonb, text) is
  'Creates a draft delivery from a confirmed or picking sales order, holding '
  'what is left to deliver on each line (or the lines and quantities p_lines '
  'names: [{"line_id": …, "quantity": …}]), each line linked back to the '
  'order. p_transition ''auto'' posts it as well. Authorises sales.despatch. '
  'Runs as the caller.';

revoke all on function public.erp_create_delivery_from_order(uuid, jsonb, text) from public, anon;
grant execute on function public.erp_create_delivery_from_order(uuid, jsonb, text) to authenticated, service_role;

create function public.erp_deliverable_lines(p_order_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_id', x.line_id, 'line_no', x.line_no,
           'item', i.code, 'item_name', i.name, 'description', dl.description,
           'ordered_quantity', x.ordered_quantity,
           'delivered_quantity', x.delivered_quantity,
           'on_deliveries_quantity', x.on_deliveries_quantity,
           'open_quantity', x.open_quantity,
           'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency)
         order by x.line_no), '[]'::jsonb)
    from erp.deliverable_lines(p_order_id) x
    join erp.document_line dl on dl.tenant_id = erp.current_tenant_id() and dl.id = x.line_id
    left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
   where x.open_quantity > 0
$$;

comment on function public.erp_deliverable_lines(uuid) is
  'The lines of a sales order with something left to deliver: ordered, '
  'delivered, on deliveries not yet cancelled, and left. Reads under row '
  'security as the caller, and authorises nothing.';

revoke all on function public.erp_deliverable_lines(uuid) from public, anon;
grant execute on function public.erp_deliverable_lines(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_delivery_from_order', 'erp.create_delivery_from_order',
   'Creates a draft delivery from a sales order that is confirmed or being picked, each open line at what is left, linked back to its order line. Gated on sales.despatch inside erp.create_delivery_from_order(); opening the delivery and adding its lines authorise the delivery type''s create permission again, and a move asked for is authorised by its transition.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The refusals, and the words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_NOT_A_SALES_ORDER',
  'Acting on a document as a sales order when it is another kind of document.',
  'Drop-ship orders, intercompany orders and deliveries are raised from a sales order, and read its customer, lines and prices.',
  'Choose a sales order. Goods that answer no order leave on a delivery raised with New delivery.');

select erp.register_refusal('CLOVEERP_ORDER_NOT_READY_TO_DELIVER',
  'Creating a delivery from a sales order that is not confirmed or being picked.',
  'A draft has not been agreed, an order waiting on its approval has not been approved, and an order already despatched, invoiced, closed or cancelled has nothing more to send.',
  'Submit the order and have it approved, then create the delivery.');

select erp.register_refusal('CLOVEERP_NOTHING_TO_DELIVER',
  'Creating a delivery from a sales order with nothing left on it to deliver.',
  'Every line has been delivered, or is on a delivery raised from the order already, posted or not, or no line was chosen.',
  'Post or cancel the deliveries already raised from the order, or choose a line with something left on it.');

select erp.register_refusal('CLOVEERP_MORE_THAN_LEFT_TO_DELIVER',
  'Delivering more of an order line than is left on it.',
  'What is left is what was ordered less what posted deliveries delivered and what draft deliveries hold. More than that was never ordered.',
  'Deliver what is left, or less. Goods beyond the order need the order amended or an order of their own.');

select erp.register_refusal('CLOVEERP_NOT_A_LINE_OF_THE_ORDER',
  'Delivering a line that is not an open product line of the order the delivery is created from.',
  'A delivery created from an order carries that order''s lines and links each back to it. A line of another order, a cancelled line or a line with no product cannot be linked.',
  'Choose lines of the order the delivery is created from.');

select erp.register_refusal('CLOVEERP_NO_DELIVERY_TYPE',
  'Creating a delivery in an organisation that has no delivery document type in use.',
  'A delivery is a document of a type the organisation installs with sales, which gives it its numbering and its lifecycle.',
  'Install sales on the Configuration screen, then create the delivery.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Create a delivery from this order',
     'The button on a sales order that creates its delivery.'),
    ('Create a delivery from an order',
     'The button on the Sales and Despatch bars that creates a delivery from a sales order chosen on the form.'),
    ('Create a delivery from a sales order',
     'The title of the form that creates a delivery from a sales order chosen on it.'),
    ('A draft delivery for the order''s customer and site, holding what is left to deliver on each line at the order''s price. Post it when the goods leave.',
     'What the form that creates a delivery from a sales order does.'),
    ('Create the delivery',
     'The button that submits the form creating a delivery from a sales order.'),
    ('Lines to deliver',
     'The line editor on the form creating a delivery from a sales order.'),
    ('Each line with something left to deliver arrives holding what is left. Lower a quantity to deliver part of a line, or remove a line to leave it for a later delivery.',
     'The line editor on the form creating a delivery from a sales order, explained.'),
    ('Nothing is left to deliver on this order: every line has been delivered or is on a delivery already.',
     'Said by the form creating a delivery when the order chosen has nothing left.'),
    ('Create the delivery from its sales order and post it when the goods leave. Then plan the shipment, choose the carrier, book it and record the proof of delivery.',
     'The Despatch process strip, once a delivery came from its order.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A live organisation with two administrators: the first sells, despatches and
-- asks for approvals; the second approves, promotes and invoices. Finance,
-- procurement and sales are installed through changes the second promotes. A
-- hundred widgets are received. Two people each hold one narrow role, made with
-- the organisation's window opened for the purpose, and call the door signed
-- in through erp_test.delivery_door_as(). Four sales orders are submitted by
-- the first administrator and approved through erp_test.approve_document(),
-- which decides the tasks as the second, because whoever asks does not approve
-- (20260914062000). Everything is built inside a block that ends by raising, so
-- nothing outlives the suite; the cases are answered from what it recorded.

create or replace function erp_test.delivery_door_as(p_subject uuid, p_order_id uuid)
returns table (outcome jsonb, ran_as text, err_state text, err_message text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner  text := current_user;
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    ran_as := current_user;
    outcome := public.erp_create_delivery_from_order(p_order_id => p_order_id);
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text;
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', v_claims, true);
  return next;
end;
$$;

comment on function erp_test.delivery_door_as(uuid, uuid) is
  'Suite helper: calls public.erp_create_delivery_from_order for one order as '
  'the given sign-in, in the authenticated role, and returns its answer and the '
  'role it ran as, or its refusal. Returns to the calling role and claims '
  'before it returns.';

revoke all on function erp_test.delivery_door_as(uuid, uuid) from public, anon, authenticated;

create or replace function erp_test.delivery_from_order_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_owner  text := current_user;
  a1       uuid := gen_random_uuid();   -- the first administrator, who sells and despatches
  a2       uuid := gen_random_uuid();   -- the second, who approves and invoices
  s_desp   uuid := gen_random_uuid();   -- holds sales.read and sales.despatch, and nothing else
  s_look   uuid := gen_random_uuid();   -- holds sales.read, and nothing else
  r        record;
  g        record;
  res      jsonb;
  v_second uuid;
  v_tok    text;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_sales uuid;
  v_state  text;
  v_step   text := 'reading the doors';
  -- The doors as the catalogue holds them.
  v_cn     integer;
  v_cargs  text;
  v_cdef   boolean;
  v_cvol   boolean;
  v_cgrant boolean;
  v_cgate  text;
  v_rn     integer;
  v_rargs  text;
  v_rdef   boolean;
  v_rstab  boolean;
  v_rgrant boolean;
  -- The organisation.
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_cust   uuid;
  v_item   uuid;
  v_grn    uuid;
  u_desp   uuid;
  u_look   uuid;
  -- A whole order, delivered.
  v_so1        uuid;
  v_so1_a      uuid;
  v_so1_b      uuid;
  v_so1_conf   text;
  v_so1_number text;
  v_dn1        jsonb;
  v_dn1_id     uuid;
  v_dn1_head   boolean;
  v_dn1_ref    text;
  v_dn1_draft  text;
  v_dn1_lines  boolean;
  v_dn1_says   text;
  v_dn1_links  integer;
  v_dn1_linked boolean;
  v_so1_mid    text;
  v_so1_mid_done numeric;
  v_again_err  text;
  v_stock0     numeric;
  v_stock1     numeric;
  v_so1_end    text;
  v_so1_a_done numeric;
  v_so1_b_done numeric;
  v_inv        uuid;
  v_inv_qty    numeric;
  v_inv_price  bigint;
  v_inv_err    text;
  -- Part of an order being picked, then the rest.
  v_so2        uuid;
  v_so2_l      uuid;
  v_so2_picking text;
  v_dn2        jsonb;
  v_dn2_qty    numeric;
  v_dn2_link   numeric;
  v_over_err   text;
  v_other_err  text;
  v_offered    jsonb;
  v_so2_mid    text;
  v_so2_mid_done numeric;
  v_dn3        jsonb;
  v_dn3_state  text;
  v_so2_end    text;
  v_so2_end_done numeric;
  -- Refused.
  v_so3        uuid;
  v_draft_err  text;
  v_kind_err   text;
  -- Signed in.
  v_so4        uuid;
  v_signed     jsonb;
  v_signed_as  text;
  v_signed_err text;
  v_signed_lines integer;
  v_signed_base  text;
  v_look_state text;
  v_look_err   text;
begin
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 'v'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_cn, v_cargs, v_cdef, v_cvol, v_cgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_create_delivery_from_order';

  select w.gate into v_cgate
    from erp_meta.public_write_allowance w
   where w.function_name = 'erp_create_delivery_from_order';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_rn, v_rargs, v_rdef, v_rstab, v_rgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_deliverable_lines';

  begin
    -- ── A live organisation and its two administrators ─────────────────────
    v_step := 'the organisation is provisioned and its two administrators join';
    select * into r from erp.provision_tenant(
      'zz-dfo-' || v_hex, 'Delivery from order suite',
      'admin@zz-dfo-' || v_hex || '.test', 'Delivery Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-dfo-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'finance, procurement and sales are installed, and the second administrator promotes them';
    cs_fin := erp.configure_finance();
    cs_proc := erp.configure_procurement(1000000);
    cs_sales := erp.configure_sales(15);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_sales);
    perform erp.promote_change_set(cs_sales);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'a site, a supplier, a customer with credit and a product';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 10000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

    v_step := 'a hundred widgets are received';
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock');
    perform erp.transition_document(v_grn, 'post', 'delivery from order suite');

    v_step := 'two people each hold one narrow role';
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status) values
      (r.tenant_id, 'zz_despatcher', 'Suite despatcher', 'active'),
      (r.tenant_id, 'zz_onlooker', 'Suite onlooker', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select r.tenant_id, ro.id, x.perm
      from (values ('zz_despatcher', 'sales.read'), ('zz_despatcher', 'sales.despatch'),
                   ('zz_onlooker', 'sales.read')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;
    perform erp_test.close_bootstrap_window(r.tenant_id);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_desp, 'person', 'active', 'Suite Despatcher', 'despatch@zz-dfo-' || v_hex || '.test', 'en')
    returning id into u_desp;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_look, 'person', 'active', 'Suite Onlooker', 'onlooker@zz-dfo-' || v_hex || '.test', 'en')
    returning id into u_look;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select r.tenant_id, x.person, ro.id, 'The suite''s narrow role.'
      from (values (u_desp, 'zz_despatcher'), (u_look, 'zz_onlooker')) as x(person, role_code)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;

    -- ── A whole order, delivered ───────────────────────────────────────────
    v_step := 'an order of two lines is submitted, and approved by the second administrator';
    v_so1 := erp.open_document('sales_order', v_cust, null, v_site);
    v_so1_a := erp.add_document_line(v_so1, v_item, 10, 2500, 'Ten widgets');
    v_so1_b := erp.add_document_line(v_so1, v_item, 5, 2500, 'Five more widgets');
    perform erp.transition_document(v_so1, 'submit', 'delivery from order suite');
    v_so1_conf := erp_test.approve_document(v_so1, 'delivery from order suite');

    v_step := 'a delivery is created from the confirmed order';
    v_dn1 := erp.create_delivery_from_order(v_so1);
    v_dn1_id := (v_dn1 ->> 'document_id')::uuid;
    select o.document_number into v_so1_number
      from erp.document o where o.tenant_id = r.tenant_id and o.id = v_so1;
    select dn.party_id = o.party_id and dn.entity_id = o.entity_id and dn.site_id = o.site_id
           and dt.base_type_code = 'delivery' and not dn.is_cancelled,
           dn.our_reference
      into v_dn1_head, v_dn1_ref
      from erp.document dn
      join erp.document_type dt on dt.tenant_id = dn.tenant_id and dt.id = dn.document_type_id
      join erp.document o on o.tenant_id = dn.tenant_id and o.id = v_so1
     where dn.tenant_id = r.tenant_id and dn.id = v_dn1_id;
    v_dn1_draft := erp.object_current_state('document', v_dn1_id);
    select coalesce(count(*) = 2
                    and bool_and(l.item_id = v_item and l.unit_price_minor = 2500)
                    and bool_or(l.quantity = 10 and l.description = 'Ten widgets')
                    and bool_or(l.quantity = 5 and l.description = 'Five more widgets'), false),
           string_agg(format('%s at %s, %s', trim_scale(l.quantity), l.unit_price_minor, l.description),
                      '; ' order by l.line_no)
      into v_dn1_lines, v_dn1_says
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = v_dn1_id and not l.is_cancelled;
    select count(*),
           coalesce(bool_and(rel.to_document_id = v_so1
                             and rel.relation_kind = 'fulfils'
                             and ((rel.to_line_id = v_so1_a and rel.quantity = 10)
                                  or (rel.to_line_id = v_so1_b and rel.quantity = 5))
                             and exists (select 1 from erp.document_line fl
                                          where fl.tenant_id = rel.tenant_id and fl.id = rel.from_line_id
                                            and fl.document_id = v_dn1_id)), false)
      into v_dn1_links, v_dn1_linked
      from erp.document_relation rel
     where rel.tenant_id = r.tenant_id and rel.from_document_id = v_dn1_id;
    v_so1_mid := erp.object_current_state('document', v_so1);
    select coalesce(sum(l.quantity_fulfilled), -1) into v_so1_mid_done
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = v_so1;

    begin
      perform erp.create_delivery_from_order(v_so1);
    exception when others then
      v_again_err := left(sqlerrm, 200);
    end;

    v_step := 'the delivery is posted';
    select coalesce(sum(b.quantity), 0) into v_stock0
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;
    perform erp.transition_document(v_dn1_id, 'post', 'delivery from order suite');
    select coalesce(sum(b.quantity), 0) into v_stock1
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;
    v_so1_end := erp.object_current_state('document', v_so1);
    select l.quantity_fulfilled into v_so1_a_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_so1_a;
    select l.quantity_fulfilled into v_so1_b_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_so1_b;

    v_step := 'the second administrator invoices the delivery';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin
      v_inv := erp.invoice_from_delivery(v_dn1_id);
    exception when others then
      v_inv_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select sum(l.quantity), max(l.unit_price_minor) into v_inv_qty, v_inv_price
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = v_inv and not l.is_cancelled;

    -- ── Part of an order being picked, then the rest ───────────────────────
    v_step := 'a second order is approved and picked';
    v_so2 := erp.open_document('sales_order', v_cust, null, v_site);
    v_so2_l := erp.add_document_line(v_so2, v_item, 20, 2500, 'Twenty widgets');
    perform erp.transition_document(v_so2, 'submit', 'delivery from order suite');
    perform erp_test.approve_document(v_so2, 'delivery from order suite');
    perform erp.transition_document(v_so2, 'pick', 'delivery from order suite');
    v_so2_picking := erp.object_current_state('document', v_so2);

    v_step := 'eight of the twenty go on a delivery';
    v_dn2 := erp.create_delivery_from_order(
      v_so2, jsonb_build_array(jsonb_build_object('line_id', v_so2_l, 'quantity', 8)));
    select sum(l.quantity) into v_dn2_qty
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = (v_dn2 ->> 'document_id')::uuid;
    select sum(rel.quantity) into v_dn2_link
      from erp.document_relation rel
     where rel.tenant_id = r.tenant_id and rel.from_document_id = (v_dn2 ->> 'document_id')::uuid
       and rel.to_line_id = v_so2_l;

    begin
      perform erp.create_delivery_from_order(
        v_so2, jsonb_build_array(jsonb_build_object('line_id', v_so2_l, 'quantity', 13)));
    exception when others then
      v_over_err := left(sqlerrm, 200);
    end;
    begin
      perform erp.create_delivery_from_order(
        v_so2, jsonb_build_array(jsonb_build_object('line_id', v_so1_a, 'quantity', 1)));
    exception when others then
      v_other_err := left(sqlerrm, 200);
    end;
    v_offered := public.erp_deliverable_lines(v_so2);

    v_step := 'the part delivery is posted';
    perform erp.transition_document((v_dn2 ->> 'document_id')::uuid, 'post', 'delivery from order suite');
    v_so2_mid := erp.object_current_state('document', v_so2);
    select l.quantity_fulfilled into v_so2_mid_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_so2_l;

    v_step := 'the rest is created and moved on in one call';
    v_dn3 := erp.create_delivery_from_order(v_so2, null, 'auto');
    v_dn3_state := erp.object_current_state('document', (v_dn3 ->> 'document_id')::uuid);
    v_so2_end := erp.object_current_state('document', v_so2);
    select l.quantity_fulfilled into v_so2_end_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_so2_l;

    -- ── Refused ─────────────────────────────────────────────────────────────
    v_step := 'a draft order, and a document that is not a sales order';
    v_so3 := erp.open_document('sales_order', v_cust, null, v_site);
    perform erp.add_document_line(v_so3, v_item, 1, 2500, 'One widget');
    begin
      perform erp.create_delivery_from_order(v_so3);
    exception when others then
      v_draft_err := left(sqlerrm, 200);
    end;
    begin
      perform erp.create_delivery_from_order(v_grn);
    exception when others then
      v_kind_err := left(sqlerrm, 200);
    end;

    -- ── Signed in ───────────────────────────────────────────────────────────
    v_step := 'a fourth order is approved';
    v_so4 := erp.open_document('sales_order', v_cust, null, v_site);
    perform erp.add_document_line(v_so4, v_item, 3, 2500, 'Three widgets');
    perform erp.transition_document(v_so4, 'submit', 'delivery from order suite');
    perform erp_test.approve_document(v_so4, 'delivery from order suite');

    v_step := 'the despatcher, signed in, creates its delivery through the door';
    select * into g from erp_test.delivery_door_as(s_desp, v_so4);
    v_signed := g.outcome;
    v_signed_as := g.ran_as;
    v_signed_err := g.err_message;
    select count(*), min(dt.base_type_code) into v_signed_lines, v_signed_base
      from erp.document_line l
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where l.tenant_id = r.tenant_id
       and l.document_id = (v_signed ->> 'document_id')::uuid
       and l.quantity = 3;

    v_step := 'the onlooker, signed in, asks the door';
    select * into g from erp_test.delivery_door_as(s_look, v_so4);
    v_look_state := g.err_state;
    v_look_err := coalesce(g.err_message, g.outcome::text);

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_DELIVERY_FROM_ORDER_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_DELIVERY_FROM_ORDER_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end if;
    -- Whatever failed, and wherever, the rest of the suite runs as its owner.
    execute format('set local role %I', v_owner);
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ───────────────────────────────────────────────────────────────────────────
  -- The doors
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the delivery door is one function that runs as the caller, may write, takes the order, its lines and a move, is on the write register, and a signed-in caller may execute it; the lines door only reads';
  passed := coalesce(v_cn = 1 and not v_cdef and v_cvol and v_cgrant
                     and v_cargs = 'p_order_id uuid, p_lines jsonb, p_transition text'
                     and v_cgate = 'erp.create_delivery_from_order'
                     and v_rn = 1 and not v_rdef and v_rstab and v_rgrant
                     and v_rargs = 'p_order_id uuid', false);
  detail := format('delivery door: %s function(s) (%s), definer %s, volatile %s, granted %s, gate %s; lines door: %s function(s) (%s), definer %s, stable %s, granted %s',
                   v_cn, coalesce(v_cargs, 'none'), v_cdef, v_cvol, v_cgrant, coalesce(v_cgate, 'none'),
                   v_rn, coalesce(v_rargs, 'none'), v_rdef, v_rstab, v_rgrant);
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- A whole order
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a confirmed sales order becomes a draft delivery for its customer, company and site, each line at what is left, at the order''s price and with its description';
  passed := coalesce(v_state is null and v_so1_conf = 'confirmed' and v_dn1_head
                     and v_dn1_draft = 'draft' and v_dn1_lines
                     and v_dn1_ref = v_so1_number
                     and (v_dn1 ->> 'lines')::integer = 2 and (v_dn1 ->> 'quantity')::numeric = 15, false);
  detail := coalesce(v_state, format('order %s; delivery %s, same customer, company and site %s, our reference %s; lines: %s',
                                     v_so1_conf, coalesce(v_dn1_draft, 'no state'), coalesce(v_dn1_head::text, 'unknown'),
                                     coalesce(v_dn1_ref, 'none'), coalesce(v_dn1_says, 'none')));
  return next;

  case_name := 'each delivery line is linked back to its order line, and nothing counts as delivered while the delivery is a draft';
  passed := coalesce(v_state is null and v_dn1_links = 2 and v_dn1_linked
                     and v_so1_mid = 'confirmed' and v_so1_mid_done = 0, false);
  detail := coalesce(v_state, format('%s link(s), each to its order line %s; the order %s with %s delivered',
                                     v_dn1_links, v_dn1_linked, v_so1_mid, trim_scale(v_so1_mid_done)));
  return next;

  case_name := 'with the whole order on a draft delivery, another is refused: nothing is left to deliver';
  passed := coalesce(v_state is null and v_again_err like 'CLOVEERP_NOTHING_TO_DELIVER%', false);
  detail := coalesce(v_state, v_again_err, 'a second delivery was created');
  return next;

  case_name := 'posting the delivery takes the stock, counts what was delivered on each order line, and moves the order through picking to despatched';
  passed := coalesce(v_state is null and v_stock0 - v_stock1 = 15
                     and v_so1_a_done = 10 and v_so1_b_done = 5
                     and v_so1_end = 'despatched', false);
  detail := coalesce(v_state, format('stock %s to %s; delivered %s and %s; the order %s',
                                     trim_scale(v_stock0), trim_scale(v_stock1), trim_scale(v_so1_a_done),
                                     trim_scale(v_so1_b_done), v_so1_end));
  return next;

  case_name := 'the delivery is invoiced from what it moved, by somebody other than the person who despatched it';
  passed := coalesce(v_state is null and v_inv_err is null and v_inv is not null
                     and v_inv_qty = 15 and v_inv_price = 2500, false);
  detail := coalesce(v_state, v_inv_err, format('an invoice for %s at %s', trim_scale(v_inv_qty), v_inv_price));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Part, then the rest
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'an order being picked takes a delivery of part of a line, at the quantity asked for';
  passed := coalesce(v_state is null and v_so2_picking = 'picking'
                     and v_dn2_qty = 8 and v_dn2_link = 8, false);
  detail := coalesce(v_state, format('the order %s; the delivery carries %s, linked %s',
                                     v_so2_picking, trim_scale(v_dn2_qty), trim_scale(v_dn2_link)));
  return next;

  case_name := 'while that delivery is a draft, asking for more than is left is refused by name';
  passed := coalesce(v_state is null and v_over_err like 'CLOVEERP_MORE_THAN_LEFT_TO_DELIVER%', false);
  detail := coalesce(v_state, v_over_err, 'thirteen were delivered where twelve were left');
  return next;

  case_name := 'a line of another order is refused by name';
  passed := coalesce(v_state is null and v_other_err like 'CLOVEERP_NOT_A_LINE_OF_THE_ORDER%', false);
  detail := coalesce(v_state, v_other_err, 'a line of another order was delivered');
  return next;

  case_name := 'the lines door offers what is left on the order, net of the draft delivery';
  passed := coalesce(v_state is null and jsonb_array_length(v_offered) = 1
                     and (v_offered -> 0 ->> 'line_id')::uuid = v_so2_l
                     and (v_offered -> 0 ->> 'ordered_quantity')::numeric = 20
                     and (v_offered -> 0 ->> 'on_deliveries_quantity')::numeric = 8
                     and (v_offered -> 0 ->> 'open_quantity')::numeric = 12, false);
  detail := coalesce(v_state, coalesce(v_offered::text, 'nothing'));
  return next;

  case_name := 'posting the part delivery counts it on the order line and leaves the order being picked';
  passed := coalesce(v_state is null and v_so2_mid_done = 8 and v_so2_mid = 'picking', false);
  detail := coalesce(v_state, format('%s delivered; the order %s', trim_scale(v_so2_mid_done), v_so2_mid));
  return next;

  case_name := 'the rest, created and moved on in one call, posts and moves the order to despatched';
  passed := coalesce(v_state is null and v_dn3 ->> 'moved_on' = 'post'
                     and (v_dn3 ->> 'quantity')::numeric = 12
                     and v_dn3_state = 'posted' and v_so2_end_done = 20
                     and v_so2_end = 'despatched' and v_dn3 ->> 'order_state' = 'despatched', false);
  detail := coalesce(v_state, format('%s carried, moved on by %s and %s; %s delivered; the order %s',
                                     coalesce(v_dn3 ->> 'quantity', 'nothing'), coalesce(v_dn3 ->> 'moved_on', 'nothing'),
                                     coalesce(v_dn3_state, 'no state'), trim_scale(v_so2_end_done), v_so2_end));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Refused
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a draft sales order is refused, naming its state';
  passed := coalesce(v_state is null and v_draft_err like 'CLOVEERP_ORDER_NOT_READY_TO_DELIVER%'
                     and v_draft_err like '%draft%', false);
  detail := coalesce(v_state, v_draft_err, 'a delivery was created from a draft');
  return next;

  case_name := 'a document that is not a sales order is refused';
  passed := coalesce(v_state is null and v_kind_err like 'CLOVEERP_NOT_A_SALES_ORDER%', false);
  detail := coalesce(v_state, v_kind_err, 'a delivery was created from a goods receipt');
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Signed in
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'signed in with only sales.read and sales.despatch, a person creates a delivery from an order through the door';
  passed := coalesce(v_state is null and v_signed_err is null and v_signed_as = 'authenticated'
                     and v_signed_lines = 1 and v_signed_base = 'delivery'
                     and (v_signed ->> 'lines')::integer = 1, false);
  detail := coalesce(v_state, v_signed_err,
                     format('ran as %s; %s line(s) of three on a %s', coalesce(v_signed_as, 'nobody'),
                            v_signed_lines, coalesce(v_signed_base, 'nothing')));
  return next;

  case_name := 'signed in with sales.read and not sales.despatch, a person is refused, naming sales.despatch';
  passed := coalesce(v_state is null and v_look_state = '42501'
                     and v_look_err like 'CLOVEERP_PERMISSION_DENIED: sales.despatch%', false);
  detail := coalesce(v_state, format('%s: %s', coalesce(v_look_state, 'no refusal'), coalesce(v_look_err, 'no answer')));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-dfo-' || v_hex);
  detail := 'the organisation, its people, stock, orders, deliveries and invoice rolled back';
  return next;
end;
$$;

comment on function erp_test.delivery_from_order_suite() is
  'A live organisation with two administrators and two narrow people: a '
  'confirmed order delivered whole, linked, posted, moved to despatched and '
  'invoiced by somebody else; an order being picked delivered in part, refused '
  'more than is left and a line of another order, offered what is left, then '
  'delivered and posted in one call; a draft order and a goods receipt refused; '
  'and the door called signed in with only sales.read and sales.despatch, and '
  'without sales.despatch. Rolls back everything it made.';

create or replace function erp_test.assert_delivery_from_order_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.delivery_from_order_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DELIVERY_FROM_ORDER_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_DELIVERY_FROM_ORDER_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the door: an order cannot be delivered, a delivered quantity is not counted, or an order does not move on.';
  end if;
  return format('delivery from order: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.delivery_from_order_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_delivery_from_order_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_delivery_from_order_suite();
select erp_test.assert_sales_suite();
select erp_test.assert_procurement_suite();
select erp_test.assert_supplier_bill_suite();
select erp_test.assert_onward_transition_suite();
