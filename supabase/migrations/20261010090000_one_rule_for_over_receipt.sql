set lock_timeout = '30s';

-- =============================================================================
-- 20261010090000  One rule for receiving more than was ordered
-- -----------------------------------------------------------------------------
-- Definition of Done P2P-03: "Attempt to receive 110 against a PO for 100.
-- Expect: blocked, or allowed only within a configured tolerance and
-- flagged. Never silently accepted." The v1 gate (7 October) held it as S2:
-- the two receiving routes give different answers, and nothing asserts that
-- they agree.
--
-- Read on main before a line of this was written:
--
--   Receiving an order line on its own (erp.receive_against) asks
--   erp.check_receipt_tolerance(): inside the tolerance it is accepted and
--   flagged with a document.over_received event (20260923100000); past it,
--   refused or sent for approval as the tolerance says. But with no
--   tolerance set at all, the check answered 'accept' whatever arrived. Two
--   hundred against an order for a hundred was received, and only the event
--   said so. That is the "silently accepted" the Definition of Done forbids.
--
--   Receive this order (erp.create_receipt_from_order) refused anything past
--   what was left on the line before the tolerance was asked
--   (CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE). Its own registered next action sent
--   the person to the line route for the extra. So a delivery inside the
--   tolerance the organisation set could not be received in one press: a
--   workaround the flow forced, which is what S2 means.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.check_receipt_tolerance(): no tolerance set is no allowance.
--      Anything past what was ordered is refused (CLOVEERP_OVER_DELIVERY),
--      in words that say no tolerance is set and what to do. A short receipt
--      is still accepted: a part receipt is ordinary trade.
--   B. erp.create_receipt_from_order() stops refusing early. Every line goes
--      through erp.receive_against(), as it did, and the tolerance there is
--      the one rule for both routes: inside it, received and flagged; past
--      it, refused or sent for approval.
--   C. CLOVEERP_OVER_DELIVERY is registered with its words, and
--      CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE, no longer raised anywhere, leaves
--      the register.
--   D. erp_test.over_receipt_suite proves both routes give the same answer.
--      erp_test.receive_from_order_suite named the retired code; its case
--      now expects the tolerance's refusal.
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- An organisation with procurement controls holds a default tolerance
-- (configure_procurement_controls), so nothing changes for it except that
-- Receive this order now takes what that tolerance allows. The over_received
-- event, the approval past the tolerance and quarantine are unchanged.
--
-- Production: one routine's refusal and one routine's early check change. No
-- table is altered and no row is changed.
--
-- Proof: erp_test.over_receipt_suite.
-- =============================================================================

select erp.register_refusal(
  'CLOVEERP_OVER_DELIVERY',
  'Receiving more of an order line than was ordered, past what the receipt tolerance allows.',
  'Goods past the order are stock nobody agreed to buy. A tolerance says how much more may be taken; with none set, '
  'nothing more is.',
  'Receive what was ordered. To take more, set a receipt tolerance for the supplier or the product, or raise an '
  'order for the extra.');

-- Receive this order no longer refuses on its own (B below), so its refusal
-- is raised nowhere and leaves the register with its words.
delete from erp_ref.resource r
 where r.key in (erp_ref.refusal_key('CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE', 'refused'),
                 erp_ref.refusal_key('CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE', 'why'),
                 erp_ref.refusal_key('CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE', 'next_action'));

delete from erp_ref.refusal f
 where f.code = 'CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE';

-- ═════════════════════════════════════════════════════════════════════════════
-- A. No tolerance set is no allowance
-- ═════════════════════════════════════════════════════════════════════════════

do $check_tolerance$
declare
  v_sig  constant text := 'erp.check_receipt_tolerance(uuid, uuid, numeric, numeric)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if not found then return 'accept'; end if;
$o$;
  v_new  constant text := $n$  -- No tolerance set is no allowance (20261010090000). Answering 'accept'
  -- here received two hundred against an order for a hundred with only an
  -- event to say so. A short receipt is still accepted: a part receipt is
  -- ordinary trade.
  if not found then
    if p_received > p_ordered then
      raise exception
        'CLOVEERP_OVER_DELIVERY: % against % ordered is % per cent over, and no receipt tolerance is set',
        trim_scale(p_received), trim_scale(p_ordered),
        round((p_received - p_ordered) * 100.0 / p_ordered, 2)
        using errcode = '23514',
        hint = 'Receive what was ordered. To take more, set a receipt tolerance for the supplier or the product, '
               'or raise an order for the extra.';
    end if;
    return 'accept';
  end if;
