set lock_timeout = '30s';

-- =============================================================================
-- 20260922370000  An order no receipt can reach still finishes
-- -----------------------------------------------------------------------------
-- An adversarial review of M1 (20260922360000), run on a built, seeded
-- database while its pull request was in CI, found five defects in it that it
-- could reproduce. Each was reproduced inside a rolled-back transaction before
-- this was written. M1 is pushed and immutable, so they are fixed here.
--
-- ── 1. Drop-ship and service orders could not leave Sent ────────────────────
--
-- M1 refused receive_all and receive_partial unless posted receipts said so.
-- Two kinds of order can never have a posted receipt:
--
--   * A drop-ship order. The supplier delivers to the customer, and
--     erp.receive_against() refuses a receipt against it by name
--     (CLOVEERP_DROP_SHIP_NOT_RECEIVED).
--   * An order with only service lines. erp.receivable_lines() holds only
--     lines with an item, and no receipt can be raised against the rest.
--
-- The lifecycle declares only receive_all and receive_partial out of Sent, so
-- both kinds were stranded there, by fact and by hand. Before M1 a hand
-- receive_all moved them. It is a regression, and it breaks decision 2's
-- promise that nothing strands. receive_all joins the reason exception for
-- exactly those orders: nothing will ever state the fact for them, so a person
-- states it, with the reason.
--
-- ── 2. A short close after the bill left a settled order Received ───────────
--
-- The bill's hook closes an order when the bill moves. If the bill for the 40
-- that arrived was registered first and the supplier then said nothing more
-- was coming, the short close moved the order to Received with everything
-- billed, and nothing asked again. The door now asks, after any purchase
-- order move that ends in Received.
--
-- ── 3. Settled ignored goods sent back ──────────────────────────────────────
--
-- Take 10 received, 4 returned on a supplier credit note, and 6 billed.
-- erp.grni_report() says nothing is waiting to be billed. erp.order_is_settled()
-- said the order was not settled, because it compared the bill with the gross
-- receipt. It now nets committed returns exactly as the report does.
--
-- ── 4. A reason nobody could read was a reason ──────────────────────────────
--
-- One-argument btrim() strips spaces only, so a tab, a newline or a zero-width
-- space passed as the reason and went on the log. A reason now has to hold a
-- visible character.
--
-- ── 5. The words ─────────────────────────────────────────────────────────────
--
--   * CLOVEERP_ORDER_NOT_RECEIVED told a person on a Sent order to close it
--     short, a move that does not exist from Sent. It now says what the move
--     that was refused needs.
--   * CLOVEERP_ORDER_NOT_SETTLED sent a person whose bill was in dispute to
--     register a bill they had already registered. It now names the dispute.
--   * The three refusals M1 raises are registered in erp_ref.refusal, as its
--     plan said they would be.
--
-- ── WHAT IS DELIBERATELY NOT HERE ────────────────────────────────────────────
--
--   * A derived close made by somebody who may not close. When the bill
--     arrives before the goods, the receipt that completes the order asks to
--     close it as the person who posted the receipt. A warehouse role may not
--     close, so the refusal is recorded and the order waits Received for
--     somebody who may. That is the limitation the approved plan accepted for
--     a bill registered by someone without procurement.order. Lifting it
--     means a derived move taking its authority from the fact rather than from
--     the person, which is a change to who may do what. It is put to the owner
--     as a decision, not made here.
--   * A requisition converted onto an order that was later cancelled still
--     counts that line as converted. erp.convert_document() has always done
--     this, and a requisition whose order is cancelled is out of PR4's scope.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Settled nets what went back
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.order_is_settled(p_order_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Settled: something arrived, every line's posted quantity, less what went
  -- back on a committed supplier credit note, is on a committed bill, and no
  -- difference between them is open. A disputed bill is not committed, so it
  -- settles nothing. A match exception is open until somebody resolves it
  -- (resolved_at), which is the test erp.dispute_unmatched_bill() and the
  -- resolve guard already make.
  --
  -- What went back is counted exactly as erp.grni_report() counts it
  -- (20260922370000): committed credit notes only, reaching the order line
  -- through the receipt line they return. A draft note has posted nothing, so
  -- it takes nothing out.
  --
  -- The bill is found by the line it invoices, not by its type code: a bill
  -- shares its base type with a sales invoice, and only one of the two ever
  -- invoices a purchase order's line. quantity_invoiced is not read, because
  -- it counts draft bills and adds credit notes as though they were bills.
  with lines as (
    select rl.line_id,
           rl.received_quantity - coalesce((
             select sum(rr.quantity)
               from erp.document_relation rr
               join erp.document_relation fr
                 on fr.tenant_id = rr.tenant_id
                and fr.from_line_id = rr.to_line_id
                and fr.relation_kind = 'fulfils'
                and fr.to_line_id = rl.line_id
               join erp.document cn
                 on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
               join erp.object_state os
                 on os.tenant_id = cn.tenant_id
                and os.object_type = 'document' and os.object_id = cn.id
               join erp.state st on st.id = os.current_state_id
              where rr.tenant_id = erp.current_tenant_id()
                and rr.relation_kind = 'returns'
                and rr.to_line_id is not null
                and st.is_committed
                and not coalesce(cn.is_cancelled, false)), 0) as kept_quantity,
           rl.received_quantity,
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
     and not exists (select 1 from lines l where l.billed_quantity < l.kept_quantity)
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
  'every posted receipt quantity less what went back on a committed supplier '
  'credit note is on a committed bill, and no match difference is open '
  '(20260922360000; returns netted as erp.grni_report() nets them at '
  '20260922370000). What closes the order, and what a hand close without a '
  'reason is refused for lacking.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1, 2, 4 and 5. The door
-- ─────────────────────────────────────────────────────────────────────────────

do $door$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_hits integer;
  v_old_dec constant text := $o$  v_fact   boolean;
$o$;
  v_new_dec constant text := $n$  v_fact   boolean;
  v_said   boolean;
$n$;
  v_old_guard constant text := $o$    if not coalesce(v_fact, false)
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
$o$;
  v_new_guard constant text := $n$    -- A reason is something a person can read (20260922370000). One-argument
    -- btrim() strips spaces only, so a tab, a newline or a zero-width space
    -- passed as one.
    v_said := coalesce(p_reason, '') ~ '[^[:space:][:cntrl:] ​⁠﻿　]';

    -- receive_all joins the exception for an order no receipt can ever reach
    -- (20260922370000): a drop-ship, which the supplier delivers to the
    -- customer and erp.receive_against() refuses by name, and an order of
    -- services, which erp.receivable_lines() does not hold. Nothing will ever
    -- state the fact for them, so a person states it, with the reason.
    if not coalesce(v_fact, false)
       and not (v_said
                and (p_transition_code in ('receive_rest', 'close')
                     or (p_transition_code = 'receive_all'
                         and (coalesce(d.order_behaviour_code, '') = 'drop_ship'
                              or not exists (select 1 from erp.receivable_lines(p_document_id))))))
    then
      if p_transition_code = 'close'
         and (exists (select 1
                        from erp.match_exception x
                        join erp.document_line ol
                          on ol.tenant_id = x.tenant_id and ol.id = x.order_line_id
                       where x.tenant_id = v_tenant and ol.document_id = p_document_id
                         and x.resolved_at is null)
              or exists (select 1
                           from erp.document_relation rel
                           join erp.document_line ol
                             on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
                           join erp.document b
                             on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
                          where rel.tenant_id = v_tenant and ol.document_id = p_document_id
                            and rel.relation_kind = 'invoices' and not b.is_cancelled
                            and erp.object_current_state('document', b.id) = 'disputed'))
      then
        raise exception
          'CLOVEERP_ORDER_NOT_SETTLED: % has a bill whose difference nobody has accepted yet',
          coalesce(d.document_number, p_document_id::text)
          using errcode = '23514',
                hint = 'Accept the difference on the match workbench once the people asked ' ||
                       'have approved it, or ask the supplier for a credit note. The order ' ||
                       'closes itself when its bill is settled.';
      elsif p_transition_code = 'close' then
        raise exception
          'CLOVEERP_ORDER_NOT_SETTLED: % has goods on it that no registered bill covers',
          coalesce(d.document_number, p_document_id::text)
          using errcode = '23514',
                hint = 'Register the supplier''s bill from the goods receipt and the order ' ||
                       'closes itself. If that bill is kept somewhere else, close the order ' ||
                       'with the reason.';
      elsif p_transition_code = 'receive_rest' then
        raise exception
          'CLOVEERP_ORDER_NOT_RECEIVED: % cannot be marked %: its posted receipts do not say so',
          coalesce(d.document_number, p_document_id::text), p_transition_code
          using errcode = '23514',
                hint = 'Post the goods receipt for what arrived and the order moves itself. ' ||
                       'If the supplier will send nothing more, close it short with the reason.';
      else
        raise exception
          'CLOVEERP_ORDER_NOT_RECEIVED: % cannot be marked %: its posted receipts do not say so',
          coalesce(d.document_number, p_document_id::text), p_transition_code
          using errcode = '23514',
                hint = 'Post the goods receipt for what arrived and the order moves itself. ' ||
                       'An order no receipt can be raised against, a drop-ship or one of ' ||
                       'services, is marked received in full with the reason.';
      end if;
    end if;
$n$;
  v_old_hook constant text := $o$  if dt.base_type_code = 'invoice_reference' then
    perform erp.close_orders_billed_by(p_document_id);
  end if;
$o$;
  v_new_hook constant text := $n$  if dt.base_type_code = 'invoice_reference' then
    perform erp.close_orders_billed_by(p_document_id);
  end if;

  -- And an order that has just reached Received may already be billed for
  -- everything that came: a person's short close after the bill, most of all
  -- (20260922370000). erp.close_order_when_settled() reads the order afresh
  -- and does nothing to one that is not received and settled.
  if dt.base_type_code = 'purchase_order' and v_to = 'received' then
    perform erp.close_order_when_settled(p_document_id, 'Received, and billed already');
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
    raise exception 'CLOVEERP_ANCHOR_MOVED: % hook anchor found % time(s)', v_sig, v_hits;
  end if;

  execute replace(replace(replace(v_def, v_old_dec, v_new_dec),
                          v_old_guard, v_new_guard),
                  v_old_hook, v_new_hook);
end
$door$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The refusals, registered
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_ORDER_NOT_RECEIVED',
  'Marking a purchase order received, in part or in full, when its posted goods receipts do not say so.',
  'Received is what the goods-in desk has posted, not a label on the order. Goods received but not invoiced, stock and the supplier''s bill are all measured from the receipts; an order marked received over nothing tells the person reading it something every one of those contradicts.',
  'Post the goods receipt for what arrived and the order moves itself. If the supplier will send nothing more, close it short with the reason. An order no receipt can be raised against, a drop-ship or one of services, is marked received in full with the reason.');

select erp.register_refusal('CLOVEERP_ORDER_NOT_SETTLED',
  'Closing a received purchase order when no committed bill covers what arrived, without saying why.',
  'Closed means nothing more is expected on the order: no goods and no bill. An order closed with its bill still to come is how goods received but not invoiced stays on the balance sheet with nothing left to clear it.',
  'Register the supplier''s bill from the goods receipt, or settle the difference on a disputed one, and the order closes itself. If the bill is kept somewhere else, close the order with the reason.');

select erp.register_refusal('CLOVEERP_REQUISITION_NOT_CONVERTED',
  'Marking a requisition ordered when no purchase order was raised from all of it.',
  'Ordered tells the person who asked for the goods that a supplier has been asked for them. A requisition marked ordered with no order behind it is a promise nobody made, and the outstanding quantity on it disappears from every list that would have raised the order.',
  'Convert it into a purchase order. It reads Ordered once every line is on an order raised from it.');

-- ─────────────────────────────────────────────────────────────────────────────
-- What proves it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.derived_order_edges_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_uom uuid; v_sup uuid; v_cus uuid; v_item uuid;
  v_so uuid; v_ds uuid;
  v_svc uuid;
  v_a uuid; v_al uuid; v_ga uuid;
  v_r uuid; v_rl uuid; v_gr uuid; v_grl uuid; v_cn uuid; v_bill uuid; x record; t record;
  v_w uuid; v_wl uuid; v_gw uuid;
  v_ok boolean; v_msg text; v_st text; v_hint text;
begin
  begin
    select p.tenant_id, p.admin_user_id, p.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzdoe', 'Derived Order Edges Suite', 'admin@zzdoe.test', 'Edges Admin') p;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzdoe.test');
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
    values (v_tenant, 'ZSUP', 'Edges Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZCUS', 'Edges Customer', 'active') returning id into v_cus;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_cus, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (v_tenant, 'ZWID', 'Edges Widget', v_uom, 100, 'active') returning id into v_item;

    -- 1. A drop-ship. No receipt can reach it, so a person marks it received,
    --    and only with a reason.
    v_so := erp.open_document('sales_order', v_cus, v_entity, v_site);
    perform erp.add_document_line(v_so, v_item, 5, 2000, 'five, delivered by the supplier');
    v_ds := erp.raise_drop_ship_order(v_so, v_sup);
    -- Raised at no price (the supplier's is agreed afterwards), and an order
    -- sent at no price has nothing to commit, so it is priced first.
    update erp.document_line
       set unit_price_minor = 1500, net_minor = round(quantity * 1500)::bigint
     where tenant_id = v_tenant and document_id = v_ds;
    perform erp.transition_document(v_ds, 'submit', null);
    if erp.object_current_state('document', v_ds) = 'pending_approval' then
      perform erp_test.approve_document(v_ds, null);
    end if;
    perform erp.transition_document(v_ds, 'send', null);
    perform erp.confirm_drop_ship(v_ds, current_date, 'POD-1');
    begin
      perform erp.transition_document(v_ds, 'receive_all', null);
      v_ok := false; v_msg := 'a drop-ship was marked received with no reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%'; v_msg := left(sqlerrm, 90);
    end;
    if v_ok then
      v_st := erp.transition_document(v_ds, 'receive_all', 'Delivered to the customer on the supplier''s word');
      v_msg := v_st;
    end if;
    return query select 'a drop-ship leaves Sent when a person says it was delivered, and only then',
      v_ok and v_st = 'received', v_msg;

    -- 2. An order of services, which no receipt can reach either.
    v_svc := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_svc, null, 1, 50000, 'Annual calibration visit');
    perform erp.transition_document(v_svc, 'submit', null);
    if erp.object_current_state('document', v_svc) = 'pending_approval' then
      perform erp_test.approve_document(v_svc, null);
    end if;
    perform erp.transition_document(v_svc, 'send', null);
    v_ok := true; v_msg := '';
    begin
      perform erp.transition_document(v_svc, 'receive_all', E'\t');
      v_ok := false; v_msg := 'a tab was taken for a reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_RECEIVED:%';
    end;
    v_st := erp.transition_document(v_svc, 'receive_all', 'The visit happened on the day');
    return query select 'an order of services is marked received with a reason, and a tab is not one',
      v_ok and v_st = 'received', coalesce(nullif(v_msg, ''), v_st);

    -- 3. Billed first for what arrived, then closed short: the order closes.
    v_a := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_al := erp.add_document_line(v_a, v_item, 100, 1000, 'a hundred');
    perform erp.transition_document(v_a, 'submit', null);
    perform erp_test.approve_document(v_a, null);
    perform erp.transition_document(v_a, 'send', null);
    v_ga := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_ga, v_al, 40, null);
    perform erp.transition_document(v_ga, 'post', null);
    perform erp.bill_from_receipt(v_ga, 'ZDOE-1', current_date, current_date + 30, true);
    v_st := erp.object_current_state('document', v_a);
    perform erp.transition_document(v_a, 'receive_rest', 'The supplier has discontinued it');
    return query select 'an order billed for what came and then closed short closes',
      v_st = 'partially_received' and erp.object_current_state('document', v_a) = 'closed',
      format('%s after the bill, %s after the short close', v_st, erp.object_current_state('document', v_a));

    -- 4. Ten received, four sent back on a credit note, six billed. Nothing is
    --    waiting to be billed, and the order closes.
    v_r := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_rl := erp.add_document_line(v_r, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp_test.approve_document(v_r, null);
    perform erp.transition_document(v_r, 'send', null);
    v_gr := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    v_grl := erp.receive_against(v_gr, v_rl, 10, null);
    perform erp.transition_document(v_gr, 'post', null);
    v_cn := erp.raise_supplier_credit_note(v_gr, 'DAMAGED', 'four arrived broken',
              jsonb_build_array(jsonb_build_object('line_id', v_grl, 'quantity', 4)));
    perform erp.transition_document(v_cn, 'issue', null);
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_rl, 6, 1000);
    update erp.document set their_reference = 'ZDOE-2', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    perform erp.transition_document(v_bill, 'register', null);
    -- The match compares the bill with the gross receipt, so the six dispute;
    -- the difference is approved and accepted, as the workbench does it.
    for x in select * from erp.match_exception mx
              where mx.tenant_id = v_tenant and mx.invoice_document_id = v_bill and mx.resolved_at is null
    loop
      if x.approval_request_id is not null then
        for t in select tk.id from erp.approval_task tk
                  where tk.approval_request_id = x.approval_request_id and tk.status = 'pending'
        loop
          perform erp.decide_approval_task(t.id, true, 'the rest went back on a credit note');
        end loop;
      end if;
      perform erp.accept_match_exception(x.id, 'the rest went back on a credit note');
    end loop;
    return query select 'goods sent back are not waiting to be billed: the bill for the rest closes the order',
      erp.object_current_state('document', v_r) = 'closed'
      and not exists (select 1 from erp.grni_report() g where g.order_line_id = v_rl),
      format('bill %s, order %s', erp.object_current_state('document', v_bill),
             erp.object_current_state('document', v_r));

    -- 5. A reason nobody can read closes nothing.
    v_w := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_wl := erp.add_document_line(v_w, v_item, 5, 1000, 'five');
    perform erp.transition_document(v_w, 'submit', null);
    perform erp_test.approve_document(v_w, null);
    perform erp.transition_document(v_w, 'send', null);
    v_gw := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_gw, v_wl, 5, null);
    perform erp.transition_document(v_gw, 'post', null);
    v_ok := true;
    begin
      perform erp.transition_document(v_w, 'close', E'\n');
      v_ok := false;
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_SETTLED:%';
    end;
    begin
      perform erp.transition_document(v_w, 'close', U&'\200B\00A0\3000');
      v_ok := false;
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_ORDER_NOT_SETTLED:%';
    end;
    return query select 'a newline or a run of invisible spaces is not a reason',
      v_ok and erp.object_current_state('document', v_w) = 'received',
      erp.object_current_state('document', v_w);

    -- 6. A disputed bill is named, not a bill to register again.
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_wl, 5, 2000);
    update erp.document set their_reference = 'ZDOE-3', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_st := erp.transition_document(v_bill, 'register', null);
    v_hint := null;
    begin
      perform erp.transition_document(v_w, 'close', null);
      v_ok := false; v_msg := 'an order with a disputed bill was closed with no reason';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_ok := sqlerrm like 'CLOVEERP_ORDER_NOT_SETTLED:%nobody has accepted%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'an order whose bill is in dispute is told to settle the dispute',
      v_st = 'disputed' and v_ok and v_hint like '%match workbench%', v_msg;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzdoe');
  detail := 'the organisation, its orders and its bills rolled back';
  return next;
end;
$$;

comment on function erp_test.derived_order_edges_suite() is
  'The orders M1''s review found stranded or mis-stated (20260922370000): a '
  'drop-ship and an order of services leave Sent with a reason, a short close '
  'after the bill closes the order, goods sent back are netted, an invisible '
  'reason is no reason, and a disputed bill is named.';

create or replace function erp_test.assert_derived_order_edges_suite()
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
    from erp_test.derived_order_edges_suite() s;

  if v_total <> 7 then
    raise exception 'CLOVEERP_DERIVED_ORDER_EDGES_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_DERIVED_ORDER_EDGES_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An order stranded in a state, or told the wrong way out of it, is the defect this suite exists for. Read the case that failed.';
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
select erp.assert_every_transition_is_driven();
