set lock_timeout = '30s';

-- =============================================================================
-- 20261009030000  The testers' records are cleared from the demonstration
-- -----------------------------------------------------------------------------
-- The owner's decision 7 of 4 October. Five testers and a retest walked the
-- live demonstration (demo-cbb10384) on 4 October and left their records in
-- it, marked JT- (the journey test) and RT- (the retest): orders waiting for
-- approval, approved and sent, orders received in part, requisitions,
-- receipts, a supplier's bill, quotations, sales orders and their despatches,
-- transfers, two payment runs still proposed, and the master records they
-- made (products JT-E-P1 and JT-E-P2, partners JT-E-CUS and JT-E-SUP, cost
-- centres JT-E-CC and JT-E-CC2). They sit in every worklist the next visitor
-- sees. The owner decided they are cleared by one migration, demonstrations
-- only, through the product's own moves: drafts and open documents ended,
-- posted records reversed where the product has a way back and the month's
-- checks hold, master records retired, history before 4 October untouched.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.clear_tester_records(p_from, p_runs_to): in a demonstration only,
--      as whoever it runs as, it finds the testers' documents again by the
--      rules the records were counted with (a JT-/RT- reference or note, a
--      line that says so, a JT-/RT- partner, a line on a JT-/RT- product),
--      raised since p_from, and what was raised from them since then (the
--      receipt made from a marked order, that receipt's bill, the invoice of a
--      marked despatch), and:
--        1. withdraws every payment run proposed in [p_from, p_runs_to) and
--           not yet approved, through erp.withdraw_payment_run(), with the
--           reason (a demonstration proposes no run of its own);
--        2. takes every open document to its end by its own moves: a draft is
--           cancelled; an order pending approval is rejected and cancelled;
--           an approved order, requisition or transfer is cancelled; a sent
--           order with nothing received is cancelled by erp.cancel_sent_order();
--           a confirmed sales order with nothing despatched is cancelled; a
--           requisition its cancelled order gave back is cancelled; a draft
--           quotation on a version with no Cancel is sent and let lapse
--           (Send, then Expire), the only way out of draft that version has;
--        3. sends every receipt back on a supplier credit note raised from it
--           and issued (the way back erp.document_reversal_route() names for a
--           receipt), with the tax the bill charged on the billed part, so
--           the goods leave at what they cost and the accrual, or the bill,
--           is unmade; returns a supplier's samples still held through the
--           Samples move; closes short an order received in part and closes
--           an order whose every receipt went back. All of step 3 is kept
--           only if every check the month closes on that held before still
--           holds after, and is otherwise put back whole and listed;
--        4. lists everything it leaves, with why;
--        5. retires the testers' products and partners (status inactive, a
--           product's lifecycle obsolete) and ends their cost centres today
--           through erp.upsert_dimension_value(), each only when no open
--           document still uses it. The product keeps no door that retires a
--           product or a partner, so their status is set here as the person
--           it runs as, which the audit trail records. Nothing is deleted.
--      Asked again it finds nothing to do. Anywhere else it does nothing.
--   B. erp_test.tester_records_fixture(): the testers' records in each state
--      the demonstration holds them, raised through the product's doors.
--   C. erp_test.clear_tester_records_suite(), thirteen cases.
--   D. Each demonstration (code 'demo-%') cleared, as its longest-standing
--      administrator, for records raised since 4 October 00:00 London time
--      and runs proposed that day; the migration says, record by record,
--      what it did and what it left.
--
-- ── WHAT IT LEAVES, AND WHY ──────────────────────────────────────────────────
--
--   A posted despatch whose invoice was never issued: the way back for a
--   despatch is a customer credit note, which reverses a sale as well as the
--   stock, and this sale was never billed. Its order stays where it stands.
--   A closed transfer: between the organisation's own sites, with no way back
--   but another transfer. An accepted quotation: it became an order. A
--   requisition whose order stays, or whose order was cancelled while it
--   stood on a lifecycle version with no way back from Ordered. A cash
--   receipt or a journal, if any were marked: neither has a reversal built
--   (erp.document_reversal_route() says by journal). Anything a move refuses
--   is listed with the refusal.
--
-- Rehearsed on the CI demonstration (a year of seeded history) renamed into a
-- demo- code, holding these records in each state production holds them, in
-- a transaction rolled back: 23 done, 5 left, every check the month closes on
-- held before and after, and a second run did nothing.
--
-- On production: in demonstrations only (demo-cbb10384), the testers' open
-- documents move to cancelled (a draft quotation on version 1 to expired),
-- their receipts go back on supplier credit notes that post and settle their
-- bill, the two payment runs proposed on 4 October are withdrawn, and their
-- products, partners and cost centres are retired; nothing is deleted and no
-- email is sent (a demonstration sends none). No other organisation's rows
-- change. No table is altered. It must run after the train (#436), #437 and
-- the batch-41 pull request: it reads the doors as they stand then.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The clearing
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.clear_tester_records(
  p_from    timestamptz default timestamptz '2026-10-04 00:00:00 Europe/London',
  p_runs_to timestamptz default timestamptz '2026-10-05 00:00:00 Europe/London')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  -- A tester's mark: JT- (the journey test) or RT- (the retest) at the start
  -- of a word, in what somebody typed on the document or a line.
  c_mark   constant text := '(^|[^[:alnum:]])(JT|RT)-';
  -- A tester's master record: its code starts with the mark.
  c_code   constant text := '^(JT|RT)-';
  c_reason constant text :=
    'A tester''s record from the walk-through of the demonstration on 4 October 2026, cleared by the owner''s decision';
  -- The checks the month closes on (erp.close_task_template), read before and
  -- after anything posted is undone.
  c_checks constant text[] := array[
    'erp.assert_stock_reconciles()', 'erp.assert_inventory_reconciles()',
    'erp.assert_subledger_reconciles()', 'erp.assert_ageing_equals_control()',
    'erp.assert_trial_balance_balances()', 'erp.assert_grni_reconciles()'];
  v_today  date;
  v_docs   uuid[];
  v_done   jsonb := '[]'::jsonb;
  v_left   jsonb := '[]'::jsonb;
  v_group  jsonb;
  v_glef   jsonb;
  v_before text[] := '{}';
  v_after  text[] := '{}';
  v_new    text[];
  v_chk    text;
  r        record;
  ln       record;
  v_state  text;
  v_was    text;
  v_moves  text[];
  v_move   text;
  v_lines  jsonb;
  v_cn     uuid;
  v_billed bigint;
  v_tax    bigint;
  v_rate   numeric;
  v_open   integer;
  v_n      integer;
  v_bills  jsonb := '{}'::jsonb;
  v_here   uuid[];
begin
  -- The testers' records in a demonstration (20261009030000, the owner's
  -- decision 7 of 4 October): taken off the demonstration through the
  -- product's own moves, as whoever this runs as, never deleted. Anywhere
  -- else it does nothing.
  if not erp.tenant_is_demonstration(v_tenant) then
    return jsonb_build_object('organisation', 'not a demonstration', 'acted', 0,
                              'done', '[]'::jsonb, 'left', '[]'::jsonb);
  end if;
  v_today := erp.local_today(null);

  -- ── Which documents are the testers' ───────────────────────────────────────
  -- Raised since the walk-through began and marked: a JT-/RT- reference or
  -- note, a line that says so, a JT-/RT- partner, or a line on a JT-/RT-
  -- product. And what the testers raised from those, which carries no mark of
  -- its own: a receipt made from a marked order, the bill of that receipt, the
  -- invoice of a marked delivery. Only documents raised since p_from.
  with recursive marked(id) as (
    select d.id
      from erp.document d
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
     where d.tenant_id = v_tenant
       and d.created_at >= p_from
       and (coalesce(d.their_reference, '') ~ c_mark
            or coalesce(d.notes, '') ~ c_mark
            or coalesce(p.code, '') ~ c_code
            or exists (select 1
                         from erp.document_line l
                         left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
                        where l.tenant_id = d.tenant_id and l.document_id = d.id
                          and (coalesce(l.description, '') ~ c_mark
                               or coalesce(i.code, '') ~ c_code)))
    union
    select x.id
      from marked m
      join erp.document_relation rel
        on rel.tenant_id = v_tenant
       and (rel.from_document_id = m.id or rel.to_document_id = m.id)
      join erp.document x
        on x.tenant_id = v_tenant
       and x.id = case when rel.from_document_id = m.id then rel.to_document_id
                       else rel.from_document_id end
     where x.created_at >= p_from
  )
  select coalesce(array_agg(distinct id), '{}') into v_docs from marked;

  -- ── 1. The payment runs proposed that day, withdrawn ───────────────────────
  -- A demonstration proposes no run of its own; one still waiting for its
  -- approver from the walk-through's day is a tester's, and holds its bills.
  for r in
    select pp.id, pp.reference, pp.status::text as status
      from erp.payment_proposal pp
     where pp.tenant_id = v_tenant
       and pp.status in ('draft', 'proposed')
       and pp.created_at >= p_from and pp.created_at < p_runs_to
     order by pp.created_at, pp.id
  loop
    begin
      perform erp.withdraw_payment_run(r.id, c_reason);
      v_done := v_done || jsonb_build_object('kind', 'payment_run', 'number', r.reference,
                  'was', r.status, 'now', 'cancelled', 'how', 'withdrawn');
    exception when others then
      v_left := v_left || jsonb_build_object('kind', 'payment_run', 'number', r.reference,
                  'state', r.status, 'why', left(sqlerrm, 300));
    end;
  end loop;

  -- ── 2. What is still open, taken to cancelled by its own moves ─────────────
  -- Despatches and receipts first, so an order is free of them; orders before
  -- their requisitions, which an order's cancellation gives back.
  for r in
    select d.id, d.document_number, dt.code as type_code, dt.base_type_code as base
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
     order by array_position(array['delivery', 'receipt', 'invoice_reference', 'credit_reference',
                                   'return_to_supplier', 'quotation', 'sales_order', 'transfer_order',
                                   'purchase_order', 'requisition'], dt.base_type_code) nulls last,
              d.document_number, d.id
  loop
    v_state := erp.document_state_code(r.id);
    v_was := v_state;
    v_moves := case
      -- A quotation raised before Cancel came (20261006120000) stays on a
      -- version whose only way out of draft is Send; the offer is then let
      -- lapse, which is where a quotation nobody took ends.
      when v_state = 'draft' and r.base = 'quotation' and not erp.document_declares_move(r.id, 'cancel')
        then array['send', 'expire']
      when v_state = 'draft' then array['cancel']
      when v_state = 'pending_approval' and r.base in ('purchase_order', 'sales_order', 'transfer_order')
        then array['reject', 'cancel']
      when v_state = 'submitted' and r.base = 'requisition' then array['cancel_submitted']
      when v_state = 'approved' and r.base in ('purchase_order', 'requisition', 'transfer_order')
        then array['cancel_approved']
      when v_state = 'confirmed' and r.base = 'sales_order' then array['cancel_confirmed']
      when v_state = 'sent' and r.base = 'purchase_order' then array['cancel_sent']
      when v_state = 'ordered' and r.base = 'requisition' then array['reopen', 'cancel_approved']
      else '{}'::text[] end;
    continue when coalesce(array_length(v_moves, 1), 0) = 0;

    begin
      foreach v_move in array v_moves loop
        if v_move = 'cancel_sent' then
          -- The order the supplier has and has sent nothing against, by the
          -- door that withdraws its answer and its links (20261004990000).
          perform erp.cancel_sent_order(r.id, c_reason);
        elsif v_move = 'reopen' then
          -- Given back only when no order raised from it still stands
          -- (20261006111000); otherwise it is the history of that order.
          perform erp.reopen_requisitions(array[r.id], c_reason);
          exit when erp.document_state_code(r.id) <> 'approved';
        elsif v_move = 'cancel_confirmed' and exists (
                select 1 from erp.document_relation rel
                  join erp.document g on g.tenant_id = rel.tenant_id and g.id = rel.from_document_id
                 where rel.tenant_id = v_tenant and rel.to_document_id = r.id
                   and rel.relation_kind = 'fulfils' and not g.is_cancelled
                   and erp.document_state_code(g.id) <> 'cancelled') then
          raise exception 'something of it has been despatched';
        elsif not erp.document_declares_move(r.id, v_move) then
          raise exception 'its lifecycle version has no % move', v_move;
        else
          perform erp.transition_document(r.id, v_move, c_reason);
        end if;
      end loop;
      v_state := erp.document_state_code(r.id);
      if v_state in ('cancelled', 'expired') then
        v_done := v_done || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                    'was', v_was, 'now', v_state, 'how', array_to_string(v_moves, ', '));
      elsif r.base = 'requisition' and not erp.document_is_fully_converted(r.id)
            and not erp.document_declares_move(r.id, 'reopen') then
        v_left := v_left || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                    'state', v_state,
                    'why', 'its order was cancelled, but the lifecycle version it was raised on has no way back from ordered');
      else
        v_left := v_left || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                    'state', v_state, 'why', 'it was ordered, and its order stays');
      end if;
    exception when others then
      v_left := v_left || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                  'state', erp.document_state_code(r.id), 'why', left(sqlerrm, 300));
    end;
  end loop;

  -- ── 3. Goods received, sent back on a supplier credit note ────────────────
  -- The way back for a receipt (erp.document_reversal_route()): a credit note
  -- raised from it, which takes the goods off the shelf at what they cost and
  -- unmakes the accrual, or what is owed where the bill is in, and pays that
  -- bill. Then an order the testers received part of is closed short, and
  -- one whose goods have all gone back is closed. Kept only if every check
  -- the month closes on that held before still holds after; otherwise all of
  -- it is put back and listed.
  foreach v_chk in array c_checks loop
    begin
      execute 'select ' || v_chk;
    exception when others then
      v_before := v_before || v_chk;
    end;
  end loop;

  -- The testers' bills as they stand, so what the credit notes settle is said.
  select coalesce(jsonb_object_agg(d.id::text, erp.document_state_code(d.id)), '{}'::jsonb) into v_bills
    from erp.document d
   where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
     and erp.document_is_purchase_bill(d.id);

  v_group := '[]'::jsonb;
  v_glef := '[]'::jsonb;
  begin
    for r in
      select d.id, d.document_number, dt.code as type_code
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
         and dt.base_type_code = 'receipt'
         and erp.document_state_code(d.id) = 'posted'
       order by d.document_number, d.id
    loop
      -- A supplier's samples were never bought (20261004930000): what of
      -- them is still held goes back as the Samples list sends it back.
      if erp.is_sample_receipt(r.id) then
        v_n := 0;
        begin
          for ln in
            select l.id from erp.document_line l
             where l.tenant_id = v_tenant and l.document_id = r.id
               and not coalesce(l.is_cancelled, false) and erp.sample_line_held(l.id) > 0
             order by l.line_no
          loop
            perform erp.settle_samples(ln.id, 'return', null, null, c_reason);
            v_n := v_n + 1;
          end loop;
          if v_n > 0 then
            v_group := v_group || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                         'was', 'posted', 'now', 'returned', 'how', 'the samples still held sent back');
          end if;
        exception when others then
          v_glef := v_glef || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                      'state', 'posted', 'why', left(sqlerrm, 300));
        end;
        continue;
      end if;

      -- What of each line is still here: received, less what went back.
      select jsonb_agg(jsonb_build_object('line_id', l.id, 'quantity', l.quantity - coalesce(rt.back, 0))
                       order by l.line_no)
        into v_lines
        from erp.document_line l
        left join lateral (select sum(rr.quantity) as back from erp.document_relation rr
                            where rr.tenant_id = l.tenant_id and rr.to_line_id = l.id
                              and rr.relation_kind = 'returns') rt on true
       where l.tenant_id = v_tenant and l.document_id = r.id
         and not coalesce(l.is_cancelled, false) and l.quantity > 0
         and l.quantity - coalesce(rt.back, 0) > 0;
      continue when v_lines is null;

      begin
        v_cn := erp.return_to_supplier(r.id, 'ORDERED_IN_ERROR', c_reason, v_lines, null, null,
                                       'credit', null, null);
        -- The tax it gives back: none on what nobody billed, and on the part
        -- that was billed the share the bills of its order charged.
        v_billed := erp.document_value_minor(v_cn) - erp.document_unbilled_return_minor(v_cn);
        if v_billed > 0 then
          select case when coalesce(sum(erp.document_value_minor(b.id)), 0) = 0 then 0
                      else sum(erp.document_tax_minor(b.id))::numeric
                           / sum(erp.document_value_minor(b.id)) end
            into v_rate
            from erp.document b
           where b.tenant_id = v_tenant and not b.is_cancelled
             and erp.document_is_purchase_bill(b.id)
             and b.id in (select rel.from_document_id from erp.document_relation rel
                           where rel.tenant_id = v_tenant and rel.relation_kind = 'invoices'
                             and rel.to_document_id in (
                               select f.to_document_id from erp.document_relation f
                                where f.tenant_id = v_tenant and f.from_document_id = r.id
                                  and f.relation_kind = 'fulfils'
                               union select r.id));
          v_tax := round(v_billed * coalesce(v_rate, 0))::bigint;
          perform erp.state_supplier_tax(v_cn, v_tax, 'S', 'what the bill charged on the goods sent back');
        end if;
        perform erp.transition_document(v_cn, 'issue', c_reason);
        v_group := v_group || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                     'was', 'posted', 'now', 'returned',
                     'how', 'sent back on ' || (select x.document_number from erp.document x
                                                  where x.tenant_id = v_tenant and x.id = v_cn));
      exception when others then
        v_glef := v_glef || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                    'state', 'posted', 'why', left(sqlerrm, 300));
      end;
    end loop;

    -- An order the testers received part of: closed short, the move a
    -- person makes when nothing more is coming. Then, where every receipt of
    -- it has gone back, closed: there is nothing left to bill.
    for r in
      select d.id, d.document_number, dt.code as type_code
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
         and dt.base_type_code = 'purchase_order'
         and erp.document_state_code(d.id) in ('partially_received', 'received')
       order by d.document_number, d.id
    loop
      v_was := erp.document_state_code(r.id);
      begin
        if v_was = 'partially_received' then
          if not erp.document_declares_move(r.id, 'receive_rest') then
            raise exception 'its lifecycle version cannot close it short';
          end if;
          perform erp.transition_document(r.id, 'receive_rest', c_reason);
        end if;
        -- Anything of it still here, or billed and not sent back.
        select count(*) into v_open
          from erp.document_line l
          join erp.document_relation f
            on f.tenant_id = l.tenant_id and f.to_line_id = l.id and f.relation_kind = 'fulfils'
          join erp.document_line gl on gl.tenant_id = f.tenant_id and gl.id = f.from_line_id
          join erp.document g on g.tenant_id = gl.tenant_id and g.id = gl.document_id
         where l.tenant_id = v_tenant and l.document_id = r.id
           and not g.is_cancelled and erp.document_state_code(g.id) = 'posted'
           and gl.quantity > coalesce((select sum(rr.quantity) from erp.document_relation rr
                                        where rr.tenant_id = v_tenant and rr.to_line_id = gl.id
                                          and rr.relation_kind = 'returns'), 0);
        if v_open = 0 and erp.document_declares_move(r.id, 'close') then
          perform erp.transition_document(r.id, 'close', c_reason);
        end if;
        v_state := erp.document_state_code(r.id);
        if v_state = 'closed' then
          v_group := v_group || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                       'was', v_was, 'now', v_state, 'how', 'closed short, everything received sent back');
        else
          v_glef := v_glef || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                      'state', v_state, 'why', 'closed short; what it received is still here');
        end if;
      exception when others then
        v_glef := v_glef || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                    'state', v_was, 'why', left(sqlerrm, 300));
      end;
    end loop;

    -- A bill the credit notes paid.
    for r in
      select d.id, d.document_number, dt.code as type_code, e.value as was
        from jsonb_each_text(v_bills) e
        join erp.document d on d.tenant_id = v_tenant and d.id = e.key::uuid
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where erp.document_state_code(d.id) is distinct from e.value
       order by d.document_number
    loop
      v_group := v_group || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                   'was', r.was, 'now', erp.document_state_code(r.id),
                   'how', 'settled by the credit notes its goods went back on');
    end loop;

    -- Every check that held before must hold now.
    foreach v_chk in array c_checks loop
      begin
        execute 'select ' || v_chk;
      exception when others then
        v_after := v_after || v_chk;
      end;
    end loop;
    select coalesce(array_agg(c), '{}') into v_new from unnest(v_after) c where c <> all (v_before);
    if coalesce(array_length(v_new, 1), 0) > 0 then
      raise exception 'it would break % of the checks the month closes on', array_to_string(v_new, ', ');
    end if;
    v_done := v_done || v_group;
    v_left := v_left || v_glef;
  exception when others then
    -- Everything in this step is put back; each record is listed as it was.
    for r in
      select d.document_number, dt.code as type_code
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
         and (dt.base_type_code = 'receipt' and erp.document_state_code(d.id) = 'posted'
              or dt.base_type_code = 'purchase_order'
                 and erp.document_state_code(d.id) in ('partially_received', 'received'))
       order by d.document_number
    loop
      v_left := v_left || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
                  'state', 'as it was', 'why', 'not undone: ' || left(sqlerrm, 300));
    end loop;
  end;

  -- ── 4. What stays, and why ─────────────────────────────────────────────────
  -- The testers' receipts that still hold something: a line not all sent
  -- back, or a sample still held.
  select coalesce(array_agg(d.id), '{}') into v_here
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
     and dt.base_type_code = 'receipt' and erp.document_state_code(d.id) = 'posted'
     and exists (select 1 from erp.document_line l
                  where l.tenant_id = d.tenant_id and l.document_id = d.id
                    and not coalesce(l.is_cancelled, false)
                    and case when erp.is_sample_receipt(d.id) then erp.sample_line_held(l.id) > 0
                             else l.quantity > coalesce((select sum(rr.quantity) from erp.document_relation rr
                                                          where rr.tenant_id = l.tenant_id and rr.to_line_id = l.id
                                                            and rr.relation_kind = 'returns'), 0) end);

  for r in
    select d.id, d.document_number, dt.code as type_code, dt.base_type_code as base,
           erp.document_state_code(d.id) as state
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant and d.id = any (v_docs) and not d.is_cancelled
     order by dt.code, d.document_number
  loop
    continue when r.state in ('cancelled', 'expired')
               or exists (select 1 from jsonb_array_elements(v_done || v_left) e
                           where e ->> 'number' = r.document_number);
    -- Undone already: a receipt with nothing left here, and an order or a
    -- bill whose every receipt is such.
    continue when r.base = 'receipt' and r.state = 'posted' and r.id <> all (v_here);
    continue when (r.base = 'purchase_order' and r.state = 'closed'
                   or r.base = 'invoice_reference' and r.state = 'paid' and erp.document_is_purchase_bill(r.id))
               and exists (select 1 from erp.document_relation f
                            where f.tenant_id = v_tenant and f.from_document_id = r.id
                              and f.relation_kind in ('invoices', 'fulfils', 'converts')
                           union all
                           select 1 from erp.document_relation f
                            where f.tenant_id = v_tenant and f.to_document_id = r.id
                              and f.relation_kind = 'fulfils')
               and not exists (
                     select 1 from erp.document_relation f
                      where f.tenant_id = v_tenant and f.relation_kind = 'fulfils'
                        and f.from_document_id = any (v_here)
                        and (f.to_document_id = r.id
                             or f.to_document_id in (select i.to_document_id from erp.document_relation i
                                                      where i.tenant_id = v_tenant and i.from_document_id = r.id
                                                        and i.relation_kind = 'invoices')));
    continue when r.base in ('return_to_supplier', 'credit_reference')
               and exists (select 1 from erp.document_relation rel
                            where rel.tenant_id = v_tenant and rel.from_document_id = r.id
                              and rel.relation_kind in ('returns', 'credits'));
    v_left := v_left || jsonb_build_object('kind', r.type_code, 'number', r.document_number,
      'state', r.state,
      'why', case
        when r.base = 'delivery' then
          'a despatch comes back on a customer credit note, which also reverses a sale; this one was never invoiced'
        when r.base = 'sales_order' then 'what it ordered was despatched, and the despatch stays'
        when r.base = 'quotation' and r.state = 'accepted' then 'it became an order; accepted is where a quotation ends'
        when r.base = 'transfer_order' then
          'a transfer between the organisation''s own sites has no way back but another transfer; the stock stays where it went'
        when r.base = 'purchase_order' and r.state = 'closed' then 'closed: received and billed'
        when r.base = 'requisition' then 'it was ordered, and its order stays'
        when r.base = 'invoice_reference' then 'its posting stands; the goods it bills were not all sent back'
        when r.base = 'receipt' then 'what it received is still here'
        when r.base in ('cash_receipt', 'cash_payment') then
          'cash is corrected by a journal on the Journals screen; reversing it is not built'
        when r.base = 'shipment' then 'a shipment booked or delivered stays with the despatch it carried'
        else 'nothing in the product takes it back from where it stands' end);
  end loop;

  -- ── 5. The testers' master records, retired once nothing open uses them ────
  -- Products, partners and cost centres made since p_from whose code carries
  -- the mark. History points at them, so they are retired, never deleted. The product keeps no door that retires a product
  -- or a partner, so their status is set here, as whoever this runs as, which
  -- the audit trail records.
  for r in
    select i.id, i.code, i.status::text as status from erp.item i
     where i.tenant_id = v_tenant and i.code ~ c_code and i.status <> 'inactive'
       and i.created_at >= p_from
     order by i.code
  loop
    select string_agg(distinct d.document_number, ', ') into v_chk
      from erp.document_line l
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where l.tenant_id = v_tenant and l.item_id = r.id
       and not d.is_cancelled and not coalesce(l.is_cancelled, false) and not s.is_terminal;
    if v_chk is null then
      update erp.item set status = 'inactive', lifecycle = 'obsolete', updated_at = now()
       where tenant_id = v_tenant and id = r.id;
      v_done := v_done || jsonb_build_object('kind', 'product', 'number', r.code,
                  'was', r.status, 'now', 'inactive', 'how', 'retired');
    else
      v_left := v_left || jsonb_build_object('kind', 'product', 'number', r.code,
                  'state', r.status, 'why', 'still on ' || v_chk);
    end if;
  end loop;

  for r in
    select p.id, p.code, p.status::text as status from erp.party p
     where p.tenant_id = v_tenant and p.code ~ c_code and p.status <> 'inactive'
       and p.created_at >= p_from
     order by p.code
  loop
    select string_agg(distinct d.document_number, ', ') into v_chk
      from erp.document d
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = v_tenant and d.party_id = r.id
       and not d.is_cancelled and not s.is_terminal;
    if v_chk is null then
      update erp.party set status = 'inactive', updated_at = now()
       where tenant_id = v_tenant and id = r.id;
      v_done := v_done || jsonb_build_object('kind', 'partner', 'number', r.code,
                  'was', r.status, 'now', 'inactive', 'how', 'retired');
    else
      v_left := v_left || jsonb_build_object('kind', 'partner', 'number', r.code,
                  'state', r.status, 'why', 'still on ' || v_chk);
    end if;
  end loop;

  -- Cost centres through the door Cost centres uses, children before their
  -- parents, ended today.
  for r in
    select dv.code, dv.name, pv.code as parent_code, dv.valid_from, dv.status::text as status
      from erp.dimension_value dv
      join erp.dimension dm on dm.tenant_id = dv.tenant_id and dm.id = dv.dimension_id
      left join erp.dimension_value pv on pv.tenant_id = dv.tenant_id and pv.id = dv.parent_value_id
     where dv.tenant_id = v_tenant and dm.code = 'COST_CENTRE'
       and dv.code ~ c_code and dv.status <> 'inactive'
       and dv.created_at >= p_from
     order by (dv.parent_value_id is null), dv.code
  loop
    select string_agg(distinct d.document_number, ', ') into v_chk
      from erp.document_line l
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where l.tenant_id = v_tenant and not d.is_cancelled and not s.is_terminal
       and exists (select 1 from jsonb_each_text(coalesce(l.dimensions, '{}'::jsonb)) e where e.value = r.code);
    if v_chk is null then
      begin
        perform erp.upsert_dimension_value('COST_CENTRE', r.code, r.name, r.parent_code, r.valid_from,
                                           greatest(v_today, coalesce(r.valid_from, v_today)), 'inactive');
        v_done := v_done || jsonb_build_object('kind', 'cost_centre', 'number', r.code,
                    'was', r.status, 'now', 'inactive', 'how', 'ended ' || v_today);
      exception when others then
        v_left := v_left || jsonb_build_object('kind', 'cost_centre', 'number', r.code,
                    'state', r.status, 'why', left(sqlerrm, 300));
      end;
    else
      v_left := v_left || jsonb_build_object('kind', 'cost_centre', 'number', r.code,
                  'state', r.status, 'why', 'still on ' || v_chk);
    end if;
  end loop;

  return jsonb_build_object('organisation', (select t.code from erp.tenant t where t.id = v_tenant),
                            'acted', jsonb_array_length(v_done),
                            'done', v_done, 'left', v_left,
                            'checks_failing_before', to_jsonb(v_before));
