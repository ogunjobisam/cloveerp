set lock_timeout = '30s';

-- =============================================================================
-- 20261010190000  A returned receipt bills what was kept
-- -----------------------------------------------------------------------------
-- Found checking the demonstration after 20261010180000 was released on
-- 7 October. Its customers were tidied, but its suppliers were not: still 58
-- receipt lines received and never billed, the oldest 401 days, £202,479.
-- The tidy and the catch-up both skip any receipt with goods sent back
-- against it, and the oldest of the 58 (PO-000010, GRN-000009) has a supplier
-- credit note (PCN-000001) against it. On the build's seeded organisation 17
-- of its 55 receipts have goods sent back.
--
-- They skip them because billing one was wrong, and it is wrong in the
-- product too, not only in a demonstration. Bill a receipt bills everything
-- the receipt brought in. A credit note issued before any bill has already
-- taken the goods it sends back out of goods received not invoiced (its rule
-- debits that account with what nobody billed, 20261004910000). So the bill
-- took them out a second time. On a copy of the seeded organisation, billing
-- its 17 receipts that way left the account £6,966.10 below the open
-- receipts, exactly what the credit notes had sent back, and
-- erp.assert_grni_reconciles() refused.
--
-- The owner's rule (1 October) is that a credit note issued after the bill
-- falls on the bill. Before the bill there is no bill for it to fall on, so
-- the bill that follows is for what was kept.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.receipt_line_returned(tenant, receipt line): how much of a
--      receipt line has gone back on a credit note that is issued and not
--      cancelled. That is the same count erp.grni_report() makes.
--   B. erp.bill_from_receipt() bills each order line for what the receipt
--      brought in less what went back, and leaves off a line that all went
--      back. A receipt that all went back is refused with
--      CLOVEERP_RECEIPT_ALL_RETURNED rather than the misleading "not received
--      against an order". A credit note still in draft takes nothing off: if
--      it is issued after the bill, it falls on the bill, as it always has.
--   C. erp.tidy_demonstration_books() and erp.demonstration_catch_up() bill a
--      receipt with goods sent back, for what was kept, instead of skipping it
--      for ever. A receipt that went back whole is still skipped.
--   D. erp_test.tidy_demonstration_books_suite counted the receipts left
--      unbilled with the same skip, so it passed while the demonstration did
--      not. It now counts every receipt with something kept.
--   E. erp_test.returned_receipt_bill_suite proves it.
--
-- Production: no data changes. The next bill raised from a part-returned
-- receipt is for what was kept. On the demonstration project, the next
-- catch-up's tidy bills the receipts it skipped.
--
-- Proof: erp_test.returned_receipt_bill_suite.
-- =============================================================================

-- ── A. What went back ────────────────────────────────────────────────────────

create or replace function erp.receipt_line_returned(p_tenant_id uuid, p_receipt_line_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- Counted from credit notes that are issued and not cancelled, as
  -- erp.grni_report() counts them: a draft has posted nothing, so it has
  -- taken nothing out of goods received not invoiced.
  select coalesce(sum(rr.quantity), 0)
    from erp.document_relation rr
    join erp.document cn
      on cn.tenant_id = rr.tenant_id and cn.id = rr.from_document_id
    join erp.object_state os
      on os.tenant_id = cn.tenant_id and os.object_type = 'document' and os.object_id = cn.id
    join erp.state st on st.id = os.current_state_id
   where rr.tenant_id = p_tenant_id
     and rr.to_line_id = p_receipt_line_id
     and rr.relation_kind = 'returns'
     and st.is_committed
     and not coalesce(cn.is_cancelled, false)
$$;

revoke all on function erp.receipt_line_returned(uuid, uuid) from public, anon;

comment on function erp.receipt_line_returned(uuid, uuid) is
  'How much of a goods receipt line has gone back to the supplier on a credit note that is issued and not cancelled '
  '(20261010190000). The same count erp.grni_report() makes.';

-- ── B. Bill a receipt bills what was kept ────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_RECEIPT_ALL_RETURNED',
  'Billing a goods receipt whose goods have all gone back to the supplier.',
  'The credit note that sent them back has already taken them out of goods received not invoiced. A bill for them '
  'would take them out a second time, and the supplier would be paid for goods they have back.',
  'Nothing is owed for this receipt. If the supplier has sent a bill for it anyway, record their credit note against '
  'that bill instead.');

