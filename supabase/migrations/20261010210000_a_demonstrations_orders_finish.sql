set lock_timeout = '30s';

-- =============================================================================
-- 20261010210000  A demonstration's orders finish
-- -----------------------------------------------------------------------------
-- Found on the live demonstration on 7 October: Purchasing's Purchase order
-- step held 105 orders still open, from as far back as September 2025. On
-- the build's seeded organisation 34 of its 72 orders were open: 17 part
-- received and 17 sent with nothing received.
--
-- Why. Two of the builder's ways of buying never finish an order. Every
-- Monday the supplier sends half of an order "and the rest stays
-- outstanding on it" (20260918600000), for ever. And an order raised from an
-- approved requisition is sent and never received (20260922360000). Real
-- trading finishes them: the rest of a part delivery comes, or the buyer
-- closes the order short when the supplier will send nothing more; an order
-- nobody receives is cancelled.
--
-- Nothing in the product changes. Both moves already exist: a part-received
-- order is closed short with a reason (receive_rest, "Close short" on the
-- order's page, 20260922360000), and a sent order nothing was received
-- against is cancelled with a reason (erp.cancel_sent_order, 20261004990000).
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.finish_demonstration_orders(day), in a demonstration that is not
--      live: every order still sent or part received whose goods were due a
--      week or more before the day. They were due on the date the order asked
--      for, or five days after it was raised; for a part delivery, a week
--      after the last part came. Where the books still take that date, what
--      is left arrives on it, received through
--      erp.create_receipt_from_order() into the bulk store as the builder
--      receives; the tidy bills it a week later as it bills any receipt.
--      Where a month of the company's ledgers has closed over it, the order
--      is finished as a buyer finishes one then: a part-received order is
--      closed short, a sent order nothing arrived against is cancelled, each
--      with its reason on the order's history. A consignment order is left
--      alone: its goods are the supplier's and are billed as used.
--   B. erp.tidy_demonstration_books() finishes them where it bills (the
--      catch-up's tidy, not the builder's pay day), between two passes of
--      its bills: what is in is billed first, then the late orders finish,
--      then what they brought in is billed. A receipt billed after the rest
--      of its order arrived would be matched against both and disputed as
--      short. It says how many it finished in its result. The demonstration
--      that exists is put right by its next catch-up.
--   C. erp_test.demonstration_orders_finish_suite proves it.
--
-- Production: production makes no demonstrations (20261010061000).
--
-- Proof: erp_test.demonstration_orders_finish_suite.
-- =============================================================================

-- ── A. The orders finish ─────────────────────────────────────────────────────

create or replace function erp.finish_demonstration_orders(p_day date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  o           record;
  v_open      boolean;
  v_bulk      uuid;
  v_lines     jsonb;
  v_grn       uuid;
  v_received  integer := 0;
  v_short     integer := 0;
  v_cancelled integer := 0;
  v_refused   integer := 0;
  v_note      text;
begin
  if not erp.tenant_is_demonstration(v_tenant)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = v_tenant and e.is_self and e.is_live) then
    return jsonb_build_object('received', 0, 'closed_short', 0, 'cancelled', 0);
  end if;

  for o in
    select x.* from (
      select d.id, d.document_number, d.entity_id, d.site_id,
             erp.object_current_state('document', d.id) as state,
             -- When what is left was due: the date asked for, or five days
             -- after the order; for a part delivery, a week after the last
             -- part came, if that is later.
             greatest(
               coalesce((select min(l.required_date) from erp.document_line l
                          where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled),
                        d.required_date, d.document_date + 5),
               coalesce((select max(g.document_date) + 7
                           from erp.document_relation r
                           join erp.document g on g.tenant_id = r.tenant_id and g.id = r.from_document_id
                          where r.tenant_id = d.tenant_id and r.to_document_id = d.id
                            and r.relation_kind = 'fulfils' and not g.is_cancelled),
                        d.document_date)) as due
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant
         and dt.base_type_code = 'purchase_order'
         and not d.is_cancelled
         and coalesce(d.order_behaviour_code, '') <> 'consignment'
         and erp.object_current_state('document', d.id) in ('sent', 'partially_received')) x
     where x.due <= p_day - 7
     order by x.due, x.document_number
  loop
    begin
      -- The books take the day it was due unless a month of one of the
      -- company's ledgers holding it is closed or missing.
      v_open := not exists (
        select 1 from erp.ledger l
         where l.tenant_id = v_tenant and l.entity_id = o.entity_id and l.status = 'active'
           and not exists (select 1 from erp.fiscal_period fp
                            where fp.tenant_id = l.tenant_id and fp.ledger_id = l.id
                              and o.due between fp.starts_on and fp.ends_on
                              and erp.period_accepts_postings(fp.id)));
      if v_open then
        -- What is left arrives, into the bulk store, on the day it was due.
        select loc.id into v_bulk from erp.location loc
         where loc.tenant_id = v_tenant and loc.site_id = o.site_id
         order by (loc.code = 'BULK') desc, (loc.location_type = 'bulk') desc, loc.code
         limit 1;
        select jsonb_agg(jsonb_build_object(
                 'line_id', l.id,
                 'quantity', l.quantity - coalesce(l.quantity_fulfilled, 0),
                 'location_id', v_bulk) order by l.line_no)
          into v_lines
          from erp.document_line l
         where l.tenant_id = v_tenant and l.document_id = o.id and not l.is_cancelled
           and l.item_id is not null and coalesce(l.quantity_fulfilled, 0) < l.quantity;
        if v_lines is null then
          continue;
        end if;
        v_grn := (erp.create_receipt_from_order(o.id, v_lines, null) ->> 'document_id')::uuid;
        update erp.document set document_date = o.due
         where tenant_id = v_tenant and id = v_grn;
        perform erp.transition_document(v_grn, 'post', 'demonstration');
        v_received := v_received + 1;
      elsif o.state = 'partially_received' then
        perform erp.transition_document(o.id, 'receive_rest', 'The supplier could not send the rest');
        v_short := v_short + 1;
      else
        perform erp.cancel_sent_order(o.id, 'The supplier could not supply it, and the need was met from stock');
        v_cancelled := v_cancelled + 1;
      end if;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('%s was not finished: %s', o.document_number, left(sqlerrm, 160)));
    end;
  end loop;

  return jsonb_build_object('received', v_received, 'closed_short', v_short, 'cancelled', v_cancelled,
                            'refused', v_refused, 'note', v_note);
