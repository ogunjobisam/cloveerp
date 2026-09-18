set lock_timeout = '30s';

-- =============================================================================
-- 20260920120000  A received line carries a price
-- -----------------------------------------------------------------------------
-- A goods receipt was raised for Yorkshire Oats Ltd: one line, OAT-25, quantity
-- ten, unit price left empty. The form says, under the lines:
--
--     "A line left without a price takes the agreed price for that partner and
--      product, where there is one."
--
-- The running total stayed at GBP 0.00, the record was created, and the line
-- reads 10 x GBP 0.00. Nothing was said at any point.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Which of the two it was
--
-- The friction log left it open — either the lookup is not firing, or there is
-- no agreed price and nothing says so. It is both, and the first is the more
-- interesting, because the rule had already been written twice and neither
-- copy covered a receipt:
--
--   erp.add_document_line() prices an unpriced line from the supplier
--   catalogue when the base type is 'purchase_order' (20260906130000), and from
--   the customer catalogue when erp.document_trade_side() says 'sale'
--   (20260916160000). A goods receipt is neither: its base type is 'receipt'
--   and its party is a supplier, so both conditions are false and the price
--   stays nought.
--
--   erp.create_document_full() prices an unpriced line from the CUSTOMER
--   catalogue for everything that is not a purchase order (20260910180854), and
--   swallows every error while doing it. That is the one that ran. It asked
--   what the customer price list says Yorkshire Oats Ltd should pay US for
--   rolled oats, found nothing, and said nothing.
--
-- So 20260916160000 closed this gap for the sales side and left the buying side
-- half open: a purchase order is priced, and every receipt, return to supplier
-- and supplier bill is not.
--
-- Worse than not firing: erp.resolve_price() matches a price row whose
-- party_role_id is null, which is the ordinary sales list. So a receipt whose
-- product has a sales list price — most products — was not merely left at
-- nought by that path. It could be received onto the books at the price we
-- sell it for.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What decides
--
-- erp.document_type_party_role_kind() (20260916042000) reads which side of the
-- trade a type is on from the permission the type requires: a sales.* type
-- stands its party as a customer, a procurement.* type as a supplier. A type
-- added tomorrow is placed by the module that raises it.
--
-- 'purchase_order' is kept beside it as a disjunct rather than replaced by it.
-- The two agree for every type this product ships, and where a tenant's own
-- type disagrees, the condition that has been pricing orders since
-- 20260906130000 is the one that must not stop.
--
-- erp.create_document_full() stops keeping its own copy. It is not merely
-- redundant now — it is the wrong catalogue, one line before the right one.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And when the catalogue is silent
--
-- Asking the right catalogue does not make a price appear, and the log's second
-- finding stands on its own: a receipt at nil value raises a nil GRNI accrual
-- against real goods, and nothing said so.
--
-- The refusal is scoped to the documents where the line's price IS the value.
-- erp.post_document_stock() hands unit_price_minor to erp.receive_cost() for an
-- inbound movement, so stock arrives on the books at whatever the line says. In
-- product-content terms that is a base type with flow 'inbound' that affects
-- stock, which today is exactly 'receipt' and tomorrow is exactly whatever a
-- tenant builds on it.
--
-- Deliberately NOT refused, so the next person does not widen it by accident:
--
--   * A purchase order line. An order commits and values nothing; a draft may
--     stay unpriced while somebody rings the supplier, and
--     erp.price_document_line() refuses that by name when the time comes.
--     Widening the refusal to orders would break a flow that works, on the
--     strength of a defect found somewhere else.
--   * An outbound line. A delivery's cost comes from erp.issue_cost() and its
--     revenue from the order behind it; the line price is not the valuation.
--   * A line on a document with no party. There is no catalogue to ask, and a
--     works order consuming components is not a purchase.
--
-- Every one of the 62 receipt lines this repository writes already passes a
-- price, so nothing that passes today is refused by this.
--
-- Proof: erp_test.received_line_price_suite(), 6 cases.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The buying side reaches past the order
--
-- Three needles against the live body, which is the 20260906130000 body as
-- patched by 20260914040000 (erp.line_description), 20260916540000 (the unit
-- and its guard) and 20260916160000 (the sales side). Re-emitting the whole
-- function would silently drop all three, so it is not re-emitted.
-- ═════════════════════════════════════════════════════════════════════════════

