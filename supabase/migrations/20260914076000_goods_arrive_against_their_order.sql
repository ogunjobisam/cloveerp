-- Goods arrive against their order.
--
-- The live desk was walked in a demonstration organisation on 14 September.
-- Six of its findings are answered here. Each was checked against the
-- definitions the database carries after every patch before this file was
-- written, reading every later execute replace(pg_get_functiondef(...)) as
-- well as every CREATE, and each was true:
--
--   1. Receiving took two awkward steps (F35). "New goods receipt" asked for a
--      supplier and a site and no lines; "Receive against an order"
--      (erp.receive_against, 20260904110000, patched by 20260906131000,
--      20260906142000 and 20260914062000) then took one order line at a time.
--      Nothing raised a goods receipt from a purchase order, as
--      erp.create_delivery_from_order (20260914064000) raises a delivery from
--      a sales order.
--
--   2. Turning a requisition into a purchase order asked for the supplier and
--      the site with nothing chosen (F29). erp.convert_document
--      (20260910225559, patched by 20260914060000) already falls back to the
--      requisition's own partner and site when none is sent; the form marked
--      the supplier required and could not say what that fallback was, and a
--      requisition raised with no partner had no fallback at all, even when
--      every product on it is bought from the same default supplier.
--
--   3. Financials → Reports did not read as reports (F25). Receivables ageing
--      showed "—" for every customer and every age band: the panel read
--      party, days_1_30_minor, days_31_60_minor and days_60_plus_minor, and
--      public.erp_receivables_ageing (20260829300000, never patched) answers
--      party_name, days_1_30, days_31_60, days_61_90 and days_over_90, with an
--      empty band as null. The name join itself was right. Totals printed as
--      minor units, and the ageing chart grouped every customer under "—".
--      Trial balance stayed on "Loading…": public.erp_trial_balance
--      (20260911005223, made volatile by 20260912200000) summed every posted
--      line of every ledger for all time into one row per account labelled
--      ALL — the commitment ledger added to the general ledger, which is not a
--      trial balance — reading four tables as the caller, where row security
--      asks who the caller is for every row. Balance sheet and profit and loss
--      over the general ledger alone loaded; the unfiltered read was the one
--      that did not, and the desk retries a failed read twice, showing
--      "Loading…" throughout. The balance sheet and profit and loss printed
--      amounts with no currency.
--
--   4. "Open order lines 100 awaiting release" while the sales order step
--      showed no open order (F45). public.erp_release_sequence (20260830100930,
--      never patched) counts every sales order line whose quantity exceeds
--      quantity_fulfilled, in any state. The demonstration's trading history
--      (erp.seed_demo_history, 20260905010000) links each delivery to its order
--      at document level with no line ids, so no history order line ever
--      counts what was delivered, and every despatched, invoiced and closed
--      history order stood in the list; 100 is the read's default limit. The
--      stock forecast's "Ordered by customers" (erp.stock_forecast_lines,
--      20260910222432, never patched) read the same lines the same way.
--
--   5. The stock forecast said "no usage" for thirty demonstration products
--      (F41). The read is right: usage is despatch, issue, consumption,
--      production issue, write-off and scrap movements whose occurred_at falls
--      in the window (90 days on the screen), and a history delivery posts a
--      despatch movement stamped with its document date (20260905010000's
--      patch of erp.post_document_stock, asserted by the demo history suite).
--      The walked demonstration's history is built oldest first, from twelve
--      months back, and that build was stopped after statement timeouts (F12)
--      and the emails it sent (F14), having reached 8 January 2026 when it was
--      last read (F15). A history that stops months short of today leaves
--      exactly the window the forecast reads empty, so nothing it built is
--      usage today. Nothing is changed for that here: finishing the build
--      fills the window.
--
--   6. Every forecast line said "No supplier" (F42). No seeder writes
--      erp.item_supplier. erp.ensure_demo_configuration (20260905010000,
--      patched by 20260905020000, 20260905030000, 20260906141000 and
--      20260909212619) records each product's supplier only as a party code in
--      the item's demo attributes, which the history builder reads and the
--      forecast and planning do not.
--
-- What this file does, in order:
--
--   1. What is left to receive. erp.receivable_lines(order) answers, for each
--      open product line of a purchase order: ordered, received on posted
--      receipts, on receipts raised against it that are not cancelled, posted
--      or not, and left: ordered less the greater of what the line counts as
--      fulfilled and what those receipts hold. A draft receipt holds what it
--      carries, as erp.receive_against has always counted it.
--      public.erp_receivable_lines lists the lines with something left.
--
--   2. The door. public.erp_create_receipt_from_order(p_order_id, p_lines,
--      p_transition) runs erp.create_receipt_from_order as the caller:
--        * refuses an order nobody may see (CLOVEERP_UNKNOWN_DOCUMENT), then
--          authorises procurement.receive for the order's company and site;
--        * refuses a document that is not a purchase order
--          (CLOVEERP_NOT_A_PURCHASE_ORDER), and an order that is not sent or
--          partially received (CLOVEERP_ORDER_NOT_SENT, the refusal
--          erp.receive_against raises since 20260914062000);
--        * locks the order row, so two people cannot both take what is left;
--        * takes every open line at what is left, or the lines p_lines names,
--          each at the quantity given or at what is left of that line when
--          none is given, with an optional location_id and batch_id. One order
--          line may be named more than once, for two batches. A line that is
--          not an open product line of the order is refused
--          (CLOVEERP_NOT_A_LINE_TO_RECEIVE), more than is left is refused
--          (CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE), and a receipt of nothing is
--          refused (CLOVEERP_NOTHING_TO_RECEIVE). Goods beyond the order are
--          received line by line with erp_receive_against, where the receipt
--          tolerance decides;
--        * opens a draft goods receipt of the organisation's receipt type
--          (CLOVEERP_NO_RECEIPT_TYPE where there is none) for the order's
--          supplier, company, site and currency, with the order's number as our
--          reference;
--        * receives each line through erp.receive_against, unchanged: the
--          order's behaviour (drop-ship refused, consignment owned by the
--          supplier), the order's state, the tolerance, quarantine and its
--          approval, shelf life, the line's price, the 'fulfils' link to the
--          order line and the refreshed fulfilled quantity are all its own.
--          A location or batch named is then written through
--          erp.set_line_stock_identity, which refuses a location of another
--          site and a batch of another product; a line that receiving put in
--          quarantine keeps its quarantine location;
--        * with p_transition 'auto', moves the receipt on as Create and move on
--          does (erp.onward_transition): out of draft that is post, and
--          posting moves the order to partially received or received through
--          erp.advance_orders_for_receipt, as every posted receipt does. Any
--          other code is performed as given.
--
--   3. What a conversion would default to. erp.conversion_defaults(document)
--      answers the supplier and site a conversion takes when none is chosen:
--      the document's own partner; for a requisition with none, the default
--      supplier every product line on it shares in item supply (active,
--      approved for use, in force today, at the requisition's site or at
--      every site, the site's own first); and the document's site.
--      public.erp_conversion_defaults reads it for the form, and
--      erp.convert_document takes that supplier when neither the caller nor
--      the requisition names one.
--
--   4. The reports. erp.receivables_ageing and its door are restated with an
--      empty band as zero, largest balance first. public.erp_trial_balance
--      reads per company and ledger (every company has a ledger coded GL),
--      each relation narrowed to the organisation by its own index before row
--      security sees it, and no longer adds ledgers together. The desk reads
--      the names each read answers with — the ageing's, and the dunning
--      worklist's, fixed assets' and intercompany's, which had drifted the same
--      way — formats every amount on the tab as money in its currency, asks the
--      trial balance for the general ledger, and gives the statements their
--      currency.
--
--   5. Open order lines are lines on orders that can still be fulfilled.
--      public.erp_release_sequence lists lines of sales orders that are
--      confirmed or being picked and not delivered in full, ranked as before
--      and cut at the limit in rank order. erp.stock_forecast_lines counts
--      customer demand from the same orders, by counted replacement.
--
--   6. A demonstration's products have their suppliers.
--      erp.seed_demo_item_suppliers(tenant) gives each product whose demo
--      attributes name an active supplier that supplier as its default for
--      every site, with a lead time of five days from the United Kingdom or
--      Ireland and ten from anywhere else, unless the product already has a
--      supplier in force. erp.ensure_demo_configuration asks it after the
--      products are written (a counted replacement), and every existing
--      demonstration is given them here.
--
-- The desk offers "Receive this order" on a purchase order's page while it is
-- sent or partially received, and "Receive an order" on Purchasing's goods
-- receipt step and bar; the form arrives holding the open lines at what is
-- left, with a location and batch for each, editable.
--
-- Proof: erp_test.receive_from_order_suite(), twenty-seven cases, pinned by its
-- wrapper; and, run here because they drive what changed, the procurement,
-- delivery from order, approval hold, onward transition, demo history and demo
-- chart suites.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What is left to receive
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.receivable_lines(p_order_id uuid)
returns table (
  line_id              uuid,
  line_no              integer,
  item_id              uuid,
  ordered_quantity     numeric,
  received_quantity    numeric,
  on_receipts_quantity numeric,
  open_quantity        numeric
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
         coalesce(x.received, 0),
         coalesce(x.on_receipts, 0),
         greatest(dl.quantity - greatest(coalesce(dl.quantity_fulfilled, 0), coalesce(x.on_receipts, 0)), 0)
    from erp.document_line dl
    left join lateral (
      -- Every receipt raised against the line that is not cancelled, posted or
      -- not: a draft holds what it carries.
      select sum(rel.quantity) filter (where coalesce(rs.is_committed, false)) as received,
             sum(rel.quantity) as on_receipts
        from erp.document_relation rel
        join erp.document rd
          on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
        join erp.document_type rdt
          on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
        left join erp.object_state ros
          on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
        left join erp.state rs on rs.id = ros.current_state_id
       where rel.tenant_id = dl.tenant_id
         and rel.to_line_id = dl.id
         and rel.relation_kind = 'fulfils'
         and rdt.base_type_code = 'receipt'
         and not (rd.is_cancelled or coalesce(rs.code = 'cancelled', false))
    ) x on true
   where dl.tenant_id = erp.current_tenant_id()
     and dl.document_id = p_order_id
     and not dl.is_cancelled
     and dl.item_id is not null
     and dl.quantity > 0
   order by dl.line_no
$$;

comment on function erp.receivable_lines(uuid) is
  'For each open product line of a purchase order: what was ordered, what '
  'posted receipts received, what receipts raised against it that are not '
  'cancelled hold, posted or not, and what is left: ordered less the greater of '
  'the line''s fulfilled quantity and what those receipts hold. Reads as the '
  'caller; lists nothing outside the caller''s organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A goods receipt is created from its order
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.create_receipt_from_order(
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
  v_tenant      uuid := erp.require_tenant_id();
  d             erp.document%rowtype;
  l             record;
  e             jsonb;
  v_base        text;
  v_state       text;
  v_state_name  text;
  v_type        text;
  v_unknown     text;
  v_qty         numeric;
  v_planned     numeric;
  v_plan_lines  uuid[] := '{}'::uuid[];
  v_plan_qty    numeric[] := '{}'::numeric[];
  v_plan_loc    uuid[] := '{}'::uuid[];
  v_plan_batch  uuid[] := '{}'::uuid[];
  v_total       numeric := 0;
  v_grn         uuid;
  v_line        uuid;
  v_held        boolean;
  v_moved       text := null;
  i             integer;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: no such purchase order in this organisation'
      using errcode = '23503',
            hint = 'Choose the purchase order from the list of orders sent to a supplier.';
  end if;

  -- Creating a goods receipt is receiving: the permission its lifecycle's post
  -- asks for, and the permission a goods receipt is created under.
  perform erp.authorise('procurement.receive', d.entity_id, d.site_id, null, 'document', p_order_id);

  select dt.base_type_code into v_base
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if v_base is distinct from 'purchase_order' then
    raise exception 'CLOVEERP_NOT_A_PURCHASE_ORDER: % is a %, and goods are received against a purchase order',
      d.document_number, coalesce(v_base, 'document')
      using errcode = '23514',
            hint = 'Choose a purchase order that has been sent to the supplier.';
  end if;

  select s.code, s.name into v_state, v_state_name
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_order_id;

  if d.is_cancelled or coalesce(v_state, '') not in ('sent', 'partially_received') then
    raise exception 'CLOVEERP_ORDER_NOT_SENT: % is %, and goods are received only against an order sent to the supplier',
      d.document_number,
      case when d.is_cancelled then 'cancelled' else coalesce(v_state_name, 'not started') end
      using errcode = '23514',
            hint = 'Have the order approved and send it to the supplier first. An order already received in full takes no more.';
  end if;

  -- One receipt at a time from one order, so two people cannot both take what
  -- is left.
  perform 1 from erp.document where tenant_id = v_tenant and id = p_order_id for update;

  select dt.code into v_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'receipt' and dt.status = 'active'
   order by (dt.entity_id = d.entity_id) desc nulls last, (dt.entity_id is null) desc,
            (dt.code = 'goods_receipt') desc, dt.code
   limit 1;

  if v_type is null then
    raise exception 'CLOVEERP_NO_RECEIPT_TYPE: this organisation has no goods receipt document type in use'
      using errcode = '23503',
            hint = 'Install purchasing on the Configuration screen, which adds the goods receipt type, then receive the order.';
  end if;

  -- The lines asked for are lines of this order.
  if p_lines is not null and jsonb_typeof(p_lines) <> 'array' then
    raise exception 'CLOVEERP_NOT_A_LINE_TO_RECEIVE: the lines to receive are not a list of the order''s lines'
      using errcode = '22023',
            hint = 'Send a list of the order''s lines, each with its line_id and, to receive less than is left, a quantity.';
  end if;

  if p_lines is not null then
    select string_agg(coalesce(x ->> 'line_id', 'a line with no line_id'), ', ')
      into v_unknown
      from jsonb_array_elements(p_lines) x
     where not exists (
       select 1
         from erp.document_line dl
        where dl.tenant_id = v_tenant
          and dl.document_id = p_order_id
          and dl.id::text = x ->> 'line_id'
          and not dl.is_cancelled
          and dl.item_id is not null
          and dl.quantity > 0);

    if v_unknown is not null then
      raise exception 'CLOVEERP_NOT_A_LINE_TO_RECEIVE: % is not an open product line of %', v_unknown, d.document_number
        using errcode = '23503',
              hint = 'Choose lines of the order the goods arrived against. A cancelled line, or one with no product, is not received.';
    end if;
  end if;

  -- What arrives, line by line, before anything is written.
  if p_lines is null then
    for l in
      select x.line_id, x.line_no, x.open_quantity
        from erp.receivable_lines(p_order_id) x
       where x.open_quantity > 0
       order by x.line_no
    loop
      v_plan_lines := v_plan_lines || l.line_id;
      v_plan_qty := v_plan_qty || l.open_quantity;
      v_plan_loc := v_plan_loc || null::uuid;
      v_plan_batch := v_plan_batch || null::uuid;
      v_total := v_total + l.open_quantity;
    end loop;
  else
    for e in select el.elem from jsonb_array_elements(p_lines) as el(elem) loop
      select x.line_id, x.line_no, x.open_quantity into l
        from erp.receivable_lines(p_order_id) x
       where x.line_id::text = e ->> 'line_id';

      -- What is already planned for the same order line, for a line named
      -- twice: two batches of one line.
      v_planned := 0;
      if cardinality(v_plan_lines) > 0 then
        for i in 1 .. cardinality(v_plan_lines) loop
          if v_plan_lines[i] = l.line_id then
            v_planned := v_planned + v_plan_qty[i];
          end if;
        end loop;
      end if;

      v_qty := coalesce(nullif(btrim(e ->> 'quantity'), '')::numeric,
                        greatest(l.open_quantity - v_planned, 0));

      if v_qty <= 0 then
        continue;
      end if;

      if v_planned + v_qty > l.open_quantity then
        raise exception 'CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE: line % of % has % left to receive, and % was asked for',
          l.line_no, d.document_number, trim_scale(l.open_quantity), trim_scale(v_planned + v_qty)
          using errcode = '23514',
                hint = 'Receive what is left, or less. What is already on a goods receipt, posted or not, is not left to receive.';
      end if;

      v_plan_lines := v_plan_lines || l.line_id;
      v_plan_qty := v_plan_qty || v_qty;
      v_plan_loc := v_plan_loc || nullif(btrim(e ->> 'location_id'), '')::uuid;
      v_plan_batch := v_plan_batch || nullif(btrim(e ->> 'batch_id'), '')::uuid;
      v_total := v_total + v_qty;
    end loop;
  end if;

  if cardinality(v_plan_lines) = 0 then
    raise exception 'CLOVEERP_NOTHING_TO_RECEIVE: % has nothing left to receive: every line has been received or is on a goods receipt already, or no line was chosen',
      d.document_number
      using errcode = '23514',
            hint = 'Post or cancel the goods receipts already raised against the order, or choose a line with something left on it.';
  end if;

  -- The receipt: the order's supplier, company, site and currency. The
  -- supplier's delivery note number is theirs to give, so their reference is
  -- left for the person at the bay.
  v_grn := erp.open_document(v_type, d.party_id, d.entity_id, d.site_id,
                             null, null, d.currency);

  update erp.document
     set party_role_id = d.party_role_id,
         our_reference = d.document_number,
         notes         = format('Goods received against purchase order %s', d.document_number),
         updated_at    = now()
   where tenant_id = v_tenant and id = v_grn;

  for i in 1 .. cardinality(v_plan_lines) loop
    -- Everything receiving means, as receiving against one line has always
    -- meant it: behaviour, state, tolerance, quarantine, shelf life, price,
    -- the link to the order line and the fulfilled quantity.
    v_line := erp.receive_against(v_grn, v_plan_lines[i], v_plan_qty[i], v_plan_batch[i]);

    if v_plan_loc[i] is not null or v_plan_batch[i] is not null then
      -- A line receiving held in quarantine stays where quarantine put it.
      select dl.location_id is not null into v_held
        from erp.document_line dl
       where dl.tenant_id = v_tenant and dl.id = v_line;

      perform erp.set_line_stock_identity(
        v_line, v_plan_batch[i],
        case when coalesce(v_held, false) then null else v_plan_loc[i] end,
        null);
    end if;
  end loop;

  if coalesce(p_transition, '') <> '' then
    if p_transition = 'auto' then
      -- The move forward, as Create and move on asks it (20260914060000): out
      -- of draft, post.
      v_moved := erp.onward_transition('document', v_grn,
                   erp.document_transition_context(v_grn, null));
    else
      v_moved := p_transition;
    end if;

    if v_moved is not null then
      perform erp.transition_document(v_grn, v_moved,
                                      format('Received against purchase order %s', d.document_number));
    end if;
  end if;

  return jsonb_build_object(
    'document_id', v_grn,
    'document_number', (select dn.document_number from erp.document dn
                         where dn.tenant_id = v_tenant and dn.id = v_grn),
    'order_document_number', d.document_number,
    'lines', cardinality(v_plan_lines),
    'quantity', v_total,
    'moved_on', v_moved,
    'order_state', erp.object_current_state('document', p_order_id));
end;
$$;

comment on function erp.create_receipt_from_order(uuid, jsonb, text) is
  'Creates a draft goods receipt against a purchase order that is sent or '
  'partially received, under procurement.receive: its supplier, company, site '
  'and currency, each open line at what is left (or the lines, quantities, '
  'locations and batches p_lines names), each received through '
  'erp.receive_against and so linked back to its order line. Refuses a document '
  'that is not a purchase order, an order in any other state, a line of '
  'another order, more than is left, and nothing at all, by name. p_transition '
  '''auto'' moves the receipt on (post). Runs as the caller.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. What a conversion would default to
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.conversion_defaults(p_document_id uuid)
returns table (party_id uuid, party_source text, site_id uuid)
language sql
stable
security invoker
set search_path = ''
as $$
  with d as (
    select doc.id, doc.tenant_id, doc.party_id, doc.site_id, dt.base_type_code
      from erp.document doc
      join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
     where doc.tenant_id = erp.current_tenant_id()
       and doc.id = p_document_id
  ),
  lines as (
    -- Each line's default supplier in item supply: in force today, approved
    -- for use, still a supplier, at the document's site or at every site, the
    -- site's own first. A line with no product has none.
    select dl.id,
           (select s.party_id
              from erp.item_supplier s
             where s.tenant_id = d.tenant_id
               and s.item_id = dl.item_id
               and s.is_default
               and s.status = 'active'
               and coalesce(s.is_approved_for_use, true)
               and (s.site_id is null or s.site_id = d.site_id)
               and s.valid_from <= current_date
               and (s.valid_to is null or s.valid_to >= current_date)
               and exists (select 1 from erp.party_role pr
                            where pr.tenant_id = s.tenant_id and pr.party_id = s.party_id
                              and pr.role_kind = 'supplier' and pr.status = 'active')
             order by (s.site_id is not null) desc, s.preference_rank
             limit 1) as supplier_id
      from d
      join erp.document_line dl on dl.tenant_id = d.tenant_id and dl.document_id = d.id
     where not dl.is_cancelled
       and dl.quantity > 0
  ),
  shared as (
    -- One supplier, named on every line. Two suppliers, or a line with none,
    -- is a choice for the person converting.
    select case when count(*) > 0
                 and count(l.supplier_id) = count(*)
                 and count(distinct l.supplier_id) = 1
                then min(l.supplier_id::text)::uuid end as supplier_id
      from lines l
  )
  select coalesce(d.party_id,
                  case when d.base_type_code = 'requisition' then sh.supplier_id end),
         case when d.party_id is not null then 'document'
              when d.base_type_code = 'requisition' and sh.supplier_id is not null then 'item_supply'
         end,
         d.site_id
    from d
   cross join shared sh
$$;

comment on function erp.conversion_defaults(uuid) is
  'The supplier and site a conversion takes when none is chosen: the '
  'document''s own partner, or for a requisition with none the default supplier '
  'every product line shares in item supply; and the document''s site. '
  'party_source says which (document, item_supply). Reads as the caller.';

-- erp.convert_document takes the same supplier when nobody names one.

do $convert$
declare
  v_sig text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_def text := pg_get_functiondef('erp.convert_document(uuid,uuid,uuid,jsonb,text)'::regprocedure);
  v_old text := $o$  v_party := coalesce(p_party_id, d.party_id);
$o$;
  v_new text := $n$  -- A requisition with no partner is ordered from the default supplier every
  -- product line on it shares in item supply (20260914076000), which is what
  -- the form arrives holding.
  v_party := coalesce(p_party_id, d.party_id,
                      case when v_base = 'requisition'
                           then (select cd.party_id from erp.conversion_defaults(p_document_id) cd) end);
$n$;
begin
  if position('erp.conversion_defaults(' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % already asks erp.conversion_defaults()', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not choose its party the way the 20260910225559 body does', v_sig;
  end if;

  execute replace(v_def, v_old, v_new);

  if position('erp.conversion_defaults(p_document_id)' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('erp.onward_transition(' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without its default supplier or its onward move', v_sig;
  end if;
end
$convert$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The reports
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Restated whole: nothing has patched it since 20260829300000. The open items,
-- the bands and the join to the customer are as they were; an empty band is
-- zero rather than null, so a band reads £0.00 rather than a dash that looks
-- like a read that failed.

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
         coalesce(sum(o.amt) filter (where o.due >= coalesce(p_as_at, current_date)), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 1 and 30), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 31 and 60), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due between 61 and 90), 0)::bigint,
         coalesce(sum(o.amt) filter (where coalesce(p_as_at, current_date) - o.due > 90), 0)::bigint,
         sum(o.amt)::bigint
    from open o
    join erp.party p on p.id = o.party_id
   group by o.party_id, p.name, o.currency
  having sum(o.amt) <> 0
   order by 9 desc
$$;

create or replace function public.erp_receivables_ageing(p_as_at date default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.total_minor desc, a.party_name), '[]'::jsonb)
    from erp.receivables_ageing(p_as_at) a
$$;

comment on function public.erp_receivables_ageing(date) is
  'What each customer owes, by currency, in bands of how overdue it is: '
  'party_id, party_name, currency, current_minor, days_1_30, days_31_60, '
  'days_61_90, days_over_90 and total_minor, an empty band as zero, largest '
  'balance first. Reads under row security as the caller.';

-- The trial balance, per ledger. The shape each row carries is as it was, with
-- the ledger's own code where it said ALL, and the company whose ledger it is:
-- every company has a ledger coded GL, and two of them are two trial balances.
-- Every relation is read by the organisation first, through the index each has
-- on it, so row security is asked about the organisation's rows only.

create or replace function public.erp_trial_balance(
  p_from date default null,
  p_to date default null,
  p_ledger text default null,
  p_cost_centre text default null)
returns jsonb
language plpgsql
volatile
set search_path to ''
as $$
declare
  v_tenant uuid;
  v_ledger text := nullif(upper(btrim(coalesce(p_ledger, ''))), '');
  v_cc     text := nullif(upper(btrim(coalesce(p_cost_centre, ''))), '');
  v_out    jsonb;
begin
  perform erp.authorise('finance.read');
  v_tenant := erp.require_tenant_id();

  with lines as (
    select e.code as entity,
           led.code as ledger,
           a.code as account,
           a.name as account_name,
           a.account_type::text as account_type,
           coalesce(led.currency, l.currency)::text as currency,
           sum(l.base_debit_minor)::bigint as debit_minor,
           sum(l.base_credit_minor)::bigint as credit_minor
      from erp.ledger led
      join erp.entity e
        on e.tenant_id = led.tenant_id and e.id = led.entity_id
      join erp.journal j
        on j.tenant_id = led.tenant_id and j.ledger_id = led.id and j.status = 'posted'
      join erp.journal_line l
        on l.tenant_id = j.tenant_id and l.journal_id = j.id
      join erp.account a
        on a.tenant_id = l.tenant_id and a.id = l.account_id
     where led.tenant_id = v_tenant
       and (v_ledger is null or led.code = v_ledger)
       and (p_from is null or j.posting_date >= p_from)
       and (p_to is null or j.posting_date <= p_to)
       and (v_cc is null or l.dimensions ->> 'COST_CENTRE' = v_cc)
     group by led.id, e.code, led.code, a.code, a.name, a.account_type, coalesce(led.currency, l.currency)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'entity', x.entity,
           'ledger', x.ledger,
           'account', x.account,
           'name', x.account_name,
           'account_type', x.account_type,
           'currency', x.currency,
           'debit_minor', x.debit_minor,
           'credit_minor', x.credit_minor,
           'balance_minor', x.debit_minor - x.credit_minor)
           order by x.entity, x.ledger, x.account, x.currency), '[]'::jsonb)
    into v_out
    from lines x;

  return v_out;
end $$;

comment on function public.erp_trial_balance(date, date, text, text) is
  'The trial balance per company and ledger: every account with a posted '
  'movement, its debits, credits and balance in the ledger''s currency, '
  'optionally narrowed to a period, a ledger code and a cost centre. Ledgers '
  'are never added together. Authorises finance.read.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Open order lines are lines on orders that can still be fulfilled
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_release_sequence(p_site_id uuid default null, p_limit integer default 100)
returns jsonb
language sql
stable
security invoker
set search_path to ''
as $$
  select coalesce(jsonb_agg(q.x order by q.release_rank), '[]'::jsonb) from (
    select r.release_rank, jsonb_build_object(
             'rank', r.release_rank,
             'line_id', r.line_id, 'document_number', r.document_number,
             'order_state', r.order_state,
             'customer', r.customer, 'item', r.item, 'item_name', r.item_name,
             'quantity', r.quantity, 'quantity_fulfilled', r.quantity_fulfilled,
             'required_date', r.required_date,
             'credit_status', r.credit_status,
             'available', r.available,
             'can_ship_in_full', r.available >= (r.quantity - coalesce(r.quantity_fulfilled, 0))) as x
      from (
        select row_number() over (
                 order by dl.required_date nulls last,
                          case when coalesce(t.credit_status, 'ok') = 'ok' then 0 else 1 end,
                          (dl.quantity * dl.unit_price_minor) desc,
                          d.document_number, dl.line_no)::integer as release_rank,
               dl.id as line_id, d.document_number, s.code as order_state,
               p.name as customer, i.code as item, i.name as item_name,
               dl.quantity, dl.quantity_fulfilled, dl.required_date,
               coalesce(t.credit_status, 'ok') as credit_status,
               coalesce(av.available, 0) as available
          from erp.document_line dl
          join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
          join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
          -- An order that can still be fulfilled: confirmed, or being picked.
          -- A draft is not agreed, one waiting on approval is not approved, and
          -- one despatched, invoiced, closed or cancelled has nothing to release.
          join erp.object_state os
            on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
          join erp.state s on s.id = os.current_state_id
          join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
          left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
          left join erp.party_role_terms t on t.tenant_id = d.tenant_id and t.party_role_id = d.party_role_id
          left join lateral (
            select sum(a.available) as available
              from erp.stock_availability a
             where a.tenant_id = dl.tenant_id and a.item_id = dl.item_id
               and (d.site_id is null or a.site_id = d.site_id)) av on true
         where dl.tenant_id = erp.current_tenant_id()
           and dt.base_type_code = 'sales_order'
           and s.code in ('confirmed', 'picking')
           and coalesce(dl.is_cancelled, false) = false
           and coalesce(d.is_cancelled, false) = false
           and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
           and (p_site_id is null or d.site_id = p_site_id)
      ) r
     order by r.release_rank
     limit greatest(coalesce(p_limit, 100), 1)
  ) q
$$;

comment on function public.erp_release_sequence(uuid, integer) is
  'Lines of sales orders that are confirmed or being picked and not delivered '
  'in full, in the order they should be released: promise date, then credit '
  'standing, then value. The first p_limit in that order. Reads under row '
  'security as the caller.';

-- The forecast's customer demand, from the same orders.

do $forecast$
declare
  v_sig text := 'erp.stock_forecast_lines(uuid,integer)';
  v_def text := pg_get_functiondef('erp.stock_forecast_lines(uuid,integer)'::regprocedure);
  v_old text := $o$     where dl.tenant_id = t.tenant_id
       and dt.code = 'sales_order'
$o$;
  v_new text := $n$     where dl.tenant_id = t.tenant_id
       and dt.code = 'sales_order'
       -- Demand is what customers are still owed: orders confirmed or being
       -- picked (20260914076000). A despatched, invoiced or closed order is
       -- not demand, whatever its lines count as fulfilled.
       and exists (select 1
                     from erp.object_state os
                     join erp.state s on s.id = os.current_state_id
                    where os.tenant_id = d.tenant_id and os.object_type = 'document'
                      and os.object_id = d.id and s.code in ('confirmed', 'picking'))
$n$;
begin
  if position('20260914076000' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % already reads demand from open orders', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not read customer demand the way the 20260910222432 body does', v_sig;
  end if;

  execute replace(v_def, v_old, v_new);

  if position('s.code in (''confirmed'', ''picking'')' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without its open-order demand', v_sig;
  end if;
end
$forecast$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. A demonstration's products have their suppliers
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.seed_demo_item_suppliers(p_tenant_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_made integer;
begin
  if erp.current_tenant_id() is distinct from p_tenant_id then
    raise exception
      'CLOVEERP_DEMO_TENANT_MISMATCH: the session is in organisation % and this '
      'call names %', coalesce(erp.current_tenant_id()::text, 'nobody'), p_tenant_id
      using errcode = '42501',
      hint = 'Adopt the organisation first: erp.set_active_tenant() for a person, '
             'erp.set_job_tenant() for a worker.';
  end if;

  -- The supplier the demo attributes name, as the default for every site. A
  -- product that already has a supplier in force keeps what it has, so running
  -- this again, or after somebody chose, changes nothing.
  insert into erp.item_supplier (
    tenant_id, item_id, party_id, site_id, preference_rank, is_default,
    is_approved_for_use, lead_time_days, status)
  select p_tenant_id, i.id, p.id, null::uuid, 1, true, true,
         case when p.country_code in ('GB', 'IE') then 5 else 10 end,
         'active'::erp.record_status
    from erp.item i
    join erp.party p
      on p.tenant_id = i.tenant_id
     and p.code = i.attributes -> 'demo' ->> 'supplier'
     and p.status = 'active'::erp.record_status
   where i.tenant_id = p_tenant_id
     and i.status = 'active'::erp.record_status
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                    and pr.role_kind = 'supplier' and pr.status = 'active')
     and not exists (select 1 from erp.item_supplier s
                      where s.tenant_id = i.tenant_id and s.item_id = i.id
                        and s.status = 'active' and s.valid_to is null);

  get diagnostics v_made = row_count;
  return v_made;
end;
$$;

comment on function erp.seed_demo_item_suppliers(uuid) is
  'Gives each product whose demo attributes name an active supplier that '
  'supplier as its default for every site, with a lead time, unless the '
  'product already has a supplier in force. Returns how many it gave. For '
  'demonstration configuration; refuses an organisation other than the '
  'session''s.';

revoke all on function erp.seed_demo_item_suppliers(uuid) from public, anon, authenticated;

do $ensure$
declare
  v_sig text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_def text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_old text := $o$    where erp.item.attributes -> 'demo' is null;
$o$;
  v_new text := $n$    where erp.item.attributes -> 'demo' is null;

  -- Who each product is bought from, where purchasing, planning and the stock
  -- forecast read it (20260914076000). The demo attributes named the supplier
  -- for the history builder alone, and every forecast line said No supplier.
  if erp.seed_demo_item_suppliers(p_tenant_id) > 0 then
    v_did := v_did || '"product suppliers"'::jsonb;
  end if;
$n$;
begin
  if position('erp.seed_demo_item_suppliers(' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % already gives products their suppliers', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % does not write its products the way the 20260905010000 body does', v_sig;
  end if;

  execute replace(v_def, v_old, v_new);

  if position('erp.seed_demo_item_suppliers(p_tenant_id)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % was re-emitted without its product suppliers', v_sig;
  end if;
end
$ensure$;

-- Every existing demonstration, in its own context, as nobody.

do $existing$
declare
  t       record;
  v_given integer := 0;
begin
  for t in select tn.id from erp.tenant tn where tn.code like 'demo-%' order by tn.code loop
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    v_given := v_given + erp.seed_demo_item_suppliers(t.id);
  end loop;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);

  raise notice 'demonstrations: % product(s) given their default supplier', v_given;
end
$existing$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The doors
-- ═════════════════════════════════════════════════════════════════════════════

create function public.erp_create_receipt_from_order(
  p_order_id   uuid,
  p_lines      jsonb default null,
  p_transition text  default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.create_receipt_from_order(p_order_id, p_lines, p_transition)
$$;

comment on function public.erp_create_receipt_from_order(uuid, jsonb, text) is
  'Creates a draft goods receipt against a sent or partially received purchase '
  'order, holding what is left to receive on each line (or the lines, '
  'quantities, locations and batches p_lines names: [{"line_id": …, '
  '"quantity": …, "location_id": …, "batch_id": …}]), each line linked back to '
  'the order. p_transition ''auto'' posts it as well. Authorises '
  'procurement.receive. Runs as the caller.';

revoke all on function public.erp_create_receipt_from_order(uuid, jsonb, text) from public, anon;
grant execute on function public.erp_create_receipt_from_order(uuid, jsonb, text) to authenticated, service_role;

create function public.erp_receivable_lines(p_order_id uuid)
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
           'received_quantity', x.received_quantity,
           'on_receipts_quantity', x.on_receipts_quantity,
           'open_quantity', x.open_quantity,
           'batch_controlled', coalesce(i.is_batch_controlled, false),
           'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency)
         order by x.line_no), '[]'::jsonb)
    from erp.receivable_lines(p_order_id) x
    join erp.document_line dl on dl.tenant_id = erp.current_tenant_id() and dl.id = x.line_id
    left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
   where x.open_quantity > 0
$$;

comment on function public.erp_receivable_lines(uuid) is
  'The lines of a purchase order with something left to receive: ordered, '
  'received, on goods receipts not yet cancelled, and left, with whether the '
  'product needs a batch. Reads under row security as the caller, and '
  'authorises nothing.';

revoke all on function public.erp_receivable_lines(uuid) from public, anon;
grant execute on function public.erp_receivable_lines(uuid) to authenticated, service_role;

create function public.erp_conversion_defaults(p_document_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
             'document_id', p_document_id,
             'party_id', cd.party_id, 'party_code', p.code, 'party', p.name,
             'party_source', cd.party_source,
             'site_id', cd.site_id, 'site', s.code)
      from erp.conversion_defaults(p_document_id) cd
      left join erp.party p on p.tenant_id = erp.current_tenant_id() and p.id = cd.party_id
      left join erp.site s on s.tenant_id = erp.current_tenant_id() and s.id = cd.site_id), '{}'::jsonb)
$$;

comment on function public.erp_conversion_defaults(uuid) is
  'The supplier and site converting a document takes when none is chosen, for '
  'the form to arrive holding: the document''s partner, or for a requisition '
  'with none the default supplier its product lines share; and its site. '
  'Reads under row security as the caller, and authorises nothing.';

revoke all on function public.erp_conversion_defaults(uuid) from public, anon;
grant execute on function public.erp_conversion_defaults(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_receipt_from_order', 'erp.create_receipt_from_order',
   'Creates a draft goods receipt against a purchase order that is sent or partially received, each open line at what is left, received through erp.receive_against and linked back to its order line. Gated on procurement.receive inside erp.create_receipt_from_order(); opening the receipt and receiving each line authorise procurement.receive again, a location or batch is written under the receipt type''s create permission, and a move asked for is authorised by its transition.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The refusals, and the words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_NOT_A_PURCHASE_ORDER',
  'Receiving goods against a document that is not a purchase order.',
  'Goods are received against the purchase order that asked the supplier for them, which gives the receipt its supplier, its lines and its prices.',
  'Choose a purchase order that has been sent to the supplier.');

select erp.register_refusal('CLOVEERP_NOTHING_TO_RECEIVE',
  'Receiving goods against a purchase order with nothing left on it to receive.',
  'Every line has been received, or is on a goods receipt raised against the order already, posted or not, or no line was chosen.',
  'Post or cancel the goods receipts already raised against the order, or choose a line with something left on it.');

select erp.register_refusal('CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE',
  'Receiving more of an order line than is left on it.',
  'What is left is what was ordered less what goods receipts already hold, posted or not. Receiving the order in one go takes what was ordered and no more.',
  'Receive what is left, or less. When the supplier sent more than was ordered, receive the extra against the order line on its own, where the receipt tolerance decides.');

select erp.register_refusal('CLOVEERP_NOT_A_LINE_TO_RECEIVE',
  'Receiving a line that is not an open product line of the purchase order the goods receipt is raised against.',
  'A goods receipt raised against an order carries that order''s lines and links each back to it. A line of another order, a cancelled line or a line with no product cannot be linked.',
  'Choose lines of the order the goods arrived against.');

select erp.register_refusal('CLOVEERP_NO_RECEIPT_TYPE',
  'Receiving goods in an organisation that has no goods receipt document type in use.',
  'A goods receipt is a document of a type the organisation installs with purchasing, which gives it its numbering and its lifecycle.',
  'Install purchasing on the Configuration screen, then receive the order.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    -- Receiving an order.
    ('Receive this order',
     'The button on a purchase order that creates its goods receipt.'),
    ('Receive an order',
     'The button on Purchasing''s goods receipt step and bar that creates a goods receipt against a purchase order chosen on the form.'),
    ('Receive goods against a purchase order',
     'The title of the form that creates a goods receipt against a purchase order chosen on it.'),
    ('A draft goods receipt for the order''s supplier and site, holding what is left to receive on each line at the order''s price. Post it once the goods are counted in.',
     'What the form that creates a goods receipt against a purchase order does.'),
    ('Create the goods receipt',
     'The button that submits the form creating a goods receipt against a purchase order.'),
    ('Lines to receive',
     'The line editor on the form creating a goods receipt against a purchase order.'),
    ('Each line with something left to receive arrives holding what is left. Lower a quantity to receive part of a line, remove a line to leave it for a later delivery, or add the same line twice for two batches. A batch-controlled product needs its batch before the receipt posts.',
     'The line editor on the form creating a goods receipt against a purchase order, explained.'),
    ('Nothing is left to receive on this order: every line has been received or is on a goods receipt already.',
     'Said by the form creating a goods receipt when the order chosen has nothing left.'),
    ('Purchase order',
     'The purchase order a form acts on.'),
    ('Location',
     'Where the goods on a line are put.'),
    ('Receipts appear here once goods are received against a purchase order. Receive an order is on this step.',
     'The goods receipt step on Purchasing: said when no receipt is waiting.'),
    -- Converting a requisition.
    ('The requisition''s supplier, or the default supplier every product on it is bought from. Change it to order from someone else.',
     'The supplier field on the form turning a requisition into a purchase order.'),
    ('The requisition''s site. Change it to deliver somewhere else.',
     'The site field on the form turning a requisition into a purchase order.'),
    ('Site the goods are for',
     'The site field''s label on the form turning a requisition into a purchase order.'),
    ('Requisition',
     'The requisition a form acts on.'),
    -- The reports.
    ('Every nominal account with a movement in the general ledger, to date.',
     'The trial balance report on Financials.'),
    ('61–90',
     'An age band on an ageing report: sixty-one to ninety days overdue.'),
    ('90+',
     'An age band on an ageing report: more than ninety days overdue.'),
    ('Days overdue',
     'How many days the oldest overdue amount has waited.'),
    ('Level',
     'The dunning level a customer has reached.'),
    ('Value',
     'An amount of money a report row carries.'),
    ('Provision',
     'The amount set aside against slow-moving stock.'),
    ('Receivable',
     'What a company in the group is owed by another.'),
    ('Payable',
     'What a company in the group owes another.'),
    ('Difference',
     'The gap between what one company says it is owed and what the other says it owes.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- A row that did not land is a string the terminology screen cannot offer.
do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values
      ('Receive this order'),
      ('Receive an order'),
      ('Receive goods against a purchase order'),
      ('Create the goods receipt'),
      ('Lines to receive'),
      ('Purchase order'),
      ('Location'),
      ('Requisition'),
      ('Site the goods are for'),
      ('Every nominal account with a movement in the general ledger, to date.'),
      ('61–90'),
      ('90+'),
      ('Days overdue'),
      ('Level'),
      ('Value'),
      ('Provision'),
      ('Receivable'),
      ('Payable'),
      ('Difference')
    ) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_STRINGS_SHORT: no resource row for %', v_missing
      using hint = 'Row security refused the write, or erp_ref.ui_key changed. Seed the row the desk asks for.';
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A live organisation with two administrators, as 20260914064000's suite: the
-- first orders, receives, sells and despatches; the second approves and
-- promotes. Finance, procurement and sales are installed through changes the
-- second promotes. Two people each hold one narrow role, made with the
-- organisation's window opened for the purpose, and call the door signed in
-- through erp_test.receipt_door_as(). Orders are submitted by the first
-- administrator and approved through erp_test.approve_document(). The
-- receiving cases run in one block, and the conversion, report, release and
-- forecast cases each in a block of their own, so a failure in one names
-- itself and does not hide the others. Everything is built inside a block that
-- ends by raising, so nothing outlives the suite.

create or replace function erp_test.receipt_door_as(p_subject uuid, p_order_id uuid)
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
    outcome := public.erp_create_receipt_from_order(p_order_id => p_order_id);
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text;
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', v_claims, true);
  return next;
end;
$$;

comment on function erp_test.receipt_door_as(uuid, uuid) is
  'Suite helper: calls public.erp_create_receipt_from_order for one order as '
  'the given sign-in, in the authenticated role, and returns its answer and the '
  'role it ran as, or its refusal. Returns to the calling role and claims '
  'before it returns.';

revoke all on function erp_test.receipt_door_as(uuid, uuid) from public, anon, authenticated;

create or replace function erp_test.receive_from_order_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_owner  text := current_user;
  a1       uuid := gen_random_uuid();   -- the first administrator, who orders, receives and sells
  a2       uuid := gen_random_uuid();   -- the second, who approves and promotes
  s_recv   uuid := gen_random_uuid();   -- holds procurement.read and procurement.receive, and nothing else
  s_look   uuid := gen_random_uuid();   -- holds procurement.read, and nothing else
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
  v_dn     integer;
  v_dargs  text;
  v_ddef   boolean;
  v_dstab  boolean;
  v_dgrant boolean;
  -- The organisation.
  v_uom    uuid;
  v_site   uuid;
  v_bulk   uuid;
  v_sup    uuid;
  v_sup2   uuid;
  v_cust   uuid;
  v_item   uuid;
  v_nut    uuid;
  v_bolt   uuid;
  u_recv   uuid;
  u_look   uuid;
  -- A whole order, received.
  v_po1        uuid;
  v_po1_a      uuid;
  v_po1_b      uuid;
  v_po1_sent   text;
  v_po1_number text;
  v_gr1        jsonb;
  v_gr1_id     uuid;
  v_gr1_head   boolean;
  v_gr1_ref    text;
  v_gr1_draft  text;
  v_gr1_lines  boolean;
  v_gr1_says   text;
  v_gr1_links  integer;
  v_gr1_linked boolean;
  v_po1_mid    text;
  v_again_err  text;
  v_stock0     numeric;
  v_stock1     numeric;
  v_po1_end    text;
  v_po1_a_done numeric;
  v_po1_b_done numeric;
  -- Part of an order, then the rest.
  v_po2        uuid;
  v_po2_l      uuid;
  v_gr2        jsonb;
  v_gr2_qty    numeric;
  v_gr2_loc    boolean;
  v_over_err   text;
  v_other_err  text;
  v_offered    jsonb;
  v_po2_mid    text;
  v_gr3        jsonb;
  v_gr3_state  text;
  v_po2_end    text;
  v_po2_done   numeric;
  -- Refused.
  v_po3        uuid;
  v_draft_err  text;
  v_kind_err   text;
  -- Signed in.
  v_po4        uuid;
  v_signed     jsonb;
  v_signed_as  text;
  v_signed_err text;
  v_signed_lines integer;
  v_signed_base  text;
  v_look_state text;
  v_look_err   text;
  -- Converting a requisition.
  v_conv_err   text;
  v_rq_a       uuid;
  v_rq_b       uuid;
  v_rq_c       uuid;
  v_def_a      jsonb;
  v_def_b      jsonb;
  v_def_c      jsonb;
  v_made_po    jsonb;
  v_made_party uuid;
  v_made_site  uuid;
  -- The reports.
  v_rep_err    text;
  v_ageing     jsonb;
  v_age_row    jsonb;
  v_tb_gl      jsonb;
  v_tb_all     jsonb;
  -- Open order lines.
  v_rel_err    text;
  v_so_open    uuid;
  v_so_open_l  uuid;
  v_so_hist    uuid;
  v_so_hist_l  uuid;
  v_so_hist_state text;
  v_released   jsonb;
  v_demand     numeric;
  -- The demonstration's suppliers, and usage.
  v_demo_err   text;
  v_given1     integer;
  v_given2     integer;
  v_wid_sup    uuid;
  v_wid_lead   integer;
  v_nut_sup    uuid;
  v_bolt_sups  integer;
  v_fc_sup     uuid;
  v_so_del     uuid;
  v_dn_made    jsonb;
  v_usage      numeric;
  v_fc_state   text;
begin
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 'v'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_cn, v_cargs, v_cdef, v_cvol, v_cgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_create_receipt_from_order';

  select w.gate into v_cgate
    from erp_meta.public_write_allowance w
   where w.function_name = 'erp_create_receipt_from_order';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_rn, v_rargs, v_rdef, v_rstab, v_rgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_receivable_lines';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_dn, v_dargs, v_ddef, v_dstab, v_dgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_conversion_defaults';

  begin
    -- ── A live organisation and its two administrators ─────────────────────
    v_step := 'the organisation is provisioned and its two administrators join';
    select * into r from erp.provision_tenant(
      'zz-rfo-' || v_hex, 'Receipt from order suite',
      'admin@zz-rfo-' || v_hex || '.test', 'Receiving Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-rfo-' || v_hex || '.test', 'Second Admin');
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

    v_step := 'a site with goods-in and bulk, two suppliers, a customer with credit and three products';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active');
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'BULK', 'Bulk store', 'bulk', 'active') returning id into v_bulk;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (r.tenant_id, 'SUP2', 'Second supplier', 'GB', 'active') returning id into v_sup2;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active'), (r.tenant_id, v_sup2, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 10000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status, attributes)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active',
            jsonb_build_object('demo', jsonb_build_object('supplier', 'SUP'))) returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status, attributes)
    values (r.tenant_id, 'NUT', 'Nut', v_uom, 'active',
            jsonb_build_object('demo', jsonb_build_object('supplier', 'SUP'))) returning id into v_nut;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status, attributes)
    values (r.tenant_id, 'BOLT', 'Bolt', v_uom, 'active',
            jsonb_build_object('demo', jsonb_build_object('supplier', 'SUP'))) returning id into v_bolt;
    -- The bolt is already bought from the second supplier.
    insert into erp.item_supplier (tenant_id, item_id, party_id, is_default, lead_time_days, status)
    values (r.tenant_id, v_bolt, v_sup2, true, 3, 'active');

    v_step := 'two people each hold one narrow role';
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status) values
      (r.tenant_id, 'zz_receiver', 'Suite receiver', 'active'),
      (r.tenant_id, 'zz_onlooker', 'Suite onlooker', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select r.tenant_id, ro.id, x.perm
      from (values ('zz_receiver', 'procurement.read'), ('zz_receiver', 'procurement.receive'),
                   ('zz_onlooker', 'procurement.read')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;
    perform erp_test.close_bootstrap_window(r.tenant_id);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_recv, 'person', 'active', 'Suite Receiver', 'receive@zz-rfo-' || v_hex || '.test', 'en')
    returning id into u_recv;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_look, 'person', 'active', 'Suite Onlooker', 'onlooker@zz-rfo-' || v_hex || '.test', 'en')
    returning id into u_look;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select r.tenant_id, x.person, ro.id, 'The suite''s narrow role.'
      from (values (u_recv, 'zz_receiver'), (u_look, 'zz_onlooker')) as x(person, role_code)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;

    -- ── A whole order, received ────────────────────────────────────────────
    v_step := 'an order of two lines is submitted, approved and sent';
    v_po1 := erp.open_document('purchase_order', v_sup, null, v_site);
    v_po1_a := erp.add_document_line(v_po1, v_item, 10, 1000, 'Ten widgets');
    v_po1_b := erp.add_document_line(v_po1, v_item, 5, 1000, 'Five more widgets');
    perform erp.transition_document(v_po1, 'submit', 'receipt from order suite');
    perform erp_test.approve_document(v_po1, 'receipt from order suite');
    v_po1_sent := erp.transition_document(v_po1, 'send', 'receipt from order suite');

    v_step := 'a goods receipt is created from the sent order';
    v_gr1 := erp.create_receipt_from_order(v_po1);
    v_gr1_id := (v_gr1 ->> 'document_id')::uuid;
    select o.document_number into v_po1_number
      from erp.document o where o.tenant_id = r.tenant_id and o.id = v_po1;
    select gr.party_id = o.party_id and gr.entity_id = o.entity_id and gr.site_id = o.site_id
           and dt.base_type_code = 'receipt' and not gr.is_cancelled,
           gr.our_reference
      into v_gr1_head, v_gr1_ref
      from erp.document gr
      join erp.document_type dt on dt.tenant_id = gr.tenant_id and dt.id = gr.document_type_id
      join erp.document o on o.tenant_id = gr.tenant_id and o.id = v_po1
     where gr.tenant_id = r.tenant_id and gr.id = v_gr1_id;
    v_gr1_draft := erp.object_current_state('document', v_gr1_id);
    select coalesce(count(*) = 2
                    and bool_and(l.item_id = v_item and l.unit_price_minor = 1000)
                    and bool_or(l.quantity = 10 and l.description = 'Ten widgets')
                    and bool_or(l.quantity = 5 and l.description = 'Five more widgets'), false),
           string_agg(format('%s at %s, %s', trim_scale(l.quantity), l.unit_price_minor, l.description),
                      '; ' order by l.line_no)
      into v_gr1_lines, v_gr1_says
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = v_gr1_id and not l.is_cancelled;
    select count(*),
           coalesce(bool_and(rel.to_document_id = v_po1
                             and rel.relation_kind = 'fulfils'
                             and ((rel.to_line_id = v_po1_a and rel.quantity = 10)
                                  or (rel.to_line_id = v_po1_b and rel.quantity = 5))
                             and exists (select 1 from erp.document_line fl
                                          where fl.tenant_id = rel.tenant_id and fl.id = rel.from_line_id
                                            and fl.document_id = v_gr1_id)), false)
      into v_gr1_links, v_gr1_linked
      from erp.document_relation rel
     where rel.tenant_id = r.tenant_id and rel.from_document_id = v_gr1_id;
    v_po1_mid := erp.object_current_state('document', v_po1);

    begin
      perform erp.create_receipt_from_order(v_po1);
    exception when others then
      v_again_err := left(sqlerrm, 200);
    end;

    v_step := 'the goods receipt is posted';
    select coalesce(sum(b.quantity), 0) into v_stock0
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;
    perform erp.transition_document(v_gr1_id, 'post', 'receipt from order suite');
    select coalesce(sum(b.quantity), 0) into v_stock1
      from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = v_item;
    v_po1_end := erp.object_current_state('document', v_po1);
    select l.quantity_fulfilled into v_po1_a_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_po1_a;
    select l.quantity_fulfilled into v_po1_b_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_po1_b;

    -- ── Part of an order, then the rest ────────────────────────────────────
    v_step := 'a second order of twenty is sent';
    v_po2 := erp.open_document('purchase_order', v_sup, null, v_site);
    v_po2_l := erp.add_document_line(v_po2, v_item, 20, 1000, 'Twenty widgets');
    perform erp.transition_document(v_po2, 'submit', 'receipt from order suite');
    perform erp_test.approve_document(v_po2, 'receipt from order suite');
    perform erp.transition_document(v_po2, 'send', 'receipt from order suite');

    v_step := 'eight of the twenty arrive, put in bulk';
    v_gr2 := erp.create_receipt_from_order(
      v_po2, jsonb_build_array(jsonb_build_object('line_id', v_po2_l, 'quantity', 8, 'location_id', v_bulk)));
    select sum(l.quantity), coalesce(bool_and(l.location_id = v_bulk), false)
      into v_gr2_qty, v_gr2_loc
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = (v_gr2 ->> 'document_id')::uuid;

    begin
      perform erp.create_receipt_from_order(
        v_po2, jsonb_build_array(jsonb_build_object('line_id', v_po2_l, 'quantity', 13)));
    exception when others then
      v_over_err := left(sqlerrm, 200);
    end;
    begin
      perform erp.create_receipt_from_order(
        v_po2, jsonb_build_array(jsonb_build_object('line_id', v_po1_a, 'quantity', 1)));
    exception when others then
      v_other_err := left(sqlerrm, 200);
    end;
    v_offered := public.erp_receivable_lines(v_po2);

    v_step := 'the part receipt is posted';
    perform erp.transition_document((v_gr2 ->> 'document_id')::uuid, 'post', 'receipt from order suite');
    v_po2_mid := erp.object_current_state('document', v_po2);

    v_step := 'the rest is created and moved on in one call';
    v_gr3 := erp.create_receipt_from_order(v_po2, null, 'auto');
    v_gr3_state := erp.object_current_state('document', (v_gr3 ->> 'document_id')::uuid);
    v_po2_end := erp.object_current_state('document', v_po2);
    select l.quantity_fulfilled into v_po2_done from erp.document_line l where l.tenant_id = r.tenant_id and l.id = v_po2_l;

    -- ── Refused ─────────────────────────────────────────────────────────────
    v_step := 'an order never sent, and a document that is not a purchase order';
    v_po3 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po3, v_item, 1, 1000, 'One widget');
    begin
      perform erp.create_receipt_from_order(v_po3);
    exception when others then
      v_draft_err := left(sqlerrm, 200);
    end;
    begin
      perform erp.create_receipt_from_order(v_gr1_id);
    exception when others then
      v_kind_err := left(sqlerrm, 200);
    end;

    -- ── Signed in ───────────────────────────────────────────────────────────
    v_step := 'a fourth order is sent';
    v_po4 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po4, v_item, 3, 1000, 'Three widgets');
    perform erp.transition_document(v_po4, 'submit', 'receipt from order suite');
    perform erp_test.approve_document(v_po4, 'receipt from order suite');
    perform erp.transition_document(v_po4, 'send', 'receipt from order suite');

    v_step := 'the receiver, signed in, creates its goods receipt through the door';
    select * into g from erp_test.receipt_door_as(s_recv, v_po4);
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
    select * into g from erp_test.receipt_door_as(s_look, v_po4);
    v_look_state := g.err_state;
    v_look_err := coalesce(g.err_message, g.outcome::text);

    -- ── Converting a requisition ───────────────────────────────────────────
    v_step := 'requisitions are raised and their defaults read';
    begin
      -- The widget and the nut are given their supplier as a demonstration's
      -- products are; the bolt keeps the second supplier it already has.
      v_given1 := erp.seed_demo_item_suppliers(r.tenant_id);
      v_given2 := erp.seed_demo_item_suppliers(r.tenant_id);

      -- Widgets and nuts, both bought from the supplier, and no partner.
      v_rq_a := erp.open_document('requisition', null, null, v_site);
      perform erp.add_document_line(v_rq_a, v_item, 4, 1000, 'Four widgets');
      perform erp.add_document_line(v_rq_a, v_nut, 6, 50, 'Six nuts');
      v_def_a := public.erp_conversion_defaults(v_rq_a);

      -- A partner named on the requisition wins.
      v_rq_b := erp.open_document('requisition', v_sup2, null, v_site);
      perform erp.add_document_line(v_rq_b, v_item, 1, 1000, 'One widget');
      v_def_b := public.erp_conversion_defaults(v_rq_b);

      -- Widgets and bolts: two suppliers, so no supplier is chosen.
      v_rq_c := erp.open_document('requisition', null, null, v_site);
      perform erp.add_document_line(v_rq_c, v_item, 1, 1000, 'One widget');
      perform erp.add_document_line(v_rq_c, v_bolt, 1, 20, 'One bolt');
      v_def_c := public.erp_conversion_defaults(v_rq_c);

      -- Converting the first with nothing chosen.
      perform erp.transition_document(v_rq_a, 'submit', 'receipt from order suite');
      perform erp.transition_document(v_rq_a, 'approve', 'receipt from order suite');
      v_made_po := erp.convert_document(v_rq_a);
      select d.party_id, d.site_id into v_made_party, v_made_site
        from erp.document d
       where d.tenant_id = r.tenant_id and d.id = (v_made_po ->> 'document_id')::uuid;
    exception when others then
      v_conv_err := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end;

    -- ── The reports ────────────────────────────────────────────────────────
    v_step := 'the customer owes an invoice forty-five days overdue, and the ledgers are read';
    begin
      insert into erp.subledger_item (
        tenant_id, entity_id, ledger_id, control_kind, control_account_id,
        party_id, currency, debit_minor, credit_minor, due_date, posting_date)
      select r.tenant_id, r.entity_id, led.id, 'receivable'::erp.control_account_kind, acc.id,
             v_cust, led.currency, 12500, 0, current_date - 45, current_date - 75
        from erp.ledger led
        cross join lateral (
          select a.id from erp.account a
           where a.tenant_id = r.tenant_id and a.control_kind = 'receivable'
           order by a.code limit 1) acc
       where led.tenant_id = r.tenant_id and led.is_primary
       order by led.code
       limit 1;
      v_ageing := public.erp_receivables_ageing();
      select el.elem into v_age_row
        from jsonb_array_elements(v_ageing) as el(elem)
       where el.elem ->> 'party_id' = v_cust::text;
      v_tb_gl := public.erp_trial_balance(p_ledger => 'GL');
      v_tb_all := public.erp_trial_balance();
    exception when others then
      v_rep_err := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end;

    -- ── Open order lines ───────────────────────────────────────────────────
    v_step := 'one sales order is confirmed, and one is despatched as the trading history despatches';
    begin
      v_so_open := erp.open_document('sales_order', v_cust, null, v_site);
      v_so_open_l := erp.add_document_line(v_so_open, v_item, 3, 2500, 'Three widgets, confirmed');
      perform erp.transition_document(v_so_open, 'submit', 'receipt from order suite');
      perform erp_test.approve_document(v_so_open, 'receipt from order suite');

      v_so_hist := erp.open_document('sales_order', v_cust, null, v_site);
      v_so_hist_l := erp.add_document_line(v_so_hist, v_item, 4, 2500, 'Four widgets, gone');
      perform erp.transition_document(v_so_hist, 'submit', 'receipt from order suite');
      perform erp_test.approve_document(v_so_hist, 'receipt from order suite');
      perform erp.transition_document(v_so_hist, 'pick', 'receipt from order suite');
      perform erp.transition_document(v_so_hist, 'despatch', 'receipt from order suite');
      v_so_hist_state := erp.object_current_state('document', v_so_hist);

      v_released := public.erp_release_sequence();
      select f.demand into v_demand
        from erp.stock_forecast_lines(v_site, 90) f
       where f.item_id = v_item;
    exception when others then
      v_rel_err := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end;

    -- ── The demonstration's suppliers, and usage ───────────────────────────
    v_step := 'the products'' suppliers are read, and a delivery goes';
    begin
      select s.party_id, s.lead_time_days into v_wid_sup, v_wid_lead
        from erp.item_supplier s
       where s.tenant_id = r.tenant_id and s.item_id = v_item and s.is_default and s.status = 'active';
      select s.party_id into v_nut_sup
        from erp.item_supplier s
       where s.tenant_id = r.tenant_id and s.item_id = v_nut and s.is_default and s.status = 'active';
      select count(*) into v_bolt_sups
        from erp.item_supplier s
       where s.tenant_id = r.tenant_id and s.item_id = v_bolt and s.status = 'active';

      v_so_del := erp.open_document('sales_order', v_cust, null, v_site);
      perform erp.add_document_line(v_so_del, v_item, 6, 2500, 'Six widgets, delivered');
      perform erp.transition_document(v_so_del, 'submit', 'receipt from order suite');
      perform erp_test.approve_document(v_so_del, 'receipt from order suite');
      v_dn_made := erp.create_delivery_from_order(v_so_del, null, 'auto');

      select f.supplier_party_id, f.usage_quantity, f.state
        into v_fc_sup, v_usage, v_fc_state
        from erp.stock_forecast_lines(v_site, 90) f
       where f.item_id = v_item;
    exception when others then
      v_demo_err := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_RECEIVE_FROM_ORDER_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_RECEIVE_FROM_ORDER_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end if;
    -- Whatever failed, and wherever, the rest of the suite runs as its owner.
    execute format('set local role %I', v_owner);
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ───────────────────────────────────────────────────────────────────────────
  -- The doors
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the receipt door is one function that runs as the caller, may write, takes the order, its lines and a move, is on the write register, and a signed-in caller may execute it; the lines and defaults doors only read';
  passed := coalesce(v_cn = 1 and not v_cdef and v_cvol and v_cgrant
                     and v_cargs = 'p_order_id uuid, p_lines jsonb, p_transition text'
                     and v_cgate = 'erp.create_receipt_from_order'
                     and v_rn = 1 and not v_rdef and v_rstab and v_rgrant
                     and v_rargs = 'p_order_id uuid'
                     and v_dn = 1 and not v_ddef and v_dstab and v_dgrant
                     and v_dargs = 'p_document_id uuid', false);
  detail := format('receipt door: %s function(s) (%s), definer %s, volatile %s, granted %s, gate %s; lines door: %s (%s), definer %s, stable %s, granted %s; defaults door: %s (%s), definer %s, stable %s, granted %s',
                   v_cn, coalesce(v_cargs, 'none'), v_cdef, v_cvol, v_cgrant, coalesce(v_cgate, 'none'),
                   v_rn, coalesce(v_rargs, 'none'), v_rdef, v_rstab, v_rgrant,
                   v_dn, coalesce(v_dargs, 'none'), v_ddef, v_dstab, v_dgrant);
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- A whole order
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a sent purchase order becomes a draft goods receipt for its supplier, company and site, each line at what is left, at the order''s price and with its description';
  passed := coalesce(v_state is null and v_po1_sent = 'sent' and v_gr1_head
                     and v_gr1_draft = 'draft' and v_gr1_lines
                     and v_gr1_ref = v_po1_number
                     and (v_gr1 ->> 'lines')::integer = 2 and (v_gr1 ->> 'quantity')::numeric = 15, false);
  detail := coalesce(v_state, format('order %s; receipt %s, same supplier, company and site %s, our reference %s; lines: %s',
                                     v_po1_sent, coalesce(v_gr1_draft, 'no state'), coalesce(v_gr1_head::text, 'unknown'),
                                     coalesce(v_gr1_ref, 'none'), coalesce(v_gr1_says, 'none')));
  return next;

  case_name := 'each receipt line is linked back to its order line, and the order stays sent while the receipt is a draft';
  passed := coalesce(v_state is null and v_gr1_links = 2 and v_gr1_linked and v_po1_mid = 'sent', false);
  detail := coalesce(v_state, format('%s link(s), each to its order line %s; the order %s',
                                     v_gr1_links, v_gr1_linked, v_po1_mid));
  return next;

  case_name := 'with the whole order on a draft goods receipt, another is refused: nothing is left to receive';
  passed := coalesce(v_state is null and v_again_err like 'CLOVEERP_NOTHING_TO_RECEIVE%', false);
  detail := coalesce(v_state, v_again_err, 'a second goods receipt was created');
  return next;

  case_name := 'posting the goods receipt puts the stock in, counts what was received on each order line, and moves the order to received';
  passed := coalesce(v_state is null and v_stock1 - v_stock0 = 15
                     and v_po1_a_done = 10 and v_po1_b_done = 5
                     and v_po1_end = 'received', false);
  detail := coalesce(v_state, format('stock %s to %s; received %s and %s; the order %s',
                                     trim_scale(v_stock0), trim_scale(v_stock1), trim_scale(v_po1_a_done),
                                     trim_scale(v_po1_b_done), v_po1_end));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Part, then the rest
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'part of a line arrives at the quantity asked for, at the location named';
  passed := coalesce(v_state is null and v_gr2_qty = 8 and v_gr2_loc, false);
  detail := coalesce(v_state, format('the receipt carries %s, at bulk %s', trim_scale(v_gr2_qty), v_gr2_loc));
  return next;

  case_name := 'while that receipt is a draft, asking for more than is left is refused by name';
  passed := coalesce(v_state is null and v_over_err like 'CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE%', false);
  detail := coalesce(v_state, v_over_err, 'thirteen were received where twelve were left');
  return next;

  case_name := 'a line of another order is refused by name';
  passed := coalesce(v_state is null and v_other_err like 'CLOVEERP_NOT_A_LINE_TO_RECEIVE%', false);
  detail := coalesce(v_state, v_other_err, 'a line of another order was received');
  return next;

  case_name := 'the lines door offers what is left on the order, net of the draft goods receipt';
  passed := coalesce(v_state is null and jsonb_array_length(v_offered) = 1
                     and (v_offered -> 0 ->> 'line_id')::uuid = v_po2_l
                     and (v_offered -> 0 ->> 'ordered_quantity')::numeric = 20
                     and (v_offered -> 0 ->> 'on_receipts_quantity')::numeric = 8
                     and (v_offered -> 0 ->> 'received_quantity')::numeric = 0
                     and (v_offered -> 0 ->> 'open_quantity')::numeric = 12, false);
  detail := coalesce(v_state, coalesce(v_offered::text, 'nothing'));
  return next;

  case_name := 'posting the part receipt moves the order to partially received';
  passed := coalesce(v_state is null and v_po2_mid = 'partially_received', false);
  detail := coalesce(v_state, format('the order %s', v_po2_mid));
  return next;

  case_name := 'the rest, created and moved on in one call, posts and moves the order to received';
  passed := coalesce(v_state is null and v_gr3 ->> 'moved_on' = 'post'
                     and (v_gr3 ->> 'quantity')::numeric = 12
                     and v_gr3_state = 'posted' and v_po2_done = 20
                     and v_po2_end = 'received' and v_gr3 ->> 'order_state' = 'received', false);
  detail := coalesce(v_state, format('%s carried, moved on by %s and %s; %s received; the order %s',
                                     coalesce(v_gr3 ->> 'quantity', 'nothing'), coalesce(v_gr3 ->> 'moved_on', 'nothing'),
                                     coalesce(v_gr3_state, 'no state'), trim_scale(v_po2_done), v_po2_end));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Refused
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a purchase order never sent is refused, naming its state';
  passed := coalesce(v_state is null and v_draft_err like 'CLOVEERP_ORDER_NOT_SENT%'
                     and v_draft_err like '%Draft%', false);
  detail := coalesce(v_state, v_draft_err, 'a goods receipt was created against a draft');
  return next;

  case_name := 'a document that is not a purchase order is refused';
  passed := coalesce(v_state is null and v_kind_err like 'CLOVEERP_NOT_A_PURCHASE_ORDER%', false);
  detail := coalesce(v_state, v_kind_err, 'a goods receipt was created against a goods receipt');
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Signed in
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'signed in with only procurement.read and procurement.receive, a person creates a goods receipt from an order through the door';
  passed := coalesce(v_state is null and v_signed_err is null and v_signed_as = 'authenticated'
                     and v_signed_lines = 1 and v_signed_base = 'receipt'
                     and (v_signed ->> 'lines')::integer = 1, false);
  detail := coalesce(v_state, v_signed_err,
                     format('ran as %s; %s line(s) of three on a %s', coalesce(v_signed_as, 'nobody'),
                            v_signed_lines, coalesce(v_signed_base, 'nothing')));
  return next;

  case_name := 'signed in with procurement.read and not procurement.receive, a person is refused, naming procurement.receive';
  passed := coalesce(v_state is null and v_look_state = '42501'
                     and v_look_err like 'CLOVEERP_PERMISSION_DENIED: procurement.receive%', false);
  detail := coalesce(v_state, format('%s: %s', coalesce(v_look_state, 'no refusal'), coalesce(v_look_err, 'no answer')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Converting a requisition
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a requisition with no partner defaults to the supplier every product on it shares in item supply, and to its own site';
  passed := coalesce(v_state is null and v_conv_err is null
                     and (v_def_a ->> 'party_id')::uuid = v_sup
                     and v_def_a ->> 'party_source' = 'item_supply'
                     and v_def_a ->> 'party' = 'Supplier'
                     and (v_def_a ->> 'site_id')::uuid = v_site, false);
  detail := coalesce(v_state, v_conv_err, coalesce(v_def_a::text, 'nothing'));
  return next;

  case_name := 'the partner a requisition names wins over item supply';
  passed := coalesce(v_state is null and v_conv_err is null
                     and (v_def_b ->> 'party_id')::uuid = v_sup2
                     and v_def_b ->> 'party_source' = 'document', false);
  detail := coalesce(v_state, v_conv_err, coalesce(v_def_b::text, 'nothing'));
  return next;

  case_name := 'products bought from two suppliers leave the supplier to be chosen, and the site still defaults';
  passed := coalesce(v_state is null and v_conv_err is null
                     and v_def_c ->> 'party_id' is null
                     and v_def_c ->> 'party_source' is null
                     and (v_def_c ->> 'site_id')::uuid = v_site, false);
  detail := coalesce(v_state, v_conv_err, coalesce(v_def_c::text, 'nothing'));
  return next;

  case_name := 'converting that requisition with nothing chosen orders from the shared default supplier, for the requisition''s site';
  passed := coalesce(v_state is null and v_conv_err is null
                     and v_made_party = v_sup and v_made_site = v_site
                     and (v_made_po ->> 'lines')::integer = 2, false);
  detail := coalesce(v_state, v_conv_err,
                     format('%s: party %s, site %s', coalesce(v_made_po::text, 'nothing'),
                            coalesce(v_made_party::text, 'none'), coalesce(v_made_site::text, 'none')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The reports
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'receivables ageing names the customer, bands what is owed by how overdue it is, and an empty band is zero';
  passed := coalesce(v_state is null and v_rep_err is null
                     and v_age_row ->> 'party_name' = 'Customer'
                     and v_age_row ->> 'currency' is not null
                     and (v_age_row ->> 'days_31_60')::bigint = 12500
                     and (v_age_row ->> 'current_minor')::bigint = 0
                     and (v_age_row ->> 'days_1_30')::bigint = 0
                     and (v_age_row ->> 'days_61_90')::bigint = 0
                     and (v_age_row ->> 'days_over_90')::bigint = 0
                     and (v_age_row ->> 'total_minor')::bigint = 12500, false);
  detail := coalesce(v_state, v_rep_err, coalesce(v_age_row::text, coalesce(v_ageing::text, 'nothing')));
  return next;

  case_name := 'the trial balance reads per ledger: the general ledger''s rows name it, carry a currency and balance, and ledgers are never added together';
  passed := coalesce(v_state is null and v_rep_err is null
                     and jsonb_array_length(v_tb_gl) > 0
                     and not exists (select 1 from jsonb_array_elements(v_tb_gl) e
                                      where e ->> 'ledger' <> 'GL' or e ->> 'currency' is null)
                     and (select sum((e ->> 'debit_minor')::bigint) = sum((e ->> 'credit_minor')::bigint)
                            from jsonb_array_elements(v_tb_gl) e)
                     and not exists (select 1 from jsonb_array_elements(v_tb_all) e where e ->> 'ledger' = 'ALL')
                     and jsonb_array_length(v_tb_all) >= jsonb_array_length(v_tb_gl), false);
  detail := coalesce(v_state, v_rep_err,
                     format('general ledger: %s row(s); every ledger: %s row(s), ledgers %s',
                            jsonb_array_length(v_tb_gl), jsonb_array_length(v_tb_all),
                            (select string_agg(distinct e ->> 'ledger', ', ') from jsonb_array_elements(v_tb_all) e)));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Open order lines
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'open order lines are lines of orders that can still be fulfilled: a confirmed order''s line is listed, a despatched order''s undelivered line is not';
  passed := coalesce(v_state is null and v_rel_err is null
                     and v_so_hist_state = 'despatched'
                     and exists (select 1 from jsonb_array_elements(v_released) e
                                  where e ->> 'line_id' = v_so_open_l::text and e ->> 'order_state' = 'confirmed')
                     and not exists (select 1 from jsonb_array_elements(v_released) e
                                      where e ->> 'line_id' = v_so_hist_l::text), false);
  detail := coalesce(v_state, v_rel_err,
                     format('the despatched order %s; listed: %s', coalesce(v_so_hist_state, 'no state'),
                            coalesce((select string_agg(e ->> 'document_number' || ' ' || (e ->> 'order_state'), ', ')
                                        from jsonb_array_elements(v_released) e), 'nothing')));
  return next;

  case_name := 'the stock forecast counts customer demand from the same orders';
  passed := coalesce(v_state is null and v_rel_err is null and v_demand = 3, false);
  detail := coalesce(v_state, v_rel_err, format('demand %s where three are confirmed and four despatched', coalesce(trim_scale(v_demand)::text, 'none')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The demonstration's suppliers, and usage
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a demonstration''s products are given the supplier their demo attributes name, once, and a product with a supplier keeps it';
  passed := coalesce(v_state is null and v_conv_err is null and v_demo_err is null
                     and v_given1 = 2 and v_given2 = 0
                     and v_wid_sup = v_sup and v_nut_sup = v_sup and v_wid_lead = 10
                     and v_bolt_sups = 1, false);
  detail := coalesce(v_state, v_conv_err, v_demo_err,
                     format('given %s then %s; widget from %s in %s day(s), nut from %s; the bolt has %s supplier(s)',
                            v_given1, v_given2, coalesce(v_wid_sup::text, 'nobody'), v_wid_lead,
                            coalesce(v_nut_sup::text, 'nobody'), v_bolt_sups));
  return next;

  case_name := 'the stock forecast names the product''s supplier';
  passed := coalesce(v_state is null and v_demo_err is null and v_fc_sup = v_sup, false);
  detail := coalesce(v_state, v_demo_err, format('supplier %s', coalesce(v_fc_sup::text, 'none')));
  return next;

  case_name := 'a posted delivery is usage on the stock forecast';
  passed := coalesce(v_state is null and v_demo_err is null
                     and v_dn_made ->> 'moved_on' = 'post'
                     and v_usage >= 6 and v_fc_state <> 'no usage', false);
  detail := coalesce(v_state, v_demo_err,
                     format('delivery moved on by %s; usage %s, state %s', coalesce(v_dn_made ->> 'moved_on', 'nothing'),
                            coalesce(trim_scale(v_usage)::text, 'none'), coalesce(v_fc_state, 'none')));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-rfo-' || v_hex);
  detail := 'the organisation, its people, stock, orders, receipts, requisitions and deliveries rolled back';
  return next;
end;
$$;

comment on function erp_test.receive_from_order_suite() is
  'A live organisation with two administrators and two narrow people: a sent '
  'order received whole, linked, posted and moved to received; an order '
  'received in part at a location, refused more than is left and a line of '
  'another order, offered what is left, then received and posted in one call; '
  'an unsent order and a goods receipt refused; the door called signed in with '
  'only procurement.read and procurement.receive, and without receive; a '
  'requisition''s supplier and site defaults and its conversion; the ageing '
  'and trial balance reads; open order lines and forecast demand from orders '
  'that can still be fulfilled; and a demonstration''s product suppliers and '
  'usage on the forecast. Rolls back everything it made.';

create or replace function erp_test.assert_receive_from_order_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 27;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.receive_from_order_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_RECEIVE_FROM_ORDER_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_RECEIVE_FROM_ORDER_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the door: an order cannot be received, a received quantity is not counted, an order does not move on, or a read answers what the desk does not show.';
  end if;
  return format('receipt from order: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.receive_from_order_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_receive_from_order_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Generators, then the checks that read what changed
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

select erp_test.assert_receive_from_order_suite();
select erp_test.assert_procurement_suite();
select erp_test.assert_delivery_from_order_suite();
select erp_test.assert_approval_hold_suite();
select erp_test.assert_onward_transition_suite();
select erp_test.assert_demo_history_suite();
select erp_test.assert_demo_chart_suite();