end;
$$;

revoke all on function erp.finish_demonstration_orders(date) from public, anon, authenticated;

comment on function erp.finish_demonstration_orders(date) is
  'In a demonstration that is not live (20261010210000): every order still sent or part received whose goods were '
  'due a week or more before the day is finished. What is left arrives on the day it was due where the books take '
  'that day; otherwise the order is closed short, or cancelled if nothing arrived, with the reason.';

-- ── B. The tidy finishes them ────────────────────────────────────────────────

do $tidy_demonstration_books$
declare
  v_sig  constant text := 'erp.tidy_demonstration_books(date, boolean)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_answers   jsonb;
$o$;
  v_new1 constant text := $n$  v_answers   jsonb;
  v_finished  jsonb;
  v_pass      integer;
$n$;
  v_old2 constant text := $o$  -- ── The bills that follow their goods ─────────────────────────────────────
  for g in
$o$;
  v_new2 constant text := $n$  -- ── The bills that follow their goods ─────────────────────────────────────
  -- Twice where orders finish (20261010210000): what is in is billed first,
  -- then the orders whose goods are late finish, then what they brought in
  -- is billed. A receipt billed after the rest of its order arrived would be
  -- matched against both and disputed as short.
  for v_pass in 1 .. 2 loop
  for g in
$n$;
  v_old3 constant text := $o$    end;
  end loop;

  -- ── The customers who pay ─────────────────────────────────────────────────
