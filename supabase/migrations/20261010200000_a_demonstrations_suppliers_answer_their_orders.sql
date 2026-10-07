set lock_timeout = '30s';

-- =============================================================================
-- 20261010200000  A demonstration's suppliers answer their orders
-- -----------------------------------------------------------------------------
-- Found on the live demonstration on 7 October: Purchasing's "Awaiting
-- confirmation" list held 105 orders, every order still open since September
-- 2025, each waiting "0 days" or "1 days". On the build's seeded
-- organisation all 72 of its orders, open or closed, still await an answer.
--
-- Why. Sending an order asks its supplier to confirm it
-- (erp.await_supplier_confirmation, 20261004990000), and records the moment
-- it asked as now. The builder sends a year of orders in one go and no
-- supplier ever answers, because nothing in a demonstration answers for
-- them. So every order looks freshly sent and unanswered, including those
-- whose goods arrived months ago.
--
-- In a live organisation this is right: an order is sent now, and the
-- supplier answers through the link in its email or the buyer records it.
-- Nothing in the product changes.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.confirm_demonstration_orders(day), in a demonstration that is not
--      live: every order still awaiting an answer and sent at least two days
--      before the day is confirmed by its supplier as ordered, with an order
--      confirmation reference, OC- and the order's number. An open order goes
--      through erp.record_supplier_response(), as the supplier's link does, so
--      its lines carry the confirmed quantity and date. An order already
--      received or closed has its answer recorded and its lines left alone.
--      The answer is dated the day after the order, and the wait from the day
--      it was sent. An order sent in the last two days still waits, dated from
--      the day it was sent, so the list shows what a buyer would see.
--   B. erp.tidy_demonstration_books() confirms them first, so the builder's
--      pay day and every catch-up do it, and says how many in its result.
--      The demonstration that exists is put right by its next catch-up.
--   C. erp_test.demonstration_order_confirmation_suite proves it.
--
-- Production: production makes no demonstrations (20261010061000).
--
-- Proof: erp_test.demonstration_order_confirmation_suite.
-- =============================================================================

-- ── A. The suppliers answer ──────────────────────────────────────────────────

create or replace function erp.confirm_demonstration_orders(p_day date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  o           record;
  v_state     text;
  v_confirmed integer := 0;
  v_refused   integer := 0;
  v_note      text;
begin
  if not erp.tenant_is_demonstration(v_tenant)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = v_tenant and e.is_self and e.is_live) then
    return jsonb_build_object('confirmed', 0);
  end if;

  for o in
    select c.id as confirmation_id, d.id, d.document_number, d.document_date
      from erp.purchase_order_confirmation c
      join erp.document d on d.tenant_id = c.tenant_id and d.id = c.order_id
     where c.tenant_id = v_tenant
       and c.status = 'awaiting'
       and not d.is_cancelled
       and d.document_date <= p_day - 2
     order by d.document_date, d.document_number
  loop
    begin
      v_state := erp.object_current_state('document', o.id);
      if v_state in ('sent', 'partially_received') then
        -- As the supplier's link answers: the order as ordered.
        perform erp.record_supplier_response(
          o.id,
          jsonb_build_object('decision', 'confirm', 'supplier_reference', 'OC-' || o.document_number),
          'supplier', null);
      elsif v_state in ('received', 'closed') then
        -- Its goods have arrived, so its lines are not touched: only the
        -- answer that came before them is recorded.
        update erp.purchase_order_confirmation
           set status = 'confirmed', responded_via = 'supplier',
               supplier_reference = coalesce(supplier_reference, 'OC-' || o.document_number),
               proposal = '[]'::jsonb, updated_at = now()
         where id = o.confirmation_id;
      else
        continue;
      end if;
      update erp.purchase_order_confirmation
         set awaiting_since = o.document_date::timestamptz + interval '9 hours',
             responded_at   = least(o.document_date + 1, p_day)::timestamptz + interval '10 hours'
       where id = o.confirmation_id;
      v_confirmed := v_confirmed + 1;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('%s was not confirmed: %s', o.document_number, left(sqlerrm, 160)));
    end;
  end loop;

  -- What still waits, waits from the day it was sent.
  update erp.purchase_order_confirmation c
     set awaiting_since = d.document_date::timestamptz + interval '9 hours'
    from erp.document d
   where c.tenant_id = v_tenant and d.tenant_id = c.tenant_id and d.id = c.order_id
     and c.status = 'awaiting'
     and c.awaiting_since > d.document_date::timestamptz + interval '1 day';

  return jsonb_build_object('confirmed', v_confirmed, 'refused', v_refused, 'note', v_note);