$n$;
  n integer;
begin
  if position('no receipt tolerance is set' in v_def) > 0 then
    raise notice '% already refuses over-delivery with no tolerance; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no-tolerance answer found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$check_tolerance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Receive this order asks the same rule
-- ═════════════════════════════════════════════════════════════════════════════

do $receipt_from_order$
declare
  v_sig  constant text := 'erp.create_receipt_from_order(uuid, jsonb, text)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      if v_planned + v_qty > l.open_quantity then
        raise exception 'CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE: line % of % has % left to receive, and % was asked for',
          l.line_no, d.document_number, trim_scale(l.open_quantity), trim_scale(v_planned + v_qty)
          using errcode = '23514',
                hint = 'Receive what is left, or less. What is already on a goods receipt, posted or not, is not left to receive.';
      end if;
$o$;
  v_new  constant text := $n$      -- More than is left on the line is for the receipt tolerance to decide
      -- (20261010090000), as it decides for a line received on its own:
      -- erp.receive_against() below asks it of every line, counting what
      -- is already on a goods receipt, posted or not. Refusing here first
      -- sent a delivery inside the organisation's own tolerance line by line.
$n$;
  n integer;
begin
  if position('for the receipt tolerance to decide' in v_def) > 0 then
    raise notice '% already leaves over-receipt to the tolerance; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % early refusal found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receipt_from_order$;

-- The receive-from-order suite named the early refusal by its code. The case
-- it proves holds: more than is left on a line under a draft receipt is
-- refused by name, now by the tolerance, which no tolerance set refuses.
do $receive_from_order_suite$
declare
  v_sig  constant text := 'erp_test.receive_from_order_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$v_over_err like 'CLOVEERP_MORE_THAN_LEFT_TO_RECEIVE%'$o$;
  v_new  constant text := $n$v_over_err like 'CLOVEERP_OVER_DELIVERY%'$n$;
  n integer;
begin
  if position(v_new in v_def) > 0 then
    raise notice '% already expects the tolerance''s refusal; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % early refusal expected % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$receive_from_order_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.over_receipt_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_answer jsonb;
  v_msg1 text; v_msg2 text; v_msg3 text; v_msg4 text;
  v_qty numeric; v_n bigint;
