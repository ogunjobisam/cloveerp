set lock_timeout = '30s';

-- =============================================================================
-- 20260922360000  An order moves when its goods and its bill do
-- -----------------------------------------------------------------------------
-- PR4, M1: node P2 of docs/spec/simplification-review.md, for every
-- organisation, on the lifecycles they already hold. Nothing here writes
-- tenant data, changes a lifecycle or renames a move; that is M2's.
--
-- A requisition reads Ordered, and a purchase order Partially received,
-- Received and Closed, because something else exists: an order raised from
-- the requisition, goods receipts posted against the order, and the supplier's
-- bill for what arrived. Until now each was also a button, and each button
-- could be pressed over nothing:
--
--   * a requisition marked Ordered with no order anywhere (public
--     erp_transition_document passes the move straight through, and the
--     demonstration seeder did exactly that, every week);
--   * an order Received on a draft receipt: erp.advance_orders_for_receipt()
--     read quantity_fulfilled, which counts receipts that were never posted,
--     so an order for 90 with 60 posted and 30 in draft read Received;
--   * an order Closed with nothing billed, which is how every demonstration
--     order was closed, because nothing closed an order but a person.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
-- Three facts, each one function, read by the move that states it and by the
-- guard that refuses it asserted without it, so the two cannot disagree:
--
--   erp.order_receipt_position()      none, part or full, from POSTED receipts
--                                     (erp.receivable_lines.received_quantity)
--   erp.order_is_settled()            every posted receipt quantity billed on a
--                                     committed bill, and no difference open
--   erp.document_is_fully_converted() every line on an order raised from it,
--                                     which erp.convert_document() now asks too
--
-- erp.advance_orders_for_receipt() is rewritten to read the first. It follows
-- only 'fulfils' relations to purchase orders, where before it followed any
-- relation of any kind. And it moves the order through erp.transition_document()
-- rather than erp.perform_transition(), which was the one document routine
-- erp.state_side_door_report() found entering a lifecycle past its door. The
-- no_state_side_doors gate goes from ten to nine.
--
-- A received order is closed by the bill that settles it. erp.transition_document()
-- asks erp.close_orders_billed_by() after every move of a bill, after the
-- dispute test, so a bill disputed on registration is not counted. Where the
-- bill arrived first, the receipt that completes the order closes it instead.
--
-- ── WHAT A PERSON MAY STILL DO (DECISION 2) ──────────────────────────────────
--
-- Two of these facts never arrive for some orders: the supplier who will send
-- nothing more, and the bill an organisation keeps somewhere else. Refusing
-- the moves outright would strand those orders in every organisation from the
-- day this deploys. So `receive_rest` (a short close) and `close` stay a
-- person's to make, and the guard takes them without the fact only when a
-- reason is given. The reason goes on the transition log with the move. The
-- screen asks for it (EXPLAINED_MOVES, src/components/erp/document-transitions.tsx),
-- and `receive_rest` leaves the door-only list and becomes a 'screen' row in
-- the register.
--
-- `receive_partial`, `receive_all` and a requisition's `order` have no such
-- exception. Each one only ever states that something exists. `order` becomes
-- a routine row, driven by erp.convert_document(), and joins the door-only
-- list.
--
-- ── WHAT CHANGES FOR DOCUMENTS ALREADY IN FLIGHT ─────────────────────────────
--
-- The guards read the document type and the move code, not a version, so they
-- cover every document from the deploy. Nothing is remapped:
--
--   * A partially received order moves on with its next posted receipt.
--   * A received order closes when it is billed, or by hand with a reason.
--   * An approved requisition is ordered by converting it, as the screen
--     already offered.
--
-- ── THE DEMONSTRATION ────────────────────────────────────────────────────────
--
-- erp.seed_demo_history() pressed `order` on every approved requisition. It
-- now converts the requisition into an order to the supplier of its first
-- product, dated the requisition's day, and sends that order as it sends every
-- other. The order reads Sent, which erp_test.demo_history_suite already
-- accepts, and the requisition reads Ordered because an order exists. The
-- seeder still closes three received orders in four by hand, with its reason,
-- because it bills one receipt a week.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The facts
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.order_receipt_position(p_order_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- What the posted receipts say about an order: nothing yet, part of it, or
  -- all of it. Drafts hold a quantity against the line (receive_against's
  -- tolerance reads that) and receive nothing until they post. The lines are
  -- erp.receivable_lines(): the ones a receipt can be raised against, which
  -- leaves out cancelled lines and lines with no item.
  select case
           when count(*) = 0
             or coalesce(sum(rl.received_quantity), 0) <= 0 then 'none'
           when bool_and(rl.received_quantity >= rl.ordered_quantity) then 'full'
           else 'part'
         end
    from erp.receivable_lines(p_order_id) rl
$$;

comment on function erp.order_receipt_position(uuid) is
  'none, part or full: what the POSTED goods receipts against a purchase order '
  'say about it (20260922360000). Read by erp.advance_orders_for_receipt() to '
  'move the order and by erp.transition_document() to refuse the same move '
  'asserted by hand, so the two cannot disagree.';

create or replace function erp.order_is_settled(p_order_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Settled: something arrived, every line's posted quantity is on a
  -- committed bill, and no difference between them is open. A disputed bill
  -- is not committed, so it settles nothing. A match exception is open until
  -- somebody resolves it (resolved_at), which is the test erp.dispute_unmatched_bill()
  -- and the resolve guard already make.
  --
  -- The bill is found by the line it invoices, not by its type code: a bill
  -- shares its base type with a sales invoice, and only one of the two ever
  -- invoices a purchase order's line. quantity_invoiced is not read, because
  -- it counts draft bills and adds credit notes as though they were bills.
  with lines as (
    select rl.line_id, rl.received_quantity,
           coalesce((
             select sum(rel.quantity)
               from erp.document_relation rel
               join erp.document b
                 on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
               join erp.document_type bdt
                 on bdt.tenant_id = b.tenant_id and bdt.id = b.document_type_id
               join erp.object_state bos
                 on bos.tenant_id = b.tenant_id and bos.object_type = 'document'
                and bos.object_id = b.id
               join erp.state bs on bs.id = bos.current_state_id
              where rel.tenant_id = erp.current_tenant_id()
                and rel.to_line_id = rl.line_id
                and rel.relation_kind = 'invoices'
                and bdt.base_type_code = 'invoice_reference'
                and not b.is_cancelled
                and bs.is_committed), 0) as billed_quantity
      from erp.receivable_lines(p_order_id) rl
  )
  select exists (select 1 from lines l where l.received_quantity > 0)
     and not exists (select 1 from lines l where l.billed_quantity < l.received_quantity)
     and not exists (
       select 1
         from erp.match_exception x
         join erp.document_line ol
           on ol.tenant_id = x.tenant_id and ol.id = x.order_line_id
        where x.tenant_id = erp.current_tenant_id()
          and ol.document_id = p_order_id
          and x.resolved_at is null)
$$;

comment on function erp.order_is_settled(uuid) is
  'Whether a purchase order''s goods have all been billed: something arrived, '
  'every posted receipt quantity is on a committed bill, and no match '
  'difference is open (20260922360000). What closes the order, and what a hand '
  'close without a reason is refused for lacking.';

create or replace function erp.document_is_fully_converted(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Every line that is not cancelled is on an order raised from it. The same
  -- test erp.convert_document() makes before it moves the source, asked line
  -- by line rather than as one sum, so no over-converted line can hide one
  -- still outstanding.
  select exists (select 1 from erp.document_line dl
                  where dl.tenant_id = erp.current_tenant_id()
                    and dl.document_id = p_document_id
                    and not dl.is_cancelled)
     and not exists (
       select 1 from erp.document_line dl
        where dl.tenant_id = erp.current_tenant_id()
          and dl.document_id = p_document_id
          and not dl.is_cancelled
          and dl.quantity > coalesce((
                select sum(r.quantity) from erp.document_relation r
                 where r.tenant_id = dl.tenant_id
                   and r.relation_kind = 'converts'
                   and r.to_line_id = dl.id), 0))
$$;

comment on function erp.document_is_fully_converted(uuid) is
  'Whether every line of a requisition or quotation is on an order raised from '
  'it (20260922360000). erp.convert_document() moves the source when this holds; '
  'erp.transition_document() refuses a requisition''s order move when it does not.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The routines that make the moves
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.close_order_when_settled(p_order_id uuid, p_reason text)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  -- Only a received order closes, and only when its bill is in. Anything else
  -- is not this routine's business, and asking twice is harmless.
  if erp.object_current_state('document', p_order_id) is distinct from 'received'
     or not erp.order_is_settled(p_order_id) then
    return false;
  end if;

  -- The bill or the receipt is already committed. If the order cannot close
  -- (a permission, a lifecycle with no such move) that is worth recording,
  -- not worth undoing the bill for. erp.advance_orders_for_receipt() has
  -- always done the same.
  begin
    perform erp.transition_document(p_order_id, 'close', p_reason);
    return true;
  exception when others then
    perform erp.append_event(
      'document.progress_not_advanced', 'document', p_order_id,
      jsonb_build_object('transition', 'close', 'reason', sqlerrm),
      null, null);
    return false;
  end;
end $$;

comment on function erp.close_order_when_settled(uuid, text) is
  'Closes a received purchase order whose goods have all been billed, and '
  'records rather than raises a refusal (20260922360000). Called by the bill '
  '(erp.close_orders_billed_by) and by the receipt that completes an order '
  'billed first (erp.advance_orders_for_receipt).';

create or replace function erp.close_orders_billed_by(p_bill_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_n      integer := 0;
  v_number text;
begin
  select b.document_number into v_number
    from erp.document b where b.tenant_id = v_tenant and b.id = p_bill_id;

  for r in
    select distinct ol.document_id as order_id
      from erp.document_relation rel
      join erp.document_line ol
        on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      join erp.document o
        on o.tenant_id = ol.tenant_id and o.id = ol.document_id
      join erp.document_type odt
        on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_bill_id
       and rel.relation_kind = 'invoices'
       and odt.base_type_code = 'purchase_order'
  loop
    if erp.close_order_when_settled(
         r.order_id, format('Billed in full by %s', coalesce(v_number, 'the supplier''s bill'))) then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end $$;

comment on function erp.close_orders_billed_by(uuid) is
  'The purchase orders a bill invoices, closed where it settles them '
  '(20260922360000). erp.transition_document() calls it after every move of a '
  'bill, after the dispute test, so a bill disputed on registration counts '
  'for nothing.';

create or replace function erp.advance_orders_for_receipt(p_receipt_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  r         record;
  l         record;
  v_state   text;
  v_pos     text;
  v_txn     text;
  v_moved   integer := 0;
begin
  -- The orders this receipt fulfils, by the relation receive_against() writes.
  -- It followed any relation of any kind until 20260922360000.
  for r in
    select distinct rel.to_document_id as order_id
      from erp.document_relation rel
      join erp.document o
        on o.tenant_id = rel.tenant_id and o.id = rel.to_document_id
      join erp.document_type odt
        on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_receipt_id
       and rel.relation_kind = 'fulfils'
       and odt.base_type_code = 'purchase_order'
  loop
    -- quantity_fulfilled is still kept, because receive_against() reads it to
    -- size what is left. The move below does not read it: it counts drafts.
    for l in
      select dl.id from erp.document_line dl
       where dl.tenant_id = v_tenant and dl.document_id = r.order_id
    loop
      perform erp.refresh_order_line_progress(l.id);
    end loop;

    v_state := erp.object_current_state('document', r.order_id);
    v_pos   := erp.order_receipt_position(r.order_id);

    v_txn := case
      when v_state = 'sent' and v_pos = 'full' then 'receive_all'
      when v_state = 'sent' and v_pos = 'part' then 'receive_partial'
      when v_state = 'partially_received' and v_pos = 'full' then 'receive_rest'
    end;

    -- The receipt is already posted. If the order cannot move — a guard, a
    -- permission, an approval — that is worth recording, not worth undoing a
    -- receipt for. Through the document door, so the order's own guards and
    -- effects apply to the move as they do to every other.
    if v_txn is not null then
      begin
        perform erp.transition_document(r.order_id, v_txn, 'Goods received');
        v_moved := v_moved + 1;
      exception when others then
        perform erp.append_event(
          'document.progress_not_advanced', 'document', r.order_id,
          jsonb_build_object('transition', v_txn, 'reason', sqlerrm,
                             'receipt_id', p_receipt_id),
          null, null);
      end;
    end if;

    -- A bill that came in before the goods closes the order the moment they
    -- arrive.
    perform erp.close_order_when_settled(r.order_id, 'Received, and billed already');
  end loop;

  return v_moved;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The door: the guards, and the bill's close
-- ─────────────────────────────────────────────────────────────────────────────

do $door$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old_dec constant text := $o$  v_was_committed boolean;
$o$;
  v_new_dec constant text := $n$  v_was_committed boolean;
  v_fact   boolean;
$n$;
  v_old_guard constant text := $o$  -- A transfer advances on stock moving, not on somebody clicking
$o$;
  v_new_guard constant text := $n$  -- A purchase order is received because goods arrived, and closed because
  -- the bill for them did (20260922360000). erp.advance_orders_for_receipt()
  -- and erp.close_order_when_settled() make these moves when the fact holds,
  -- reading the same two functions; this is what stops the same moves being
  -- asserted over nothing — a Received with no posted receipt behind it, a
  -- Closed with nothing billed.
  --
  -- Two stay a person's to make when the fact will never arrive, with the
  -- reason said: the supplier who will send nothing more (receive_rest, a
  -- short close) and the bill kept somewhere else (close). The reason goes on
  -- the transition log with the move.
  if dt.base_type_code = 'purchase_order'
     and p_transition_code in ('receive_partial', 'receive_all', 'receive_rest', 'close')
  then
    v_fact := case p_transition_code
                when 'receive_partial' then erp.order_receipt_position(p_document_id) = 'part'
                when 'close'           then erp.order_is_settled(p_document_id)
                else                        erp.order_receipt_position(p_document_id) = 'full'
              end;

    if not coalesce(v_fact, false)
       and not (p_transition_code in ('receive_rest', 'close')
                and coalesce(btrim(p_reason), '') <> '')
    then
      if p_transition_code = 'close' then
        raise exception
          'CLOVEERP_ORDER_NOT_SETTLED: % has goods on it that no registered bill covers',
          coalesce(d.document_number, p_document_id::text)
          using errcode = '23514',
                hint = 'Register the supplier''s bill from the goods receipt and the order ' ||
                       'closes itself. If that bill is kept somewhere else, close the order ' ||
                       'with the reason.';
      else
        raise exception
          'CLOVEERP_ORDER_NOT_RECEIVED: % cannot be marked %: its posted receipts do not say so',
          coalesce(d.document_number, p_document_id::text), p_transition_code
          using errcode = '23514',
                hint = 'Post the goods receipt for what arrived and the order moves itself. ' ||
                       'If the supplier will send nothing more, close it short with the reason.';
      end if;
    end if;
  end if;

  -- A requisition is ordered because an order was raised from all of it
  -- (20260922360000). erp.convert_document() raises the order and then makes
  -- this move; pressed with no order behind it, the move said something that
  -- was not so.
  if dt.base_type_code = 'requisition' and p_transition_code = 'order'
     and not erp.document_is_fully_converted(p_document_id)
  then
    raise exception
      'CLOVEERP_REQUISITION_NOT_CONVERTED: % has lines no purchase order was raised for',
      coalesce(d.document_number, p_document_id::text)
      using errcode = '23514',
            hint = 'Convert it into a purchase order. It reads Ordered once every line ' ||
                   'is on an order raised from it.';
  end if;

  -- A transfer advances on stock moving, not on somebody clicking
$n$;
  v_old_hook constant text := $o$  if erp.dispute_unmatched_bill(p_document_id) then
    v_to := 'disputed';
  end if;
$o$;
  v_new_hook constant text := $n$  if erp.dispute_unmatched_bill(p_document_id) then
    v_to := 'disputed';
  end if;

  -- A purchase order is closed by the bill that settles it (20260922360000).
  -- Asked after the dispute above, so a bill disputed as it registers counts
  -- for nothing, and after every move of a bill, because a resolved dispute
  -- or a payment may be what completes it. The routine reads the order's
  -- state afresh and does nothing to an order already closed.
  if dt.base_type_code = 'invoice_reference' then
    perform erp.close_orders_billed_by(p_document_id);
  end if;
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_guard, ''))) / length(v_old_guard);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % guard anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_hook, ''))) / length(v_old_hook);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % dispute anchor found % time(s)', v_sig, v_hits;
  end if;

  execute replace(replace(replace(v_def, v_old_dec, v_new_dec),
                          v_old_guard, v_new_guard),
                  v_old_hook, v_new_hook);
