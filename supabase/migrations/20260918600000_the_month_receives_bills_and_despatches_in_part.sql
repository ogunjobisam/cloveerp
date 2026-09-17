set lock_timeout = '30s';

-- =============================================================================
-- 20260918600000  The month receives, bills and despatches in part
-- -----------------------------------------------------------------------------
-- The Definition of Done's master gate asks for a seeded trading month holding
-- at least one of each of seven transactions. Three were in the month and
-- asserted: the Wednesday transfer (20260918100000), the Tuesday return to a
-- supplier and the Friday credit note to a customer (20260918220000). This
-- adds three more and says why the seventh is not here.
--
-- What the month could not show, each read against the deployed body:
--
--   * A part receipt. erp.seed_demo_history() receives the whole ordered
--     quantity of every line (20260905010000), and a recent order is either
--     received in full or skipped. No purchase order in a seeded month was
--     ever partly received.
--
--   * A price variance. The seeder never bills a supplier at all. It bills
--     customers through erp.invoice_from_delivery(); nothing in it calls
--     erp.invoice_against() or erp.bill_from_receipt(), so goods received not
--     invoiced only ever grew, and the variance 20260918300000 now posts had
--     nothing to post from.
--
--   * A part despatch. It happened only when the bulk store ran short, because
--     the seeder despatches least(ordered, on hand), and nothing asserted it.
--     Those deliveries are linked to their order at document level with no
--     lines, so even when one happened the order line never said what was
--     left.
--
-- ── 1. THREE NAMED DAYS, TWO OF THEM NEW ─────────────────────────────────────
--
-- The same rules as the three before: a named weekday, not a draw, so the
-- month always holds several; nothing here calls random(), so every document
-- the rest of a day builds is the document it built before; every document is
-- dated the day it was built and carries that day's DEMO- reference, which is
-- what keeps a slice idempotent; and everything goes through the functions a
-- person's screen calls. Tuesday, Wednesday and Friday are taken.
--
--   MONDAY — a delivery arrives short. The buyer orders two weeks of the
--   product whose bulk stock covers the fewest weeks of its demand, at its
--   catalogue cost, and the supplier sends half. Received through
--   erp.create_receipt_from_order() naming the line, half the quantity and the
--   bulk store, which is how the desk's "Receive this order" form receives
--   less than is left; posting moves the order to partially received and the
--   other half stays outstanding. Monday, because it is when the week's
--   deliveries come in, and because it shares a day with nothing: the Tuesday
--   return and the Wednesday lorry both size themselves against the bulk store
--   this adds to, and each of them reads it a day or more later.
--
--   THURSDAY — the supplier's bill comes in above the order. The most recent
--   posted receipt nobody has billed yet is billed through
--   erp.invoice_against(), one invoice line per order line, which writes the
--   erp.document_relation from each invoice line to its order line. That
--   relation is the whole point: 20260918300000 clears goods received not
--   invoiced at relation quantity × the order's price and posts the rest to
--   purchase price variance, and an invoice line with no relation clears in
--   full with no variance at all. erp.bill_from_receipt() writes the same
--   relations but always at the order's price, so it cannot carry a
--   difference; the desk's "Invoice against an order" form is the one that
--   takes a price, and this is that form.
--
--   The price. Every line is billed five per cent above the agreed price, and
--   never more than a pound a unit above it — the Definition of Done's own
--   case of ten pounds billed at ten pounds fifty. erp.match_three_way() raises
--   a price_variance exception only when the difference exceeds BOTH the
--   tolerance's absolute amount and its percentage; the default the
--   demonstration installs is a pound and two per cent, so a difference of a
--   pound or less a unit never raises one, whatever the price. An exception
--   would not stop the bill: 'register' has no guard that reads the exception
--   register, and erp.propose_payment_run() is where it holds — the bill
--   registers either way and its payment is held. But an exception also asks
--   the approval chain for a decision, and a demonstration that raised one a
--   week would fill somebody's queue with decisions nobody asked for. So the
--   price is inside tolerance, the variance still posts, and no exception is
--   raised. The bill is linked to its receipt, as erp.bill_from_receipt()
--   links one, so the receipt is not billed twice.
--
--   THURSDAY, too — a customer takes half now. A sales order for a week of
--   the finished good the bulk store holds most of, rounded up to ten, for the
--   customer whose turn it is by the week of the year; approved, and half of
--   it delivered through erp.create_delivery_from_order() naming the line and
--   the quantity, loaded from the bulk store and invoiced. A part delivery
--   leaves the order where it is (20260914064000), confirmed, and the other
--   half is still to deliver. The order is sized against what is on the shelf
--   so the half is a choice and not a shortage.
--
--   Why the two Thursday blocks may share a day: they cannot touch each
--   other's arithmetic. The bill reads goods receipts, their relations and the
--   order lines' prices and invoiced quantities, and writes a purchase invoice,
--   goods received not invoiced, purchase price variance and a payable. It
--   reads no stock balance, moves no stock and changes no item's cost —
--   20260918300000 says in terms that a bill does not revalue the shelf. The
--   despatch reads the bulk store's balances and the customers, and writes a
--   sales order, a delivery, a movement, cost of sales, revenue and a
--   receivable. It reads no receipt and no purchase order line. No amount
--   either posts depends on which of them ran first.
--
-- ── 2. THE SEVENTH, WHICH IS NOT HERE ────────────────────────────────────────
--
-- A stock adjustment needs a mechanism that does not exist, so none is seeded.
-- erp.write_off_stock() (20260906143000) and erp.post_count() (20260906070000)
-- both insert the movement without an occurred_at, so it takes the column's
-- default, clock_timestamp(); erp.post_movement_finance() then posts the
-- journal on occurred_at::date. Neither takes a date, and neither makes a
-- document: erp_ref.document_type has carried an 'adjustment' base type since
-- 0025, but no installer has ever made a tenant document type of it, and no
-- document type binds the scrap or count_adjustment movement types. So a
-- write-off built into a history day would be dated today, fall outside the
-- month it was built for, carry no DEMO- reference, and be written again by a
-- second call on a day that built nothing else. Inventing a dated door or a
-- document type is not something a seeder should do. The demonstration's
-- register has no STOCK_ADJUSTMENT reason codes either — 20260918220000
-- installed the two return categories only — and they are left for the change
-- that brings the mechanism.
--
-- ── 3. PROOF ─────────────────────────────────────────────────────────────────
--
-- erp_test.demo_history_suite() gains five cases, after the credit notes and
-- over the same fifteen days: the month receives part of an order, bills a
-- receipt above the agreed price, keeps goods received not invoiced
-- reconciled, despatches part of an order, and holds all four ties — the
-- trial balance, stock valuation against the inventory control, and both
-- ageings against their control accounts — with every one of them in it.
--
-- Fifteen days is enough, and the number was checked rather than assumed, by
-- enumerating every combination of the first day's eight receipt dates for
-- each of the seven weekdays a month can start on, with each call's p_to
-- capping the dates as the suite's calls do. A Monday needs nothing that could
-- be missing, and a Thursday's delivery needs stock, which the first day
-- receives; seven days hold both for every start. The Thursday bill needs a
-- receipt dated on or before it: when the month starts on a Tuesday the first
-- Thursday is its third day and has one 90% of the time, and the next
-- Thursday is day ten. Ten days make all three certain for every start; the
-- fifteen the credit notes already needed hold them with room to spare.
--
-- What the fifth case found, and what it asserts instead. goods received not
-- invoiced does not come back to nil in a month with a Tuesday return in it,
-- and not because of the bills. erp.raise_supplier_credit_note() prices the
-- credit at the receipt line's price, and its posting (20260918170000) debits
-- goods received not invoiced at the stock's cost and credits it at the
-- credit's value. Under average costing those two agree only while the
-- product has been received at one price; once it has been received twice at
-- two, the return leaves the difference in the account, and erp.grni_report()
-- — which counts receipts and bills, not returns — cannot see it. The
-- Monday receipt at catalogue cost is exactly such a second price. So the case
-- asserts that the difference between the ledger and the open receipts is
-- EXACTLY what the month's supplier credit notes left in the account: a bill
-- that cleared at its own value instead of the receipt's fails it, and so
-- does any other residue. The return's posting is a defect in its own right,
-- reported separately; it is not fixed inside a seeder.
--
-- Collateral, restated with the reason. Case 4 lists the states a document of
-- the first five days may end in, and a purchase order may now end partially
-- received: a Monday in the first five days receives half of one. The count
-- goes from fourteen to nineteen in the suite and in the wrapper.
-- supabase/ci/seed_demo.sql reports the part receipts, the supplier bills and
-- the part deliveries beside the transfers and credit notes. Its document
-- total grows by two a Monday (the order and its receipt) and by up to four a
-- Thursday (the bill, the order, its delivery and its invoice), give or take
-- whatever the extra stock changes in the replenishment and despatches of the
-- days after; 141 was the month's total before.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A Monday short delivery; a Thursday bill and a Thursday half-delivery
-- ═════════════════════════════════════════════════════════════════════════════