begin
  begin
    v_step := 'an organisation with procurement and inventory, and no receipt tolerance yet';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzorc-' || v_tag, 'Over Receipt Suite',
      'admin@zzorc-' || v_tag || '.test', 'Over Receipt Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzorc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_inventory('average');

    v_step := 'its own unit, site, places, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZOEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZOSITE', 'Over receipt suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZO-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZO-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZOSUP', 'Over Receipt Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZOWID', 'Over Receipt Suite Widget', v_uom, 'active')
    returning id into v_item;

    v_step := 'a hundred widgets ordered and sent';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets');
    perform erp.transition_document(v_po, 'submit', 'over receipt suite');
    perform erp_test.approve_document(v_po, 'over receipt suite');
    perform erp.transition_document(v_po, 'send', 'over receipt suite');

    -- ── 1–2. With no tolerance, both routes refuse the same way ─────────────
    v_step := 'a hundred and ten received line by line, with no tolerance set';
    begin
      v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
      perform erp.receive_against(v_grn, v_pol, 110, null);
      v_msg1 := 'received';
    exception when others then v_msg1 := left(sqlerrm, 200);
    end;

    v_cases := v_cases + 1;
    case_name := 'with no tolerance set, a line received past its order is refused, never silently accepted';
    passed := v_state is null and v_msg1 like 'CLOVEERP_OVER_DELIVERY:%no receipt tolerance is set%';
    detail := v_msg1;
    return next;

    v_step := 'a hundred and ten received with Receive this order, with no tolerance set';
    begin
      v_answer := erp.create_receipt_from_order(v_po,
                    jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 110)), null);
      v_msg2 := 'received';
    exception when others then v_msg2 := left(sqlerrm, 200);
    end;

    v_cases := v_cases + 1;
    case_name := 'and Receive this order gives the same answer';
    passed := v_state is null and v_msg2 = v_msg1;
    detail := v_msg2;
    return next;

    -- ── 3. A short receipt is still ordinary trade ──────────────────────────
    v_step := 'sixty received with Receive this order';
    v_answer := erp.create_receipt_from_order(v_po,
                  jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 60)), null);

    v_cases := v_cases + 1;
    case_name := 'a receipt short of the order is accepted with no tolerance set';
    passed := v_state is null and (v_answer ->> 'quantity')::numeric = 60;
    detail := format('%s holds %s', v_answer ->> 'document_number', v_answer ->> 'quantity');
    return next;

    -- ── 4–6. A tolerance of five per cent, one press ────────────────────────
    v_step := 'procurement controls installed, with a five per cent receipt tolerance';
    perform erp.configure_procurement_controls();
    update erp.receipt_tolerance rt
       set over_pct = 5, over_action = 'reject', updated_at = now()
     where rt.tenant_id = rb.tenant_id and rt.code = 'default';

    v_step := 'forty-three more received with Receive this order: a hundred and three in all';
    v_answer := erp.create_receipt_from_order(v_po,
                  jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 43)), null);
    v_grn := (v_answer ->> 'document_id')::uuid;

    v_cases := v_cases + 1;
    case_name := 'inside the tolerance, Receive this order takes the whole delivery in one press';
    passed := v_state is null and (v_answer ->> 'quantity')::numeric = 43;
    detail := format('%s holds %s', v_answer ->> 'document_number', v_answer ->> 'quantity');
    return next;

    select count(*) into v_n
      from erp.event e
     where e.tenant_id = rb.tenant_id
       and e.event_type = 'document.over_received'
       and e.aggregate_id = v_grn
       and (e.payload ->> 'over_pct')::numeric = 3;

    v_cases := v_cases + 1;
    case_name := 'and it is flagged as received past the order';
    passed := v_state is null and v_n = 1;
    detail := format('%s over-received event(s) naming three per cent', v_n);
    return next;

    v_step := 'three more received: a hundred and six, past five per cent';
    begin
      perform erp.create_receipt_from_order(v_po,
                jsonb_build_array(jsonb_build_object('line_id', v_pol, 'quantity', 3)), null);
      v_msg3 := 'received';
    exception when others then v_msg3 := left(sqlerrm, 200);
    end;
    begin
      v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
      perform erp.receive_against(v_grn, v_pol, 3, null);
      v_msg4 := 'received';
    exception when others then v_msg4 := left(sqlerrm, 200);
    end;

    v_cases := v_cases + 1;
    case_name := 'past the tolerance both routes refuse, in the same words';
    passed := v_state is null
          and v_msg3 like 'CLOVEERP_OVER_DELIVERY:%'
          and v_msg4 = v_msg3;
    detail := v_msg3;
    return next;

    -- ── 7. And inside it both accept ────────────────────────────────────────
    v_step := 'two more received line by line: a hundred and five, at the tolerance';
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 2, null);
    select coalesce(sum(rel.quantity), 0) into v_qty
      from erp.document_relation rel
     where rel.tenant_id = rb.tenant_id and rel.to_line_id = v_pol and rel.relation_kind = 'fulfils';

    v_cases := v_cases + 1;
    case_name := 'up to the tolerance the line route accepts too, so the two routes agree';
    passed := v_state is null and v_qty = 105;
    detail := format('%s on receipts against the line ordered at 100', trim_scale(v_qty));
    return next;

    -- ── 8. The refusal is registered with words ─────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the refusal is registered with what was refused, why, and what to do';
    passed := v_state is null
          and exists (select 1 from erp_ref.refusal r
                       where r.code = 'CLOVEERP_OVER_DELIVERY'
                         and r.next_action like '%receipt tolerance%');
    detail := coalesce((select r.next_action from erp_ref.refusal r where r.code = 'CLOVEERP_OVER_DELIVERY'),
                       'not registered');
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzorc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzorc rolled back with its order and its receipts');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_OVER_RECEIPT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_over_receipt_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _over_receipt on commit drop as
    select * from erp_test.over_receipt_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _over_receipt;
  drop table _over_receipt;
  if v_fail > 0 then
    raise exception E'CLOVEERP_OVER_RECEIPT_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_OVER_RECEIPT_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('one rule for over-receipt: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.over_receipt_suite() from public, anon;
revoke all on function erp_test.assert_over_receipt_suite() from public, anon;

comment on function erp_test.over_receipt_suite() is
  'Definition of Done P2P-03 (20261010090000): with no tolerance set, receiving past the order is refused by both '
  'routes in the same words; inside a tolerance Receive this order takes the delivery in one press and it is '
  'flagged; past it both routes refuse.';

comment on function erp_test.assert_over_receipt_suite() is
  'erp_test.over_receipt_suite(), nine cases: P2P-03, over-receipt.';

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
