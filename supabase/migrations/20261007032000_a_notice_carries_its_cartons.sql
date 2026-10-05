set lock_timeout = '30s';

-- =============================================================================
-- 20261007032000  A buyer's notice carries its cartons, and receiving one
--                 arrives holding its lines
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October:
--
--   J-70  "Receive a carton" could not succeed in the demonstration. Cartons
--         came only from the supplier's emailed link, which a demonstration
--         never sends: the buyer's "Record a shipping notice" had no carton
--         fields, although its door has always taken them
--         (erp.record_buyer_shipping_notice hands p_notice, cartons and all,
--         to erp.record_shipping_notice).
--   J-59  "Receive what arrived" opened empty, and each line that differed
--         had to be added by hand, although the notice's lines were already
--         on the order's page.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
-- No door changes. The screen does the rest:
--
--   A. The words of the buyer's new Cartons rows: a row per line a carton
--      holds, by the SSCC on its label, and that the cartons together hold
--      exactly what the lines say, as the door refuses otherwise
--      (CLOVEERP_CARTON_INVALID).
--   B. "Receive what arrived" on a notice still wholly on its way arrives
--      holding the notice's lines at what it said, read from
--      public.erp_order_shipping_notices: notices[].lines within the notice
--      whose notice_id the dialog was opened on. The screen-columns check
--      cannot read inside erp.shipping_notice(), which writes each notice
--      that door aggregates, so it is told so in erp_meta.app_column_allowance.
--      A part-received notice arrives empty: its quantities are not what is
--      left, and a line left out is still taken as what is left of it.
--   C. erp_test.buyer_notice_cartons_suite: a buyer records a notice with
--      cartons, cartons that do not add up are refused, a carton is received
--      by its label, and a notice's own lines sent back untouched are received
--      as notified with nothing different.
--
-- Production: three resource rows and two register rows are added. No
-- function, table or other row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A buyer''s notice carries its cartons (20261007032000).'
  from (values
    ('Cartons'),
    ('Add a carton'),
    ('Optional. For cartons with an SSCC label: a row for each line a carton holds. Together the cartons must hold exactly what the lines above say.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What the screen reads of a notice's lines
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.app_column_allowance (door, column_name, reason) values
  ('erp_order_shipping_notices', 'notices.notice_id',
   'Answered: notices is jsonb_agg(erp.shipping_notice(n.id)), and erp.shipping_notice writes notice_id. The '
   'column report reads the keys a door''s own body writes and cannot read through that call. "Receive what '
   'arrived" finds the notice it was opened on by it (20261007032000, J-59).'),
  ('erp_order_shipping_notices', 'notices.lines',
   'Answered: erp.shipping_notice writes lines, each with order_line_id and quantity, inside the notices this '
   'door aggregates; the column report cannot read through that call. "Receive what arrived" arrives holding '
   'them (20261007032000, J-59).')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.buyer_notice_cartons_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_coat uuid; v_scarf uuid; v_sa uuid;
  v_po     uuid; v_l1 uuid; v_l2 uuid;
  v_n1     jsonb; v_n2 jsonb; v_page jsonb; v_lines jsonb; v_r jsonb;
  v_err    text;
  v_count  integer;
  c1 constant text := '350123451234567894';
  c2 constant text := '350123451234567900';
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, and an order of coats and scarves sent to its supplier';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzbnc-' || v_tag, 'Buyer Notice Cartons Suite',
      'admin@zzbnc-' || v_tag || '.test', 'Buyer Notice Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzbnc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZBNCOAT', 'Buyer Notice Coat', v_uom, 'active') returning id into v_coat;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZBNSCARF', 'Buyer Notice Scarf', v_uom, 'active') returning id into v_scarf;
    v_sa := erp_test.cash_payment_supplier('ZBNBRAND');
    v_po := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    perform erp.add_document_line(v_po, v_coat, 10, 9000, 'bought for ZBN1');
    perform erp.add_document_line(v_po, v_scarf, 10, 1000, 'scarves for ZBN1');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'buyer notice cartons suite');
    perform erp.transition_document(v_po, 'send', null);
    select l.id into v_l1 from erp.document_line l where l.document_id = v_po and l.item_id = v_coat;
    select l.id into v_l2 from erp.document_line l where l.document_id = v_po and l.item_id = v_scarf;

    -- ── 1. Cartons that do not add up ───────────────────────────────────────
    v_step := 'the buyer records six coats and four scarves, with cartons holding five coats';
    begin
      perform public.erp_record_shipping_notice(v_po, jsonb_build_object(
        'expected_arrival', (current_date + 3)::text,
        'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 6),
                                   jsonb_build_object('order_line_id', v_l2, 'quantity', 4)),
        'cartons', jsonb_build_array(
          jsonb_build_object('sscc', c1, 'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 5))),
          jsonb_build_object('sscc', c2, 'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l2, 'quantity', 4))))));
      v_err := 'notified';
    exception when others then v_err := sqlerrm;
    end;
    select count(*) into v_count from erp.shipping_notice n where n.tenant_id = rb.tenant_id and n.order_id = v_po;
    v_cases := v_cases + 1;
    case_name := 'a buyer''s notice whose cartons do not hold what its lines say is refused by name, and nothing is recorded';
    passed := v_state is null and v_err like 'CLOVEERP_CARTON_INVALID:%' and v_count = 0;
    detail := coalesce(v_state, left(format('%s | notices %s', v_err, v_count), 500));
    return next;

    -- ── 2. The buyer records cartons ────────────────────────────────────────
    v_step := 'the buyer records six coats and four scarves in two labelled cartons';
    v_n1 := public.erp_record_shipping_notice(v_po, jsonb_build_object(
      'expected_arrival', (current_date + 3)::text,
      'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 6),
                                 jsonb_build_object('order_line_id', v_l2, 'quantity', 4)),
      'cartons', jsonb_build_array(
        jsonb_build_object('sscc', '(00)' || c1, 'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 6))),
        jsonb_build_object('sscc', c2, 'contents', jsonb_build_array(jsonb_build_object('order_line_id', v_l2, 'quantity', 4))))));
    v_page := public.erp_order_shipping_notices(v_po);
    v_cases := v_cases + 1;
    case_name := 'a notice the buyer records with two labelled cartons holds them, and the order''s page reads them with the notice';
    passed := v_state is null
          and v_n1 ->> 'sent_via' = 'buyer'
          and v_n1 ->> 'status' = 'notified'
          and jsonb_array_length(v_n1 -> 'cartons') = 2
          and (select count(*) from jsonb_array_elements(v_page -> 'notices') x
                where x ->> 'notice_id' = v_n1 ->> 'notice_id'
                  and jsonb_array_length(x -> 'cartons') = 2) = 1;
    detail := coalesce(v_state, left(v_n1::text, 500));
    return next;

    -- ── 3. A carton, scanned ────────────────────────────────────────────────
    v_step := 'the coats'' carton received by its label';
    v_r := public.erp_receive_notified_carton('(00)' || c1);
    v_cases := v_cases + 1;
    case_name := 'scanning the label of a carton the buyer recorded receives the six coats in a posted receipt; the notice is part received';
    passed := v_state is null
          and v_r ->> 'status' = 'part_received'
          and erp.object_current_state('document', (v_r ->> 'receipt_id')::uuid) = 'posted'
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_l1) = 6
          and jsonb_array_length(v_r -> 'differences') = 0;
    detail := coalesce(v_state, left(coalesce(v_r::text, 'nothing'), 500));
    return next;

    -- ── 4. What arrived, as the notice said ─────────────────────────────────
    -- "Receive what arrived" arrives holding the notice's own lines, read from
    -- the order's page; untouched, they are sent back as they were.
    v_step := 'two more coats notified, and received with the notice''s own lines sent back';
    v_n2 := public.erp_record_shipping_notice(v_po, jsonb_build_object(
      'expected_arrival', (current_date + 4)::text,
      'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 2))));
    v_page := public.erp_order_shipping_notices(v_po);
    select coalesce(jsonb_agg(jsonb_build_object('order_line_id', l ->> 'order_line_id', 'quantity', l -> 'quantity')), '[]'::jsonb)
      into v_lines
      from jsonb_array_elements(v_page -> 'notices') x, jsonb_array_elements(x -> 'lines') l
     where x ->> 'notice_id' = v_n2 ->> 'notice_id';
    v_r := public.erp_receive_as_notified((v_n2 ->> 'notice_id')::uuid, v_lines);
    v_cases := v_cases + 1;
    case_name := 'a notice''s own lines as the order''s page reads them, sent back untouched, are received as notified with nothing different';
    passed := v_state is null
          and jsonb_array_length(v_lines) = 1
          and v_lines -> 0 ->> 'order_line_id' = v_l1::text
          and (v_lines -> 0 ->> 'quantity')::numeric = 2
          and v_r ->> 'status' = 'received'
          and jsonb_array_length(v_r -> 'differences') = 0
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_l1) = 8;
    detail := coalesce(v_state, left(format('%s | %s', v_lines, v_r), 500));
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
    raise exception 'CLOVEERP_BUYER_NOTICE_CARTONS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.buyer_notice_cartons_suite() from public, anon;

comment on function erp_test.buyer_notice_cartons_suite() is
  'A buyer''s notice carries its cartons (20261007032000, J-70, J-59): cartons that do not add up are refused, '
  'cartons the buyer records are held and received by their label, and a notice''s own lines sent back '
  'untouched are received as notified with nothing different.';

create or replace function erp_test.assert_buyer_notice_cartons_suite()
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
    from erp_test.buyer_notice_cartons_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_BUYER_NOTICE_CARTONS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A buyer''s cartons, or a notice''s own lines sent back, are not received as notified. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_BUYER_NOTICE_CARTONS_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a buyer''s notice carries its cartons: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_buyer_notice_cartons_suite() from public, anon;

comment on function erp_test.assert_buyer_notice_cartons_suite() is
  'A buyer records cartons on a notice, goods-in receives one by its label, and a notice''s own lines are '
  'received as notified (20261007032000).';

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
