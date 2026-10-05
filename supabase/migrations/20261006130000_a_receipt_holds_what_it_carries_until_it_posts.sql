set lock_timeout = '30s';

-- =============================================================================
-- 20261006130000  A receipt holds what it carries until it posts
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-13). A goods receipt
-- still in draft counted as received: an order line's quantity_fulfilled was
-- written from every receipt not cancelled, posted or not, while the ledger
-- credits goods received not invoiced only when the receipt posts. The owner
-- decided (4 October) that a draft goods receipt receives nothing: only posted
-- receipts count, as deliveries already do. 20261006131000 makes that the rule.
--
-- ── WHAT THIS IS FOR ─────────────────────────────────────────────────────────
--
-- Four readers use quantity_fulfilled to mean "held by a receipt", posted or
-- not, and must keep meaning that once a draft no longer counts in it:
--
--   * erp.order_line_open_for_notice(): what is still open to notify on a
--     shipping notice (the buyer's door and the supplier's link refuse more);
--   * public.erp_supplier_response_peek(): the supplier's link, open_to_notify;
--   * erp.cancel_sent_order(): a sent order with goods on a receipt is not
--     cancelled under them;
--   * erp.purchase_order_confirmation(): received_any, which the order page
--     reads to hide Cancel exactly when the door refuses.
--
-- erp.receivable_lines() and erp.receive_against() already count a draft as
-- holding, by reading the receipts themselves.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.order_line_on_receipts(line): what every receipt not cancelled
--      carries against an order line, posted or not, read exactly as
--      erp.receivable_lines() reads on_receipts. The organisation is the
--      line's own, never erp.current_tenant_id(): the supplier's link reaches
--      it from a definer door with no organisation in context.
--   B. The four readers above count the larger of quantity_fulfilled and what
--      receipts hold (the larger, so a drop-ship line, whose quantity_fulfilled
--      erp.confirm_drop_ship writes directly, still counts).
--   C. erp_test.shipping_notice_suite and erp_test.supplier_confirmation_suite
--      gain a case each: a draft receipt holds.
--
-- On its own this changes no number: quantity_fulfilled still counts a draft
-- until 20261006131000, so every reader gives what it gave before.
--
-- Production: no row is changed.
--
-- Proof: erp_test.shipping_notice_suite, erp_test.supplier_confirmation_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What receipts hold
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.order_line_on_receipts(p_line uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- What every receipt raised against the line carries, posted or not, less
  -- any cancelled by its flag or by its lifecycle (20261006130000). A draft
  -- holds what it carries; only a posted receipt receives it. The
  -- organisation is the line's own.
  select coalesce(sum(rel.quantity), 0)
    from erp.document_line l
    join erp.document_relation rel
      on rel.tenant_id = l.tenant_id and rel.to_line_id = l.id and rel.relation_kind = 'fulfils'
    join erp.document rd
      on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
    join erp.document_type rdt
      on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
    left join erp.object_state ros
      on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
    left join erp.state rs on rs.id = ros.current_state_id
   where l.id = p_line
     and rdt.base_type_code = 'receipt'
     and not (rd.is_cancelled or coalesce(rs.code = 'cancelled', false))
$$;

revoke all on function erp.order_line_on_receipts(uuid) from public, anon;

comment on function erp.order_line_on_receipts(uuid) is
  'What every receipt not cancelled carries against an order line, posted or not: what receipts hold. Read as '
  'erp.receivable_lines reads on_receipts; the organisation is the line''s own (20261006130000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The four readers that mean "held"
-- ═════════════════════════════════════════════════════════════════════════════

do $held$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select * from (values
      ('erp.order_line_open_for_notice(uuid,uuid)', 'aeb49cb601de83083d461207ccda1aad',
       $o$  select greatest(0, l.quantity - coalesce(l.quantity_fulfilled, 0)
$o$,
       $n$  -- Received is what receipts hold, posted or not (20261006130000).
  select greatest(0, l.quantity - greatest(coalesce(l.quantity_fulfilled, 0), erp.order_line_on_receipts(l.id))
$n$),
      ('public.erp_supplier_response_peek(text)', '12ec8ab1d774ae51113b9010a0078883',
       $o$                      'open_to_notify', greatest(0, l.quantity - coalesce(l.quantity_fulfilled, 0)
$o$,
       $n$                      -- What receipts hold, posted or not (20261006130000).
                      'open_to_notify', greatest(0, l.quantity - greatest(coalesce(l.quantity_fulfilled, 0),
                                                                          erp.order_line_on_receipts(l.id))
$n$),
      ('erp.cancel_sent_order(uuid,text)', '6ddabb77661deccd2a3dfa68b124fdd3',
       $o$                   and coalesce(l.quantity_fulfilled, 0) > 0)
$o$,
       $n$                   -- Goods on a receipt not yet posted hold it too (20261006130000).
                   and (erp.order_line_on_receipts(l.id) > 0 or coalesce(l.quantity_fulfilled, 0) > 0))
$n$),
      ('erp.purchase_order_confirmation(uuid)', 'e1eb828c7f75075e8c9471c1329d770f',
       $o$                                      and coalesce(l.quantity_fulfilled, 0) > 0),
$o$,
       $n$                                      -- As erp.cancel_sent_order refuses (20261006130000).
                                      and (erp.order_line_on_receipts(l.id) > 0
                                           or coalesce(l.quantity_fulfilled, 0) > 0)),
$n$)
    ) as t(sig, digest, old_text, new_text)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261006130000') > 0 then
      raise notice '% already counts what receipts hold; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.digest then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006130000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    if (length(v_def) - length(replace(v_def, r.old_text, ''))) / length(r.old_text) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, r.old_text, r.new_text);
  end loop;
end
$held$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The proof
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.shipping_notice_suite: a second order of ten coats, confirmed
-- through its link, with four on a draft receipt. Six are open to notify on
-- the order and on the supplier's link (read with no organisation in
-- context), a notice for seven is refused, and posting the receipt leaves six.
do $notice$
declare
  v_sig  constant text := 'erp_test.shipping_notice_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $o$  c_expected constant integer := 11;