$o$;
  v_new3 constant text := $n$    end;
  end loop;

  -- ── The orders that finish (20261010210000) ──────────────────────────────
  -- Only where this tidy bills: the builder's pay day leaves its receipts to
  -- the catch-up.
  exit when v_pass = 2 or not p_bill;
  v_finished := erp.finish_demonstration_orders(p_day);
  v_note := coalesce(v_note, v_finished ->> 'note');
  exit when coalesce((v_finished ->> 'received')::integer, 0) = 0;
  end loop;

  -- ── The customers who pay ─────────────────────────────────────────────────
$n$;
  v_old4 constant text := $o$    'orders_confirmed', coalesce((v_answers ->> 'confirmed')::integer, 0),
$o$;
  v_new4 constant text := $n$    'orders_confirmed', coalesce((v_answers ->> 'confirmed')::integer, 0),
    'orders_received', coalesce((v_finished ->> 'received')::integer, 0),
    'orders_closed_short', coalesce((v_finished ->> 'closed_short')::integer, 0),
    'orders_cancelled', coalesce((v_finished ->> 'cancelled')::integer, 0),
$n$;
  v_olds text[] := array[v_old1, v_old2, v_old3, v_old4];
  v_news text[] := array[v_new1, v_new2, v_new3, v_new4];
  i integer;
  n integer;
begin
  if position('erp.finish_demonstration_orders(' in v_def) > 0 then
    raise notice '% already finishes the orders; left as it is', v_sig;
    return;
  end if;
  for i in 1 .. 4 loop
    n := (length(v_def) - length(replace(v_def, v_olds[i], ''))) / length(v_olds[i]);
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i, n;
    end if;
  end loop;
  for i in 1 .. 4 loop
    v_def := replace(v_def, v_olds[i], v_news[i]);
  end loop;
  execute v_def;
end
$tidy_demonstration_books$;