end
$door$;

-- erp.convert_document() moves the source by the same fact the guard reads.

do $convert$
declare
  v_sig constant text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old constant text := $o$  if v_left <= 0 then
$o$;
  v_new constant text := $n$  -- erp.document_is_fully_converted() since 20260922360000: the test the
  -- requisition's own guard makes, so the conversion and the guard agree.
  if erp.document_is_fully_converted(p_document_id) then
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$convert$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The register
--
-- Restated whole, because src/lib/stage-records.test.ts reads the newest
-- migration that defines it and holds DOOR_ONLY_TRANSITIONS to its rows that
-- are not 'screen'. Two rows change:
--
--   requisition.order         screen → routine, erp.convert_document()
--   purchase_order.receive_rest  routine → screen: the receipt still makes it,
--                             and a person may now, with a reason, as a short
--                             close
--
-- purchase_order.close stays 'screen'. A person draws it with a reason, and
-- erp.close_order_when_settled() makes it when the bill arrives. The register
-- has one driver per row and the screen is the one a reader has to know about.
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
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000).
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
      ('quotation',          'accept',                 'screen', ''),
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

comment on function erp.transition_driver_register() is
  'What fires each transition of every document lifecycle this repository '
  'ships: a button the document page draws (screen), a door or mechanism named '
  'by signature (routine), or a written-down allowance with its reason '
  '(undriven). Read by erp.undriven_transition_report(); mirrored in '
  'DOOR_ONLY_TRANSITIONS, which src/lib/stage-records.test.ts holds to it. '
  'Restated at 20260922360000.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The side-door gate takes the credit
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.enforcement_gate
   set tolerated_findings = 9,
       rationale = rationale || ' '
         'Lowered from ten to nine at 20260922360000: erp.advance_orders_for_receipt() '
         'moves the order through erp.transition_document() now, so the one document '
         'routine that entered a lifecycle past its door no longer does, and every '
         'finding left is what the first sentence says it is.'
 where gate = 'no_state_side_doors'
   and tolerated_findings = 10;