do $history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  -- The end of the day, after the Friday credit note. What is built last in a
  -- day is built from what the day left on the shelf and in the ledger.
  v_n    constant text := E'  end loop days;\n';
  v_r    constant text := $r$  -- ── A delivery that arrives short ────────────────────────────────────────
  -- Every Monday the buyer orders two weeks of the product whose bulk stock
  -- covers the fewest weeks of its demand, and the supplier sends half
  -- (20260918600000). Received through erp.create_receipt_from_order() naming
  -- the line, the quantity and the bulk store, as the desk receives less than
  -- is left; posting moves the order to partially received and the rest stays
  -- outstanding on it.
  --
  -- Monday, because it shares a day with nothing: the Tuesday return and the
  -- Wednesday lorry both size themselves against the bulk store this adds to.
  -- Nothing here draws on random(), so the rest of the day is what it was.
  if extract(isodow from v_day) = 1 then
    declare
      v_short_item  uuid;
      v_short_name  text;
      v_short_party uuid;
      v_short_price bigint;
      v_ordered     integer;
      v_short_po    uuid;
      v_short_line  uuid;
      v_short_grn   uuid;
    begin
      select i.id, i.name, p.id,
             (i.attributes -> 'demo' ->> 'cost_minor')::bigint,
             (ceil((i.attributes -> 'demo' ->> 'demand_per_week')::numeric * 2 / 10) * 10)::integer
        into v_short_item, v_short_name, v_short_party, v_short_price, v_ordered
        from erp.item i
        join erp.party p
          on p.tenant_id = i.tenant_id
         and p.code = i.attributes -> 'demo' ->> 'supplier'
         and p.status = 'active'::erp.record_status
       cross join lateral (
         select coalesce(sum(b.quantity), 0) as on_hand
           from erp.stock_balance b
          where b.tenant_id = v_tenant and b.site_id = v_site
            and b.location_id = v_bulk and b.item_id = i.id
            and b.batch_id is null and b.serial_id is null and b.container_id is null
            and b.stock_status = 'available'::erp.stock_status) sb
       where v_bulk is not null
         and i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
         and i.attributes ? 'demo'
         and (i.attributes -> 'demo' ->> 'demand_per_week')::numeric > 0
       order by sb.on_hand / (i.attributes -> 'demo' ->> 'demand_per_week')::numeric, i.code
       limit 1;

      if v_short_item is not null and v_ordered >= 2 then
        v_seq := v_seq + 1;
        v_short_po := erp.create_document('purchase_order', v_entity, v_site, v_short_party, v_day, v_ccy,
                                          v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
        v_short_line := erp.add_document_line(v_short_po, v_short_item, v_ordered, v_short_price,
                                              v_short_name, v_day + 5);
        perform erp.transition_document(v_short_po, 'submit', 'demonstration');
        perform erp.approve_my_document_tasks(v_short_po, 'demonstration');
        perform erp.transition_document(v_short_po, 'approve', 'demonstration');
        perform erp.transition_document(v_short_po, 'send', 'demonstration');
        v_built := v_built + 1;

        -- Half of it, into the bulk store. Opened today, then dated the day it
        -- arrived under that day's reference before it posts, as the invoices
        -- above are dated before they are issued.
        v_short_grn := (erp.create_receipt_from_order(
                          v_short_po,
                          jsonb_build_array(jsonb_build_object(
                            'line_id', v_short_line, 'quantity', v_ordered / 2,
                            'location_id', v_bulk)),
                          null) ->> 'document_id')::uuid;
        v_seq := v_seq + 1;
        update erp.document
           set document_date = v_day,
               their_reference = v_prefix || lpad(v_seq::text, 3, '0')
         where tenant_id = v_tenant and id = v_short_grn;
        perform erp.transition_document(v_short_grn, 'post', 'demonstration');
        v_built := v_built + 1;
      end if;
    end;
  end if;

  -- ── The supplier's bill, above the order ─────────────────────────────────
  -- Every Thursday the bill for the most recent receipt nobody has billed
  -- comes in (20260918600000), five per cent above the agreed price and never
  -- more than a pound a unit above it. Billed line by line through
  -- erp.invoice_against(), which relates each invoice line to its order line:
  -- goods received not invoiced is cleared at what the receipt credited and
  -- the difference posts to purchase price variance. A pound a unit is inside
  -- the tolerance the demonstration installs whatever the price, so no match
  -- exception is raised and nobody is asked to decide one. Linked to the
  -- receipt, as erp.bill_from_receipt() links a bill, so it is not billed
  -- twice.
  --
  -- Thursday, and shared with the half-delivery below, because neither can
  -- move the other's numbers: this reads receipts and order lines and posts to
  -- goods received not invoiced, the variance and the payable; that reads the
  -- bulk store and posts to stock, cost of sales and the receivable. Nothing
  -- here draws on random().
  if extract(isodow from v_day) = 4 then
    declare
      v_billed_receipt uuid;
      v_bill_party     uuid;
      v_bill           uuid;
      v_bill_line      record;
    begin
      select g.id, g.party_id
        into v_billed_receipt, v_bill_party
        from erp.document g
        join erp.document_type gt
          on gt.tenant_id = g.tenant_id and gt.id = g.document_type_id
       where v_bulk is not null
         and g.tenant_id = v_tenant
         and gt.code = 'goods_receipt'
         and g.site_id = v_site
         and g.their_reference like 'DEMO-%'
         and g.document_date <= v_day
         and not g.is_cancelled
         and erp.object_current_state('document', g.id) = 'posted'
         and exists (select 1 from erp.document_relation fr
                      where fr.tenant_id = v_tenant and fr.from_document_id = g.id
                        and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)
         and not exists (select 1 from erp.document_relation fr
                           join erp.document_line ol
                             on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                          where fr.tenant_id = v_tenant and fr.from_document_id = g.id
                            and fr.relation_kind = 'fulfils'
                            and coalesce(ol.quantity_invoiced, 0) > 0)
       order by g.document_date desc, g.document_number desc
       limit 1;

      if v_billed_receipt is not null then
        v_seq := v_seq + 1;
        v_bill := erp.create_document('purchase_invoice', v_entity, v_site, v_bill_party, v_day, v_ccy,
                                      v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
        for v_bill_line in
          select fr.to_line_id as order_line_id,
                 sum(fr.quantity) as quantity,
                 max(ol.unit_price_minor) as agreed_minor
            from erp.document_relation fr
            join erp.document_line ol
              on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
           where fr.tenant_id = v_tenant and fr.from_document_id = v_billed_receipt
             and fr.relation_kind = 'fulfils' and fr.to_line_id is not null
           group by fr.to_line_id
           order by min(ol.line_no)
        loop
          perform erp.invoice_against(
                    v_bill, v_bill_line.order_line_id, v_bill_line.quantity,
                    v_bill_line.agreed_minor
                      + least(100, greatest(1, round(v_bill_line.agreed_minor * 0.05)))::bigint);
        end loop;
        update erp.document
           set due_date = v_day + 30
         where tenant_id = v_tenant and id = v_bill;
        perform erp.link_documents(v_bill, v_billed_receipt, 'invoices');
        perform erp.transition_document(v_bill, 'register', 'demonstration');
        v_built := v_built + 1;
      end if;
    end;

  -- ── Half now, the rest later ─────────────────────────────────────────────
  -- And every Thursday a customer takes half an order (20260918600000): a
  -- week of the finished good the bulk store holds most of, rounded up to ten,
  -- for the customer whose turn it is by the week of the year, approved and
  -- delivered in part through erp.create_delivery_from_order() naming the line
  -- and the quantity, loaded from the bulk store and invoiced. A part delivery
  -- leaves the order confirmed with the other half still to deliver. Only a
  -- product with the whole order on the shelf is chosen, so the half is the
  -- customer's choice and not a shortage.
    declare
      v_customers   integer;
      v_customer    uuid;
      v_half_item   uuid;
      v_half_name   text;
      v_half_price  bigint;
      v_half_order  integer;
      v_half_so     uuid;
      v_half_line   uuid;
      v_half_dn     uuid;
      v_half_dnline uuid;
      v_half_inv    uuid;
    begin
      select i.id, i.name,
             (i.attributes -> 'demo' ->> 'list_minor')::bigint,
             (ceil((i.attributes -> 'demo' ->> 'demand_per_week')::numeric / 10) * 10)::integer
        into v_half_item, v_half_name, v_half_price, v_half_order
        from erp.item i
       cross join lateral (
         select coalesce(sum(b.quantity), 0) as on_hand
           from erp.stock_balance b
          where b.tenant_id = v_tenant and b.site_id = v_site
            and b.location_id = v_bulk and b.item_id = i.id
            and b.batch_id is null and b.serial_id is null and b.container_id is null
            and b.stock_status = 'available'::erp.stock_status) sb
       where v_bulk is not null
         and i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
         and i.item_class = 'finished_good' and i.attributes ? 'demo'
         and (i.attributes -> 'demo' ->> 'demand_per_week')::numeric > 0
         and sb.on_hand >= ceil((i.attributes -> 'demo' ->> 'demand_per_week')::numeric / 10) * 10
       order by sb.on_hand desc, i.code
       limit 1;

      select count(*) into v_customers
        from erp.party p
       where p.tenant_id = v_tenant and p.code like 'C-%' and p.status = 'active'::erp.record_status;
      select p.id into v_customer
        from erp.party p
       where p.tenant_id = v_tenant and p.code like 'C-%' and p.status = 'active'::erp.record_status
       order by p.code
      offset extract(week from v_day)::integer % greatest(v_customers, 1)
       limit 1;

      if v_half_item is not null and v_customer is not null and v_half_order >= 2 then
        v_seq := v_seq + 1;
        v_half_so := erp.create_document('sales_order', v_entity, v_site, v_customer, v_day, v_ccy,
                                         v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
        v_half_line := erp.add_document_line(v_half_so, v_half_item, v_half_order, v_half_price,
                                             v_half_name, v_day + 7);
        perform erp.transition_document(v_half_so, 'submit', 'demonstration');
        perform erp.approve_my_document_tasks(v_half_so, 'demonstration');
        perform erp.transition_document(v_half_so, 'approve', 'demonstration');
        v_built := v_built + 1;

        v_half_dn := (erp.create_delivery_from_order(
                        v_half_so,
                        jsonb_build_array(jsonb_build_object(
                          'line_id', v_half_line, 'quantity', v_half_order / 2)),
                        null) ->> 'document_id')::uuid;
        -- Loaded from the shelf the order was sized against, as the deliveries
        -- above are, and dated the day it left under that day's reference.
        select dl.id into v_half_dnline
          from erp.document_line dl
         where dl.tenant_id = v_tenant and dl.document_id = v_half_dn
         order by dl.line_no
         limit 1;
        perform erp.set_line_stock_identity(v_half_dnline, null, v_bulk, null);
        v_seq := v_seq + 1;
        update erp.document
           set document_date = v_day,
               their_reference = v_prefix || lpad(v_seq::text, 3, '0')
         where tenant_id = v_tenant and id = v_half_dn;
        perform erp.transition_document(v_half_dn, 'post', 'demonstration');
        v_built := v_built + 1;

        -- What went is what is billed; the order stays confirmed.
        v_half_inv := erp.invoice_from_delivery(v_half_dn, true);
        v_seq := v_seq + 1;
        update erp.document
           set document_date = v_day, due_date = v_day + 30,
               their_reference = v_prefix || lpad(v_seq::text, 3, '0')
         where tenant_id = v_tenant and id = v_half_inv;
        perform erp.transition_document(v_half_inv, 'issue', 'demonstration');
        v_built := v_built + 1;
      end if;
    end;
  end if;

  end loop days;
$r$;
  v_hits integer;
  v_secdef boolean;
begin
  if position('erp.create_receipt_from_order(' in v_def) > 0
     or position('erp.invoice_against(' in v_def) > 0
     or position('erp.create_delivery_from_order(' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % already receives, bills or delivers in part; this migration would do it twice', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: expected the day to end once in %, found %', v_sig, v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- What the body already carried is still in it, and all three took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  select p.prosecdef into v_secdef from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure;
  if position('erp.create_receipt_from_order(' in v_def) = 0
     or position('erp.invoice_against(' in v_def) = 0
     or position('erp.create_delivery_from_order(' in v_def) = 0
     or position('0.92 + random()::numeric * 0.16' in v_def) = 0                         -- 20260906050000
     or position('Close only what actually arrived in Received.' in v_def) = 0           -- 20260912190000
     or (length(v_def) - length(replace(v_def, 'erp.approve_my_document_tasks(v_doc, ''demonstration'')', '')))
        / length('erp.approve_my_document_tasks(v_doc, ''demonstration'')') <> 2         -- 20260914062000
     or position('<<days>>' in v_def) = 0                                                -- 20260914072000
     or position('erp.receive_transfer(v_transfer)' in v_def) = 0                        -- 20260918100000
     or position('erp.raise_supplier_credit_note(' in v_def) = 0                         -- 20260918220000
     or position('erp.raise_customer_credit_note(' in v_def) = 0                         -- 20260918220000
     or (length(v_def) - length(replace(v_def, E'  end loop days;\n', ''))) / length(E'  end loop days;\n') <> 1
     or not coalesce(v_secdef, false) then                                               -- 20260914030000
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % dropped a patch it already had, or did not take its part receipt, bill or part delivery', v_sig;
  end if;
end
$history$;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds demonstration trading one day at a time through the spine — purchase '
  'orders and receipts, sales orders, despatches, invoices and cash, quotations, '
  'requisitions, every Monday a delivery that arrives short, every Tuesday a '
  'return to a supplier, every Wednesday a transfer from the main warehouse to '
  'the company''s other site, every Thursday a supplier''s bill above the order '
  'and a customer''s order delivered in part, and every Friday a credit note to '
  'a customer — at most five days per call, starting no new day once a quarter '
  'of the caller''s statement timeout has gone, and says where the next call '
  'should start. A day already built, or inside a five-day slice built before, '
  'is skipped; refused in a live environment; every journal and movement is '
  'raised by the same bridges and doors a person''s document goes through.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite says the month holds all three, and the ties with them
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Five cases, needled on to the deployed body: 20260914062000 put
-- erp_test.approve_document() into it and 20260918220000 the credit notes and
-- the fifteen days, and a re-emission from either file would drop the other,
-- so both are asserted still present afterwards. The cases go where
-- 20260918220000 put its own, after the fifteen days are built and before the
-- sandbox is taken away.

do $cases$
declare
  v_sig  constant text := 'erp_test.demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.demo_history_suite()'::regprocedure);

  -- The last of the declarations, as 20260918220000 left them.
  v_o1 constant text := $o1$  v_back   numeric; v_gone numeric; v_dr bigint; v_cr bigint;
$o1$;
  v_r1 constant text := $q1$  v_back   numeric; v_gone numeric; v_dr bigint; v_cr bigint;
  -- What the month receives, bills and delivers in part (20260918600000)
  v_grni_code text; v_ppv_code text; v_inv_code text; v_cos_code text;
  v_left numeric; v_residue bigint; v_ppv bigint; g record;
$q1$;

  -- The head of the sandbox case, which is where the new ones go.
  v_o2 constant text := $o2$  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
$o2$;
  v_r2 constant text := $q2$  -- ── 8e. The month receives part of an order ────────────────────────────────
  -- The accounts, by what they are for, so the cases read the same on either
  -- chart.
  v_grni_code := erp.tenant_account_code('goods_received_not_invoiced');
  v_ppv_code  := erp.tenant_account_code('purchase_price_variance');
  v_inv_code  := erp.tenant_account_code('inventory');
  v_cos_code  := erp.tenant_account_code('cost_of_sales');

  v_cases := v_cases + 1;
  select count(*), coalesce(sum(x.left_over), 0) into v_n, v_left
    from (select (select coalesce(sum(rl.open_quantity), 0)
                    from erp.receivable_lines(o.id) rl) as left_over
            from erp.document o
            join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
           where o.tenant_id = v_tenant and ot.code = 'purchase_order'
             and erp.object_current_state('document', o.id) = 'partially_received') x;
  return query select 'the month receives part of an order: on a Monday the supplier sends half, the order stays partly received with the rest outstanding, and stock and goods received not invoiced move by what arrived and no more'::text,
    v_n >= 1 and v_left > 0
    and not exists (
      select 1
        from erp.document o
        join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
        join erp.document_relation fr
          on fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
         and fr.relation_kind = 'fulfils' and fr.to_line_id is not null
        join erp.document gr on gr.tenant_id = fr.tenant_id and gr.id = fr.from_document_id
        join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
       where o.tenant_id = v_tenant and ot.code = 'purchase_order'
         and erp.object_current_state('document', o.id) = 'partially_received'
         and (   extract(isodow from gr.document_date) <> 1
              or gr.their_reference not like 'DEMO-' || to_char(gr.document_date, 'YYYYMMDD') || '-%'
              or erp.object_current_state('document', gr.id) <> 'posted'
              or fr.quantity >= ol.quantity
              or (select coalesce(sum(rl.open_quantity), 0) from erp.receivable_lines(o.id) rl
                   where rl.line_id = ol.id) <> ol.quantity - fr.quantity
              or (select coalesce(sum(m.quantity), 0) from erp.stock_movement m
                   where m.tenant_id = gr.tenant_id and m.document_id = gr.id
                     and m.document_line_id = fr.from_line_id and not m.is_reversal) <> fr.quantity
              or (select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = gr.tenant_id and j.document_id = gr.id
                     and j.status = 'posted' and a.code = v_grni_code)
                 <> round(fr.quantity * ol.unit_price_minor)
              or (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = gr.tenant_id and j.document_id = gr.id
                     and j.status = 'posted' and a.code = v_inv_code)
                 <> round(fr.quantity * ol.unit_price_minor))),
    format('%s order(s) partly received, %s unit(s) still to come', v_n, v_left);

  -- ── 8f. The month bills a receipt above the agreed price ───────────────────
  v_cases := v_cases + 1;
  select count(*), coalesce(sum(b.variance), 0)::bigint into v_m, v_ppv
    from (select (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = x.tenant_id and j.document_id = x.id
                     and j.status = 'posted' and a.code = v_ppv_code) as variance
            from erp.document x
            join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
           where x.tenant_id = v_tenant and dt.code = 'purchase_invoice') b;
  return query select 'the month bills a receipt above the agreed price: on a Thursday the supplier''s bill is registered against the order lines it matches, clears goods received not invoiced at what the receipt credited, posts the difference to purchase price variance, and raises no match exception'::text,
    v_m >= 1 and v_ppv > 0
    and not exists (
      select 1 from erp.document x
        join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
       where x.tenant_id = v_tenant and dt.code = 'purchase_invoice'
         and (   extract(isodow from x.document_date) <> 4
              or x.their_reference not like 'DEMO-' || to_char(x.document_date, 'YYYYMMDD') || '-%'
              or erp.object_current_state('document', x.id) <> 'registered'
              or exists (select 1 from erp.document_line il
                          where il.tenant_id = x.tenant_id and il.document_id = x.id
                            and not coalesce(il.is_cancelled, false)
                            and not exists (select 1 from erp.document_relation ir
                                             where ir.tenant_id = il.tenant_id and ir.from_line_id = il.id
                                               and ir.relation_kind = 'invoices' and ir.to_line_id is not null))
              or exists (select 1 from erp.match_exception e
                          where e.tenant_id = x.tenant_id and e.invoice_document_id = x.id)
              or erp.document_price_variance_minor(x.id) <= 0
              or (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = x.tenant_id and j.document_id = x.id
                     and j.status = 'posted' and a.code = v_grni_code)
                 <> erp.document_matched_receipt_minor(x.id)
              or (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = x.tenant_id and j.document_id = x.id
                     and j.status = 'posted' and a.code = v_ppv_code)
                 <> erp.document_price_variance_minor(x.id))),
    format('%s supplier bill(s), %s to purchase price variance on %s', v_m, v_ppv, v_ppv_code);

  -- ── 8g. And goods received not invoiced still reconciles ───────────────────
  -- To exactly what the month's returns to suppliers left in it, which is
  -- nothing until a product received at two prices is sent back. See the
  -- header of 20260918600000: that residue is the return's, not the bill's.
  v_cases := v_cases + 1;
  select r.account_code, r.ledger_minor, r.open_receipts_minor, r.difference_minor
    into g
    from erp.grni_reconciliation() r;
  select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)::bigint into v_residue
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
    join erp.document x on x.tenant_id = j.tenant_id and x.id = j.document_id
    join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
   where j.tenant_id = v_tenant and j.status = 'posted'
     and dt.code = 'purchase_credit_note' and a.code = v_grni_code;
  return query select 'goods received not invoiced reconciles to the receipts still open with the month''s bills in it: they cleared both sides alike, and the only difference is what the returns to suppliers left in the account'::text,
    coalesce(g.account_code = v_grni_code and g.difference_minor = v_residue, false),
    format('%s: ledger %s, open receipts %s, difference %s; the month''s returns to suppliers left %s',
           g.account_code, g.ledger_minor, g.open_receipts_minor, g.difference_minor, v_residue);

  -- ── 8h. The month despatches part of an order ──────────────────────────────
  v_cases := v_cases + 1;
  select count(*), coalesce(sum(x.left_over), 0) into v_n, v_left
    from (select (select coalesce(sum(dl.open_quantity), 0)
                    from erp.deliverable_lines(o.id) dl) as left_over
            from erp.document o
            join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
           where o.tenant_id = v_tenant and ot.code = 'sales_order'
             and erp.object_current_state('document', o.id) = 'confirmed'
             and exists (select 1 from erp.document_relation fr
                          where fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
                            and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)) x;
  return query select 'the month despatches part of an order: on a Thursday half of it leaves, the order stays confirmed with the rest to deliver, stock and cost of sales move by what left and no more, and what left is what is billed'::text,
    v_n >= 1 and v_left > 0
    and not exists (
      select 1
        from erp.document o
        join erp.document_type ot on ot.tenant_id = o.tenant_id and ot.id = o.document_type_id
        join erp.document_relation fr
          on fr.tenant_id = o.tenant_id and fr.to_document_id = o.id
         and fr.relation_kind = 'fulfils' and fr.to_line_id is not null
        join erp.document dn on dn.tenant_id = fr.tenant_id and dn.id = fr.from_document_id
        join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
       where o.tenant_id = v_tenant and ot.code = 'sales_order'
         and erp.object_current_state('document', o.id) = 'confirmed'
         and (   extract(isodow from dn.document_date) <> 4
              or dn.their_reference not like 'DEMO-' || to_char(dn.document_date, 'YYYYMMDD') || '-%'
              or erp.object_current_state('document', dn.id) <> 'posted'
              or fr.quantity >= ol.quantity
              or coalesce(ol.quantity_fulfilled, 0) <> fr.quantity
              or (select coalesce(sum(dl.open_quantity), 0) from erp.deliverable_lines(o.id) dl
                   where dl.line_id = ol.id) <> ol.quantity - fr.quantity
              or (select coalesce(sum(m.quantity), 0) from erp.stock_movement m
                   where m.tenant_id = dn.tenant_id and m.document_id = dn.id
                     and m.document_line_id = fr.from_line_id and not m.is_reversal) <> fr.quantity
              or (select coalesce(sum(m.cost_minor), 0) from erp.stock_movement m
                   where m.tenant_id = dn.tenant_id and m.document_id = dn.id
                     and not m.is_reversal) <= 0
              or (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = dn.tenant_id and j.document_id = dn.id
                     and j.status = 'posted' and a.code = v_cos_code)
                 <> (select coalesce(sum(m.cost_minor), 0) from erp.stock_movement m
                      where m.tenant_id = dn.tenant_id and m.document_id = dn.id
                        and not m.is_reversal)
              or (select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)
                    from erp.journal j
                    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                   where j.tenant_id = dn.tenant_id and j.document_id = dn.id
                     and j.status = 'posted' and a.code = v_inv_code)
                 <> (select coalesce(sum(m.cost_minor), 0) from erp.stock_movement m
                      where m.tenant_id = dn.tenant_id and m.document_id = dn.id
                        and not m.is_reversal)
              or (select coalesce(sum(ir.quantity), 0)
                    from erp.document_relation ir
                    join erp.document iv on iv.tenant_id = ir.tenant_id and iv.id = ir.from_document_id
                   where ir.tenant_id = dn.tenant_id and ir.to_document_id = dn.id
                     and ir.relation_kind = 'invoices' and ir.to_line_id is not null
                     and erp.object_current_state('document', iv.id) in ('issued', 'paid')) <> fr.quantity)),
    format('%s order(s) delivered in part, %s unit(s) still to deliver', v_n, v_left);

  -- ── 8i. And the four ties hold with the whole month in the books ───────────
  v_cases := v_cases + 1;
  begin
    v_msg := erp.assert_trial_balance_balances() || '; ' || erp.assert_inventory_reconciles()
             || '; ' || erp.assert_subledger_reconciles() || '; ' || erp.assert_ageing_equals_control()
             || '; ' || erp.assert_stock_reconciles();
    v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 300);
  end;
  return query select 'the four ties hold with the month''s part receipts, bills, part deliveries, credit notes and transfers in it: the trial balance balances, stock valuation equals the inventory control, and both ageings equal their control accounts'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
