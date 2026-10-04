set lock_timeout = '30s';

-- =============================================================================
-- 20261005700000  A receipt counts once it is posted
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October. An order of fifteen
-- units had two received on a posted receipt. A second receipt was raised for
-- the other thirteen and cancelled while still a draft. From then on:
--
--   "Nothing is left to receive on this order: every line has been received
--    or is on a goods receipt already."
--
-- and the order's lines read fully received, 6 of 6, 4 of 4 and 5 of 5, with
-- two units in the warehouse. The Purchasing tile "Received, not yet billed"
-- had gone up by the draft's value when it was raised and stayed there.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- erp.refresh_order_line_progress() writes an order line's quantity_fulfilled
-- from every receipt raised against it that is not flagged cancelled: a draft
-- counted as received the moment it was raised, and a draft cancelled by its
-- lifecycle (state cancelled, flag untouched) counted for ever, because
-- nothing refreshes the line when a receipt is cancelled.
--
-- For a delivery the same routine already reads only what has posted
-- (20260914064000): "a draft delivery holds its quantity against what is left
-- and delivers nothing until it posts". A receipt is the same thing arriving.
-- And the ledger agrees: goods received not invoiced is credited when the
-- receipt posts, while erp.grni_report() reads quantity_fulfilled, so a draft
-- receipt put the report ahead of the ledger and the close's check
-- (erp.assert_grni_reconciles) would refuse the month for it.
--
-- What a draft receipt holds is still held: erp.receivable_lines() and
-- erp.receive_against() count every receipt not cancelled, drafts included,
-- so two drafts cannot both take the same goods.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.refresh_order_line_progress(): a receipt counts towards
--      quantity_fulfilled once it is in a committed state, and never once it
--      is cancelled.
--   B. Every purchase order line a receipt was ever raised against is
--      refreshed here, in every organisation, so a line a draft or a
--      cancelled receipt was counted on reads what has arrived.
--
-- Proof: erp_test.receipt_counts_once_posted_suite.
-- =============================================================================

do $progress$
declare
  v_sig  constant text := 'erp.refresh_order_line_progress(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled), 0)$o$;
  v_new  constant text := $n$              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled
              -- Received is what a posted receipt brought (20261005700000): a
              -- draft holds its quantity against what is left
              -- (erp.receivable_lines) and receives nothing until it posts,
              -- and a receipt cancelled as a draft never did.
              and exists (select 1
                            from erp.object_state ros
                            join erp.state rs on rs.id = ros.current_state_id
                           where ros.tenant_id = rd.tenant_id
                             and ros.object_type = 'document'
                             and ros.object_id = rd.id
                             and rs.is_committed
                             and rs.code <> 'cancelled')), 0)$n$;