$o$;
  v_a_new constant text := $n$  -- Eleven until 20261006130000, which added a draft receipt that holds.
  c_expected constant integer := 12;
  v_po2 uuid; v_l3 uuid; v_g uuid; v_tok2 text; v_peek2 jsonb; v_open0 numeric; v_open1 numeric;
$n$;
  v_b_old constant text := $o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$;
  v_b_new constant text := $n$    -- ── 11. A draft receipt holds what it carries (20261006130000) ─────────
    v_step := 'a second order of ten coats, confirmed, with four on a draft receipt';
    v_po2 := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    perform erp.add_document_line(v_po2, v_item, 10, 9000, 'bought for ZNO2');
    perform erp.transition_document(v_po2, 'submit', null);
    perform erp_test.approve_document(v_po2, 'shipping notice suite');
    select l.id into v_l3 from erp.document_line l where l.document_id = v_po2 order by l.line_no limit 1;
    res := public.erp_send_purchase_order(v_po2, 'orders@znbrand-' || v_tag || '.test', null, null, null);
    select t.response_token into v_tok2 from erp.claim_document_email_batch(10, 'suite') t
     where t.document_kind = 'purchase_order' limit 1;
    perform set_config('request.jwt.claims', '', true);
    perform erp.supplier_respond(v_tok2, '{"decision": "confirm"}');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_g := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g, v_l3, 4, null);
    v_open0 := erp.order_line_open_for_notice(v_l3, null);
    -- The supplier's link reads it with no organisation in context.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    v_peek2 := public.erp_supplier_response_peek(v_tok2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin perform public.erp_record_shipping_notice(v_po2, jsonb_build_object('expected_arrival', (current_date + 3)::text,
            'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l3, 'quantity', 7)))); v_err := 'notified';
    exception when others then v_err := sqlerrm; end;
    perform erp.transition_document(v_g, 'post', null);
    v_open1 := erp.order_line_open_for_notice(v_l3, null);
    v_cases := v_cases + 1;
    case_name := 'four of ten coats on a receipt not yet posted are held: six are open to notify on the order and on the supplier''s link, a notice for seven is refused, and posting the receipt leaves six';
    passed := v_state is null
          and v_open0 = 6
          and (select (x ->> 'open_to_notify')::numeric from jsonb_array_elements(v_peek2 -> 'lines') x
                where x ->> 'line_id' = v_l3::text) = 6
          and v_err like 'CLOVEERP_NOTICE_LINE_INVALID:%'
          and v_open1 = 6;
    detail := coalesce(v_state, left(format('open %s; on the link %s; notice for seven: %s; posted, open %s', v_open0,
                (select x ->> 'open_to_notify' from jsonb_array_elements(v_peek2 -> 'lines') x
                  where x ->> 'line_id' = v_l3::text), v_err, v_open1), 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$n$;
begin
  if strpos(v_src, '20261006130000') > 0 then
    raise notice '% already proves a draft receipt holds; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7472b269d7700fbf1f72d0019e3e97c7' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006130000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new);
end
$notice$;

do $notice_count$
declare
  v_sig  constant text := 'erp_test.assert_shipping_notice_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 11 then
    raise exception 'CLOVEERP_SHIPPING_NOTICE_SUITE_SHRANK: % case(s), expected 11', v_total
$o$;
  v_new  constant text := $n$  -- Eleven until 20261006130000, which added a draft receipt that holds.
  if v_total <> 12 then
    raise exception 'CLOVEERP_SHIPPING_NOTICE_SUITE_SHRANK: % case(s), expected 12', v_total
$n$;
begin
  if strpos(v_src, '20261006130000') > 0 then
    raise notice '% already counts 12; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a705a959b06be5d2ff8b5966e7f82b65' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006130000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$notice_count$;

-- erp_test.supplier_confirmation_suite: a sent order with two coats on a
-- draft receipt is refused cancellation, and its page says goods have come.
do $confirmation$
declare
  v_sig  constant text := 'erp_test.supplier_confirmation_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $o$  c_expected constant integer := 12;
$o$;
  v_a_new constant text := $n$  -- Twelve until 20261006130000, which added a draft receipt that holds the order.
  c_expected constant integer := 13;
  v_po4 uuid; v_l3 uuid; v_g uuid; v_conf2 jsonb;
$n$;
  v_b_old constant text := $o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$;
  v_b_new constant text := $n$    -- ── 12. A draft receipt holds the order (20261006130000) ───────────────
    v_step := 'a sent order with two coats on a receipt not yet posted';
    v_po4 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 4, 9000, 'ZCO5');
    select l.id into v_l3 from erp.document_line l where l.document_id = v_po4 order by l.line_no limit 1;
    v_g := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g, v_l3, 2, null);
    begin perform public.erp_cancel_sent_order(v_po4, 'Changed our mind'); v_err := 'cancelled';
    exception when others then v_err := sqlerrm; end;
    v_conf2 := erp.purchase_order_confirmation(v_po4);
    v_cases := v_cases + 1;
    case_name := 'an order with goods on a receipt not yet posted is refused cancellation by name, and its page says goods have come';
    passed := v_state is null
          and v_err like 'CLOVEERP_SENT_ORDER_CANNOT_CANCEL:%'
          and coalesce((v_conf2 ->> 'received_any')::boolean, false)
          and erp.object_current_state('document', v_po4) = 'sent';
    detail := coalesce(v_state, left(format('%s | received_any %s | %s', v_err, v_conf2 ->> 'received_any',
                erp.object_current_state('document', v_po4)), 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$n$;
begin
  if strpos(v_src, '20261006130000') > 0 then
    raise notice '% already proves a draft receipt holds the order; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '059cc62ae66db5732dd0de26cb059f56' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006130000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new);
end
$confirmation$;

do $confirmation_count$
declare
  v_sig  constant text := 'erp_test.assert_supplier_confirmation_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 12 then
    raise exception 'CLOVEERP_SUPPLIER_CONFIRMATION_SUITE_SHRANK: % case(s), expected 12', v_total
$o$;
  v_new  constant text := $n$  -- Twelve until 20261006130000, which added a draft receipt that holds the order.
  if v_total <> 13 then
    raise exception 'CLOVEERP_SUPPLIER_CONFIRMATION_SUITE_SHRANK: % case(s), expected 13', v_total
$n$;
begin
  if strpos(v_src, '20261006130000') > 0 then
    raise notice '% already counts 13; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '1f9eec1e7870137c87f6e6687f617706' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006130000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$confirmation_count$;

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