do $add_line$
declare
  v_sig    constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def    text := pg_get_functiondef('erp.add_document_line(uuid,uuid,numeric,bigint,text,date)'::regprocedure);

  -- (a) one more answer for the body to hold
  v_dec_old constant text := E'  pr       record;\nbegin\n';
  v_dec_new constant text := E'  pr       record;\n  v_valued boolean;\nbegin\n';

  -- (b) the buying side, which stopped at the order
  v_buy_old constant text := E'  if v_base = ''purchase_order'' and v_price = 0 then\n';
  v_buy_new constant text :=
       E'  -- Every document that buys, not only the order. This read the supplier\n'
    || E'  -- catalogue for a purchase order and nothing else, so a goods receipt fell\n'
    || E'  -- through to erp.create_document_full(), which asked the CUSTOMER list and\n'
    || E'  -- wrote the line at nought. The type says which side it is on.\n'
    || E'  if v_price = 0\n'
    || E'     and (v_base = ''purchase_order''\n'
    || E'          or erp.document_type_party_role_kind(v_tenant, d.document_type_id)\n'
    || E'             = ''supplier'') then\n';

  -- (c) and the refusal, before the line number is taken
  v_guard_old constant text :=
    E'  select coalesce(max(l.line_no), 0) + 10 into v_line\n';
  v_guard_new constant text :=
       E'  -- Stock coming in is valued at the price on its line:\n'
    || E'  -- erp.post_document_stock() hands unit_price_minor to erp.receive_cost().\n'
    || E'  -- A receipt line at nought is real goods taken onto the books at nothing,\n'
    || E'  -- and a GRNI accrual of nothing owed for them. An ORDER may still be\n'
    || E'  -- drafted unpriced, because nothing is valued yet.\n'
    || E'  select bt.flow = ''inbound'' and bt.affects_stock into v_valued\n'
    || E'    from erp_ref.document_type bt where bt.code = v_base;\n'
    || E'\n'
    || E'  if coalesce(v_valued, false) and v_price = 0 then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE: % on % has no price, and no ''\n'
    || E'      ''agreed price is on record for this supplier and product'',\n'
    || E'      coalesce((select i.code from erp.item i\n'
    || E'                 where i.tenant_id = v_tenant and i.id = p_item_id), ''the product''),\n'
    || E'      d.document_number\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Put the price you are being charged on the line, or agree a ''\n'
    || E'                   ''price with this supplier on the Item suppliers screen so ''\n'
    || E'                   ''every line fills itself.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  select coalesce(max(l.line_no), 0) + 10 into v_line\n';
