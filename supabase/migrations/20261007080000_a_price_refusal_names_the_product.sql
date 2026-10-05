set lock_timeout = '30s';

-- =============================================================================
-- 20261007080000  A price refusal names the product
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-118). Pricing a line
-- that nothing prices was refused as "This is not allowed right now", with the
-- product named by its uuid. erp.price_document_line raised
--
--   CLOVEERP_NO_PURCHASE_PRICE: nothing prices <uuid> from this supplier on …
--   CLOVEERP_NO_PRICE: nothing prices <uuid> for this customer on …
--
-- Neither code was in the refusal register, so the screen had no headline for
-- it. The purchase hint named a table and its columns, which the screen hides
-- as internal, so nothing said what to do; the sales hint ended "configure
-- one", without saying where.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Both refusals are registered: what was refused, why, and what to do.
--   B. erp.price_document_line names the product by its code and name in both
--      refusals, and each hint says where the price comes from:
--        - a purchase line: the supplier's price, set under Supplier prices on
--          the Product-suppliers screen (20261007070000 added it), or the
--          price typed on the line;
--        - a sales line: the price typed on the line, or the product's default
--          sell price loaded from a products file under Imports. No screen
--          keeps a customer's own prices: the products file is the one place
--          a sales price enters a working organisation, and it is the one the
--          hint names.
--   C. erp_test.price_refusal_suite.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- What prices a line, who may price it and when: the same lookups, the same
-- permissions, the same refusal codes. On production: one function's two
-- refusals are reworded and two refusals are registered. No row of any
-- organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NO_PURCHASE_PRICE',
  'Pricing a purchase line when the supplier has no price for the product on that day.',
  'A purchase line takes what the supplier charges; with no price on record there is nothing to take, and a guess would be paid.',
  'Set the supplier''s price under Supplier prices on the Product-suppliers screen, or type the price you are being charged on the line.');

select erp.register_refusal('CLOVEERP_NO_PRICE',
  'Pricing a sales line when nothing prices the product for this customer on that day.',
  'A sales line takes the customer''s contract, promotion or list price; with none in force there is nothing to take.',
  'Type the price on the line, or load the product''s default sell price from a products file under Imports.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The product by its name, and where its price is set
-- ─────────────────────────────────────────────────────────────────────────────

do $price$
declare
  v_sig  constant text := 'erp.price_document_line(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old_buy constant text := $o$    if not found then
      raise exception
        'CLOVEERP_NO_PURCHASE_PRICE: nothing prices % from this supplier on %',
        l.item_id, coalesce(d.document_date, current_date)
        using errcode = '23503',
              hint = 'Add a purchase list or contract price for this supplier in '
                     'erp.item_price (price_kind purchase_list or contract), or '
                     'receive the item once so a last cost is on record.';
    end if;
$o$;
  v_new_buy constant text := $n$    if not found then
      -- The product by its code and name, and the screen where the supplier's
      -- price is set (20261007080000). It named the product's uuid, and a
      -- table the screen hides.
      raise exception
        'CLOVEERP_NO_PURCHASE_PRICE: nothing prices % from this supplier on %',
        coalesce((select i.code || coalesce(' (' || nullif(btrim(i.name), '') || ')', '')
                    from erp.item i where i.tenant_id = v_tenant and i.id = l.item_id), 'the product'),
        coalesce(d.document_date, current_date)
        using errcode = '23503',
              hint = format('Set the supplier''s price for %s under Supplier prices on the '
                            'Product-suppliers screen, or type the price you are being charged '
                            'on the line.',
                            coalesce((select i.code || coalesce(' (' || nullif(btrim(i.name), '') || ')', '')
                                        from erp.item i where i.tenant_id = v_tenant and i.id = l.item_id),
                                     'the product'));
    end if;
$n$;
  v_old_sell constant text := $o$    if not found then
      raise exception
        'CLOVEERP_NO_PRICE: nothing prices % for this customer on %',
        l.item_id, coalesce(d.document_date, current_date)
        using errcode = '23503',
        hint = 'A price typed onto the line by whoever raised it is not a price '
               'list; configure one.';
    end if;
$o$;
  v_new_sell constant text := $n$    if not found then
      -- The product by its code and name, and the one place a sales price
      -- enters an organisation (20261007080000). It named the product's uuid
      -- and said "configure one" without saying where.
      raise exception
        'CLOVEERP_NO_PRICE: nothing prices % for this customer on %',
        coalesce((select i.code || coalesce(' (' || nullif(btrim(i.name), '') || ')', '')
                    from erp.item i where i.tenant_id = v_tenant and i.id = l.item_id), 'the product'),
        coalesce(d.document_date, current_date)
        using errcode = '23503',
              hint = format('Type the price on the line, or load a default sell price for %s '
                            'from a products file under Imports.',
                            coalesce((select i.code || coalesce(' (' || nullif(btrim(i.name), '') || ')', '')
                                        from erp.item i where i.tenant_id = v_tenant and i.id = l.item_id),
                                     'the product'));
    end if;
$n$;
begin
  if strpos(v_src, '20261007080000') > 0 then
    raise notice '% already names the product; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '9693d9cc9d340f39bf0b12199dc6f3c9' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007080000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old_buy, ''))) / length(v_old_buy) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % purchase anchor found other than once', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_old_sell, ''))) / length(v_old_sell) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % sales anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old_buy, v_new_buy), v_old_sell, v_new_sell);
