set lock_timeout = '30s';

-- =============================================================================
-- 20261010220000  A cancelled order's requisition closes with it
-- -----------------------------------------------------------------------------
-- Found on the live demonstration on 7 October, after 20261010210000 was
-- released: Purchasing's Approval step went from 0 to 44. The release's
-- catch-up cancelled the old orders raised from requisitions that nothing was
-- ever received against, saying the need was met from stock. A cancelled
-- order gives its requisition back (20261006111000), so each of the 44 read
-- Approved again, waiting to be ordered, the oldest from February.
--
-- The product is right to give a requisition back when its order is
-- cancelled: usually somebody still needs the goods. Here the reason given is
-- that nobody does, so the requisition is finished with its order.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.finish_demonstration_orders(day), in a demonstration that is not
--      live, also cancels every requisition that has stood Approved for two
--      weeks or more before the day, with the reason its order was
--      cancelled for: "The need was met from stock". The requisitions its own
--      cancellations give back are among them, so the 44 on the live
--      demonstration are finished by its next catch-up. The builder approves
--      a requisition and orders it in the same press, so nothing else stands
--      Approved that long. It says how many in its result.
--   B. erp_test.cancelled_order_requisition_suite proves it.
--
-- Production: production makes no demonstrations (20261010061000).
--
-- Proof: erp_test.cancelled_order_requisition_suite.
-- =============================================================================

do $finish_demonstration_orders$
declare
  v_sig  constant text := 'erp.finish_demonstration_orders(date)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_cancelled integer := 0;
$o$;
  v_new1 constant text := $n$  v_cancelled integer := 0;
  v_requisitions integer := 0;
