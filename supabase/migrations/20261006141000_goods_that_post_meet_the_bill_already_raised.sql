set lock_timeout = '30s';

-- =============================================================================
-- 20261006141000  Goods that post meet the bill already raised for them
-- -----------------------------------------------------------------------------
-- Found in the design that followed the owner's decision that a draft goods
-- receipt receives nothing (20261006131000). A supplier's bill may be
-- registered before its goods arrive: erp.match_three_way() compares it with
-- what has been received, and nothing received is not yet a difference, so
-- the bill matches (erp_test.derived_authority_suite, case 1). Nothing ever
-- matched it again. When the goods then arrived short of the bill, the order
-- read billed in full, erp.order_is_settled() found no open difference, and
-- erp.close_order_when_settled() closed it with the shortfall paid for.
--
-- The owner decided (5 October): a bill registered before its goods stays
-- matched, and is checked again when the receipt posts.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.advance_orders_for_receipt(), which erp.transition_document()
--      calls as a goods receipt posts, matches again every order line the
--      receipt fulfils that has been billed, after reading the lines again
--      and before it moves or closes the order. A difference is raised then:
--      it names the bill, so the payment run holds it, it keeps the order
--      open, and it is on the workbench. Equal quantities stay matched.
--      A line that already has an open difference is left to the workbench,
--      so posting never raises a second difference for the same line. A
--      match that fails is recorded as document.progress_not_advanced (an
--      event already registered) and never undoes the posting. The stale
--      comment that said the order's move counts drafts is corrected.
--   B. erp_test.match_exception_suite proves it.
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- A bill registered before its goods is accepted as it was. A bill that
-- agrees with what arrives closes the order as before (derived_authority
-- cases 1 and 15). The difference raised at posting does not move a bill
-- already registered to disputed: the payment run holds a bill with an open
-- difference (erp.propose_payment_run), and accepting it is the workbench's.
--
-- Production: one routine is replaced. No table is altered and no row is
-- changed; nothing is matched again until a receipt next posts. On live no
-- order line is billed beyond what has posted.
--
-- Proof: erp_test.match_exception_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. Matched again as the goods post
-- ═════════════════════════════════════════════════════════════════════════════

do $advance$
declare
  v_sig  constant text := 'erp.advance_orders_for_receipt(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$    -- quantity_fulfilled is still kept, because receive_against() reads it to
    -- size what is left. The move below does not read it: it counts drafts.
$o$,
$o$      perform erp.refresh_order_line_progress(l.id);
    end loop;