do $pinned$
declare
  v_n     integer;
  v_found integer;
begin
  select tolerated_findings into v_n
    from erp_meta.enforcement_gate where gate = 'no_state_side_doors';
  if v_n is distinct from 9 then
    raise exception
      'CLOVEERP_TOLERANCE_UNRECOGNISED: no_state_side_doors tolerates %, not the nine this '
      'migration lowered it to', v_n
      using hint = 'Read erp_meta.enforcement_gate. If the number moved since, re-anchor on what it is now.';
  end if;

  select count(*) into v_found
    from erp.state_side_door_report() s
   where s.reference = 'erp.advance_orders_for_receipt';
  if v_found <> 0 then
    raise exception
      'CLOVEERP_SIDE_DOOR_STILL_OPEN: erp.advance_orders_for_receipt() is still reported as '
      'entering a lifecycle past its door'
      using hint = 'The rewrite above calls erp.transition_document(). Read the report''s finding.';
  end if;
end
$pinned$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. The demonstration converts what it approves
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text;
  v_hits integer;
  v_old_dec constant text := $o$  v_doc      uuid;
$o$;
  v_new_dec constant text := $n$  v_doc      uuid;
  v_conv     uuid;
$n$;
  v_old constant text := $o$      perform erp.transition_document(v_doc, 'order', 'demonstration');
