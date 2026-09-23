set lock_timeout = '30s';

-- =============================================================================
-- 20260923400000  A quotation becomes the order it was for
-- -----------------------------------------------------------------------------
-- PR5, M1: node S1 of docs/spec/simplification-review.md.
--
-- The spec says no transformation from a quotation to a sales order exists.
-- It does: erp.convert_document() has raised a sales order from a sent or
-- accepted quotation since the document spine, carrying the customer, the
-- site, the currency and every outstanding line at the quoted price, and
-- moving the quotation to Accepted as a consequence of the conversion when
-- the person converting may make that move. What a prospect saw instead was:
--
--   * a demonstration whose accepted quotations had no order: the seeder
--     accepted them with the bare move and never converted one;
--   * a document page that offered the bare Accept on a sent quotation and no
--     way to convert it, so the one press there left an accepted quotation
--     with no order and nothing on the screen to raise one;
--   * a discount on a quoted line that did not reach the order.
--
-- This migration carries the discount, lets a quotation every line of which
-- is already on an order be accepted by converting it again, and makes the
-- demonstration's accepted quotations the ones its sales orders were raised
-- from. The screens are in the same pull request.
-- erp_test.quotation_transform_suite is the node's proof.
--
-- Unchanged on purpose: a seller converting at a site they may not accept at
-- does not accept the quotation on the owner's behalf
-- (erp_test.derived_authority_suite, case 4). Acceptance by conversion is the
-- person's, not the system's.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The discount on a converted line
--
-- Only a line that carries one: a line with none keeps what
-- erp.add_document_line() wrote, so an order converted from a requisition
-- reads exactly as it did and the approval it carries still recognises it.
-- ─────────────────────────────────────────────────────────────────────────────

