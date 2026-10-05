set lock_timeout = '30s';

-- =============================================================================
-- 20261006131000  A draft goods receipt receives nothing
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-13). A goods receipt
-- still in draft counted as received. erp.refresh_order_line_progress()
-- wrote an order line's quantity_fulfilled from every receipt not cancelled,
-- posted or not, while the ledger credits goods received not invoiced only
-- when the receipt posts. erp.grni_report() reads quantity_fulfilled, so
-- "Received, not yet billed" and the close's erp.assert_grni_reconciles()
-- ran ahead of the ledger for as long as a draft lay about. On live, two
-- draft receipt lines for four units, all in the demonstration.
--
-- The owner decided (4 October): a draft goods receipt receives nothing.
-- Only posted receipts count, as deliveries already do.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.refresh_order_line_progress(): the receipt branch of
--      quantity_fulfilled counts receipts raised against the line that are
--      committed (posted) and not cancelled, in the delivery branch's shape.
--      Committed, not the state code 'posted', because erp.receivable_lines()
--      and erp.order_receipt_position() already decide "received" by it, so
--      the three cannot disagree. quantity_invoiced is untouched.
--   B. erp.grni_report(): the day a line was received (the ageing date) is
--      the earliest posted receipt's, not the earliest receipt of any state.
--   C. The suites that billed or read what arrived before the receipt was
--      posted now post it first; the rule is not loosened for any of them.
--      erp_test.draft_line_suite, which read what a draft receipt line holds
--      in quantity_fulfilled, reads it through erp.order_line_on_receipts().
--      erp_test.cancelled_receipt_suite proves the rule.
--   D. Every order line a draft receipt was raised against is read again, in
--      every organisation, and the migration says how many changed.
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- A draft still HOLDS what it carries, so nothing is offered twice: Receive
-- this order, the receipt's order-line picker and erp.receive_against()'s
-- tolerance read the receipts themselves (erp.receivable_lines), and the
-- shipping notice, the supplier's link and cancelling a sent order read
-- erp.order_line_on_receipts() (20261006130000). Posting a receipt already
-- reads its orders' lines again (erp.transition_document ->
-- erp.advance_orders_for_receipt), and cancelling one does (20261005800000).
--
-- Readers of quantity_fulfilled that become posted-only with no edit, and are
-- right to: three-way matching (a bill is compared with what posted), the
-- received-not-billed report and its reconciliation, the order status and
-- supplier performance views, and planning's supply (a draft's goods are not
-- on hand yet, so they count as still coming).
--
-- Production: D reads again the order lines a draft goods receipt was raised
-- against (on live, two lines for four units, in the demonstration). Their
-- quantity_fulfilled drops by what the draft carries; nothing else changes,
-- and nothing is posted, matched or sent.
--
-- Proof: erp_test.cancelled_receipt_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What a receipt receives
-- ═════════════════════════════════════════════════════════════════════════════

do $progress$
declare
  v_sig  constant text := 'erp.refresh_order_line_progress(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$     set quantity_fulfilled = coalesce((
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document rd on rd.id = rel.from_document_id
             join erp.document_type rdt on rdt.id = rd.document_type_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled
              -- Nor one its lifecycle cancelled, whose flag stays as it was
              -- (20261005800000), as erp.receivable_lines() already reads.
              and not exists (select 1
                                from erp.object_state ros
                                join erp.state rs on rs.id = ros.current_state_id
                               where ros.tenant_id = rd.tenant_id
                                 and ros.object_type = 'document'
                                 and ros.object_id = rd.id
                                 and rs.code = 'cancelled')), 0)
$o$;
  v_new  constant text := $n$     set quantity_fulfilled = coalesce((
           -- What posted receipts raised against the line received
           -- (20261006131000; owner, 4 October). A draft receipt holds what
           -- it carries (erp.receivable_lines, erp.order_line_on_receipts)
           -- and receives nothing until it posts, as a delivery delivers
           -- nothing until it posts. A cancelled one, by its flag or by its
           -- lifecycle (20261005800000), is not committed.
           select sum(rel.quantity)
             from erp.document_relation rel
             join erp.document rd
               on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
             join erp.document_type rdt
               on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
             join erp.object_state ros
               on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
             join erp.state rs on rs.id = ros.current_state_id
            where rel.tenant_id = v_tenant
              and rel.to_line_id = ol.id
              and rel.relation_kind = 'fulfils'
              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled
              and rs.is_committed), 0)