$o$;
  v_new constant text := $n$      -- Ordered because an order was raised from it (20260922360000), not
      -- because the seeder said so, which the database now refuses. To the
      -- supplier its first product is bought from, dated the requisition's
      -- day, and sent the way every other order here is sent.
      v_seq := v_seq + 1;
      v_conv := (erp.convert_document(
                   v_doc,
                   (select p.id
                      from erp.document_line dl
                      join erp.item i
                        on i.tenant_id = dl.tenant_id and i.id = dl.item_id
                      join erp.party p
                        on p.tenant_id = i.tenant_id
                       and p.code = i.attributes -> 'demo' ->> 'supplier'
                     where dl.tenant_id = v_tenant and dl.document_id = v_doc
                     order by dl.line_no
                     limit 1),
                   null, null, null) ->> 'document_id')::uuid;
      update erp.document
         set document_date = v_date,
             their_reference = v_prefix || lpad(v_seq::text, 3, '0')
       where tenant_id = v_tenant and id = v_conv;
      perform erp.transition_document(v_conv, 'submit', 'demonstration');
      perform erp.approve_my_document_tasks(v_conv, 'demonstration');
      perform erp.transition_document(v_conv, 'approve', 'demonstration');
      perform erp.transition_document(v_conv, 'send', 'demonstration');