end;
$$;

revoke all on function erp.confirm_demonstration_orders(date) from public, anon, authenticated;

comment on function erp.confirm_demonstration_orders(date) is
  'In a demonstration that is not live (20261010200000): every order awaiting its supplier''s answer and sent at '
  'least two days before the day is confirmed by its supplier as ordered, dated the day after the order. What '
  'still waits is dated from the day it was sent.';

-- ── B. The tidy has them answered ────────────────────────────────────────────

do $tidy_demonstration_books$
declare
  v_sig  constant text := 'erp.tidy_demonstration_books(date, boolean)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_bill_on   date;
$o$;
  v_new1 constant text := $n$  v_bill_on   date;
  v_answers   jsonb;
$n$;
  v_old2 constant text := $o$  -- ── The bills that follow their goods ─────────────────────────────────────
$o$;
  v_new2 constant text := $n$  -- ── The orders their suppliers answered (20261010200000) ──────────────────
  v_answers := erp.confirm_demonstration_orders(p_day);
  v_note := v_answers ->> 'note';

  -- ── The bills that follow their goods ─────────────────────────────────────
$n$;
  v_old3 constant text := $o$    'note', v_note);$o$;
  v_new3 constant text := $n$    'orders_confirmed', coalesce((v_answers ->> 'confirmed')::integer, 0),
    'note', v_note);$n$;
  n integer;
begin
  if position('erp.confirm_demonstration_orders(' in v_def) > 0 then
    raise notice '% already has the orders answered; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % v_bill_on declaration found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % bills heading found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % result found % time(s)', v_sig, n;
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$tidy_demonstration_books$;

-- ── C. The proof ─────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_order_confirmation_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_open uuid; v_open_line uuid; v_done uuid; v_done_line uuid; v_grn uuid; v_live uuid;
  v_res jsonb; v_again jsonb; v_list jsonb;
  c record; c2 record; c3 record;
  v_lines_ok boolean;