begin
  if strpos(v_src, '20261005700000') > 0 then
    raise notice '% already counts a receipt once it is posted; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '8d0a8a22ac4ffae553838d0b5282af44' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005700000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$progress$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.receipt_counts_once_posted_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_po uuid; v_line uuid;
  v_g1 uuid; v_g2 uuid; v_g3 uuid;
  v_cancel text;
  v_open   numeric;
  v_res    text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an order of ten, sent';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzrcp-' || v_tag, 'Receipt Counts Suite',
      'admin@zzrcp-' || v_tag || '.test', 'Receipt Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzrcp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRCOAT', 'Received Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZRBRAND');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZRO1', false);
    perform public.erp_send_purchase_order(v_po, 'orders@zrbrand-' || v_tag || '.test', null, null, null);
    select l.id into v_line from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;

    -- ── 1. Two received, on a posted receipt ────────────────────────────────
    v_step := 'two of the ten received and posted';
    v_g1 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g1, v_line, 2, null);
    perform erp.transition_document(v_g1, 'post', null);
    v_cases := v_cases + 1;
    case_name := 'a posted receipt of two counts as two received';
    passed := v_state is null
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 2;
    detail := coalesce(v_state, 'quantity_fulfilled 2');
    return next;

    -- ── 2. A draft holds, and receives nothing ──────────────────────────────
    v_step := 'a draft receipt for the other eight';
    v_g2 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g2, v_line, 8, null);
    select coalesce(sum((x ->> 'open_quantity')::numeric), 0) into v_open
      from jsonb_array_elements(public.erp_receivable_lines(v_po)) x;
    v_cases := v_cases + 1;
    case_name := 'a draft receipt for the other eight holds them, so nothing more is offered, and counts nothing as received';
    passed := v_state is null and v_open = 0
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 2;
    detail := coalesce(v_state, format('open %s, quantity_fulfilled %s', v_open,
                (select l.quantity_fulfilled from erp.document_line l where l.id = v_line)));
    return next;

    -- ── 3. The ledger and the report agree while the draft stands ───────────
    v_step := 'the close''s check with a draft receipt outstanding';
    begin
      v_res := erp.assert_grni_reconciles();
    exception when others then
      v_res := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'goods received not invoiced reconciles while a draft receipt is outstanding';
    passed := v_state is null and v_res like 'grni:%reconciles%';
    detail := coalesce(v_state, left(v_res, 300));
    return next;

    -- ── 4. Cancelled as a draft, it gives them back ─────────────────────────
    v_step := 'cancelling the draft receipt';
    select x ->> 'code' into v_cancel
      from jsonb_array_elements(public.erp_available_transitions(v_g2)) x
     where x ->> 'to_state' = 'cancelled' limit 1;
    perform erp.transition_document(v_g2, v_cancel, 'the lorry was turned away');
    select coalesce(sum((x ->> 'open_quantity')::numeric), 0) into v_open
      from jsonb_array_elements(public.erp_receivable_lines(v_po)) x;
    v_cases := v_cases + 1;
    case_name := 'cancelling the draft gives its eight back: they are open to receive again and the line still reads two received';
    passed := v_state is null and v_cancel is not null and v_open = 8
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 2;
    detail := coalesce(v_state, format('cancelled by "%s"; open %s', coalesce(v_cancel, 'no move'), v_open));
    return next;

    -- ── 5. And the rest arrives ─────────────────────────────────────────────
    v_step := 'receiving the eight on a third receipt';
    v_g3 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g3, v_line, 8, null);
    perform erp.transition_document(v_g3, 'post', null);
    v_cases := v_cases + 1;
    case_name := 'the eight are then received on another receipt, and the order reads received in full';
    passed := v_state is null
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 10
          and erp.object_current_state('document', v_po) in ('received', 'closed');
    detail := coalesce(v_state, erp.object_current_state('document', v_po));
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
    raise exception 'CLOVEERP_RECEIPT_COUNTS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.receipt_counts_once_posted_suite() from public, anon;

comment on function erp_test.receipt_counts_once_posted_suite() is
  'A receipt counts once it is posted (20261005700000): a draft holds its quantity and receives nothing, '
  'the close''s check reconciles with a draft outstanding, and a draft cancelled gives its quantity back.';

create or replace function erp_test.assert_receipt_counts_once_posted_suite()
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
    from erp_test.receipt_counts_once_posted_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_RECEIPT_COUNTS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A draft or cancelled receipt would read as goods received. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_RECEIPT_COUNTS_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('receipt counts once posted: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_receipt_counts_once_posted_suite() from public, anon;

comment on function erp_test.assert_receipt_counts_once_posted_suite() is
  'An order line reads received what posted receipts brought, never a draft or a cancelled one (20261005700000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Every line a receipt was raised against, read again
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  r       record;
  l       record;
  v_n     integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := 0;
    for l in
      select ol.id, ol.quantity_fulfilled as was
        from erp.document_line ol
        join erp.document od on od.tenant_id = ol.tenant_id and od.id = ol.document_id
        join erp.document_type odt on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
       where ol.tenant_id = r.id
         and odt.base_type_code = 'purchase_order'
         -- Only a line some receipt that is not posted was raised against:
         -- every other line already reads what its posted receipts brought.
         and exists (
           select 1
             from erp.document_relation rel
             join erp.document rd on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
             join erp.document_type rdt on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
             left join erp.object_state ros
               on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
             left join erp.state rs on rs.id = ros.current_state_id
            where rel.tenant_id = ol.tenant_id and rel.to_line_id = ol.id
              and rdt.base_type_code = 'receipt'
              and (not coalesce(rs.is_committed, false) or rs.code = 'cancelled'))
    loop
      perform erp.refresh_order_line_progress(l.id);
      if (select x.quantity_fulfilled from erp.document_line x where x.id = l.id) is distinct from l.was then
        v_n := v_n + 1;
      end if;
    end loop;
    -- The checks the updates left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the table.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'receipts: % order line(s) of % now read what their posted receipts brought', v_n, r.code;
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