$n$;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'seed_demo_history';
  if v_def is null then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not defined', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: seed_demo_history declaration anchor found % time(s)', v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: seed_demo_history order anchor found % time(s)', v_hits;
  end if;

  execute replace(replace(v_def, v_old_dec, v_new_dec), v_old, v_new);
end
$seed$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. The suites that pressed these moves by hand
-- ─────────────────────────────────────────────────────────────────────────────

do $procurement$
declare
  v_sig constant text := 'erp_test.procurement_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old_req constant text := $o$  return query select 'a requisition reaches its terminal state',
    erp.transition_document(v_req, 'order') = 'ordered', 'draft to ordered';
$o$;
  v_new_req constant text := $n$  -- By the order raised from it (20260922360000). The bare move is refused.
  -- Converted first and read after, because one SQL expression is free to
  -- read the state before it runs the conversion.
  res := erp.convert_document(v_req, null, v_site);
  return query select 'a requisition reaches its terminal state',
    res ->> 'source_moved_on' = 'order'
    and erp.object_current_state('document', v_req) = 'ordered',
    format('draft to ordered, by the order raised from it (%s)', res ->> 'source_moved_on');
$n$;
  v_old_po constant text := $o$  return query select 'a purchase order runs its full lifecycle',
    erp.transition_document(v_po, 'receive_all') = 'received', 'sent to received';