do $bill_from_receipt$
declare
  v_sig  constant text := 'erp.bill_from_receipt(uuid, text, date, date, boolean, bigint, text)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  for r in
    select rel.to_line_id as order_line_id, sum(rel.quantity) as qty
      from erp.document_relation rel
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_receipt_id
       and rel.relation_kind = 'fulfils'
       and rel.to_line_id is not null
     group by rel.to_line_id
  loop$o$;
  v_new1 constant text := $n$  --
  -- Less what went back on a credit note that is issued (20261010190000):
  -- that note has already taken those goods out of goods received not
  -- invoiced, so a bill for them would take them out twice. A line that all
  -- went back is left off.
  for r in
    select rel.to_line_id as order_line_id,
           sum(rel.quantity - erp.receipt_line_returned(v_tenant, rel.from_line_id)) as qty
      from erp.document_relation rel
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_receipt_id
       and rel.relation_kind = 'fulfils'
       and rel.to_line_id is not null
     group by rel.to_line_id
    having sum(rel.quantity - erp.receipt_line_returned(v_tenant, rel.from_line_id)) > 0
  loop$n$;
  v_old2 constant text := $o$  if v_lines = 0 then
    raise exception 'CLOVEERP_RECEIPT_HAS_NO_ORDER_LINES:$o$;
  v_new2 constant text := $n$  if v_lines = 0 and exists (select 1 from erp.document_relation rel
                                where rel.tenant_id = v_tenant
                                  and rel.from_document_id = p_receipt_id
                                  and rel.relation_kind = 'fulfils'
                                  and rel.to_line_id is not null) then
    raise exception 'CLOVEERP_RECEIPT_ALL_RETURNED: everything % brought in has gone back to the supplier, so there is nothing to bill',
      rd.document_number
      using errcode = '23514',
            hint = 'Nothing is owed for this receipt. If the supplier has sent a bill for it anyway, record their credit note against that bill instead.';
  end if;

  if v_lines = 0 then
    raise exception 'CLOVEERP_RECEIPT_HAS_NO_ORDER_LINES:$n$;
  n integer;
begin
  if position('erp.receipt_line_returned(' in v_def) > 0 then
    raise notice '% already bills what was kept; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % line loop found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no-lines refusal found % time(s)', v_sig, n;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$bill_from_receipt$;

-- ── C. The demonstration bills a part-returned receipt ───────────────────────

do $tidy_demonstration_books$
declare
  v_sig  constant text := 'erp.tidy_demonstration_books(date, boolean)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$       -- Nothing on its way back to the supplier.
       and not exists (select 1 from erp.document_line gl
                         join erp.document_relation rr
                           on rr.tenant_id = gl.tenant_id and rr.to_line_id = gl.id and rr.relation_kind = 'returns'
                        where gl.tenant_id = d.tenant_id and gl.document_id = d.id)$o$;
  v_new  constant text := $n$       -- Something of it kept (20261010190000). Bill a receipt bills what was
       -- kept, so goods sent back no longer keep a receipt from being billed;
       -- one sent back whole has nothing to bill.
       and exists (select 1 from erp.document_relation kr
                    where kr.tenant_id = d.tenant_id and kr.from_document_id = d.id
                      and kr.relation_kind = 'fulfils' and kr.to_line_id is not null
                      and kr.quantity > erp.receipt_line_returned(d.tenant_id, kr.from_line_id))$n$;
  n integer;
begin
  if position('erp.receipt_line_returned(' in v_def) > 0 then
    raise notice '% already bills what was kept; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % returns clause found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$tidy_demonstration_books$;