end;
$$;

revoke all on function erp.clear_tester_records(timestamptz, timestamptz) from public, anon;

comment on function erp.clear_tester_records(timestamptz, timestamptz) is
  'In a demonstration, clears the testers'' JT-/RT- records raised since p_from through the product''s own moves, as '
  'the person it runs as: withdraws the runs proposed before p_runs_to, ends open documents, sends receipts back on '
  'supplier credit notes while the month''s checks hold, retires their products, partners and cost centres, and '
  'lists what it leaves and why (20261009030000, owner''s decision 7). Anywhere else it does nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The testers' records, as a fixture
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.tester_records_fixture()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_ent    uuid; s_main uuid; s_north uuid; v_uom uuid;
  i_rm1    uuid; i_rm2 uuid; i_fg uuid; i_p1 uuid; i_p2 uuid;
  p_sup    uuid; p_cus uuid; p_jsup uuid; p_jcus uuid;
  v_po     uuid; v_grn uuid; v_bill uuid; v_req uuid; v_so uuid; v_dn uuid; v_q uuid;
  v_out    jsonb := '{}'::jsonb;
  x        jsonb;
  l1       uuid; l2 uuid;
begin
  -- The testers' records of 4 October in each state the live demonstration
  -- holds them (20261009030000), raised through the product's own doors in
  -- the organisation it is called in, as whoever calls it. Answers each
  -- record's id by name.
  select e.id into v_ent from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  select s.id into s_main from erp.site s
   where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
   order by (s.site_type = 'warehouse') desc, s.code limit 1;
  select s.id into s_north from erp.site s
   where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active' and s.id <> s_main
   order by s.code limit 1;
  select i.id, i.stock_uom_id into i_rm1, v_uom from erp.item i
   where i.tenant_id = v_tenant and i.code = 'RM-300';
  select i.id into i_rm2 from erp.item i where i.tenant_id = v_tenant and i.code = 'RM-310';
  select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
  select p.id into p_sup from erp.party p where p.tenant_id = v_tenant and p.code = 'S-FAST';
  select p.id into p_cus from erp.party p where p.tenant_id = v_tenant and p.code = 'C-HARBOUR';

  -- The testers' master records: two products, a supplier, a customer and
  -- two cost centres, the second under the first.
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'JT-E-P1', 'Tester product one', v_uom, 'active') returning id into i_p1;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'JT-E-P2', 'Tester product two', v_uom, 'active') returning id into i_p2;
  insert into erp.party (tenant_id, code, name, country_code, status)
  values (v_tenant, 'JT-E-SUP', 'Tester supplier', 'GB', 'active') returning id into p_jsup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (v_tenant, p_jsup, 'supplier', 'active');
  insert into erp.party (tenant_id, code, name, country_code, status)
  values (v_tenant, 'JT-E-CUS', 'Tester customer', 'GB', 'active') returning id into p_jcus;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (v_tenant, p_jcus, 'customer', 'active');
  perform public.erp_upsert_cost_centre('JT-E-CC', 'Tester cost centre');
  perform public.erp_upsert_cost_centre('JT-E-CC2', 'Tester cost centre two', 'JT-E-CC');

  -- Stock of the finished good to sell, from an order nobody marked.
  v_po := erp.open_document('purchase_order', p_sup, v_ent, s_main);
  perform erp.add_document_line(v_po, i_fg, 20, 4000, 'stock to sell');
  perform erp.transition_document(v_po, 'submit', null);
  perform erp_test.approve_document(v_po, 'fixture');
  perform erp.transition_document(v_po, 'send', null);
  x := erp.create_receipt_from_order(v_po, null, 'post');
  v_out := v_out || jsonb_build_object('stock_order', v_po);

  -- A run proposed that night, before the testers' bill: it holds nothing of
  -- theirs, but it is the night's.
  v_bill := erp.bill_from_receipt((x ->> 'document_id')::uuid, 'STOCK-BILL-1', current_date, current_date, true);
  v_out := v_out || jsonb_build_object('stock_bill', v_bill,
                      'run_1', erp.propose_payment_run(current_date, null, interval '60 days'));

  -- ── Purchasing ────────────────────────────────────────────────────────────
  -- Pending approval, on the tester's own supplier and product.
  v_po := erp.open_document('purchase_order', p_jsup, v_ent, s_main, 'JT-E order');
  perform erp.add_document_line(v_po, i_p1, 3, 1000, 'tester product');
  perform erp.transition_document(v_po, 'submit', null);
  v_out := v_out || jsonb_build_object('po_pending', v_po);

  -- Approved, converted from a requisition that is therefore ordered.
  v_req := erp.open_document('requisition', p_sup, v_ent, s_main, 'JT-A requisition');
  perform erp.add_document_line(v_req, i_rm1, 6, 1250, 'bolts');
  perform erp.transition_document(v_req, 'submit', null);
  perform erp_test.approve_document(v_req, 'fixture');
  x := erp.convert_document(v_req, p_sup, s_main);
  v_po := coalesce((x ->> 'document_id')::uuid, (x ->> 'id')::uuid);
  if erp.document_state_code(v_po) = 'draft' then
    perform erp.transition_document(v_po, 'submit', null);
  end if;
  if erp.document_state_code(v_po) = 'pending_approval' then
    perform erp_test.approve_document(v_po, 'fixture');
  end if;
  v_out := v_out || jsonb_build_object('req_ordered', v_req, 'po_approved', v_po);

  -- Sent, nothing received.
  v_po := erp.open_document('purchase_order', p_sup, v_ent, s_main, 'JT-A order 2');
  perform erp.add_document_line(v_po, i_rm1, 3, 1250, 'bolts');
  perform erp.transition_document(v_po, 'submit', null);
  perform erp_test.approve_document(v_po, 'fixture');
  perform erp.transition_document(v_po, 'send', null);
  v_out := v_out || jsonb_build_object('po_sent', v_po);

  -- Partially received; the rest put on a receipt that was then cancelled.
  v_po := erp.open_document('purchase_order', p_sup, v_ent, s_main, 'JT-D requisition 1');
  l1 := erp.add_document_line(v_po, i_rm1, 10, 1250, 'bolts');
  perform erp.add_document_line(v_po, i_rm2, 5, 840, 'washers');
  perform erp.transition_document(v_po, 'submit', null);
  perform erp_test.approve_document(v_po, 'fixture');
  perform erp.transition_document(v_po, 'send', null);
  x := erp.create_receipt_from_order(v_po, jsonb_build_array(jsonb_build_object('line_id', l1, 'quantity', 6)), 'post');
  v_out := v_out || jsonb_build_object('po_partial', v_po, 'grn_partial', (x ->> 'document_id')::uuid);
  x := erp.create_receipt_from_order(v_po, null, null);
  perform erp.transition_document((x ->> 'document_id')::uuid, 'cancel', 'raised twice');
  v_out := v_out || jsonb_build_object('grn_cancelled', (x ->> 'document_id')::uuid);

  -- Received in two receipts and billed for the second: the bill is the
  -- tester's (RT-INV-1), the order closed by hand. The second receipt and
  -- the bill carry no mark of their own.
  v_req := erp.open_document('requisition', p_sup, v_ent, s_main, 'RT-REQ-1');
  perform erp.add_document_line(v_req, i_rm1, 6, 1100, 'bolts');
  perform erp.add_document_line(v_req, i_rm2, 4, 900, 'washers');
  perform erp.transition_document(v_req, 'submit', null);
  perform erp_test.approve_document(v_req, 'fixture');
  x := erp.convert_document(v_req, p_sup, s_main);
  v_po := coalesce((x ->> 'document_id')::uuid, (x ->> 'id')::uuid);
  if erp.document_state_code(v_po) = 'draft' then
    perform erp.transition_document(v_po, 'submit', null);
  end if;
  if erp.document_state_code(v_po) = 'pending_approval' then
    perform erp_test.approve_document(v_po, 'fixture');
  end if;
  perform erp.transition_document(v_po, 'send', null);
  select l.id into l1 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = v_po and l.item_id = i_rm1;
  select l.id into l2 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = v_po and l.item_id = i_rm2;
  x := erp.create_receipt_from_order(v_po, jsonb_build_array(jsonb_build_object('line_id', l1, 'quantity', 6)), 'post');
  v_grn := (x ->> 'document_id')::uuid;
  x := erp.create_receipt_from_order(v_po, jsonb_build_array(jsonb_build_object('line_id', l2, 'quantity', 4)), 'post');
  v_bill := erp.bill_from_receipt((x ->> 'document_id')::uuid, 'RT-INV-1', current_date, current_date, true);
  if erp.document_state_code(v_po) = 'received' then
    perform erp.transition_document(v_po, 'close', 'kept elsewhere');
  end if;
  v_out := v_out || jsonb_build_object('req_closed', v_req, 'po_closed', v_po, 'grn_closed_1', v_grn,
                                       'grn_closed_2', (x ->> 'document_id')::uuid, 'bill', v_bill,
                                       'run_2', erp.propose_payment_run(current_date, null, interval '60 days'));

  -- Cancelled already: an order and a requisition.
  v_po := erp.open_document('purchase_order', p_sup, v_ent, s_main, 'JT-A order 0');
  perform erp.add_document_line(v_po, i_rm1, 1, 1250, 'bolts');
  perform erp.transition_document(v_po, 'cancel', 'raised twice');
  v_req := erp.open_document('requisition', p_sup, v_ent, s_main, 'RT-REQ-2');
  perform erp.add_document_line(v_req, i_rm1, 1, 1250, 'bolts');
  perform erp.transition_document(v_req, 'cancel', 'raised twice');
  v_out := v_out || jsonb_build_object('po_cancelled', v_po, 'req_cancelled', v_req);

  -- ── Selling ───────────────────────────────────────────────────────────────
  -- A draft quotation for the tester's customer.
  v_q := erp.open_document('quotation', p_jcus, v_ent, s_main, 'JT-E quote');
  perform erp.add_document_line(v_q, i_p2, 2, 2500, 'tester product two');
  v_out := v_out || jsonb_build_object('quo_draft', v_q);

  -- Accepted, ordered, despatched and invoiced in draft: the order reads
  -- invoiced, the despatch posted.
  v_q := erp.open_document('quotation', p_cus, v_ent, s_main, 'RT-QUO-1');
  perform erp.add_document_line(v_q, i_fg, 5, 4950, 'sensor');
  perform erp.transition_document(v_q, 'send', null);
  x := erp.convert_document(v_q, p_cus, s_main);
  v_so := coalesce((x ->> 'document_id')::uuid, (x ->> 'id')::uuid);
  if erp.document_state_code(v_so) = 'draft' then
    perform erp.transition_document(v_so, 'submit', null);
  end if;
  if erp.document_state_code(v_so) = 'pending_approval' then
    perform erp_test.approve_document(v_so, 'fixture');
  end if;
  -- A customer with debt overdue holds the order; the fixture releases it.
  begin
    perform erp.release_credit_hold(v_so, 'released for the fixture');
  exception when others then
    null;
  end;
  x := erp.create_delivery_from_order(v_so, null, 'post');
  v_dn := (x ->> 'document_id')::uuid;
  v_out := v_out || jsonb_build_object('quo_accepted', v_q, 'so_invoiced', v_so, 'dn_posted', v_dn,
                                       'inv_draft', erp.invoice_from_delivery(v_dn, true, 'fixture'));

  -- Confirmed, with a despatch in draft.
  v_so := erp.open_document('sales_order', p_cus, v_ent, s_main, 'JT-B order 1');
  perform erp.add_document_line(v_so, i_fg, 2, 4950, 'sensor');
  perform erp.transition_document(v_so, 'submit', null);
  if erp.document_state_code(v_so) = 'pending_approval' then
    perform erp_test.approve_document(v_so, 'fixture');
  end if;
  -- A customer with debt overdue holds the order; the fixture releases it.
  begin
    perform erp.release_credit_hold(v_so, 'released for the fixture');
  exception when others then
    null;
  end;
  x := erp.create_delivery_from_order(v_so, null, null);
  v_out := v_out || jsonb_build_object('so_confirmed_1', v_so, 'dn_draft', (x ->> 'document_id')::uuid);

  -- Confirmed, its despatch cancelled.
  v_so := erp.open_document('sales_order', p_cus, v_ent, s_main, 'JT-B order 2');
  perform erp.add_document_line(v_so, i_fg, 1, 4950, 'sensor');
  perform erp.transition_document(v_so, 'submit', null);
  if erp.document_state_code(v_so) = 'pending_approval' then
    perform erp_test.approve_document(v_so, 'fixture');
  end if;
  -- A customer with debt overdue holds the order; the fixture releases it.
  begin
    perform erp.release_credit_hold(v_so, 'released for the fixture');
  exception when others then
    null;
  end;
  x := erp.create_delivery_from_order(v_so, null, null);
  perform erp.transition_document((x ->> 'document_id')::uuid, 'cancel', 'raised twice');
  v_out := v_out || jsonb_build_object('so_confirmed_2', v_so, 'dn_cancelled', (x ->> 'document_id')::uuid);

  -- ── Moving ────────────────────────────────────────────────────────────────
  x := erp.raise_transfer_order(s_main, s_north, jsonb_build_array(
         jsonb_build_object('item_id', i_fg, 'quantity', 1)), null, 'JT-C transfer');
  perform erp.despatch_transfer((x ->> 'document_id')::uuid);
  perform erp.receive_transfer((x ->> 'document_id')::uuid);
  v_out := v_out || jsonb_build_object('trf_closed', (x ->> 'document_id')::uuid);

  -- A supplier's samples, one of three already sent back.
  x := erp.receive_samples(p_sup, s_main, jsonb_build_array(jsonb_build_object('item_id', i_rm2, 'quantity', 3)),
                           current_date + 14, 'fit', 'JT-D samples 1');
  v_grn := coalesce((x ->> 'document_id')::uuid, (x ->> 'receipt_id')::uuid);
  select l.id into l1 from erp.document_line l where l.tenant_id = v_tenant and l.document_id = v_grn;
  perform erp.settle_samples(l1, 'return', 1, null, 'JT-D return one');
  v_out := v_out || jsonb_build_object('grn_samples', v_grn);

  return v_out;