$o$;
  v_new_po constant text := $n$  -- Received by its goods (20260922360000). The walk from receipt to bill to
  -- closed is erp_test.derived_order_state_suite()'s.
  begin
    perform erp.transition_document(v_po, 'receive_all');
    v_ok := false; v_msg := 'a sent order was marked received with nothing received';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a purchase order is received by its goods, not by a button', v_ok, v_msg;
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old_req, ''))) / length(v_old_req);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % requisition anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_po, ''))) / length(v_old_po);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % order anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old_req, v_new_req), v_old_po, v_new_po);
end
$procurement$;

do $metering$
declare
  v_sig constant text := 'erp_test.metering_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old constant text := $o$  perform erp.transition_document(v_req, 'order');
$o$;
  v_new constant text := $n$  -- Ordered by the order raised from it (20260922360000).
  perform erp.convert_document(v_req, null, v_site);
$n$;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$metering$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. What proves it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.derived_order_state_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_uom uuid; v_sup uuid; v_item uuid;
  v_a uuid; v_al uuid; v_g1 uuid; v_g2 uuid;
  v_b uuid;
  v_c uuid; v_cl uuid; v_gc uuid; v_bill uuid;
  v_d uuid; v_dl uuid; v_gd uuid;
  v_e uuid; v_el uuid; v_ge uuid;
  v_req uuid; v_reql uuid;
  v_ok boolean; v_msg text; v_st text;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzdos', 'Derived Order State Suite', 'admin@zzdos.test', 'Order Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzdos.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (v_tenant, v_entity, 'ZMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    if not exists (select 1 from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site
                     and l.location_type = 'receiving' and l.status = 'active') then
      insert into erp.location (tenant_id, site_id, code, name, location_type, status)
      values (v_tenant, v_site, 'ZRECV', 'Receiving', 'receiving', 'active');
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (v_tenant, 'ZEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZSUP', 'Order Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (v_tenant, 'ZWID', 'Order Suite Widget', v_uom, 100, 'active') returning id into v_item;

    -- 1. Part posted, the rest in draft. The draft is raised first, so the old
    --    routine, reading quantity_fulfilled, saw all ninety and read Received.
    v_a := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_al := erp.add_document_line(v_a, v_item, 90, 1000, 'ninety');
    perform erp.transition_document(v_a, 'submit', null);
    perform erp_test.approve_document(v_a, null);
    perform erp.transition_document(v_a, 'send', null);
    v_g2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g2, v_al, 30, null);
    v_g1 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g1, v_al, 60, null);
    perform erp.transition_document(v_g1, 'post', null);
    return query select 'a posted receipt for part of an order reads partially received, and a draft counts for nothing',
      erp.object_current_state('document', v_a) = 'partially_received'
      and erp.order_receipt_position(v_a) = 'part',
      format('%s, position %s, with 60 posted and 30 in draft',
             erp.object_current_state('document', v_a), erp.order_receipt_position(v_a));

    -- 2. The rest posts, and the order moves with nobody pressing anything.
    perform erp.transition_document(v_g2, 'post', null);
    return query select 'posting the rest reads received, and nobody pressed it',
      erp.object_current_state('document', v_a) = 'received'
      and (select l.transition_code || '/' || l.reason from erp.state_transition_log l
            where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_a
            order by l.id desc limit 1) = 'receive_rest/Goods received',
      erp.object_current_state('document', v_a);

    -- 3. Received, and nothing billed.
    begin
      perform erp.transition_document(v_a, 'close', null);
      v_ok := false; v_msg := 'a received order was closed with nothing billed and no reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_SETTLED:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a received order is not closed by hand with nothing billed and no reason', v_ok, v_msg;

    -- 4. One bill for all ninety, at the agreed price. One bill rather than one
    --    per receipt, because erp.match_three_way() compares what a line has
    --    been billed with everything received, so a bill for the first receipt
    --    alone disputes. That is a matching defect of its own and not this
    --    suite's subject.
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_al, 90, 1000);
    update erp.document set their_reference = 'ZDOS-1', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_st := erp.transition_document(v_bill, 'register', null);
    return query select 'the bill for everything that arrived closes the order, and says it did',
      v_st = 'registered'
      and erp.object_current_state('document', v_a) = 'closed'
      and (select l.reason from erp.state_transition_log l
            where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_a
              and l.transition_code = 'close') like 'Billed in full by %',
      format('bill %s, order %s, %s', v_st, erp.object_current_state('document', v_a),
             (select l.reason from erp.state_transition_log l
               where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_a
                 and l.transition_code = 'close'));

    -- 5. And asking again closes nothing twice and records nothing.
    return query select 'asking again of a closed order does nothing and records nothing',
      not erp.close_order_when_settled(v_a, 'again')
      and erp.close_orders_billed_by(v_bill) = 0
      and not exists (select 1 from erp.event ev
                       where ev.tenant_id = v_tenant and ev.event_type = 'document.progress_not_advanced'
                         and ev.aggregate_id = v_a),
      erp.object_current_state('document', v_a);

    -- 6. Sent, and nothing arrived.
    v_b := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_b, v_item, 5, 1000, 'five');
    perform erp.transition_document(v_b, 'submit', null);
    perform erp_test.approve_document(v_b, null);
    perform erp.transition_document(v_b, 'send', null);
    v_ok := true; v_msg := '';
    begin
      perform erp.transition_document(v_b, 'receive_all', 'it came');
      v_ok := false; v_msg := 'receive_all was accepted with nothing received';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform erp.transition_document(v_b, 'receive_partial', 'some came');
      v_ok := false; v_msg := 'receive_partial was accepted with nothing received';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%';
    end;
    return query select 'an order is not marked received over nothing, whatever reason is given',
      v_ok and erp.object_current_state('document', v_b) = 'sent', v_msg;

    -- 7. A bill that disputes as it registers settles nothing.
    v_c := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_cl := erp.add_document_line(v_c, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_c, 'submit', null);
    perform erp_test.approve_document(v_c, null);
    perform erp.transition_document(v_c, 'send', null);
    v_gc := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_gc, v_cl, 10, null);
    perform erp.transition_document(v_gc, 'post', null);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_cl, 10, 2000);
    update erp.document set their_reference = 'ZDOS-3', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_st := erp.transition_document(v_bill, 'register', null);
    return query select 'a bill that disputes as it registers closes nothing',
      v_st = 'disputed' and erp.object_current_state('document', v_c) = 'received',
      format('bill %s, order %s', v_st, erp.object_current_state('document', v_c));

    -- 8. The supplier will send no more.
    v_d := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_dl := erp.add_document_line(v_d, v_item, 100, 1000, 'a hundred');
    perform erp.transition_document(v_d, 'submit', null);
    perform erp_test.approve_document(v_d, null);
    perform erp.transition_document(v_d, 'send', null);
    v_gd := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_gd, v_dl, 40, null);
    perform erp.transition_document(v_gd, 'post', null);
    begin
      perform erp.transition_document(v_d, 'receive_rest', null);
      v_ok := false; v_msg := 'a short close was taken with no reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%'; v_msg := left(sqlerrm, 90);
    end;
    if v_ok then
      perform erp.transition_document(v_d, 'receive_rest', 'The supplier has discontinued it');
      perform erp.bill_from_receipt(v_gd, 'ZDOS-4', current_date, current_date + 30, true);
      v_msg := format('%s, reason %s', erp.object_current_state('document', v_d),
                      (select l.reason from erp.state_transition_log l
                        where l.tenant_id = v_tenant and l.object_type = 'document'
                          and l.object_id = v_d and l.transition_code = 'receive_rest'));
    end if;
    return query select 'a supplier who will send no more is closed short with the reason kept, and the bill closes it',
      v_ok
      and erp.object_current_state('document', v_d) = 'closed'
      and exists (select 1 from erp.state_transition_log l
                   where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_d
                     and l.transition_code = 'receive_rest'
                     and l.reason = 'The supplier has discontinued it'),
      v_msg;

    -- 9. The bill is kept somewhere else.
    v_e := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_el := erp.add_document_line(v_e, v_item, 5, 1000, 'five');
    perform erp.transition_document(v_e, 'submit', null);
    perform erp_test.approve_document(v_e, null);
    perform erp.transition_document(v_e, 'send', null);
    v_ge := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_ge, v_el, 5, null);
    perform erp.transition_document(v_ge, 'post', null);
    perform erp.transition_document(v_e, 'close', 'Billed on the old system');
    return query select 'an order whose bill is kept elsewhere is closed by hand with the reason kept',
      erp.object_current_state('document', v_e) = 'closed'
      and exists (select 1 from erp.state_transition_log l
                   where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_e
                     and l.transition_code = 'close' and l.reason = 'Billed on the old system'),
      erp.object_current_state('document', v_e);

    -- 10. A requisition is ordered by the order raised from all of it.
    v_req := erp.open_document('requisition', v_sup, v_entity, v_site);
    v_reql := erp.add_document_line(v_req, v_item, 4, 1000, 'four');
    perform erp.transition_document(v_req, 'submit', null);
    perform erp.transition_document(v_req, 'approve', null);
    v_ok := true; v_msg := '';
    begin
      perform erp.transition_document(v_req, 'order', 'ordered by phone');
      v_ok := false; v_msg := 'a requisition was marked ordered with no order raised';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_REQUISITION_NOT_CONVERTED:%'; v_msg := left(sqlerrm, 90);
    end;
    perform erp.convert_document(v_req, null, v_site,
      jsonb_build_array(jsonb_build_object('line_id', v_reql, 'quantity', 2)));
    v_ok := v_ok and erp.object_current_state('document', v_req) = 'approved';
    begin
      perform erp.transition_document(v_req, 'order', 'ordered by phone');
      v_ok := false; v_msg := 'a half-converted requisition was marked ordered';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_REQUISITION_NOT_CONVERTED:%';
    end;
    perform erp.convert_document(v_req, null, v_site);
    return query select 'a requisition is ordered by the order raised from all of it, not by a button',
      v_ok and erp.object_current_state('document', v_req) = 'ordered',
      coalesce(nullif(v_msg, ''), erp.object_current_state('document', v_req));

    -- 11. And the receipt's move goes through the document door.
    return query select 'the receipt moves the order through the document door',
      not exists (select 1 from erp.state_side_door_report() s
                   where s.reference = 'erp.advance_orders_for_receipt'),
      'erp.state_side_door_report() no longer names erp.advance_orders_for_receipt';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzdos');
  detail := 'the organisation, its orders and its bills rolled back';
  return next;