begin
  if position('CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already refuses an unpriced received line', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_dec_old, ''))) / length(v_dec_old) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not end its declarations once the way the 20260906130000 body does', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_buy_old, ''))) / length(v_buy_old) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not open its buying-side pricing once the way the 20260906130000 body does', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_guard_old, ''))) / length(v_guard_old) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not take its line number once the way the 20260906130000 body does', v_sig;
  end if;
  -- The sales side 20260916160000 added has to still be there afterwards, and
  -- it is the piece a careless re-emission would take away.
  if position('erp.document_trade_side(p_document_id) = ''sale''' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry the sales side 20260916160000 gave it', v_sig;
  end if;

  v_def := replace(v_def, v_dec_old,   v_dec_new);
  v_def := replace(v_def, v_buy_old,   v_buy_new);
  v_def := replace(v_def, v_guard_old, v_guard_new);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE' in v_def) = 0
     or position('erp.document_type_party_role_kind(v_tenant, d.document_type_id)' in v_def) = 0
     or position('erp.document_trade_side(p_document_id) = ''sale''' in v_def) = 0
     or position('erp.require_quantity_fits_uom(' in v_def) = 0
     or position('erp.item_line_uom(p_item_id, d.document_type_id),' in v_def) = 0
     or position('erp.line_description(p_item_id, p_description)' in v_def) = 0 then
    raise exception
      'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the new rule, or '
      'without one of the three patches it already carried', v_sig;
  end if;
end
$add_line$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And create-the-whole-document stops keeping its own copy
-- ═════════════════════════════════════════════════════════════════════════════

do $create_full$
declare
  v_sig    constant text := 'erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)';
  v_def    text := pg_get_functiondef('erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)'::regprocedure);
  v_needle constant text :=
       E'    if v_price = 0 and v_base is distinct from ''purchase_order'' and d.party_id is not null then\n'
    || E'      begin\n'
    || E'        select * into pr from erp.resolve_price(v_item, d.party_id, v_qty, d.document_date, d.site_id);\n'
    || E'        if found and (pr.currency is null or pr.currency = d.currency) then\n'
    || E'          v_price := pr.amount_minor;\n'
    || E'        end if;\n'
    || E'      exception when others then\n'
    || E'        null;  -- no catalogue answer is not a reason to refuse a draft line\n'
    || E'      end;\n'
    || E'    end if;\n';
  v_new    constant text :=
       E'    -- Pricing an unpriced line belongs to erp.add_document_line(), which\n'
    || E'    -- does it for both sides of the trade (20260920120000). This asked the\n'
    || E'    -- customer catalogue for everything that was not a purchase order, so a\n'
    || E'    -- goods receipt from a supplier was priced from the sales list or, more\n'
    || E'    -- often, not at all.\n';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not price an unpriced line exactly once the way the 20260910180854 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.resolve_price(' in v_def) > 0
     or position('erp.onward_transition(' in v_def) = 0 then
    raise exception
      'CLOVEERP_BODY_UNRECOGNISED: % still keeps its own pricing, or was '
      're-emitted without the onward transition 20260914060000 gave it', v_sig;
  end if;
end
$create_full$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.received_line_price_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 8;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3);
  v_supp    uuid; v_cust uuid;
  v_bought  uuid; v_sold uuid; v_uom uuid;
  v_grn     uuid; v_form uuid; v_po uuid; v_so uuid;
  v_line    bigint; v_byform bigint; v_typed bigint; v_poline bigint; v_soline bigint;
  v_ok      boolean; v_msg text;
begin
  begin
  v_step := 'provisioning the organisation';
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-recv-price', 'Received line price suite',
                              'admin@zz-recv-price.test', 'Received Price Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f2', 'admin@zz-recv-price.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f2')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select p.id into v_supp from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- Two products, deliberately different. One the organisation buys, with a
  -- purchase list price. One it only sells, with a sales list price and nothing
  -- on the buying side at all — which is the shape that made the old path
  -- dangerous rather than merely silent.
  v_step := 'putting a purchase price on one product and a sales price on another';
  select i.id into v_bought from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
   order by i.code limit 1;
  select i.id into v_sold from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
     and i.id <> v_bought
   order by i.code desc limit 1;

  delete from erp.item_price p
   where p.tenant_id = v_tenant and p.item_id in (v_bought, v_sold);

  select coalesce(i.stock_uom_id, i.sales_uom_id) into v_uom from erp.item i where i.id = v_bought;
  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              currency, amount_minor, per_quantity, uom_id,
                              min_quantity, valid_from)
  values (v_tenant, v_bought, 'purchase_list', 'ZZ-BUY', v_ccy, 1850, 1, v_uom, 0,
          erp.local_today(v_site) - 10);

  select coalesce(i.stock_uom_id, i.sales_uom_id) into v_uom from erp.item i where i.id = v_sold;
  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              currency, amount_minor, per_quantity, uom_id,
                              min_quantity, valid_from)
  values (v_tenant, v_sold, 'sales_list', 'ZZ-SELL', v_ccy, 9900, 1, v_uom, 0,
          erp.local_today(v_site) - 10);

  -- ── 1. The reported case ─────────────────────────────────────────────────
  v_step := 'adding an unpriced line to a goods receipt';
  v_cases := v_cases + 1;
  v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supp,
                               null, v_ccy, 'ZZRP-GRN', '{}'::jsonb);
  perform erp.add_document_line(v_grn, v_bought, 10, null, null);
  select l.unit_price_minor into v_line
    from erp.document_line l where l.document_id = v_grn order by l.line_no limit 1;

  case_name := 'a goods receipt line left without a price takes the price agreed with the supplier';
  passed := v_line = 1850;
  detail := format('the line was written at %s; the supplier purchase list says 1850', v_line);
  return next;

  -- ── 2. And the form writes the same ──────────────────────────────────────
  v_step := 'raising a whole goods receipt through the form';
  v_cases := v_cases + 1;
  v_form := (erp.create_document_full('goods_receipt', v_supp, v_site, 'ZZRP-FORM',
                                      null, v_ccy,
                                      jsonb_build_array(jsonb_build_object(
                                        'item_id', v_bought, 'quantity', 10)),
                                      null) ->> 'document_id')::uuid;
  select l.unit_price_minor into v_byform
    from erp.document_line l where l.document_id = v_form order by l.line_no limit 1;

  case_name := 'the New goods receipt form writes the same price a line added afterwards is written at';
  passed := v_byform = v_line and v_byform > 0;
  detail := format('the form wrote %s and the added line wrote %s', v_byform, v_line);
  return next;

  -- ── 3. Silence is refused, by name ───────────────────────────────────────
  v_step := 'receiving a product the supplier has no agreed price for';
  v_cases := v_cases + 1;
  begin
    perform erp.add_document_line(v_grn, v_sold, 10, null, null);
    v_ok := false; v_msg := 'the line was written';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE%'; v_msg := left(sqlerrm, 160);
  end;

  case_name := 'a goods receipt line with no price and no agreed price is refused, naming the product and the receipt';
  passed := v_ok
        and v_msg like '%' || (select i.code from erp.item i where i.id = v_sold) || '%'
        and v_msg like '%' || (select d.document_number from erp.document d where d.id = v_grn) || '%';
  detail := v_msg;
  return next;

  -- ── 4. And it is not priced from the sales list ──────────────────────────
  -- The old path asked erp.resolve_price(), which matches a price row with no
  -- party on it — the ordinary sales list. So this product, received from a
  -- supplier, could be taken onto the books at 9900: what we sell it for.
  v_step := 'checking the sales list is not reached for a purchase';
  v_cases := v_cases + 1;
  case_name := 'a product with a sales price and no purchase price is refused, not received at the price it sells for';
  passed := v_ok
        and not exists (select 1 from erp.document_line l
                         where l.tenant_id = v_tenant and l.document_id = v_grn
                           and l.item_id = v_sold);
  detail := format('the sales list says 9900 for that product, and no line of it was written at any price');
  return next;

  -- ── 5. A typed price is still theirs ─────────────────────────────────────
  v_step := 'typing a price on a receipt line';
  v_cases := v_cases + 1;
  perform erp.add_document_line(v_grn, v_sold, 10, 2200, null);
  select l.unit_price_minor into v_typed
    from erp.document_line l
   where l.document_id = v_grn and l.item_id = v_sold order by l.line_no desc limit 1;

  case_name := 'a price somebody typed on a receipt line stands, whatever either catalogue says';
  passed := v_typed = 2200;
  detail := format('typed 2200, stored %s', v_typed);
  return next;

  -- ── 6. An order may still be drafted unpriced ────────────────────────────
  -- Nothing is valued until goods arrive, and a buyer drafting an order while
  -- waiting for the supplier to quote is a flow that works. This is the case
  -- that says the refusal above was scoped and not just added.
  v_step := 'drafting a purchase order line nobody has priced';
  v_cases := v_cases + 1;
  v_po := erp.create_document('purchase_order', v_entity, v_site, v_supp,
                              null, v_ccy, 'ZZRP-PO', '{}'::jsonb);
  begin
    perform erp.add_document_line(v_po, v_sold, 10, null, null);
    select l.unit_price_minor into v_poline
      from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
    v_ok := true; v_msg := format('the order line was written at %s', v_poline);
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 160);
  end;

  case_name := 'a purchase order line the supplier has not quoted yet is still allowed to be drafted';
  passed := v_ok and coalesce(v_poline, -1) = 0;
  detail := v_msg;
  return next;

  -- ── 7. The sales side is where 20260916160000 left it ────────────────────
  v_step := 'adding an unpriced sales line';
  v_cases := v_cases + 1;
  v_so := erp.create_document('sales_order', v_entity, v_site, v_cust,
                              null, v_ccy, 'ZZRP-SO', '{}'::jsonb);
  perform erp.add_document_line(v_so, v_sold, 1, null, null);
  select l.unit_price_minor into v_soline
    from erp.document_line l where l.document_id = v_so order by l.line_no limit 1;

  case_name := 'a sales line left without a price is still taken from the customer catalogue';
  passed := v_soline = 9900;
  detail := format('the sales line was written at %s; the sales list says 9900', v_soline);
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 8. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant where code = 'zz-recv-price')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000f2');
  detail := coalesce(v_state, 'zz-recv-price rolled back with its documents and prices');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: received_line_price_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.received_line_price_suite() from public, anon;

comment on function erp_test.received_line_price_suite() is
  'A received line carries a price. A goods receipt line left empty takes what '
  'the supplier has agreed; the form and a line added afterwards write the same '
  'figure; a product the supplier has no price for is refused by name rather '
  'than received at the price we sell it for; a typed price stands; and the two '
  'things this deliberately does not touch — an unpriced purchase order draft '
  'and the sales side 20260916160000 built — are each asserted still working.';

create or replace function erp_test.assert_received_line_price_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 8;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _received_line_price on commit drop as
    select * from erp_test.received_line_price_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _received_line_price;
  drop table _received_line_price;
  if v_fail > 0 then
    raise exception E'CLOVEERP_RECEIVED_LINE_PRICE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: received_line_price_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a received line carries a price: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_received_line_price_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_received_line_price_suite();
-- The two suites whose subject this changes.
select erp_test.assert_line_price_parity_suite();
select erp_test.assert_purchase_pricing_suite();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_diagnostics_registered();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_isolation();