-- An order of forty widgets at ten pounds, raised, approved and sent today.
create or replace function erp_test.zz_finish_order(p_supplier uuid, p_entity uuid, p_site uuid, p_item uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_po uuid;
begin
  v_po := erp.open_document('purchase_order', p_supplier, p_entity, p_site);
  perform erp.add_document_line(v_po, p_item, 40, 1000, 'forty at ten pounds');
  perform erp.transition_document(v_po, 'submit', 'orders finish suite');
  perform erp_test.approve_document(v_po, 'orders finish suite');
  perform erp.transition_document(v_po, 'send', 'orders finish suite');
  return v_po;
end;
$$;

revoke all on function erp_test.zz_finish_order(uuid, uuid, uuid, uuid) from public, anon;

comment on function erp_test.zz_finish_order(uuid, uuid, uuid, uuid) is
  'A sent order of forty widgets at ten pounds, for erp_test.demonstration_orders_finish_suite (20261010210000).';

-- ── C. The proof ─────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_orders_finish_suite()
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
  v_uom uuid; v_site uuid; v_bulk uuid; v_sup uuid; v_item uuid;
  v_recent uuid; v_old_sent uuid; v_old_part uuid; v_old_part_line uuid;
  v_new_sent uuid; v_new_part uuid; v_new_part_line uuid; v_grn uuid;
  v_res jsonb; v_again jsonb; v_live jsonb;
  v_reason text; v_rcv record;
  v_open_left integer;
begin
  begin
    v_step := 'a demonstration organisation with finance, procurement and inventory';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzfin' || v_tag, 'Orders Finish Suite',
      'admin@demo-zzfin' || v_tag || '.test', 'Orders Finish Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzfin' || v_tag || '.test');
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
      values (rb.tenant_id, 'ZFEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZFSITE', 'Orders finish suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZF-RECV', 'Goods in', 'receiving');
    v_bulk := erp.create_location(v_site, 'BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZFSUP', 'Orders Finish Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZFWID', 'Orders Finish Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── The orders, each raised and sent today ──────────────────────────────
    v_step := 'three orders sent, one of them received in part';
    v_recent   := erp_test.zz_finish_order(v_sup, rb.entity_id, v_site, v_item);
    v_old_sent := erp_test.zz_finish_order(v_sup, rb.entity_id, v_site, v_item);
    v_old_part := erp_test.zz_finish_order(v_sup, rb.entity_id, v_site, v_item);
    select l.id into v_old_part_line from erp.document_line l where l.tenant_id = rb.tenant_id and l.document_id = v_old_part;
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_old_part_line, 20, null);
    perform erp.transition_document(v_grn, 'post', 'orders finish suite');

    -- ── 1. Not yet late ─────────────────────────────────────────────────────
    v_step := 'the books tidied while the goods are not yet a week late';
    v_res := erp.finish_demonstration_orders(current_date + 7);
    v_cases := v_cases + 1;
    case_name := 'an order whose goods are not yet a week late is left as it is';
    passed := v_state is null and erp.object_current_state('document', v_recent) = 'sent'
          and (v_res ->> 'received')::integer + (v_res ->> 'closed_short')::integer
              + (v_res ->> 'cancelled')::integer = 0;
    detail := v_res::text;
    return next;

    -- ── 2–3. Where the books have closed ────────────────────────────────────
    -- Every period is closed, so nothing can arrive on the day it was due.
    v_step := 'every month closed, then the books tidied three weeks on';
    update erp.fiscal_period set status = 'closed', closed_at = now()
     where tenant_id = rb.tenant_id and status = 'open';
    v_res := erp.finish_demonstration_orders(current_date + 21);
    update erp.fiscal_period set status = 'open', closed_at = null
     where tenant_id = rb.tenant_id and status = 'closed';

    select l.reason into v_reason
      from erp.state_transition_log l
     where l.tenant_id = rb.tenant_id and l.object_type = 'document' and l.object_id = v_old_part
       and l.transition_code = 'receive_rest'
     order by l.occurred_at desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'where the books have closed, a part-received order is closed short, with the reason on its history';
    passed := v_state is null
          and erp.object_current_state('document', v_old_part) in ('received', 'closed')
          and v_reason = 'The supplier could not send the rest'
          and (select coalesce(l.quantity_fulfilled, 0) from erp.document_line l where l.id = v_old_part_line) = 20;
    detail := format('%s, reason %s; %s', erp.object_current_state('document', v_old_part), coalesce(v_reason, 'none'), v_res);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and a sent order nothing arrived against is cancelled, its supplier''s answer withdrawn';
    passed := v_state is null
          and erp.object_current_state('document', v_old_sent) = 'cancelled'
          and (select c.status from erp.purchase_order_confirmation c
                where c.tenant_id = rb.tenant_id and c.order_id = v_old_sent) = 'withdrawn';
    detail := format('%s; %s', erp.object_current_state('document', v_old_sent), v_res);
    return next;

    -- ── 4–5. Where the books are open ───────────────────────────────────────
    -- Two more orders, one received in part, and the months open again.
    v_step := 'two more orders, the months open again, the books tidied three weeks on';
    v_new_sent := erp_test.zz_finish_order(v_sup, rb.entity_id, v_site, v_item);
    v_new_part := erp_test.zz_finish_order(v_sup, rb.entity_id, v_site, v_item);
    select l.id into v_new_part_line from erp.document_line l where l.tenant_id = rb.tenant_id and l.document_id = v_new_part;
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_new_part_line, 20, null);
    perform erp.transition_document(v_grn, 'post', 'orders finish suite');
    v_res := erp.finish_demonstration_orders(current_date + 21);
    select g.document_date, g.id,
           (select string_agg(distinct coalesce(gl.location_id::text, '?'), ',')
              from erp.document_line gl where gl.tenant_id = g.tenant_id and gl.document_id = g.id) as places
      into v_rcv
      from erp.document_relation r
      join erp.document g on g.tenant_id = r.tenant_id and g.id = r.from_document_id
     where r.tenant_id = rb.tenant_id and r.to_document_id = v_new_sent and r.relation_kind = 'fulfils'
     limit 1;

    v_cases := v_cases + 1;
    case_name := 'where the books are open, a sent order is received in full into the bulk store, on the day it was due';
    passed := v_state is null
          and erp.object_current_state('document', v_new_sent) in ('received', 'closed')
          and v_rcv.document_date = current_date + 5
          and v_rcv.places = v_bulk::text
          and erp.object_current_state('document', v_rcv.id) = 'posted';
    detail := format('%s; receipt dated %s into %s; %s', erp.object_current_state('document', v_new_sent),
                     v_rcv.document_date, v_rcv.places, v_res);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and a part-received order''s rest arrives a week after the part did';
    passed := v_state is null
          and erp.object_current_state('document', v_new_part) in ('received', 'closed')
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_new_part_line) = 40
          and exists (select 1 from erp.document_relation r
                        join erp.document g on g.tenant_id = r.tenant_id and g.id = r.from_document_id
                       where r.tenant_id = rb.tenant_id and r.to_document_id = v_new_part
                         and r.relation_kind = 'fulfils' and g.document_date = current_date + 7);
    detail := format('%s; %s', erp.object_current_state('document', v_new_part), v_res);
    return next;

    -- ── 6. Nothing late is left open ────────────────────────────────────────
    select count(*) into v_open_left
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'purchase_order'
       and erp.object_current_state('document', d.id) in ('sent', 'partially_received');
    v_cases := v_cases + 1;
    case_name := 'no order is left sent or part received three weeks after its goods were due';
    passed := v_state is null and v_open_left = 0
          and (v_res ->> 'received')::integer = 2 and coalesce((v_res ->> 'refused')::integer, 0) = 0;
    detail := format('%s left open; %s', v_open_left, v_res);
    return next;

    -- ── 7. Twice is once ────────────────────────────────────────────────────
    v_again := erp.tidy_demonstration_books(current_date + 22);
    v_cases := v_cases + 1;
    case_name := 'tidied again, nothing more is finished, and the tidy says how many it finished';
    passed := v_state is null
          and (v_again ->> 'orders_received')::integer = 0
          and (v_again ->> 'orders_closed_short')::integer = 0
          and (v_again ->> 'orders_cancelled')::integer = 0;
    detail := v_again::text;
    return next;

    -- ── 8. Never in a live organisation ─────────────────────────────────────
    v_step := 'an order sent, then the demonstration made live';
    v_recent := erp_test.zz_finish_order(v_sup, rb.entity_id, v_site, v_item);
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_live := erp.finish_demonstration_orders(current_date + 60);
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    v_cases := v_cases + 1;
    case_name := 'a demonstration that is live finishes nobody''s orders';
    passed := v_state is null and erp.object_current_state('document', v_recent) = 'sent'
          and (v_live ->> 'received')::integer = 0;
    detail := v_live::text;
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzfin' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'demo-zzfin rolled back with its orders and receipts');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ORDERS_FINISH_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_demonstration_orders_finish_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_orders_finish on commit drop as
    select * from erp_test.demonstration_orders_finish_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_orders_finish;
  drop table _demo_orders_finish;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ORDERS_FINISH_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_ORDERS_FINISH_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a demonstration''s orders finish: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.demonstration_orders_finish_suite() from public, anon;
revoke all on function erp_test.assert_demonstration_orders_finish_suite() from public, anon;

comment on function erp_test.demonstration_orders_finish_suite() is
  'A demonstration''s orders finish (20261010210000): an order not yet a week late is left; where the books have '
  'closed a part-received order is closed short and a sent one cancelled, with their reasons; where they are open '
  'what is left arrives on the day it was due; nothing late stays open; a second tidy finishes nothing; a live '
  'organisation is never touched.';

comment on function erp_test.assert_demonstration_orders_finish_suite() is
  'erp_test.demonstration_orders_finish_suite(), nine cases.';

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
