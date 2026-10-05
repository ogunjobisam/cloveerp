set lock_timeout = '30s';

-- =============================================================================
-- 20261007041000  Orders waiting to be collected
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-65). "Book a
-- collection" picked its order from every purchase order not yet finished:
-- drafts, orders awaiting approval, orders the supplier delivers, and orders
-- already being collected, each labelled with its raw state code.
-- erp.ship_inbound books only an order that is sent or partly received, whose
-- freight terms are We collect, and that has no collection planned or booked;
-- it refused every other order the picker offered, after the form was filled
-- in. The rows the picker read carried no freight terms, so the screen could
-- not narrow the list itself.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_orders_to_collect(p_order): the purchase orders a collection
--      can be booked for, under erp.ship_inbound's three conditions, newest
--      first, each with its supplier, site and state name. Given an order, it
--      answers that order alone, or nothing when it cannot be collected: the
--      order's own page offers "Book a collection" from it. Read under the
--      organisation's row security, as every reader is.
--      "Book a collection" picks from it; "Set freight terms" keeps every open
--      order, which is what erp.set_freight_terms accepts. Both label the
--      state by its name.
--   B. The words the picker says when no order is waiting.
--   C. erp_test.orders_to_collect_suite.
--
-- Production: one read door is added. No table is altered and no row is
-- changed.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The reader
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_orders_to_collect(p_order uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The orders a collection can be booked for (20261007041000, J-65): what
  -- erp.ship_inbound accepts, and nothing it refuses.
  select coalesce(jsonb_agg(x order by x ->> 'document_date' desc, x ->> 'document_number' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'document_id', d.id, 'document_number', d.document_number,
               'document_date', d.document_date, 'party', p.name,
               'site', st.code, 'currency', d.currency,
               'state', s.code, 'state_name', s.name) as x
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        join erp.state s on s.id = os.current_state_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.site st on st.tenant_id = d.tenant_id and st.id = d.site_id
       where d.tenant_id = erp.current_tenant_id()
         and (p_order is null or d.id = p_order)
         and dt.base_type_code = 'purchase_order'
         and not d.is_cancelled
         -- Sent to the supplier, and not yet all received.
         and s.code in ('sent', 'partially_received')
         -- We collect: what erp.order_freight_terms reads, where an order
         -- never set is the supplier's to deliver.
         and d.attributes ->> 'freight_terms' = 'we_collect'
         -- No collection planned or booked for it already.
         and not exists (
               select 1
                 from erp.shipment_line sl
                 join erp.shipment sh on sh.tenant_id = sl.tenant_id and sh.id = sl.shipment_id
                where sl.tenant_id = d.tenant_id
                  and sl.document_id = d.id
                  and sh.direction = 'inbound'
                  and sh.status in ('planned', 'booked'))
       order by d.document_date desc, d.document_number desc
       limit 200
    ) t
$$;

revoke all on function public.erp_orders_to_collect(uuid) from public, anon;
grant execute on function public.erp_orders_to_collect(uuid) to authenticated, service_role;

comment on function public.erp_orders_to_collect(uuid) is
  'The purchase orders a collection can be booked for, under erp.ship_inbound''s conditions: sent or partly '
  'received, freight terms We collect, and no collection planned or booked; given an order, that order alone or '
  'nothing (20261007041000). Reads only; row security keeps it in the organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The words
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Orders waiting to be collected (20261007041000).'
  from (values
    ('No order is waiting to be collected. Set an order''s freight terms to We collect and send it to the supplier, and it is offered here until its collection is booked.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.orders_to_collect_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_step    text := 'provisioning';
  v_state   text;
  v_entity  uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid;
  v_carrier text; v_service text;
  v_collect uuid; v_delivers uuid; v_unsent uuid;
  v_ids     uuid[]; v_ids2 uuid[];
  v_one     jsonb; v_none jsonb; v_ship jsonb;
  v_err1    text; v_err2 text; v_err3 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys and ships, a supplier and three orders';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzotc-' || v_tag, 'Orders To Collect Suite',
      'admin@zzotc-' || v_tag || '.test', 'Collection Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzotc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZOTCCOAT', 'Collected Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZOTCA');
    select c.code, c.services -> 0 ->> 'code' into v_carrier, v_service
      from erp.carrier c
     where c.tenant_id = rb.tenant_id and c.status = 'active' and jsonb_array_length(c.services) > 0
     order by c.code limit 1;
    if v_carrier is null then
      raise exception 'the demonstration configuration installs no carrier with a service';
    end if;

    -- Sent and we collect; sent and the supplier delivers; we collect but
    -- not yet sent.
    v_collect := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZOTC1', false);
    perform public.erp_set_freight_terms(v_collect, 'we_collect');
    perform erp.transition_document(v_collect, 'send', null);
    v_delivers := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 4, 9000, 'ZOTC2', true);
    v_unsent := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 2, 9000, 'ZOTC3', false);
    perform public.erp_set_freight_terms(v_unsent, 'we_collect');

    -- ── 1. Only an order a collection can be booked for ─────────────────────
    v_step := 'reading the orders waiting to be collected';
    select coalesce(array_agg((x ->> 'document_id')::uuid), '{}') into v_ids
      from jsonb_array_elements(public.erp_orders_to_collect()) x;
    v_one := public.erp_orders_to_collect(v_collect);
    v_none := public.erp_orders_to_collect(v_delivers);
    v_cases := v_cases + 1;
    case_name := 'a sent order we collect is waiting to be collected, by its state''s name; an order the supplier delivers and one not yet sent are not, and asked for by name each answers itself or nothing';
    passed := v_state is null
          and v_ids = array[v_collect]
          and jsonb_array_length(v_one) = 1
          and v_one -> 0 ->> 'document_id' = v_collect::text
          and v_one -> 0 ->> 'state' = 'sent'
          and coalesce(v_one -> 0 ->> 'state_name', '') <> ''
          and jsonb_array_length(v_none) = 0
          and jsonb_array_length(public.erp_orders_to_collect(v_unsent)) = 0;
    detail := coalesce(v_state, left(format('listed %s; asked for %s; delivers %s', v_ids, v_one, v_none), 500));
    return next;

    -- ── 2. What is offered books, and then is not offered ───────────────────
    v_step := 'booking the collection of the order offered';
    v_ship := public.erp_ship_inbound(v_collect, v_carrier, v_service, 5000, null, null, 12000);
    select coalesce(array_agg((x ->> 'document_id')::uuid), '{}') into v_ids2
      from jsonb_array_elements(public.erp_orders_to_collect()) x;
    v_cases := v_cases + 1;
    case_name := 'the order offered is one a collection is booked for, and once booked it is no longer waiting';
    passed := v_state is null
          and v_ship ->> 'status' = 'booked'
          and not (v_collect = any(v_ids2))
          and jsonb_array_length(public.erp_orders_to_collect(v_collect)) = 0;
    detail := coalesce(v_state, left(format('booked %s; listed after %s', v_ship ->> 'status', v_ids2), 500));
    return next;

    -- ── 3. What is not offered is refused ───────────────────────────────────
    v_step := 'booking the orders not offered';
    begin
      perform public.erp_ship_inbound(v_delivers, v_carrier, v_service, 5000, null, null, 12000);
      v_err1 := 'booked';
    exception when others then v_err1 := sqlerrm; end;
    begin
      perform public.erp_ship_inbound(v_unsent, v_carrier, v_service, 5000, null, null, 12000);
      v_err2 := 'booked';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_ship_inbound(v_collect, v_carrier, v_service, 5000, null, null, 12000);
      v_err3 := 'booked';
    exception when others then v_err3 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'every order not offered is one the booking refuses by name: the supplier delivers, not yet sent, already being collected';
    passed := v_state is null
          and v_err1 like 'CLOVEERP_ORDER_NOT_COLLECTED%'
          and v_err2 like 'CLOVEERP_ORDER_NOT_COLLECTED%'
          and v_err3 like 'CLOVEERP_INBOUND_ALREADY_BOOKED%';
    detail := coalesce(v_state, left(format('%s | %s | %s', v_err1, v_err2, v_err3), 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_ORDERS_TO_COLLECT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.orders_to_collect_suite() from public, anon;

comment on function erp_test.orders_to_collect_suite() is
  'Orders waiting to be collected (20261007041000, J-65): erp_orders_to_collect offers a sent order we collect and '
  'not one the supplier delivers, one not yet sent or one already being collected; the order offered books, and '
  'every order not offered is refused by erp_ship_inbound by name.';

create or replace function erp_test.assert_orders_to_collect_suite()
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
    from erp_test.orders_to_collect_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ORDERS_TO_COLLECT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Book a collection offers an order the booking refuses, or leaves out one it accepts. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_ORDERS_TO_COLLECT_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('orders waiting to be collected: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_orders_to_collect_suite() from public, anon;

comment on function erp_test.assert_orders_to_collect_suite() is
  'erp_orders_to_collect offers what erp_ship_inbound books and nothing it refuses (20261007041000).';

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