$n$;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already counts posted receipts only; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '91952d819f7ba78bcdac9f33beaa9db5' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$progress$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The day it was received
-- ═════════════════════════════════════════════════════════════════════════════

do $grni$
declare
  v_sig  constant text := 'erp.grni_report()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$                else (select min(rd.document_date)
                        from erp.document_relation rel
                        join erp.document rd on rd.id = rel.from_document_id
                        join erp.document_type rdt on rdt.id = rd.document_type_id
                       where rel.to_line_id = ol.id and rdt.base_type_code = 'receipt')
$o$;
  v_new  constant text := $n$                -- The day of the first posted receipt (20261006131000): a
                -- draft or a cancelled one received nothing.
                else (select min(rd.document_date)
                        from erp.document_relation rel
                        join erp.document rd
                          on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
                        join erp.document_type rdt
                          on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
                        join erp.object_state ros
                          on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
                        join erp.state rs on rs.id = ros.current_state_id
                       where rel.tenant_id = ol.tenant_id
                         and rel.to_line_id = ol.id
                         and rel.relation_kind = 'fulfils'
                         and rdt.base_type_code = 'receipt'
                         and not rd.is_cancelled
                         and rs.is_committed)
$n$;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already ages from the first posted receipt; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a9a07f66e4a12fc36aa26f794928d1e3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$grni$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The suites
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.procurement_controls_suite billed and read GRNI against one
-- receipt left in draft until its landed-cost block posted it. Each receipt
-- is now posted before anything bills it or reads what arrived: v_grn with
-- the first two lines, then one receipt for each later arrival. The cases
-- and what they expect are unchanged, but the first, which now proves that a
-- draft receives nothing and a posted receipt fills quantity_fulfilled in.
do $controls$
declare
  v_sig  constant text := 'erp_test.procurement_controls_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  v_grn uuid; v_inv uuid; v_lc uuid;
$o$,
$o$  perform erp.receive_against(v_grn, v_pol, 100);

  return query select 'a receipt against an order line fills in what B7 left null',
    (select ol.quantity_fulfilled from erp.document_line ol where ol.id = v_pol) = 100,
    'quantity_fulfilled has existed since B7 and nothing had ever written it';

  perform erp.receive_against(v_grn, v_pol2, 10);
$o$,
$o$  perform erp.receive_against(v_grn, v_pol3, 50);
$o$,
$o$  perform erp.receive_against(v_grn, v_pol4, 60);
$o$,
$o$  perform erp.receive_against(v_grn, v_pol4, 20);
$o$,
$o$  perform erp.transition_document(v_grn,'post');

  select c.unit_cost_minor into v_cost from erp.item_cost c