$n$;
  v_old2 constant text := $o$  return jsonb_build_object('received', v_received, 'closed_short', v_short, 'cancelled', v_cancelled,
$o$;
  v_new2 constant text := $n$  -- ── Requisitions nobody orders (20261010220000) ───────────────────────────
  -- A cancelled order gives its requisition back, Approved. Cancelled here
  -- because the need was met from stock, the requisition is finished with
  -- it, and so is any other left Approved two weeks.
  for o in
    select d.id, d.document_number
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant
       and dt.base_type_code = 'requisition'
       and not d.is_cancelled
       and d.document_date <= p_day - 14
       and erp.object_current_state('document', d.id) = 'approved'
     order by d.document_date, d.document_number
  loop
    begin
      perform erp.transition_document(o.id, 'cancel_approved', 'The need was met from stock');
      v_requisitions := v_requisitions + 1;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('%s was not cancelled: %s', o.document_number, left(sqlerrm, 160)));
    end;
  end loop;

  return jsonb_build_object('received', v_received, 'closed_short', v_short, 'cancelled', v_cancelled,
                            'requisitions_cancelled', v_requisitions,
$n$;
  n integer;
begin
  if position('20261010220000' in v_def) > 0 then
    raise notice '% already finishes requisitions; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % v_cancelled declaration found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % result found % time(s)', v_sig, n;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$finish_demonstration_orders$;

comment on function erp.finish_demonstration_orders(date) is
  'In a demonstration that is not live (20261010210000): every order still sent or part received whose goods were '
  'due a week or more before the day is finished. What is left arrives on the day it was due where the books take '
  'that day; otherwise the order is closed short, or cancelled if nothing arrived, with the reason. A requisition '
  'left Approved two weeks, as a cancelled order leaves it, is cancelled with it (20261010220000).';

create or replace function erp_test.cancelled_order_requisition_suite()
returns table (case_name text, passed boolean, detail text)
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
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid; v_ccy char(3);
  v_req uuid; v_po uuid; v_fresh uuid;
  v_res jsonb; v_again jsonb;
  v_reason text;
begin
  begin
    v_step := 'a demonstration organisation with finance, procurement and inventory';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzreq' || v_tag, 'Cancelled Order Requisition Suite',
      'admin@demo-zzreq' || v_tag || '.test', 'Requisition Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzreq' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();
    select e.base_currency into v_ccy from erp.entity e where e.id = rb.entity_id;

    v_step := 'its own unit, site, places, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZQEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZQSITE', 'Requisition suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZQ-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZQSUP', 'Requisition Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZQWID', 'Requisition Suite Widget', v_uom, 'active')
    returning id into v_item;

    v_step := 'a requisition approved and ordered, the order sent, as the builder raises one';
    v_req := erp.create_document('requisition', rb.entity_id, v_site, v_sup, current_date, v_ccy, 'ZQ-REQ', '{}'::jsonb);
    perform erp.add_document_line(v_req, v_item, 12, 1000, 'twelve widgets', current_date + 10);
    perform erp.transition_document(v_req, 'submit', 'requisition suite');
    perform erp.approve_my_document_tasks(v_req, 'requisition suite');
    perform erp.transition_document(v_req, 'approve', 'requisition suite');
    v_po := (erp.convert_document(v_req, v_sup, null, null, null) ->> 'document_id')::uuid;
    if erp.object_current_state('document', v_po) = 'draft' then
      perform erp.transition_document(v_po, 'submit', 'requisition suite');
      perform erp_test.approve_document(v_po, 'requisition suite');
    end if;
    perform erp.transition_document(v_po, 'send', 'requisition suite');

    -- ── 1–2. Its order cancelled where the books have closed ────────────────
    v_step := 'every month closed, the orders finished a month on';
    update erp.fiscal_period set status = 'closed', closed_at = now()
     where tenant_id = rb.tenant_id and status = 'open';
    v_res := erp.finish_demonstration_orders(current_date + 30);
    update erp.fiscal_period set status = 'open', closed_at = null
     where tenant_id = rb.tenant_id and status = 'closed';
    select l.reason into v_reason
      from erp.state_transition_log l
     where l.tenant_id = rb.tenant_id and l.object_type = 'document' and l.object_id = v_req
       and l.transition_code = 'cancel_approved'
     order by l.occurred_at desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'an order cancelled because the need was met from stock leaves its requisition cancelled, not approved';
    passed := v_state is null
          and erp.object_current_state('document', v_po) = 'cancelled'
          and erp.object_current_state('document', v_req) = 'cancelled'
          and v_reason = 'The need was met from stock'
          and (v_res ->> 'requisitions_cancelled')::integer = 1;
    detail := format('order %s, requisition %s, reason %s; %s', erp.object_current_state('document', v_po),
                     erp.object_current_state('document', v_req), coalesce(v_reason, 'none'), v_res);
    return next;

    -- ── 3. A requisition approved this week waits to be ordered ─────────────
    v_step := 'a requisition approved today and not yet ordered';
    v_fresh := erp.create_document('requisition', rb.entity_id, v_site, v_sup, current_date, v_ccy, 'ZQ-REQ2', '{}'::jsonb);
    perform erp.add_document_line(v_fresh, v_item, 6, 1000, 'six widgets', current_date + 10);
    perform erp.transition_document(v_fresh, 'submit', 'requisition suite');
    perform erp.approve_my_document_tasks(v_fresh, 'requisition suite');
    perform erp.transition_document(v_fresh, 'approve', 'requisition suite');
    v_again := erp.finish_demonstration_orders(current_date + 7);

    v_cases := v_cases + 1;
    case_name := 'a requisition approved less than two weeks ago still waits to be ordered';
    passed := v_state is null and erp.object_current_state('document', v_fresh) = 'approved'
          and (v_again ->> 'requisitions_cancelled')::integer = 0;
    detail := format('%s; %s', erp.object_current_state('document', v_fresh), v_again);
    return next;

    -- ── 4. Never in a live organisation ─────────────────────────────────────
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_again := erp.finish_demonstration_orders(current_date + 60);
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    v_cases := v_cases + 1;
    case_name := 'a demonstration that is live cancels no requisition';
    passed := v_state is null and erp.object_current_state('document', v_fresh) = 'approved';
    detail := format('%s; %s', erp.object_current_state('document', v_fresh), v_again);
    return next;

    -- ── 5. Two weeks on it is finished too ──────────────────────────────────
    v_again := erp.finish_demonstration_orders(current_date + 14);
    v_cases := v_cases + 1;
    case_name := 'two weeks on, a requisition still approved and never ordered is cancelled';
    passed := v_state is null and erp.object_current_state('document', v_fresh) = 'cancelled'
          and (v_again ->> 'requisitions_cancelled')::integer = 1;
    detail := format('%s; %s', erp.object_current_state('document', v_fresh), v_again);
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzreq' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'demo-zzreq rolled back with its requisitions and orders');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CANCELLED_ORDER_REQUISITION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_cancelled_order_requisition_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _cancelled_order_requisition on commit drop as
    select * from erp_test.cancelled_order_requisition_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _cancelled_order_requisition;
  drop table _cancelled_order_requisition;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CANCELLED_ORDER_REQUISITION_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_CANCELLED_ORDER_REQUISITION_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a cancelled order''s requisition closes with it: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.cancelled_order_requisition_suite() from public, anon;
revoke all on function erp_test.assert_cancelled_order_requisition_suite() from public, anon;

comment on function erp_test.cancelled_order_requisition_suite() is
  'A cancelled order''s requisition closes with it (20261010220000): a demonstration order cancelled because the '
  'need was met from stock leaves its requisition cancelled with that reason; one approved less than two weeks ago '
  'waits; a live organisation is untouched; two weeks on an unordered approved requisition is cancelled.';

comment on function erp_test.assert_cancelled_order_requisition_suite() is
  'erp_test.cancelled_order_requisition_suite(), five cases.';

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