begin
  begin
    v_step := 'a demonstration organisation with finance, procurement and inventory';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzcnf' || v_tag, 'Order Confirmation Suite',
      'admin@demo-zzcnf' || v_tag || '.test', 'Order Confirmation Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzcnf' || v_tag || '.test');
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
      values (rb.tenant_id, 'ZCEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZCSITE', 'Order confirmation suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZC-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZC-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZCSUP', 'Order Confirmation Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCWID', 'Order Confirmation Suite Widget', v_uom, 'active')
    returning id into v_item;

    v_step := 'an order sent and waiting, and an order sent and received in full';
    v_open := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_open_line := erp.add_document_line(v_open, v_item, 40, 1000, 'forty, still to come');
    perform erp.transition_document(v_open, 'submit', 'order confirmation suite');
    perform erp_test.approve_document(v_open, 'order confirmation suite');
    perform erp.transition_document(v_open, 'send', 'order confirmation suite');
    v_done := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_done_line := erp.add_document_line(v_done, v_item, 20, 1000, 'twenty, all arrived');
    perform erp.transition_document(v_done, 'submit', 'order confirmation suite');
    perform erp_test.approve_document(v_done, 'order confirmation suite');
    perform erp.transition_document(v_done, 'send', 'order confirmation suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_done_line, 20, null);
    perform erp.transition_document(v_grn, 'post', 'order confirmation suite');

    -- ── 1. Sent today, it still waits ───────────────────────────────────────
    v_step := 'the books tidied the day the orders were sent';
    v_res := erp.tidy_demonstration_books(current_date, false);
    v_list := public.erp_awaiting_confirmations();
    select * into c from erp.purchase_order_confirmation x where x.tenant_id = rb.tenant_id and x.order_id = v_open;

    v_cases := v_cases + 1;
    case_name := 'an order sent today still waits for its supplier, and is listed as waiting';
    passed := v_state is null and c.status = 'awaiting'
          and coalesce((v_res ->> 'orders_confirmed')::integer, -1) = 0
          and exists (select 1 from jsonb_array_elements(v_list) e where e.value ->> 'order_id' = v_open::text);
    detail := format('%s; %s listed; %s', c.status, jsonb_array_length(v_list), v_res);
    return next;

    -- ── 2–4. A week later its supplier has answered ─────────────────────────
    v_step := 'the books tidied a week later';
    v_res := erp.tidy_demonstration_books(current_date + 7, false);
    select * into c  from erp.purchase_order_confirmation x where x.tenant_id = rb.tenant_id and x.order_id = v_open;
    select * into c2 from erp.purchase_order_confirmation x where x.tenant_id = rb.tenant_id and x.order_id = v_done;
    -- As ordered: the quantity ordered, and the date asked for, if one was.
    select bool_and(l.confirmed_quantity = l.quantity
                    and l.confirmed_date is not distinct from coalesce(l.required_date, d.required_date))
      into v_lines_ok
      from erp.document_line l
      join erp.document d on d.tenant_id = l.tenant_id and d.id = l.document_id
     where l.tenant_id = rb.tenant_id and l.document_id = v_open and not l.is_cancelled;

    v_cases := v_cases + 1;
    case_name := 'an open order is confirmed by its supplier as ordered, with their reference, and its lines carry what was confirmed';
    passed := v_state is null and c.status = 'confirmed' and c.responded_via = 'supplier'
          and c.supplier_reference = 'OC-' || (select d.document_number from erp.document d where d.id = v_open)
          and coalesce(v_lines_ok, false);
    detail := format('%s via %s, %s; lines confirmed %s', c.status, c.responded_via, c.supplier_reference, v_lines_ok);
    return next;

    v_cases := v_cases + 1;
    case_name := 'an order whose goods have all arrived has its answer recorded too';
    passed := v_state is null and c2.status = 'confirmed'
          and erp.object_current_state('document', v_done) in ('received', 'closed');
    detail := format('%s, the order %s', c2.status, erp.object_current_state('document', v_done));
    return next;

    v_cases := v_cases + 1;
    case_name := 'the answer is dated the day after the order, and the wait from the day it was sent';
    passed := v_state is null
          and c.responded_at::date = (select d.document_date + 1 from erp.document d where d.id = v_open)
          and c.awaiting_since::date = (select d.document_date from erp.document d where d.id = v_open)
          and (v_res ->> 'orders_confirmed')::integer = 2;
    detail := format('waited from %s, answered %s; %s', c.awaiting_since, c.responded_at, v_res);
    return next;

    -- ── 5. Nothing is left on the list ──────────────────────────────────────
    v_list := public.erp_awaiting_confirmations();
    v_cases := v_cases + 1;
    case_name := 'Purchasing''s list of orders awaiting confirmation is empty';
    passed := v_state is null and jsonb_array_length(v_list) = 0;
    detail := v_list::text;
    return next;

    -- ── 6. Twice is once ────────────────────────────────────────────────────
    v_again := erp.tidy_demonstration_books(current_date + 8, false);
    v_cases := v_cases + 1;
    case_name := 'tidied again, nothing more is answered';
    passed := v_state is null and (v_again ->> 'orders_confirmed')::integer = 0;
    detail := v_again::text;
    return next;

    -- ── 7. Never in a live organisation ─────────────────────────────────────
    v_step := 'an order sent, then the demonstration made live';
    v_live := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    perform erp.add_document_line(v_live, v_item, 5, 1000, 'five');
    perform erp.transition_document(v_live, 'submit', 'order confirmation suite');
    perform erp_test.approve_document(v_live, 'order confirmation suite');
    perform erp.transition_document(v_live, 'send', 'order confirmation suite');
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_again := erp.confirm_demonstration_orders(current_date + 30);
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    select * into c3 from erp.purchase_order_confirmation x where x.tenant_id = rb.tenant_id and x.order_id = v_live;

    v_cases := v_cases + 1;
    case_name := 'a demonstration that is live answers nothing for its suppliers';
    passed := v_state is null and c3.status = 'awaiting' and (v_again ->> 'confirmed')::integer = 0;
    detail := format('%s; %s', c3.status, v_again);
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzcnf' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'demo-zzcnf rolled back with its orders and their answers');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ORDER_CONFIRMATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_demonstration_order_confirmation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_order_confirmation on commit drop as
    select * from erp_test.demonstration_order_confirmation_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_order_confirmation;
  drop table _demo_order_confirmation;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ORDER_CONFIRMATION_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_ORDER_CONFIRMATION_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a demonstration''s suppliers answer their orders: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.demonstration_order_confirmation_suite() from public, anon;
revoke all on function erp_test.assert_demonstration_order_confirmation_suite() from public, anon;

comment on function erp_test.demonstration_order_confirmation_suite() is
  'A demonstration''s suppliers answer their orders (20261010200000): an order sent today still waits; two days '
  'on, open and received orders are confirmed by their supplier, dated the day after the order, Purchasing''s '
  'waiting list empties, a second tidy answers nothing more, and a live organisation is never answered for.';

comment on function erp_test.assert_demonstration_order_confirmation_suite() is
  'erp_test.demonstration_order_confirmation_suite(), eight cases.';

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