do $discount$
declare
  v_sig constant text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$     order by dl.line_no desc
     limit 1;

    insert into erp.document_relation (
$o$;
  v_new constant text := $n$     order by dl.line_no desc
     limit 1;

    -- The quoted discount goes with the line (20260923400000).
    if coalesce(l.discount_pct, 0) <> 0 then
      update erp.document_line
         set discount_pct = l.discount_pct,
             net_minor = round(v_qty * coalesce(l.unit_price_minor, 0)
                               * (1 - l.discount_pct / 100.0))::bigint,
             updated_at = now()
       where tenant_id = v_tenant and id = v_newline;
    end if;

    insert into erp.document_relation (
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % line anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$discount$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. A quotation already on an order, accepted by converting it again
--
-- A seller who may raise the order but may not accept at the quotation's site
-- converts it, and it stays Sent (erp_test.derived_authority_suite, case 4).
-- Every line is on the order, so converting it again raised nothing and
-- refused with CLOVEERP_NOTHING_OUTSTANDING, and with the bare Accept left to
-- the conversion on the document page nobody could record the acceptance.
-- Now converting it again raises no order and makes the move the first
-- conversion would have made, for whoever may make it — the person's move,
-- as it was the first time, not the system's. Found on review.
-- ─────────────────────────────────────────────────────────────────────────────

do $again$
declare
  v_sig constant text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- A requisition every line of which is already on an order, still reading
$o$;
  v_new constant text := $n$  -- A quotation every line of which is already on an order, still reading
  -- Sent because the person who converted it could not accept it there
  -- (20260923400000): converting it again raises no order and accepts it,
  -- for a person who may.
  if v_base = 'quotation' and v_state = 'sent' and erp.document_is_fully_converted(p_document_id) then
    select at.transition_code into v_source
      from erp.available_transitions('document', p_document_id,
             erp.document_transition_context(p_document_id, null)) at
     where at.guard_passes and at.permitted and at.to_state = 'accepted'
     limit 1;

    if v_source is not null then
      perform erp.transition_document(p_document_id, v_source, 'Converted into an order');
      return jsonb_build_object(
        'document_id', null,
        'document_number', null,
        'source_document_number', d.document_number,
        'lines', 0,
        'outstanding_on_source', 0,
        'source_moved_on', v_source,
        'moved_on', null,
        'born_approved', false,
        'approval_carried_from', null,
        'approval_not_carried', null);
    end if;
  end if;

  -- A requisition every line of which is already on an order, still reading
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % again anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$again$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The demonstration's orders come from its quotations
--
-- The seeder accepted about half its quotations with the bare move and never
-- raised an order from one, so the demonstration showed accepted quotations
-- with nothing after them. Now one sales order in four, the first of every
-- run among them, is raised from a quotation: the lines are quoted to the
-- customer, the quotation is sent, and the order is converted from it, dated
-- the day and under the reference it always had. From there it is walked as
-- every other order is, through approval, despatch, invoice and cash, and
-- the quotation reads Accepted because its order was raised from it. The
-- quotations raised on their own are the ones nobody ordered from: the share
-- the bare move used to accept lapses instead, once it is a month old. No
-- random draw is added or removed, so every other document is the one the
-- seeder built before.
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$    v_seq := v_seq + 1;
    v_doc := erp.create_document('sales_order', v_entity, v_site, v_party, v_date, v_ccy,
                                 v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    v_lines := 1 + floor(random()::numeric * 3)::integer;
$o$;
  b1 constant text := $n$    v_seq := v_seq + 1;
    -- One order in four, the first among them, is quoted first
    -- (20260923400000): its lines go on the quotation, and the order is
    -- converted from it below.
    if v_i % 4 = 1 then
      v_conv := erp.create_document('quotation', v_entity, v_site, v_party, v_date, v_ccy,
                                    v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
      v_doc := v_conv;
    else
      v_conv := null;
      v_doc := erp.create_document('sales_order', v_entity, v_site, v_party, v_date, v_ccy,
                                   v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    end if;
    v_lines := 1 + floor(random()::numeric * 3)::integer;
$n$;
  a2 constant text := $o$    end loop;
    v_built := v_built + 1;

    v_roll := random()::numeric;
    if v_roll < 0.03 then
$o$;
  b2 constant text := $n$    end loop;
    if v_conv is not null then
      -- Sent, and ordered: the conversion reads it Accepted.
      perform erp.transition_document(v_conv, 'send', 'demonstration');
      v_doc := (erp.convert_document(v_conv, null, null, null, null) ->> 'document_id')::uuid;
      v_seq := v_seq + 1;
      update erp.document
         set document_date = v_date,
             their_reference = v_prefix || lpad(v_seq::text, 3, '0')
       where tenant_id = v_tenant and id = v_doc;
      v_built := v_built + 1;
    end if;
    v_built := v_built + 1;

    v_roll := random()::numeric;
    if v_roll < 0.03 then
$n$;
  a3 constant text := $o$    if v_roll < 0.45 and v_date < current_date - 7 then
      perform erp.transition_document(v_doc, 'accept', 'demonstration');
$o$;
  b3 constant text := $n$    if v_roll < 0.45 and v_date < current_date - 7 then
      -- Accepted quotations are the ones the orders above were raised from
      -- (20260923400000). This one nobody ordered from, so it lapses.
      if v_date < current_date - 30 then
        perform erp.transition_document(v_doc, 'expire', 'demonstration');
      end if;
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3);
end
$seed$;

-- The slice the demonstration history suite builds says so: an accepted
-- demonstration quotation has an order raised from it. Case 4 gains the
-- condition, so the suite keeps its twenty cases.
do $history$
declare
  v_sig constant text := 'erp_test.demo_history_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    and not exists (select 1 from erp.document x where x.tenant_id = v_tenant
                     and x.their_reference like 'DEMO-%' and x.document_date > v_slice + 4 + 60),
$o$;
  v_new constant text := $n$    -- An accepted quotation is one an order was raised from, and the slice
    -- has one: its first order is quoted first (20260923400000).
    and exists (select 1 from erp.document x
                  join erp.document_type dt on dt.id = x.document_type_id
                  join erp.document_relation r
                    on r.tenant_id = x.tenant_id and r.to_document_id = x.id and r.relation_kind = 'converts'
                 where x.tenant_id = v_tenant and dt.code = 'quotation' and x.their_reference like 'DEMO-%'
                   and erp.object_current_state('document', x.id) = 'accepted')
    and not exists (select 1 from erp.document x
                      join erp.document_type dt on dt.id = x.document_type_id
                     where x.tenant_id = v_tenant and dt.code = 'quotation'
                       and x.their_reference like 'DEMO-%'
                       and erp.object_current_state('document', x.id) = 'accepted'
                       and not exists (select 1 from erp.document_relation r
                                        where r.tenant_id = x.tenant_id and r.to_document_id = x.id
                                          and r.relation_kind = 'converts'))
    and not exists (select 1 from erp.document x where x.tenant_id = v_tenant
                     and x.their_reference like 'DEMO-%' and x.document_date > v_slice + 4 + 60),
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % slice anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$history$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The quotation A2 unsticks, where it sticks
--
-- erp_test.derived_authority_suite's case 4 leaves a quotation Sent with every
-- line on the order a seller from another site raised. The suite gains a case
-- at its end: somebody who may accept converts it again, it reads Accepted,
-- and no second order is raised. Twenty cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $unstick$
declare
  v_sig constant text := 'erp_test.derived_authority_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    raise exception 'CLOVEERP_SUITE_UNDO';
$o$;
  v_new constant text := $n$    -- Case 4's quotation, converted again by somebody who may accept it,
    -- reads Accepted, and nothing more is ordered (20260923400000). Last,
    -- because case 7 reads the same quotation still Sent.
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    begin
      r := public.erp_convert_document(v_q, null, null, null, null);
      v_msg := null;
    exception when others then v_msg := left(sqlerrm, 160); end;
    return query select 'the same quotation converted again by somebody who may accept it reads accepted, and raises no second order',
      v_msg is null and r ->> 'document_id' is null and r ->> 'source_moved_on' = 'accept'
      and erp.object_current_state('document', v_q) = 'accepted'
      and (select count(distinct rel.from_document_id) from erp.document_relation rel
            where rel.tenant_id = v_tenant and rel.to_document_id = v_q
              and rel.relation_kind = 'converts') = 1,
      coalesce(v_msg, format('%s; quotation %s', r - 'document_number', erp.object_current_state('document', v_q)));

    raise exception 'CLOVEERP_SUITE_UNDO';
$n$;
  a2 constant text := $o$  if v_total <> 19 then
    raise exception 'CLOVEERP_DERIVED_AUTHORITY_SUITE_SHRANK: % case(s), expected 19', v_total$o$;
  b2 constant text := $n$  if v_total <> 20 then
    raise exception 'CLOVEERP_DERIVED_AUTHORITY_SUITE_SHRANK: % case(s), expected 20', v_total$n$;
  v_wsig constant text := 'erp_test.assert_derived_authority_suite()';
  v_wdef text := pg_get_functiondef(v_wsig::regprocedure);
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % end anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
  v_hits := (length(v_wdef) - length(replace(v_wdef, a2, ''))) / length(a2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor found % time(s)', v_wsig, v_hits;
  end if;
  execute replace(v_wdef, a2, b2);
end
$unstick$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The register says who accepts a quotation
--
-- No screen offers the bare Accept any more: the document page and the strip
-- leave it to the conversion, which reads the quotation Accepted because an
-- order was raised from it. Restated whole, from 20260922380000, with that
-- one row changed, so the register the screens are checked against
-- (src/lib/stage-records.test.ts) is the one the database holds.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'screen', ''),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The proof: erp_test.quotation_transform_suite
--
-- A non-live organisation with the demonstration's configuration, undone at
-- the end. The quotation's customer, site, currency and every line carry
-- over; the quotation reads Accepted because the order was raised from it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.quotation_transform_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   uuid := gen_random_uuid();
  v_demo   jsonb;
  v_entity uuid; v_site uuid; v_uom uuid; v_cust uuid; v_i1 uuid; v_i2 uuid;
  v_q uuid; v_ql1 uuid; v_ql2 uuid; v_so uuid; res jsonb; res2 jsonb;
  v_q2 uuid; v_q2l1 uuid; v_q3 uuid; v_q4 uuid;
  v_n integer; v_m integer; v_x text; v_x2 text; v_st text; v_st2 text;
  q record; o record;
begin
  begin
    select p.tenant_id, p.admin_user_id, p.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzquot', 'Quotation Transform Suite', 'admin@zzquot.test', 'Quote Admin') p;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzquot.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    v_demo := erp.ensure_demo_configuration(v_tenant, v_admin);
    v_entity := (v_demo ->> 'entity_id')::uuid;
    v_site := (v_demo ->> 'site_id')::uuid;

    select u.id into v_uom from erp.uom u
     where u.tenant_id = v_tenant and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZQCUS', 'Quotation Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_cust, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZQONE', 'Quotation Suite Widget', v_uom, 'active') returning id into v_i1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZQTWO', 'Quotation Suite Gadget', v_uom, 'active') returning id into v_i2;

    -- A sent quotation of two lines, the second at ten per cent off, to the
    -- customer's own reference.
    v_q := erp.open_document('quotation', v_cust, v_entity, v_site, 'THEIR-PO-7', current_date + 21, 'GBP');
    v_ql1 := erp.add_document_line(v_q, v_i1, 7, 39500, 'Seven widgets', current_date + 21);
    v_ql2 := erp.add_document_line(v_q, v_i2, 3, 12000, 'Three gadgets', current_date + 21);
    update erp.document_line
       set discount_pct = 10, net_minor = round(3 * 12000 * 0.90)::bigint
     where tenant_id = v_tenant and id = v_ql2;
    perform erp.transition_document(v_q, 'send', null);
    res := erp.convert_document(v_q, null, null, null, null);
    v_so := (res ->> 'document_id')::uuid;
    select * into q from erp.document where tenant_id = v_tenant and id = v_q;
    select * into o from erp.document where tenant_id = v_tenant and id = v_so;

    -- 1. The header.
    return query select 'the order goes to the quotation''s customer, at its site, in its currency, under the customer''s reference',
      o.party_id = v_cust and o.site_id is not distinct from q.site_id and o.currency = q.currency
      and o.their_reference is not distinct from q.their_reference
      and (select dt.base_type_code from erp.document_type dt where dt.id = o.document_type_id) = 'sales_order',
      format('party %s, site %s, currency %s, reference %s', o.party_id = v_cust,
             o.site_id is not distinct from q.site_id, o.currency, o.their_reference);

    -- 2. Every line, at the quoted price, each linked to the line it came from.
    select count(*) into v_n
      from erp.document_line ql
      join erp.document_relation r
        on r.tenant_id = ql.tenant_id and r.to_line_id = ql.id and r.relation_kind = 'converts'
      join erp.document_line ol
        on ol.tenant_id = r.tenant_id and ol.id = r.from_line_id and ol.document_id = v_so
     where ql.tenant_id = v_tenant and ql.document_id = v_q
       and ol.item_id = ql.item_id and ol.quantity = ql.quantity and r.quantity = ql.quantity
       and ol.unit_price_minor = ql.unit_price_minor and ol.description = ql.description;
    select count(*) into v_m from erp.document_line ol where ol.tenant_id = v_tenant and ol.document_id = v_so;
    return query select 'every line carries over: its product, quantity, quoted price and words, linked to the line it came from',
      v_n = 2 and v_m = 2 and (res ->> 'lines')::integer = 2,
      format('%s of 2 lines matched, %s on the order', v_n, v_m);

    -- 3. The discount, and the net it makes.
    select count(*) into v_n
      from erp.document_line ol
      join erp.document_relation r
        on r.tenant_id = ol.tenant_id and r.from_line_id = ol.id and r.relation_kind = 'converts'
      join erp.document_line ql on ql.tenant_id = r.tenant_id and ql.id = r.to_line_id
     where ol.tenant_id = v_tenant and ol.document_id = v_so
       and coalesce(ol.discount_pct, 0) = coalesce(ql.discount_pct, 0)
       and ol.net_minor = ql.net_minor;
    return query select 'a quoted discount carries over, and each line nets what it netted on the quotation',
      v_n = 2
      and exists (select 1 from erp.document_line ol where ol.tenant_id = v_tenant and ol.document_id = v_so
                     and ol.item_id = v_i2 and ol.discount_pct = 10 and ol.net_minor = 32400),
      format('%s of 2 lines net alike', v_n);

    -- 4. The quotation reads Accepted, because the order was raised from it.
    v_st := erp.object_current_state('document', v_q);
    return query select 'the quotation reads accepted, moved by the conversion that raised its order',
      v_st = 'accepted' and res ->> 'source_moved_on' = 'accept'
      and (res ->> 'outstanding_on_source')::numeric = 0
      and exists (select 1 from erp.state_transition_log l
                   where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_q
                     and l.transition_code = 'accept' and l.reason = 'Converted into an order'),
      format('quotation %s, moved on %s, outstanding %s', v_st, res ->> 'source_moved_on',
             res ->> 'outstanding_on_source');

    -- 5. Nothing is left to convert a second time.
    begin
      perform erp.convert_document(v_q, null, null, null, null);
      v_x := 'converted again';
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'a quotation every line of which is on an order raises no second order',
      v_x like 'CLOVEERP_NOTHING_OUTSTANDING:%', v_x;

    -- 6. Part of it: the quotation stays with the customer until the rest is
    --    ordered, and then reads Accepted.
    v_q2 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    v_q2l1 := erp.add_document_line(v_q2, v_i1, 10, 1000, 'Ten widgets', null);
    perform erp.add_document_line(v_q2, v_i2, 4, 2000, 'Four gadgets', null);
    perform erp.transition_document(v_q2, 'send', null);
    res2 := erp.convert_document(v_q2, null, null,
              jsonb_build_array(jsonb_build_object('line_id', v_q2l1, 'quantity', 6)), null);
    v_st := erp.object_current_state('document', v_q2);
    perform erp.convert_document(v_q2, null, null, null, null);
    v_st2 := erp.object_current_state('document', v_q2);
    select count(*) into v_n from erp.document_relation r
     where r.tenant_id = v_tenant and r.to_document_id = v_q2 and r.relation_kind = 'converts';
    return query select 'a quotation ordered in part stays sent with the rest outstanding, and reads accepted once the rest is ordered',
      v_st = 'sent' and (res2 ->> 'outstanding_on_source')::numeric = 8 and v_st2 = 'accepted' and v_n = 3,
      format('after part: %s with %s outstanding; after the rest: %s; %s relation(s)', v_st,
             res2 ->> 'outstanding_on_source', v_st2, v_n);

    -- 7. A draft has not been offered to anybody, so it orders nothing.
    v_q3 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    perform erp.add_document_line(v_q3, v_i1, 1, 1000, 'One widget', null);
    begin
      perform erp.convert_document(v_q3, null, null, null, null);
      v_x := 'converted';
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'a quotation still being written does not convert',
      v_x like 'CLOVEERP_NOT_ACCEPTED_YET:%', v_x;

    -- 8. Accepted with the bare move and never ordered, as the demonstration
    --    left them before this: it still converts, and stays accepted.
    v_q4 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    perform erp.add_document_line(v_q4, v_i2, 2, 5000, 'Two gadgets', null);
    perform erp.transition_document(v_q4, 'send', null);
    perform erp.transition_document(v_q4, 'accept', null);
    begin
      res2 := erp.convert_document(v_q4, null, null, null, 'auto');
      v_x := null;
    exception when others then v_x := left(sqlerrm, 120); end;
    v_st := erp.object_current_state('document', v_q4);
    v_st2 := erp.object_current_state('document', (res2 ->> 'document_id')::uuid);
    return query select 'an accepted quotation with no order still converts, and with move-on its order goes forward',
      v_x is null and v_st = 'accepted' and res2 ->> 'source_moved_on' is null
      and res2 ->> 'moved_on' = 'submit' and v_st2 in ('pending_approval', 'confirmed'),
      coalesce(v_x, format('quotation %s; order moved on %s to %s', v_st, res2 ->> 'moved_on', v_st2));

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzquot')
            and not exists (select 1 from auth.users u where u.id = v_auth);
  detail := 'the organisation, its configuration and its documents rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_quotation_transform_suite()
returns void
language plpgsql
security definer
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
    from erp_test.quotation_transform_suite() s;
  if v_total <> 9 then
    raise exception 'CLOVEERP_QUOTATION_TRANSFORM_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_QUOTATION_TRANSFORM_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A quotation that does not become the order it was for is the first thing a prospect sees. Read the case that failed.';
  end if;
end;
$$;


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