end;
$$;

comment on function erp_test.derived_order_state_suite() is
  'P2 of the simplification plan (20260922360000): an order is received by its '
  'posted goods and closed by its bill, a requisition is ordered by the order '
  'raised from it, and the two moves a person may still make, a short close and '
  'a close without the bill, are taken only with a reason.';

create or replace function erp_test.assert_derived_order_state_suite()
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
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.derived_order_state_suite() s;

  if v_total <> 12 then
    raise exception 'CLOVEERP_DERIVED_ORDER_STATE_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_DERIVED_ORDER_STATE_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An order that reads a state nothing put it in is the defect this suite exists for. Read the case that failed.';
  end if;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. The words the screen asks for the reason in
--
-- EXPLAINED_MOVES in src/components/erp/document-transitions.tsx, which
-- renders them through ui(), and which supabase/ci/screen_strings.sh reads.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). ' || v.why
  from (values
    ('Close short',
     'The button on a partially received purchase order when nothing more is coming.'),
    ('Close this order short',
     'The title of the form that asks why.'),
    ('Nothing more is coming from the supplier. The order reads Received for what arrived, and the bill for that closes it.',
     'What a short close does, said in the form before it is done.'),
    ('Close it short',
     'The button that confirms a short close.'),
    ('Close without the bill',
     'The button on a received purchase order whose bill is kept somewhere else.'),
    ('Close this order without its bill',
     'The title of the form that asks why.'),
    ('An order closes itself when the bill for what arrived is registered. Close it here only when that bill is kept somewhere else.',
     'Why the button is an exception, said in the form before it is pressed.'),
    ('Close it',
     'The button that confirms closing an order without its bill.'),
    ('Kept on the order''s history with the move.',
     'The hint under the reason a short close or a close without the bill asks for.'),
    ('Reason',
     'The field a move that needs explaining asks for its explanation in.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

do $seeded$
declare
  v_missing text;
  v_n integer;
begin
  select count(*), string_agg(quote_literal(v.text), E'\n  ')
    into v_n, v_missing
    from (values
      ('Close short'),
      ('Close this order short'),
      ('Nothing more is coming from the supplier. The order reads Received for what arrived, and the bill for that closes it.'),
      ('Close it short'),
      ('Close without the bill'),
      ('Close this order without its bill'),
      ('An order closes itself when the bill for what arrived is registered. Close it here only when that bill is kept somewhere else.'),
      ('Close it'),
      ('Kept on the order''s history with the move.'),
      ('Reason')
    ) as v(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(v.text) and r.locale = 'en');

  if v_n > 0 then
    raise exception E'CLOVEERP_SCREEN_STRINGS_NOT_SEEDED: % of the ten words this migration adds have no en row:\n  %',
      v_n, v_missing
      using hint = 'erp_ref.ui_key() decides the key. If it has changed, the rows this migration wrote are under the old one.';
  end if;
end
$seeded$;

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