$o$];
  v_new  text[] := array[
$n$  v_grn uuid; v_inv uuid; v_lc uuid;
  -- One receipt for each later arrival, each posted before it is billed (20261006131000).
  v_grn2 uuid; v_grn3 uuid; v_grn4 uuid;
$n$,
$n$  perform erp.receive_against(v_grn, v_pol, 100);
  v_n := (select ol.quantity_fulfilled from erp.document_line ol where ol.id = v_pol);
  perform erp.receive_against(v_grn, v_pol2, 10);
  -- Posted before anything bills it or reads what arrived (20261006131000):
  -- a draft goods receipt receives nothing; only a posted one counts.
  perform erp.transition_document(v_grn,'post');

  return query select 'a draft receipt receives nothing; posted, it fills in what B7 left null',
    coalesce(v_n, 0) = 0
    and (select ol.quantity_fulfilled from erp.document_line ol where ol.id = v_pol) = 100,
    format('quantity_fulfilled %s as a draft, %s posted', coalesce(v_n, 0),
           (select ol.quantity_fulfilled from erp.document_line ol where ol.id = v_pol));
$n$,
$n$  v_grn2 := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.receive_against(v_grn2, v_pol3, 50);
  perform erp.transition_document(v_grn2,'post');
$n$,
$n$  v_grn3 := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.receive_against(v_grn3, v_pol4, 60);
  perform erp.transition_document(v_grn3,'post');
$n$,
$n$  v_grn4 := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.receive_against(v_grn4, v_pol4, 20);
  perform erp.transition_document(v_grn4,'post');
$n$,
$n$  -- Every receipt above was posted as it arrived (20261006131000).

  select c.unit_cost_minor into v_cost from erp.item_cost c
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already posts its receipts before billing them; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'fb9e82d46909e40b18dfbe022f710219' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$controls$;

-- erp_test.controls_finish_suite billed both lines of its matching order
-- against a receipt it never posted. It is posted first; the base is the same
-- ten and five, so every status it expects is as it was.
do $finish$
declare
  v_sig  constant text := 'erp_test.controls_finish_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      perform erp.receive_against(v_grn, v_pol, 10);
      perform erp.receive_against(v_grn, v_pol2, 5);
$o$;
  v_new  constant text := $n$      perform erp.receive_against(v_grn, v_pol, 10);
      perform erp.receive_against(v_grn, v_pol2, 5);
      -- Posted before it is billed (20261006131000): a draft goods receipt
      -- receives nothing.
      perform erp.transition_document(v_grn, 'post', 'controls suite');
$n$;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already posts its receipt before billing it; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '31c2138682d0f7e8de2fca320dcdfc67' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$finish$;

-- erp_test.cancelled_receipt_suite: a draft receives nothing. While the
-- draft for the other eight is open the line reads two received, received-
-- not-billed carries two, and the close's check reconciles; the third
-- receipt reads two received until it posts, and ten after.
do $cancelled$
declare
  v_sig  constant text := 'erp_test.cancelled_receipt_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  c_expected constant integer := 4;
$o$,
$o$    detail := coalesce(v_state, format('open %s', v_open));
    return next;
$o$,
$o$    perform erp.receive_against(v_g3, v_line, 8, null);
    perform erp.transition_document(v_g3, 'post', null);
    v_cases := v_cases + 1;
    case_name := 'the eight are then received on another receipt, and the order reads received in full';
    passed := v_state is null
$o$];
  v_new  text[] := array[
$n$  -- Four until 20261006131000, which added that a draft receives nothing.
  c_expected constant integer := 6;
$n$,
$n$    detail := coalesce(v_state, format('open %s', v_open));
    return next;

    -- ── 1b. And receives nothing (20261006131000) ───────────────────────────
    v_step := 'reading what the draft received';
    v_cases := v_cases + 1;
    case_name := 'and receives nothing: the line reads two received, and received-not-billed carries two';
    passed := v_state is null
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 2
          and (select g.open_quantity from erp.grni_report() g where g.order_line_id = v_line) = 2;
    detail := coalesce(v_state, format('fulfilled %s; received, not billed %s',
                (select l.quantity_fulfilled from erp.document_line l where l.id = v_line),
                (select g.open_quantity from erp.grni_report() g where g.order_line_id = v_line)));
    return next;

    -- ── 1c. The report and the ledger agree while it is open ────────────────
    v_step := 'the close''s check while the draft is open';
    v_cases := v_cases + 1;
    case_name := 'received-not-billed reconciles with the ledger while the draft is open';
    begin
      detail := erp.assert_grni_reconciles();
      passed := v_state is null and detail like 'grni:%reconciles%';
    exception when others then
      detail := left(sqlerrm, 300);
      passed := false;
    end;
    detail := coalesce(v_state, left(detail, 300));
    return next;
$n$,
$n$    perform erp.receive_against(v_g3, v_line, 8, null);
    -- Two received while the third receipt is a draft (20261006131000).
    v_open := (select l.quantity_fulfilled from erp.document_line l where l.id = v_line);
    perform erp.transition_document(v_g3, 'post', null);
    v_cases := v_cases + 1;
    case_name := 'the eight are then received on another receipt: two read received while it is a draft and ten once it posts, and the order reads received in full';
    passed := v_state is null
          and v_open = 2
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already proves a draft receives nothing; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '27df6ee9f3f0bb896c6e61dc892265b7' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$cancelled$;

-- erp_test.draft_line_suite (20261006101000) read what a draft receipt line
-- holds of its order line in quantity_fulfilled. A draft receives nothing,
-- so it now reads what receipts hold, erp.order_line_on_receipts(), and also
-- proves that the draft received nothing; the removed line holds nothing.
do $draft_line$
declare
  v_sig  constant text := 'erp_test.draft_line_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol) = 4
$o$,
$o$    detail := coalesce(v_state, format('relation %s; fulfilled %s; open %s; raise: %s; price: %s',
$o$,
$o$          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol) = 0;
$o$];
  v_new  text[] := array[
$n$          -- What receipts hold comes down with it, and a draft receives
          -- nothing (20261006131000).
          and erp.order_line_on_receipts(v_spol) = 4
          and coalesce((select l.quantity_fulfilled from erp.document_line l where l.id = v_spol), 0) = 0
$n$,
$n$    detail := coalesce(v_state, format('held %s; relation %s; fulfilled %s; open %s; raise: %s; price: %s',
                erp.order_line_on_receipts(v_spol),
$n$,
$n$          and erp.order_line_on_receipts(v_spol) = 0
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol) = 0;
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already reads what receipts hold; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '5bf1bfa9d4f3a626461c2f2f96c4ad2c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$draft_line$;

comment on function erp_test.cancelled_receipt_suite() is
  'A cancelled receipt gives its quantities back (20261005800000): a draft holds, cancelling it reopens the '
  'order line, the received-not-billed report reconciles again, and the goods are then received. A draft '
  'receives nothing: the line and the report count posted receipts only, and agree with the ledger while '
  'a draft is open (20261006131000).';

do $cancelled_count$
declare
  v_sig  constant text := 'erp_test.assert_cancelled_receipt_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 4 then
    raise exception 'CLOVEERP_CANCELLED_RECEIPT_SUITE_SHRANK: % case(s), expected 4', v_total
$o$;
  v_new  constant text := $n$  -- Four until 20261006131000, which added that a draft receives nothing.
  if v_total <> 6 then
    raise exception 'CLOVEERP_CANCELLED_RECEIPT_SUITE_SHRANK: % case(s), expected 6', v_total
$n$;
begin
  if strpos(v_src, '20261006131000') > 0 then
    raise notice '% already counts 6; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7d26bc26e4b5aa3670a71f333f4683a4' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cancelled_count$;

comment on function erp_test.assert_cancelled_receipt_suite() is
  'A goods receipt cancelled by its lifecycle stops counting as received and reopens its order lines '
  '(20261005800000); a draft receives nothing (20261006131000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Every line a draft receipt was raised against, read again
-- ═════════════════════════════════════════════════════════════════════════════

do $repair$
declare
  r       record;
  l       record;
  v_n     integer;
  v_qty   numeric;
  v_now   numeric;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := 0;
    v_qty := 0;
    for l in
      select distinct rel.to_line_id as id,
             (select x.quantity_fulfilled from erp.document_line x where x.id = rel.to_line_id) as was
        from erp.document_relation rel
        join erp.document rd on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
        join erp.document_type rdt on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
        join erp.object_state ros
          on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
        join erp.state rs on rs.id = ros.current_state_id
       where rel.tenant_id = r.id
         and rel.to_line_id is not null
         and rel.relation_kind = 'fulfils'
         and rdt.base_type_code = 'receipt'
         and not rd.is_cancelled
         and rs.code <> 'cancelled'
         and not rs.is_committed
    loop
      perform erp.refresh_order_line_progress(l.id);
      v_now := (select x.quantity_fulfilled from erp.document_line x where x.id = l.id);
      if v_now is distinct from l.was then
        v_n := v_n + 1;
        v_qty := v_qty + coalesce(l.was, 0) - coalesce(v_now, 0);
      end if;
    end loop;
    -- The checks the updates left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the table.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'draft receipts: % order line(s) of % read again, % fewer received', v_n, r.code, v_qty;
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
