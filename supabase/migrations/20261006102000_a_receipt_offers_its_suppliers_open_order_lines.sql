set lock_timeout = '30s';

-- =============================================================================
-- 20261006102000  A receipt offers its supplier's open order lines
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-10). Receive against
-- an order, on Purchasing's goods receipt step, said nothing about what it
-- does, and its order-line picker listed the open lines of every supplier's
-- orders, each by the quantity ordered. A buyer receiving three of ten picked
-- from lines that were not this supplier's and could not see what was left.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_receipt_order_lines(receipt): the lines of orders sent to
--      the receipt's own supplier that have something left to receive, each
--      with what is left, read through erp.receivable_lines(), the reader
--      Receive an order already uses, so the two cannot disagree about what
--      is open. A drop-ship order is left out: its goods never arrive here.
--      Read under the organisation's row security, as every reader is.
--   B. The words the step says.
--   C. erp_test.receipt_order_lines_suite.
--
-- Production: no row is changed.
--
-- Proof: erp_test.receipt_order_lines_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The reader
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_receipt_order_lines(p_receipt_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The open lines of orders sent to this receipt's supplier, with what is
  -- left on each (20261006102000). erp.receive_against() refuses any other.
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_id', x.line_id,
           'document_id', o.id,
           'document_number', o.document_number,
           'line_no', x.line_no,
           'item', i.code,
           'item_name', i.name,
           'description', dl.description,
           'ordered_quantity', x.ordered_quantity,
           'open_quantity', x.open_quantity)
         order by o.document_number, x.line_no), '[]'::jsonb)
    from erp.document r
    join erp.document_type rdt on rdt.tenant_id = r.tenant_id and rdt.id = r.document_type_id
    join erp.document o on o.tenant_id = r.tenant_id and o.party_id = r.party_id
    join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
    join erp.object_state os
      on os.tenant_id = o.tenant_id and os.object_type = 'document' and os.object_id = o.id
    join erp.state s on s.id = os.current_state_id
    cross join lateral erp.receivable_lines(o.id) x
    join erp.document_line dl on dl.tenant_id = o.tenant_id and dl.id = x.line_id
    left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
   where r.tenant_id = erp.current_tenant_id()
     and r.id = p_receipt_id
     and rdt.base_type_code = 'receipt'
     and odt.base_type_code = 'purchase_order'
     and s.code in ('sent', 'partially_received')
     and not o.is_cancelled
     and coalesce(o.order_behaviour_code, '') <> 'drop_ship'
     and x.open_quantity > 0
$$;

revoke all on function public.erp_receipt_order_lines(uuid) from public, anon;
grant execute on function public.erp_receipt_order_lines(uuid) to authenticated, service_role;

comment on function public.erp_receipt_order_lines(uuid) is
  'The open lines of orders sent to a goods receipt''s supplier, each with what is left to receive, read through '
  'erp.receivable_lines (20261006102000). Reads only; row security keeps it in the organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The words the step says
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A receipt offers its supplier''s open order lines (20261006102000).'
  from (values
    ('Adds a line to a goods receipt still in draft, against a line of an order sent to the same supplier. Each line shows what is left to receive on it.'),
    ('Nothing is left to receive from this receipt''s supplier: every line of their sent orders has been received, or is on a goods receipt already.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.receipt_order_lines_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_sb uuid;
  v_po_a   uuid; v_po_a2 uuid; v_po_b uuid; v_pol uuid;
  v_g      uuid;
  v_rows   jsonb;
begin
  begin
    v_step := 'two suppliers, each with an order sent, and one order not yet sent';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzrol-' || v_tag, 'Receipt Order Lines Suite',
      'admin@zzrol-' || v_tag || '.test', 'Receipt Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzrol-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZROLCOAT', 'Receipt Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZROLA');
    v_sb := erp_test.cash_payment_supplier('ZROLB');
    v_po_a := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZROLA1', true);
    v_po_a2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 3, 9000, 'ZROLA2', false);
    v_po_b := erp_test.prepayment_order(v_entity, v_site, v_item, v_sb, 7, 9000, 'ZROLB1', true);
    select l.id into v_pol from erp.document_line l where l.document_id = v_po_a order by l.line_no limit 1;
    v_g := erp.open_document('goods_receipt', v_sa, v_entity, v_site);

    -- ── 1. Only this supplier's sent orders ───────────────────────────────────
    v_step := 'reading the lines a receipt from the first supplier is offered';
    v_rows := public.erp_receipt_order_lines(v_g);
    v_cases := v_cases + 1;
    case_name := 'a receipt is offered the open lines of orders sent to its own supplier, and no other supplier''s';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'line_id')::uuid = v_pol
          and (v_rows -> 0 ->> 'open_quantity')::numeric = 10;
    detail := coalesce(v_state, v_rows::text);
    return next;

    -- ── 2. What is left ───────────────────────────────────────────────────────
    v_step := 'receiving four of the ten on the draft';
    perform erp.receive_against(v_g, v_pol, 4, null);
    v_rows := public.erp_receipt_order_lines(v_g);
    v_cases := v_cases + 1;
    case_name := 'each line says what is left to receive, counting what is already on a receipt';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 1
          and (v_rows -> 0 ->> 'open_quantity')::numeric = 6
          and (v_rows -> 0 ->> 'ordered_quantity')::numeric = 10;
    detail := coalesce(v_state, v_rows::text);
    return next;

    -- ── 3. Nothing left ───────────────────────────────────────────────────────
    v_step := 'receiving the other six';
    perform erp.receive_against(v_g, v_pol, 6, null);
    v_rows := public.erp_receipt_order_lines(v_g);
    v_cases := v_cases + 1;
    case_name := 'a line with nothing left is no longer offered';
    passed := v_state is null and jsonb_array_length(v_rows) = 0;
    detail := coalesce(v_state, v_rows::text);
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
    raise exception 'CLOVEERP_RECEIPT_ORDER_LINES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.receipt_order_lines_suite() from public, anon;

comment on function erp_test.receipt_order_lines_suite() is
  'A receipt offers its supplier''s open order lines, each with what is left (20261006102000).';

create or replace function erp_test.assert_receipt_order_lines_suite()
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
    from erp_test.receipt_order_lines_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_RECEIPT_ORDER_LINES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Receiving against an order would offer another supplier''s lines, or not say what is left. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_RECEIPT_ORDER_LINES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('receipt order lines: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_receipt_order_lines_suite() from public, anon;

comment on function erp_test.assert_receipt_order_lines_suite() is
  'A goods receipt is offered its own supplier''s open order lines with what is left on each (20261006102000).';

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