do $demonstration_catch_up$
declare
  v_sig  constant text := 'erp.demonstration_catch_up()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$         -- Nothing on its way back to the supplier: billing for goods that were
         -- returned is how a demonstration acquires a credit balance nobody can
         -- explain.
         and not exists (select 1 from erp.document_line gl
                           join erp.document_relation rr
                             on rr.tenant_id = gl.tenant_id
                            and rr.to_line_id = gl.id
                            and rr.relation_kind = 'returns'
                          where gl.tenant_id = d.tenant_id
                            and gl.document_id = d.id)
$o$;
  v_new  constant text := $n$         -- Something of it kept (20261010190000). Bill a receipt bills what
         -- was kept, so goods sent back no longer keep a receipt from being
         -- billed; one sent back whole has nothing to bill.
         and exists (select 1 from erp.document_relation kr
                      where kr.tenant_id = d.tenant_id
                        and kr.from_document_id = d.id
                        and kr.relation_kind = 'fulfils'
                        and kr.to_line_id is not null
                        and kr.quantity > erp.receipt_line_returned(d.tenant_id, kr.from_line_id))
$n$;
  n integer;
begin
  if position('erp.receipt_line_returned(' in v_def) > 0 then
    raise notice '% already bills what was kept; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % returns clause found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$demonstration_catch_up$;

-- ── D. The tidy's own suite counts what was kept ─────────────────────────────

do $tidy_suite$
declare
  v_sig  constant text := 'erp_test.tidy_demonstration_books_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$       and not exists (select 1 from erp.document_line gl
                         join erp.document_relation rr on rr.tenant_id = gl.tenant_id and rr.to_line_id = gl.id
                          and rr.relation_kind = 'returns'
                        where gl.tenant_id = d.tenant_id and gl.document_id = d.id);$o$;
  v_new  constant text := $n$       -- Every receipt with something kept (20261010190000): skipping those
       -- with goods sent back is how this case passed while the
       -- demonstration's were never billed.
       and exists (select 1 from erp.document_relation kr
                    where kr.tenant_id = d.tenant_id and kr.from_document_id = d.id
                      and kr.relation_kind = 'fulfils' and kr.to_line_id is not null
                      and kr.quantity > erp.receipt_line_returned(d.tenant_id, kr.from_line_id));$n$;
  n integer;
begin
  if position('erp.receipt_line_returned(' in v_def) > 0 then
    raise notice '% already counts what was kept; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % unbilled count found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$tidy_suite$;

-- ── E. The proof ─────────────────────────────────────────────────────────────

create or replace function erp_test.returned_receipt_bill_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_scn uuid; v_bill uuid;
  v_pol1 uuid;
  v_qty numeric; v_open numeric; v_recon text;
  v_err text; v_hint text; v_bills_before integer; v_bills_after integer;
  v_res jsonb;