$o$];
  v_new  text[] := array[
$n$    -- What each line has received, from posted receipts only
    -- (20261006131000), as the order's position below counts it. What a
    -- draft receipt holds is read from the receipts themselves
    -- (erp.receivable_lines, erp.order_line_on_receipts).
$n$,
$n$      perform erp.refresh_order_line_progress(l.id);
    end loop;

    -- A bill raised before the goods is matched again now they have posted
    -- (20261006141000; owner, 5 October). Matching treats nothing received
    -- as no difference, so a bill registered first matched, and goods
    -- arriving short of it would have let the order close. A line that
    -- already holds an open difference is left to the workbench, so no
    -- second one is raised for it. A match that fails is recorded, never a
    -- reason to undo a receipt that has posted.
    for l in
      select distinct ol.id
        from erp.document_relation rel
        join erp.document_line ol
          on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
       where rel.tenant_id = v_tenant
         and rel.from_document_id = p_receipt_id
         and rel.relation_kind = 'fulfils'
         and ol.document_id = r.order_id
         and coalesce(ol.quantity_invoiced, 0) > 0
         and not exists (select 1 from erp.match_exception x
                          where x.tenant_id = v_tenant
                            and x.order_line_id = ol.id
                            and x.resolved_at is null)
    loop
      begin
        perform erp.match_three_way(l.id);
      exception when others then
        perform erp.append_event(
          'document.progress_not_advanced', 'document', r.order_id,
          jsonb_build_object('match_order_line_id', l.id, 'reason', sqlerrm,
                             'receipt_id', p_receipt_id),
          null, null);
      end;
    end loop;
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006141000') > 0 then
    raise notice '% already matches a billed line again; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4a050d1efae8a947c9ce7552d3a4562a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006141000 expects (md5 %)', v_sig, md5(v_src);
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
$advance$;

comment on function erp.advance_orders_for_receipt(uuid) is
  'As a goods receipt posts: reads its orders'' lines again, matches again each billed line it fulfils that '
  'holds no open difference (20261006141000), moves each order to partly or fully received, and closes one '
  'that is now settled. Nothing here undoes the posting; what cannot be done is recorded as an event.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The suite
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.match_exception_suite: a bill for ten registered before anything
-- arrived stays matched. Eight arrive: one quantity difference is raised
-- against the bill, received eight, and the order stays open. One more
-- arrives: still one difference for the line, not two.
do $suite$
declare
  v_sig  constant text := 'erp_test.match_exception_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  c_expected constant integer := 7;
$o$,
$o$  v_fixture text;
$o$,
$o$  raise exception 'CLOVEERP_SUITE_UNDO';
$o$,
$o$  -- ── 7. Undone ─────────────────────────────────────────────────────────────
$o$];
  v_new  text[] := array[
$n$  -- Seven until 20261006141000, which added that a bill raised before its
  -- goods is matched again when they post.
  c_expected constant integer := 8;
$n$,
$n$  v_fixture text;
  v_po2 uuid; v_pol3 uuid; v_grn2 uuid; v_grn3 uuid; v_bill2 uuid;
  v_bill_state text; v_po_state text; v_settled boolean; v_names boolean; v_kind text;
  v_open0 integer; v_open8 integer; v_open9 integer; v_rq numeric;
$n$,
$n$  -- ── 7. A bill raised before its goods is matched again when they post ────
  -- (20261006141000; owner, 5 October.) Registered against nothing received
  -- the bill stays matched: nothing received is not yet a difference. When
  -- eight of the ten arrive it is checked again, the difference is raised
  -- against the bill, and the order does not close. One more arriving raises
  -- no second difference for the line, which the workbench already holds.
  v_cases := v_cases + 1;
  v_po2 := erp.open_document('purchase_order', v_sup, null, v_site);
  v_pol3 := erp.add_document_line(v_po2, v_item, 10, 1000, 'billed before it came');
  perform erp.transition_document(v_po2, 'submit', 'match exception suite');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po2 and tk.status = 'pending'
  loop perform erp.decide_approval_task(t.id, true, 'match exception suite'); end loop;
  if erp.object_current_state('document', v_po2) = 'pending_approval' then
    perform erp.transition_document(v_po2, 'approve', 'match exception suite');
  end if;
  perform erp.transition_document(v_po2, 'send', 'match exception suite');
  v_bill2 := erp.open_document('purchase_invoice', v_sup, null, v_site);
  perform erp.invoice_against(v_bill2, v_pol3, 10, 1000);
  perform erp.transition_document(v_bill2, 'register', 'match exception suite');
  v_bill_state := erp.object_current_state('document', v_bill2);
  v_open0 := (select count(*) from erp.match_exception x
               where x.tenant_id = r.tenant_id and x.order_line_id = v_pol3
                 and x.resolved_at is null);

  v_grn2 := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.receive_against(v_grn2, v_pol3, 8);
  perform erp.transition_document(v_grn2, 'post', 'match exception suite');
  select count(*), max(x.received_quantity), bool_and(x.invoice_document_id = v_bill2),
         string_agg(x.status::text, ', ')
    into v_open8, v_rq, v_names, v_kind
    from erp.match_exception x
   where x.tenant_id = r.tenant_id and x.order_line_id = v_pol3 and x.resolved_at is null;
  v_settled := erp.order_is_settled(v_po2);
  v_po_state := erp.object_current_state('document', v_po2);

  v_grn3 := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.receive_against(v_grn3, v_pol3, 1);
  perform erp.transition_document(v_grn3, 'post', 'match exception suite');
  v_open9 := (select count(*) from erp.match_exception x
               where x.tenant_id = r.tenant_id and x.order_line_id = v_pol3
                 and x.resolved_at is null);

  case_name := 'a bill raised before its goods is matched again when they post: eight of ten arriving raises one quantity difference against the bill and the order does not close; one more arriving raises no second';
  passed := v_bill_state = 'registered'
        and v_open0 = 0
        and v_open8 = 1 and v_rq = 8 and v_names and v_kind = 'quantity_variance'
        and not v_settled and v_po_state = 'partially_received'
        and v_open9 = 1
        and not erp.order_is_settled(v_po2)
        and erp.object_current_state('document', v_po2) = 'partially_received';
  detail := format('bill %s with %s difference(s); eight posted: %s open (%s), received %s, naming the bill %s, order %s, settled %s; nine posted: %s open, order %s',
                   v_bill_state, v_open0, v_open8, coalesce(v_kind, 'none'), coalesce(v_rq::text, '-'),
                   coalesce(v_names::text, '-'), v_po_state, v_settled, v_open9,
                   erp.object_current_state('document', v_po2));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
$n$,
$n$  -- ── 8. Undone ─────────────────────────────────────────────────────────────
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006141000') > 0 then
    raise notice '% already proves a bill is matched again; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e227d9f30e444a7f150944f4d625b988' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006141000 expects (md5 %)', v_sig, md5(v_src);
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
$suite$;

do $suite_count$
declare
  v_sig  constant text := 'erp_test.assert_match_exception_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 7 then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_SUITE_SHRANK: % case(s), expected 7', v_total
$o$;
  v_new  constant text := $n$  -- Seven until 20261006141000, which added that a bill raised before its
  -- goods is matched again when they post.
  if v_total <> 8 then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_SUITE_SHRANK: % case(s), expected 8', v_total
$n$;
begin
  if strpos(v_src, '20261006141000') > 0 then
    raise notice '% already counts 8; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '354cc29cd2d1e3ba92a5369e6b9932fe' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006141000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$suite_count$;

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