end;
$$;

revoke all on function erp_test.tester_records_fixture() from public, anon;

comment on function erp_test.tester_records_fixture() is
  'Raises, in the organisation it is called in, the testers'' records of 4 October in each state the demonstration '
  'holds them (20261009030000), and answers their ids by name. For erp_test.clear_tester_records_suite().';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.clear_tester_records_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 13;
  c_reason   constant text :=
    'A tester''s record from the walk-through of the demonstration on 4 October 2026, cleared by the owner''s decision';
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  rb2      record;
  v_step   text := 'provisioning';
  v_state  text;
  v_code   text;
  v_other  text;
  f        jsonb;
  r0       jsonb;
  r        jsonb;
  r2       jsonb;
  r3       jsonb;
  v_po2    uuid;
  v_item2  uuid;
  v_bad    text;
  v_fail0  jsonb;
  v_fail1  jsonb;
  v_checks text;
  v_chk    text;
  v_today  date;
begin
  begin
    -- ── The fixture: a demonstration holding the testers' records ───────────
    v_step := 'a demonstration';
    perform set_config('request.jwt.claims', '', true);
    v_code := 'demo-zzclr' || v_tag;
    select * into rb from erp.provision_tenant(
      v_code, 'Clear Tester Records Suite', 'admin@' || v_code || '.test', 'Clearing Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@' || v_code || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'the testers'' records';
    f := erp_test.tester_records_fixture();
    v_today := erp.local_today(null);

    -- ── And an organisation that is not a demonstration, with a mark ───────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    v_other := 'zzclr-' || v_tag;
    select * into rb2 from erp.provision_tenant(
      v_other, 'Clear Tester Records Other', 'admin@' || v_other || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = rb2.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@' || v_other || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    perform erp.ensure_demo_configuration(rb2.tenant_id, rb2.admin_user_id);
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    select rb2.tenant_id, 'JT-E-P1', 'Not a tester''s', i.stock_uom_id, 'active'
      from erp.item i where i.tenant_id = rb2.tenant_id and i.code = 'RM-300'
    returning id into v_item2;
    v_po2 := erp.open_document('purchase_order',
               (select p.id from erp.party p where p.tenant_id = rb2.tenant_id and p.code = 'S-FAST'),
               (select e.id from erp.entity e where e.tenant_id = rb2.tenant_id order by e.code limit 1),
               (select s.id from erp.site s where s.tenant_id = rb2.tenant_id order by s.code limit 1),
               'JT-A order 1');
    perform erp.add_document_line(v_po2, v_item2, 1, 100, 'JT- line');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 1. The fixture holds each state the demonstration holds ─────────────
    v_step := 'reading the fixture';
    select string_agg(e.key || ' ' || coalesce(erp.document_state_code(e.value::uuid), 'none'), ', ' order by e.key)
      into v_bad
      from jsonb_each_text(f) e
     where e.key not like 'run%'
       and coalesce(erp.document_state_code(e.value::uuid), 'none') <> case e.key
             when 'po_pending' then 'pending_approval' when 'po_approved' then 'approved'
             when 'po_sent' then 'sent' when 'po_partial' then 'partially_received'
             when 'po_closed' then 'closed' when 'po_cancelled' then 'cancelled'
             when 'stock_order' then 'closed' when 'req_ordered' then 'ordered'
             when 'req_closed' then 'ordered' when 'req_cancelled' then 'cancelled'
             when 'grn_partial' then 'posted' when 'grn_cancelled' then 'cancelled'
             when 'grn_closed_1' then 'posted' when 'grn_closed_2' then 'posted'
             when 'grn_samples' then 'posted' when 'bill' then 'registered'
             when 'stock_bill' then 'registered' when 'quo_draft' then 'draft'
             when 'quo_accepted' then 'accepted' when 'so_confirmed_1' then 'confirmed'
             when 'so_confirmed_2' then 'confirmed' when 'so_invoiced' then 'despatched'
             when 'dn_draft' then 'draft' when 'dn_cancelled' then 'cancelled'
             when 'dn_posted' then 'posted' when 'inv_draft' then 'draft'
             when 'trf_closed' then 'closed' else '?' end;
    v_cases := v_cases + 1;
    case_name := 'the fixture holds the testers'' records in each state the demonstration holds them, and two runs proposed';
    passed := v_state is null and v_bad is null
          and (select count(*) from erp.payment_proposal pp
                where pp.tenant_id = rb.tenant_id and pp.status = 'proposed') = 2;
    detail := coalesce(v_state, coalesce('out of place: ' || v_bad, 'every record where it should be'));
    return next;

    -- ── 2. Outside the window, nothing ──────────────────────────────────────
    v_step := 'clearing with a window that opens after the records were raised';
    r0 := erp.clear_tester_records(now() + interval '1 minute', now() + interval '2 minutes');
    v_cases := v_cases + 1;
    case_name := 'records raised before the window opens are history: nothing is done to them';
    passed := v_state is null and (r0 ->> 'acted')::integer = 0
          and erp.document_state_code((f ->> 'po_pending')::uuid) = 'pending_approval'
          and erp.document_state_code((f ->> 'dn_draft')::uuid) = 'draft'
          and (select count(*) from erp.payment_proposal pp
                where pp.tenant_id = rb.tenant_id and pp.status = 'proposed') = 2;
    detail := coalesce(v_state, left(r0::text, 300));
    return next;

    -- What platform assurance says before the clearing.
    v_step := 'platform assurance before';
    select coalesce(jsonb_agg(c ->> 'code' order by c ->> 'code') filter (where c ->> 'ok' = 'false'), '[]'::jsonb)
      into v_fail0 from jsonb_array_elements(erp.platform_assurance()) c;

    -- ── The clearing ────────────────────────────────────────────────────────
    v_step := 'clearing';
    r := erp.clear_tester_records(now() - interval '1 hour', now() + interval '1 hour');

    -- ── 3. Open orders, by their own moves ──────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'open purchase orders end cancelled by their own moves: pending is rejected then cancelled, approved and sent are cancelled, each with the reason';
    passed := v_state is null
          and erp.document_state_code((f ->> 'po_pending')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'po_approved')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'po_sent')::uuid) = 'cancelled'
          and exists (select 1 from erp.state_transition_log l
                       where l.tenant_id = rb.tenant_id and l.object_id = (f ->> 'po_pending')::uuid
                         and l.transition_code = 'reject')
          and exists (select 1 from erp.state_transition_log l
                       where l.tenant_id = rb.tenant_id and l.object_id = (f ->> 'po_sent')::uuid
                         and l.transition_code = 'cancel_sent')
          and not exists (select 1 from erp.supplier_response_link k
                           where k.tenant_id = rb.tenant_id and k.order_id = (f ->> 'po_sent')::uuid
                             and k.revoked_at is null);
    detail := coalesce(v_state, format('pending %s, approved %s, sent %s',
                erp.document_state_code((f ->> 'po_pending')::uuid),
                erp.document_state_code((f ->> 'po_approved')::uuid),
                erp.document_state_code((f ->> 'po_sent')::uuid)));
    return next;

    -- ── 4. Requisitions ─────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a requisition its cancelled order gave back is cancelled; one whose order stays is left ordered and listed';
    passed := v_state is null
          and erp.document_state_code((f ->> 'req_ordered')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'req_closed')::uuid) = 'ordered'
          and exists (select 1 from jsonb_array_elements(r -> 'left') e
                       where e ->> 'number' = (select d.document_number from erp.document d
                                                where d.id = (f ->> 'req_closed')::uuid)
                         and coalesce(e ->> 'why', '') <> '');
    detail := coalesce(v_state, format('given back %s, ordered %s',
                erp.document_state_code((f ->> 'req_ordered')::uuid),
                erp.document_state_code((f ->> 'req_closed')::uuid)));
    return next;

    -- ── 5. Selling, still open ──────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the draft quotation, the confirmed orders, the draft despatch and the draft invoice end; the accepted quotation is listed';
    passed := v_state is null
          and erp.document_state_code((f ->> 'quo_draft')::uuid) in ('cancelled', 'expired')
          and erp.document_state_code((f ->> 'so_confirmed_1')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'so_confirmed_2')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'dn_draft')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'inv_draft')::uuid) = 'cancelled'
          and erp.document_state_code((f ->> 'quo_accepted')::uuid) = 'accepted'
          and exists (select 1 from jsonb_array_elements(r -> 'left') e
                       where e ->> 'number' = (select d.document_number from erp.document d
                                                where d.id = (f ->> 'quo_accepted')::uuid));
    detail := coalesce(v_state, format('quotation %s, orders %s and %s, despatch %s, invoice %s',
                erp.document_state_code((f ->> 'quo_draft')::uuid),
                erp.document_state_code((f ->> 'so_confirmed_1')::uuid),
                erp.document_state_code((f ->> 'so_confirmed_2')::uuid),
                erp.document_state_code((f ->> 'dn_draft')::uuid),
                erp.document_state_code((f ->> 'inv_draft')::uuid)));
    return next;

    -- ── 6. Receipts, sent back ──────────────────────────────────────────────
    select string_agg(g.document_number || ' line ' || l.line_no, ', ') into v_bad
      from erp.document g
      join erp.document_line l on l.tenant_id = g.tenant_id and l.document_id = g.id
     where g.tenant_id = rb.tenant_id
       and g.id in ((f ->> 'grn_partial')::uuid, (f ->> 'grn_closed_1')::uuid, (f ->> 'grn_closed_2')::uuid)
       and l.quantity > coalesce((select sum(rr.quantity) from erp.document_relation rr
                                   join erp.document cn on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
                                  where rr.tenant_id = l.tenant_id and rr.to_line_id = l.id
                                    and rr.relation_kind = 'returns'
                                    and erp.document_state_code(cn.id) = 'issued'), 0);
    v_cases := v_cases + 1;
    case_name := 'every receipt goes back on a supplier credit note issued from it, the samples still held go back, and goods received not invoiced holds nothing of them';
    passed := v_state is null and v_bad is null
          and (select coalesce(sum(erp.sample_line_held(l.id)), 0) from erp.document_line l
                where l.tenant_id = rb.tenant_id and l.document_id = (f ->> 'grn_samples')::uuid) = 0
          and not exists (select 1 from erp.grni_report() g
                           where g.order_number in (select d.document_number from erp.document d
                                                     where d.id in ((f ->> 'po_partial')::uuid, (f ->> 'po_closed')::uuid))
                             and g.open_quantity <> 0);
    detail := coalesce(v_state, coalesce('not sent back: ' || v_bad, 'every line sent back'));
    return next;

    -- ── 7. The bill and the order received in part ──────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the bill is settled by the credit note its goods went back on, and the order received in part is closed short and then closed';
    passed := v_state is null
          and erp.document_state_code((f ->> 'bill')::uuid) = 'paid'
          and erp.document_state_code((f ->> 'po_partial')::uuid) = 'closed'
          and exists (select 1 from erp.state_transition_log l
                       where l.tenant_id = rb.tenant_id and l.object_id = (f ->> 'po_partial')::uuid
                         and l.transition_code = 'receive_rest')
          and erp.document_state_code((f ->> 'stock_bill')::uuid) = 'registered';
    detail := coalesce(v_state, format('bill %s, order %s, the bill nobody marked %s',
                erp.document_state_code((f ->> 'bill')::uuid),
                erp.document_state_code((f ->> 'po_partial')::uuid),
                erp.document_state_code((f ->> 'stock_bill')::uuid)));
    return next;

    -- ── 8. What stays ───────────────────────────────────────────────────────
    select string_agg(d.document_number, ', ') into v_bad
      from erp.document d
     where d.id in ((f ->> 'dn_posted')::uuid, (f ->> 'so_invoiced')::uuid, (f ->> 'trf_closed')::uuid)
       and not exists (select 1 from jsonb_array_elements(r -> 'left') e
                        where e ->> 'number' = d.document_number and coalesce(e ->> 'why', '') <> '');
    v_cases := v_cases + 1;
    case_name := 'the posted despatch, the order it fulfilled and the closed transfer stay as they are, each listed with why';
    passed := v_state is null and v_bad is null
          and erp.document_state_code((f ->> 'dn_posted')::uuid) = 'posted'
          and erp.document_state_code((f ->> 'so_invoiced')::uuid) = 'despatched'
          and erp.document_state_code((f ->> 'trf_closed')::uuid) = 'closed';
    detail := coalesce(v_state, coalesce('not listed: ' || v_bad, 'all three listed'));
    return next;

    -- ── 9. The payment runs ─────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'both payment runs proposed that day are withdrawn, with the reason in the audit trail';
    passed := v_state is null
          and (select count(*) from erp.payment_proposal pp
                where pp.tenant_id = rb.tenant_id and pp.status = 'cancelled'
                  and pp.id in ((f ->> 'run_1')::uuid, (f ->> 'run_2')::uuid)) = 2
          and (select count(*) from erp.audit_entry ae
                where ae.tenant_id = rb.tenant_id and ae.object_type = 'payment_proposal'
                  and ae.object_id in ((f ->> 'run_1')::uuid, (f ->> 'run_2')::uuid)
                  and ae.reason = c_reason) = 2;
    detail := coalesce(v_state, (select string_agg(pp.reference || ' ' || pp.status, ', ')
                                   from erp.payment_proposal pp where pp.tenant_id = rb.tenant_id));
    return next;

    -- ── 10. Master records ──────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the testers'' products, partners and cost centres are retired, ended today, and none is deleted';
    passed := v_state is null
          and (select count(*) from erp.item i where i.tenant_id = rb.tenant_id
                 and i.code in ('JT-E-P1', 'JT-E-P2') and i.status = 'inactive') = 2
          and (select count(*) from erp.party p where p.tenant_id = rb.tenant_id
                 and p.code in ('JT-E-SUP', 'JT-E-CUS') and p.status = 'inactive') = 2
          and (select count(*) from erp.dimension_value dv where dv.tenant_id = rb.tenant_id
                 and dv.code in ('JT-E-CC', 'JT-E-CC2') and dv.status = 'inactive'
                 and dv.valid_to = v_today) = 2
          and (select count(*) from erp.item i where i.tenant_id = rb.tenant_id
                 and i.code in ('RM-300', 'FG-1000') and i.status = 'active') = 2;
    detail := coalesce(v_state, (select string_agg(x.code || ' ' || x.status, ', ') from (
                select i.code, i.status::text from erp.item i where i.tenant_id = rb.tenant_id and i.code like 'JT-%'
                union all select p.code, p.status::text from erp.party p where p.tenant_id = rb.tenant_id and p.code like 'JT-%'
                union all select dv.code, dv.status::text from erp.dimension_value dv
                 where dv.tenant_id = rb.tenant_id and dv.code like 'JT-%') x));
    return next;

    -- ── 11. The month still closes, and assurance has nothing new ──────────
    v_step := 'the checks after';
    v_checks := null;
    foreach v_chk in array array[
      'erp.assert_stock_reconciles()', 'erp.assert_inventory_reconciles()',
      'erp.assert_subledger_reconciles()', 'erp.assert_ageing_equals_control()',
      'erp.assert_trial_balance_balances()', 'erp.assert_grni_reconciles()'] loop
      begin
        execute 'select ' || v_chk;
      exception when others then
        v_checks := concat_ws('; ', v_checks, v_chk || ': ' || left(sqlerrm, 160));
      end;
    end loop;
    select coalesce(jsonb_agg(c ->> 'code' order by c ->> 'code') filter (where c ->> 'ok' = 'false'), '[]'::jsonb)
      into v_fail1 from jsonb_array_elements(erp.platform_assurance()) c;
    v_cases := v_cases + 1;
    case_name := 'every check the month closes on holds in the demonstration afterwards, and platform assurance fails nothing it did not fail before';
    passed := v_state is null and v_checks is null and v_fail0 @> v_fail1
          and coalesce(jsonb_array_length(r -> 'checks_failing_before'), 0) = 0;
    detail := coalesce(v_state, format('checks: %s; assurance before %s, after %s',
                coalesce(v_checks, 'all hold'), v_fail0, v_fail1));
    return next;

    -- ── 12. Asked again, nothing ────────────────────────────────────────────
    v_step := 'clearing again';
    r2 := erp.clear_tester_records(now() - interval '1 hour', now() + interval '1 hour');
    v_cases := v_cases + 1;
    case_name := 'asked again it finds nothing to do, and lists only what it left the first time';
    passed := v_state is null and (r ->> 'acted')::integer > 0 and (r2 ->> 'acted')::integer = 0
          and jsonb_array_length(r2 -> 'left') <= jsonb_array_length(r -> 'left');
    detail := coalesce(v_state, format('first %s done and %s left; again %s done and %s left',
                r ->> 'acted', jsonb_array_length(r -> 'left'),
                r2 ->> 'acted', jsonb_array_length(r2 -> 'left')));
    return next;

    -- ── 13. Never outside a demonstration ───────────────────────────────────
    v_step := 'clearing in the organisation that is not a demonstration';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    r3 := erp.clear_tester_records(now() - interval '1 hour', now() + interval '1 hour');
    v_cases := v_cases + 1;
    case_name := 'in an organisation that is not a demonstration nothing is done, and the clearing in the demonstration touched nothing of it';
    passed := v_state is null and (r3 ->> 'acted')::integer = 0
          and r3 ->> 'organisation' = 'not a demonstration'
          and erp.document_state_code(v_po2) = 'draft'
          and (select i.status from erp.item i where i.id = v_item2) = 'active';
    detail := coalesce(v_state, format('%s; its order %s', left(r3::text, 200), erp.document_state_code(v_po2)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CLEAR_TESTER_RECORDS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in (v_code, v_other))
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_CLEAR_TESTER_RECORDS_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.clear_tester_records_suite() from public, anon;

comment on function erp_test.clear_tester_records_suite() is
  'The testers'' records are cleared from a demonstration (20261009030000): open documents end by their own moves, '
  'receipts go back on supplier credit notes that settle the bill, the day''s payment runs are withdrawn, the '
  'testers'' products, partners and cost centres are retired; posted records with no clean way back are listed; '
  'the month''s checks and platform assurance hold; a second run does nothing; nothing outside a demonstration moves.';

create or replace function erp_test.assert_clear_tester_records_suite()
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
    from erp_test.clear_tester_records_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CLEAR_TESTER_RECORDS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The testers'' records would not be cleared from the demonstration as the owner decided. Read the case that failed.';
  end if;
  if v_total <> 13 then
    raise exception 'CLOVEERP_CLEAR_TESTER_RECORDS_SUITE_SHRANK: % case(s), expected 13', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('clear tester records: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_clear_tester_records_suite() from public, anon;

comment on function erp_test.assert_clear_tester_records_suite() is
  'The testers'' records of 4 October are cleared from a demonstration through the product''s own moves, and only '
  'from a demonstration (20261009030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Each demonstration cleared, as its administrator
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  r          record;
  e          jsonb;
  v_admin    uuid;
  v_pref     uuid;
  v_pref_at  timestamptz;
  v_had_pref boolean;
  v_out      jsonb;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);

    -- The demonstration's longest-standing administrator who may approve
    -- purchases, sell and withdraw a payment run, as 20261006011000 and
    -- 20261007140000 pick the person they act as.
    v_admin := null;
    select u.auth_user_id into v_admin
      from erp.app_user u
     where u.tenant_id = r.id
       and u.kind = 'person'::erp.principal_kind
       and u.status = 'active'::erp.principal_status
       and u.auth_user_id is not null
       and erp.has_permission('procurement.approve', null, null, null, u.id)
       and erp.has_permission('sales.order', null, null, null, u.id)
       and erp.has_permission('finance.approve_payment', null, null, null, u.id)
     order by u.created_at, u.id
     limit 1;
    if v_admin is null then
      raise warning 'testers'' records: nobody in % may clear them, so they are left as they are', r.code;
      continue;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    perform set_config('erp.job_tenant_id', r.id::text, true);
    -- The administrator resolves to the organisation they last chose; it is
    -- made the demonstration for this transaction and put back after.
    select p.active_tenant_id, p.chosen_at into v_pref, v_pref_at
      from erp_meta.principal_preference p
     where p.auth_user_id = v_admin;
    v_had_pref := found;
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
    values (v_admin, r.id, now())
    on conflict (auth_user_id) do update
      set active_tenant_id = excluded.active_tenant_id, chosen_at = excluded.chosen_at;

    v_out := null;
    if erp.current_tenant_id() is distinct from r.id or erp.current_principal_id() is null then
      raise warning 'testers'' records: % does not resolve to its administrator, so they are left as they are', r.code;
    else
      v_out := erp.clear_tester_records();
      -- The checks the writes left waiting, fired while still in the
      -- organisation they read, so the generators below can alter the tables.
      set constraints all immediate;
    end if;

    if v_had_pref then
      update erp_meta.principal_preference
         set active_tenant_id = v_pref, chosen_at = v_pref_at
       where auth_user_id = v_admin;
    else
      delete from erp_meta.principal_preference where auth_user_id = v_admin;
    end if;
    perform set_config('request.jwt.claims', '', true);

    if v_out is not null then
      for e in select x from jsonb_array_elements(v_out -> 'done') x loop
        raise warning 'testers'' records in %: % % % -> % (%)', r.code, e ->> 'kind', e ->> 'number',
          e ->> 'was', e ->> 'now', e ->> 'how';
      end loop;
      for e in select x from jsonb_array_elements(v_out -> 'left') x loop
        raise warning 'testers'' records in %: % % left %: %', r.code, e ->> 'kind', e ->> 'number',
          e ->> 'state', e ->> 'why';
      end loop;
      raise warning 'testers'' records in %: % done, % left; checks failing before: %', r.code,
        v_out ->> 'acted', jsonb_array_length(v_out -> 'left'), v_out -> 'checks_failing_before';
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
select erp.assert_personal_data_register_sound();