begin
  begin
    v_step := 'a demonstration organisation with finance, procurement, inventory and controls';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzkpt' || v_tag, 'Returned Receipt Suite',
      'admin@demo-zzkpt' || v_tag || '.test', 'Returned Receipt Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzkpt' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_step := 'its own unit, site, places, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZKEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZKSITE', 'Returned receipt suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZK-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZK-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZKSUP', 'Returned Receipt Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZKWID', 'Returned Receipt Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── 1. A hundred in, ten back, ninety billed ────────────────────────────
    v_step := 'a hundred received, ten sent back on an issued credit note, then billed from the receipt';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol1 := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'returned receipt suite');
    perform erp_test.approve_document(v_po, 'returned receipt suite');
    perform erp.transition_document(v_po, 'send', 'returned receipt suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol1, 100, null);
    perform erp.transition_document(v_grn, 'post', 'returned receipt suite');
    v_scn := erp.raise_supplier_credit_note(
      v_grn, 'DAMAGED_ARRIVAL', 'Crushed on the pallet',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn order by l.line_no limit 1),
        'quantity', 10)));
    perform erp.transition_document(v_scn, 'issue', 'returned receipt suite');
    v_bill := erp.bill_from_receipt(v_grn, 'ZK-ONE', current_date, current_date + 30);
    select sum(l.quantity) into v_qty from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_bill;

    v_cases := v_cases + 1;
    case_name := 'a receipt of a hundred with ten sent back on an issued credit note is billed for the ninety kept';
    passed := v_state is null and v_qty = 90;
    detail := format('the bill is for %s', coalesce(v_qty::text, 'nothing'));
    return next;

    -- ── 2. And the account agrees ───────────────────────────────────────────
    v_step := 'goods received not invoiced after that bill';
    select coalesce(sum(g.open_quantity), 0) into v_open
      from erp.grni_report() g where g.order_line_id = v_pol1;
    begin
      v_recon := erp.assert_grni_reconciles();
    exception when others then
      v_recon := 'refused: ' || left(sqlerrm, 300);
    end;

    v_cases := v_cases + 1;
    case_name := 'nothing of that order is left open in goods received not invoiced, and the account still agrees with the ledger';
    passed := v_state is null and v_open = 0 and v_recon not like 'refused:%';
    detail := format('%s open; %s', v_open, v_recon);
    return next;

    -- ── 3. A draft takes nothing off; issued after, it falls on the bill ────
    v_step := 'fifty received, five on a credit note left in draft, billed, then the note issued';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 50, 1000, 'fifty at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'returned receipt suite');
    perform erp_test.approve_document(v_po, 'returned receipt suite');
    perform erp.transition_document(v_po, 'send', 'returned receipt suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 50, null);
    perform erp.transition_document(v_grn, 'post', 'returned receipt suite');
    v_scn := erp.raise_supplier_credit_note(
      v_grn, 'DAMAGED_ARRIVAL', 'Dented, still being argued about',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn order by l.line_no limit 1),
        'quantity', 5)));
    v_bill := erp.bill_from_receipt(v_grn, 'ZK-TWO', current_date, current_date + 30);
    select sum(l.quantity) into v_qty from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_bill;
    perform erp.transition_document(v_scn, 'issue', 'returned receipt suite');
    begin
      v_recon := erp.assert_grni_reconciles();
    exception when others then
      v_recon := 'refused: ' || left(sqlerrm, 300);
    end;

    v_cases := v_cases + 1;
    case_name := 'a credit note still in draft takes nothing off the bill, and issued after it the accounts still agree';
    passed := v_state is null and v_qty = 50 and v_recon not like 'refused:%';
    detail := format('the bill is for %s; %s', coalesce(v_qty::text, 'nothing'), v_recon);
    return next;

    -- ── 4. All of it back ───────────────────────────────────────────────────
    v_step := 'twenty received and all twenty sent back on an issued credit note';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 20, 1000, 'twenty at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'returned receipt suite');
    perform erp_test.approve_document(v_po, 'returned receipt suite');
    perform erp.transition_document(v_po, 'send', 'returned receipt suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 20, null);
    perform erp.transition_document(v_grn, 'post', 'returned receipt suite');
    v_scn := erp.raise_supplier_credit_note(
      v_grn, 'WRONG_ITEM', 'Not what was ordered',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn order by l.line_no limit 1),
        'quantity', 20)));
    perform erp.transition_document(v_scn, 'issue', 'returned receipt suite');
    select count(*) into v_bills_before from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.code = 'purchase_invoice';
    begin
      perform erp.bill_from_receipt(v_grn, 'ZK-THREE', current_date, current_date + 30);
      v_err := 'billed';
    exception when others then
      v_err := sqlerrm;
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    select count(*) into v_bills_after from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.code = 'purchase_invoice';

    v_cases := v_cases + 1;
    case_name := 'a receipt sent back whole is refused a bill, says what to do instead, and raises nothing';
    passed := v_state is null
          and v_err like 'CLOVEERP_RECEIPT_ALL_RETURNED:%'
          and coalesce(v_hint, '') <> ''
          and v_bills_after = v_bills_before;
    detail := left(format('%s | hint: %s | bills %s then %s', v_err, v_hint, v_bills_before, v_bills_after), 600);
    return next;

    -- ── 5. The demonstration's tidy bills it ────────────────────────────────
    v_step := 'forty received, fifteen sent back, then the books tidied a week on';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 40, 1000, 'forty at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'returned receipt suite');
    perform erp_test.approve_document(v_po, 'returned receipt suite');
    perform erp.transition_document(v_po, 'send', 'returned receipt suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 40, null);
    perform erp.transition_document(v_grn, 'post', 'returned receipt suite');
    v_scn := erp.raise_supplier_credit_note(
      v_grn, 'DAMAGED_ARRIVAL', 'Wet through',
      jsonb_build_array(jsonb_build_object(
        'line_id', (select l.id from erp.document_line l
                     where l.tenant_id = rb.tenant_id and l.document_id = v_grn order by l.line_no limit 1),
        'quantity', 15)));
    perform erp.transition_document(v_scn, 'issue', 'returned receipt suite');
    -- A week on, when the tidy takes a receipt to be a week old.
    v_res := erp.tidy_demonstration_books(current_date + 7, true);
    select sum(l.quantity) into v_qty
      from erp.document_relation r
      join erp.document b on b.tenant_id = r.tenant_id and b.id = r.from_document_id
      join erp.document_line l on l.tenant_id = b.tenant_id and l.document_id = b.id
     where r.tenant_id = rb.tenant_id and r.to_document_id = v_grn and r.relation_kind = 'invoices'
       and not b.is_cancelled;

    v_cases := v_cases + 1;
    case_name := 'a demonstration''s tidy bills a receipt with goods sent back, for what was kept, and skips the one sent back whole';
    passed := v_state is null
          and (v_res ->> 'tidied')::boolean
          and v_qty = 25
          and coalesce((v_res ->> 'bills')::integer, 0) = 1
          and coalesce((v_res ->> 'bills_refused')::integer, 0) = 0;
    detail := format('billed for %s; %s', coalesce(v_qty::text, 'nothing'), v_res);
    return next;

    -- ── 6. The catch-up's own pass reads the same ───────────────────────────
    v_step := 'the catch-up''s billing pass';
    v_cases := v_cases + 1;
    case_name := 'the catch-up''s own billing pass asks what was kept, not whether anything went back';
    passed := v_state is null
          and position('erp.receipt_line_returned(' in pg_catalog.pg_get_functiondef('erp.demonstration_catch_up()'::regprocedure)) > 0
          and position('Nothing on its way back to the supplier' in pg_catalog.pg_get_functiondef('erp.demonstration_catch_up()'::regprocedure)) = 0;
    detail := 'erp.demonstration_catch_up() selects receipts with something kept';
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzkpt' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'demo-zzkpt rolled back with its orders, receipts, credit notes and bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_RETURNED_RECEIPT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_returned_receipt_bill_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _returned_receipt_bill on commit drop as
    select * from erp_test.returned_receipt_bill_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _returned_receipt_bill;
  drop table _returned_receipt_bill;
  if v_fail > 0 then
    raise exception E'CLOVEERP_RETURNED_RECEIPT_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_RETURNED_RECEIPT_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a returned receipt bills what was kept: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.returned_receipt_bill_suite() from public, anon;
revoke all on function erp_test.assert_returned_receipt_bill_suite() from public, anon;

comment on function erp_test.returned_receipt_bill_suite() is
  'A returned receipt bills what was kept (20261010190000): Bill a receipt bills what a receipt brought in less what '
  'went back on an issued credit note, refuses a receipt sent back whole, leaves a draft credit note to fall on the '
  'bill, keeps goods received not invoiced agreeing with the ledger, and a demonstration''s tidy and catch-up bill '
  'such a receipt instead of skipping it.';

comment on function erp_test.assert_returned_receipt_bill_suite() is
  'erp_test.returned_receipt_bill_suite(), seven cases.';

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