$q2$;

  -- A purchase order of the first five days may now end partly received.
  v_o3 constant text := $o3$(dt.code = 'purchase_order' and erp.object_current_state('document', x.id) not in ('sent', 'received', 'closed'))$o3$;
  v_r3 constant text := $q3$(dt.code = 'purchase_order' and erp.object_current_state('document', x.id) not in ('sent', 'partially_received', 'received', 'closed'))$q3$;

  -- The count, pinned in the suite as well as in the wrapper.
  v_o4 constant text := $o4$  if v_cases <> 14 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 14', v_cases
$o4$;
  v_r4 constant text := $q4$  if v_cases <> 19 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 19', v_cases
$q4$;
  v_hits integer;
begin
  if position('purchase_invoice' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % already reads the month''s supplier bills', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_o1, ''))) / length(v_o1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % declares what the month gave back % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o2, ''))) / length(v_o2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % takes the sandbox away % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o3, ''))) / length(v_o3);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % lists the states of a purchase order % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o4, ''))) / length(v_o4);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % pins its count % time(s), not once', v_sig, v_hits;
  end if;

  v_def := replace(v_def, v_o1, v_r1);
  v_def := replace(v_def, v_o2, v_r2);
  v_def := replace(v_def, v_o3, v_r3);
  v_def := replace(v_def, v_o4, v_r4);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp_test.approve_document(v_po, ''suite'')' in v_def) = 0   -- 20260914062000
     or position('purchase_credit_note' in v_def) = 0                      -- 20260918220000
     or position('perform erp.seed_demo_history(v_slice + 10, v_slice + 14, 1);' in v_def) = 0
     or position('purchase_invoice' in v_def) = 0
     or position('erp.assert_ageing_equals_control()' in v_def) = 0
     or position('''partially_received'', ''received''' in v_def) = 0
     or position('v_cases <> 19' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % dropped a patch it already had, or did not take its cases', v_sig;
  end if;
end
$cases$;

-- The wrapper, needled too: 20260906050000 rewrote every suite wrapper to count
-- a null verdict as a failure, and erp.assert_suite_verdicts_strict() refuses a
-- wrapper that has lost that. All this moves is the other end of the count.
do $wrapper$
declare
  v_sig  constant text := 'erp_test.assert_demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.assert_demo_history_suite()'::regprocedure);
  v_o constant text := $o$  if v_all <> 14 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % case(s), expected 14', v_all
$o$;
  v_r constant text := $q$  if v_all <> 19 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % case(s), expected 19', v_all
$q$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_o, ''))) / length(v_o);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % pins its count % time(s), not once', v_sig, v_hits;
  end if;

  execute replace(v_def, v_o, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('not coalesce(passed, false)' in v_def) = 0                     -- 20260906050000
     or position('v_all <> 19' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % lost its null-verdict count, or did not take its pin', v_sig;
  end if;
end
$wrapper$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_demo_history_suite();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