end
$price$;

comment on function erp.price_document_line(uuid) is
  'Prices one line from the catalogue for the side of the trade it is on: a sales line from the sales catalogue '
  'under sales.price with the margin checked, a purchase line from the supplier catalogue under the permission that '
  'raised the document. Either refuses by name when nothing prices it, naming the product by its code and name and '
  'where its price is set (20261007080000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.price_refusal_suite()
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
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_supp uuid; v_cust uuid;
  v_ccy    text;
  v_po uuid; v_so uuid; v_buy uuid; v_sell uuid;
  v_err  text; v_hint text; v_err2 text; v_hint2 text;
  v_kept bigint; v_priced bigint;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with a product nothing prices, a supplier and a customer';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzprf-' || v_tag, 'Price Refusal Suite',
      'admin@zzprf-' || v_tag || '.test', 'Price Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzprf-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select e.id, e.base_currency into v_entity, v_ccy from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPRFBOLT', 'Unpriced Bolt', v_uom, 'active') returning id into v_item;
    v_supp := erp_test.cash_payment_supplier('ZPRFSUP');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZPRFCUST', 'Price Refusal Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');

    -- ── 1. Registered, in words a person reads ──────────────────────────────
    v_step := 'reading the register';
    v_cases := v_cases + 1;
    case_name := 'both refusals are registered, say where a price is set, and name no table, routine or code';
    passed := v_state is null
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_NO_PURCHASE_PRICE', 'CLOVEERP_NO_PRICE')
                  and f.refused || ' ' || f.why || ' ' || f.next_action
                      !~ '(erp_|erp\.|[a-z0-9]_[a-z0-9]|uuid|configure)') = 2
          and (select f.next_action from erp_ref.refusal f where f.code = 'CLOVEERP_NO_PURCHASE_PRICE')
              like '%Supplier prices on the Product-suppliers screen%'
          and (select f.next_action from erp_ref.refusal f where f.code = 'CLOVEERP_NO_PRICE')
              like '%products file under Imports%'
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en'
                  and x.key in (erp_ref.refusal_key('CLOVEERP_NO_PURCHASE_PRICE', 'refused'),
                                erp_ref.refusal_key('CLOVEERP_NO_PRICE', 'refused'))) = 2;
    detail := coalesce(v_state, 'register read');
    return next;

    -- ── 2. A purchase line nothing prices ───────────────────────────────────
    v_step := 'a purchase order line priced from a supplier with no price';
    v_po := erp.open_document('purchase_order', v_supp, v_entity, v_site);
    v_buy := erp.add_document_line(v_po, v_item, 10, 500, 'typed by the buyer');
    begin
      perform erp.price_document_line(v_buy);
      v_err := 'priced';
    exception when others then
      get stacked diagnostics v_err = message_text, v_hint = pg_exception_hint;
    end;
    v_kept := (select l.unit_price_minor from erp.document_line l where l.id = v_buy);
    v_cases := v_cases + 1;
    case_name := 'a purchase line nothing prices is refused naming the product, not its uuid, and the hint sends the buyer to Supplier prices on Product-suppliers';
    passed := v_state is null
          and v_err like 'CLOVEERP_NO_PURCHASE_PRICE: nothing prices ZPRFBOLT (Unpriced Bolt) from this supplier on %'
          and strpos(v_err, v_item::text) = 0
          and v_hint like 'Set the supplier''s price for ZPRFBOLT (Unpriced Bolt) under Supplier prices on the Product-suppliers screen%'
          and v_hint !~ '(erp_|erp\.|[a-z0-9]_[a-z0-9])'
          and v_kept = 500;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_hint, v_kept::text));
    return next;

    -- ── 3. Where the hint sends the buyer, the line is priced ───────────────
    v_step := 'the supplier''s price set where the hint says, then the line priced again';
    perform public.erp_set_supplier_price(v_item, v_supp, 4.25, v_ccy);
    v_priced := erp.price_document_line(v_buy);
    v_cases := v_cases + 1;
    case_name := 'once the supplier''s price is set on Product-suppliers, the same line prices from it';
    passed := v_state is null
          and v_priced = 425
          and (select l.unit_price_minor from erp.document_line l where l.id = v_buy) = 425;
    detail := coalesce(v_state, format('priced at %s', v_priced));
    return next;

    -- ── 4. A sales line nothing prices ──────────────────────────────────────
    v_step := 'a sales order line priced for a customer nothing prices it for';
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    v_sell := erp.add_document_line(v_so, v_item, 2, 900, 'typed by the seller');
    begin
      perform erp.price_document_line(v_sell);
      v_err2 := 'priced';
    exception when others then
      get stacked diagnostics v_err2 = message_text, v_hint2 = pg_exception_hint;
    end;
    v_cases := v_cases + 1;
    case_name := 'a sales line nothing prices is refused naming the product, not its uuid, and the hint names the products file under Imports';
    passed := v_state is null
          and v_err2 like 'CLOVEERP_NO_PRICE: nothing prices ZPRFBOLT (Unpriced Bolt) for this customer on %'
          and strpos(v_err2, v_item::text) = 0
          and v_hint2 = 'Type the price on the line, or load a default sell price for ZPRFBOLT (Unpriced Bolt) from a products file under Imports.'
          and (select l.unit_price_minor from erp.document_line l where l.id = v_sell) = 900;
    detail := coalesce(v_state, concat_ws(' / ', v_err2, v_hint2));
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
    raise exception 'CLOVEERP_PRICE_REFUSAL_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.price_refusal_suite() from public, anon;

comment on function erp_test.price_refusal_suite() is
  'A price refusal names the product (20261007080000): both refusals are registered in plain words, a purchase '
  'line and a sales line nothing prices are refused by the product''s code and name with a hint that says where '
  'the price is set, and a price set where the purchase hint says prices the line.';

create or replace function erp_test.assert_price_refusal_suite()
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
    from erp_test.price_refusal_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRICE_REFUSAL_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A line nothing prices was refused without naming the product or where its price is set. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_PRICE_REFUSAL_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('price refusal: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_price_refusal_suite() from public, anon;

comment on function erp_test.assert_price_refusal_suite() is
  'A line nothing prices is refused by the product''s name, with the screen that sets its price (20261007080000).';

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
select erp.assert_invoker_doors_executable();
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
