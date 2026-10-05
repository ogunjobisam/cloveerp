set lock_timeout = '30s';

-- =============================================================================
-- 20261007101000  Only priced products are offered for a price
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-73). "Find a price"
-- on Sales offered every product the organisation keeps, raw materials and
-- packaging among them, because its product list is public.erp_items, which
-- lists everything not archived. A product nobody has a selling price for can
-- only ever answer "nothing prices this", so offering it is a question with
-- no answer. The product's class cannot be the filter: the demonstration's
-- quotation QUO-000133 sells RM-201, a raw material. Whether a product has a
-- selling price can.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_items takes p_sales_priced, false unless asked. Asked, it
--      lists only the products with a contract, promotion or sales-list price
--      in force today. Not asked, it lists exactly what it listed before, so
--      every other list of products (a new quotation's lines among them,
--      where a typed price is allowed) is unchanged. The old two-argument door
--      is dropped and the new one created, so the name stays one door.
--   B. erp_test.sales_priced_products_suite.
--
-- The screen's half: "Find a price" asks erp_items for priced products only
-- (src/routes/sales/index.tsx).
--
-- The tester's own product JT-E-P1 is cleared with the other test records by
-- the migration that clears them (decision 7), not here.
--
-- On production: one door is replaced by the same door with one optional
-- argument. No table is altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The door
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.erp_items(text, integer);

create or replace function public.erp_items(
  p_search       text default null,
  p_limit        integer default 200,
  p_sales_priced boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'item_id', i.id, 'code', i.code, 'name', i.name,
      'description', i.description,
      'item_class', i.item_class, 'item_group', i.item_group,
      'lifecycle', i.lifecycle, 'status', i.status,
      'stock_uom_id', i.stock_uom_id,
      'stock_uom_code', u.code,
      'is_batch_controlled', i.is_batch_controlled,
      'is_serial_controlled', i.is_serial_controlled,
      'has_expiry', i.has_expiry) as x
      from erp.item i
      left join erp.uom u on u.tenant_id = i.tenant_id and u.id = i.stock_uom_id
     where i.tenant_id = erp.current_tenant_id()
       and i.status <> 'archived'
       and (p_search is null or i.code ilike '%' || p_search || '%'
                             or i.name ilike '%' || p_search || '%')
       -- Asked for priced products only, a product with a selling price in
       -- force today (20261007101000): one with none can only answer that
       -- nothing prices it.
       and (not coalesce(p_sales_priced, false)
            or exists (select 1 from erp.item_price p
                        where p.tenant_id = i.tenant_id and p.item_id = i.id
                          and p.price_kind in ('contract', 'promotion', 'sales_list')
                          and p.valid_from <= current_date
                          and (p.valid_to is null or p.valid_to > current_date)))
     order by i.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$$;

revoke all on function public.erp_items(text, integer, boolean) from public, anon;
grant execute on function public.erp_items(text, integer, boolean) to authenticated, service_role;

comment on function public.erp_items(text, integer, boolean) is
  'The organisation''s products not archived, in code order, matching a search on code or name. Asked with '
  'p_sales_priced, only those with a contract, promotion or sales-list price in force today (20261007101000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.sales_priced_products_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  r        record; r2 record;
  v_uom uuid; v_cust uuid; v_role uuid; v_sup uuid; v_srole uuid;
  v_list uuid; v_contract uuid; v_promo uuid; v_bought uuid; v_ended uuid; v_later uuid; v_bare uuid; v_gone uuid;
  v_all jsonb; v_priced jsonb; v_search jsonb; v_other jsonb;
  v_codes text;
  v_state text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    select * into r from erp.provision_tenant(
      'zz-spp-' || v_hex, 'Priced products suite',
      'admin@zz-spp-' || v_hex || '.test', 'Price Admin');
    insert into auth.users (id, email) values (a1, 'admin@zz-spp-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active') returning id into v_role;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active') returning id into v_srole;

    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P1-LIST',     'On the sales list',            v_uom, 'active') returning id into v_list;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P2-CONTRACT', 'Under a customer contract',    v_uom, 'active') returning id into v_contract;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P3-PROMO',    'On promotion',                 v_uom, 'active') returning id into v_promo;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P4-BOUGHT',   'Only bought, never sold',      v_uom, 'active') returning id into v_bought;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P5-ENDED',    'Its selling price has ended',  v_uom, 'active') returning id into v_ended;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P6-LATER',    'Its selling price starts later', v_uom, 'active') returning id into v_later;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P7-BARE',     'No price at all',              v_uom, 'active') returning id into v_bare;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P8-ARCHIVED', 'Priced but archived',          v_uom, 'archived') returning id into v_gone;

    insert into erp.item_price (tenant_id, item_id, price_kind, party_role_id, currency,
                                amount_minor, per_quantity, valid_from, valid_to)
    values (r.tenant_id, v_list,     'sales_list',    null,    'GBP', 1000, 1, current_date - 10, null),
           (r.tenant_id, v_contract, 'contract',      v_role,  'GBP',  900, 1, current_date - 10, null),
           (r.tenant_id, v_promo,    'promotion',     null,    'GBP',  800, 1, current_date,      current_date + 3),
           (r.tenant_id, v_bought,   'purchase_list', v_srole, 'GBP',  500, 1, current_date - 10, null),
           (r.tenant_id, v_ended,    'sales_list',    null,    'GBP', 1200, 1, current_date - 10, current_date),
           (r.tenant_id, v_later,    'sales_list',    null,    'GBP', 1300, 1, current_date + 1,  null),
           (r.tenant_id, v_gone,     'sales_list',    null,    'GBP', 1400, 1, current_date - 10, null);

    v_all    := public.erp_items();
    v_priced := public.erp_items(null, 200, true);
    v_search := public.erp_items('contract', 200, true);
    select string_agg(e ->> 'code', ',' order by e ->> 'code') into v_codes
      from jsonb_array_elements(v_priced) e;

    -- ── 1. The door ─────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the door takes p_sales_priced, false unless asked, and is the only door of its name';
    passed := to_regprocedure('public.erp_items(text,integer,boolean)') is not null
          and to_regprocedure('public.erp_items(text,integer)') is null
          and (select count(*) from pg_catalog.pg_proc p
                 join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'erp_items') = 1
          and has_function_privilege('authenticated', 'public.erp_items(text,integer,boolean)', 'execute')
          and not has_function_privilege('anon', 'public.erp_items(text,integer,boolean)', 'execute');
    detail := 'public.erp_items(text,integer,boolean)';
    return next;

    -- ── 2. Not asked, every product as before ──────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'not asked, the list holds every product not archived, priced or not, as before';
    passed := jsonb_array_length(v_all) = 7
          and not exists (select 1 from jsonb_array_elements(v_all) e where e ->> 'code' = 'P8-ARCHIVED')
          and exists (select 1 from jsonb_array_elements(v_all) e where e ->> 'code' = 'P7-BARE');
    detail := format('%s product(s)', jsonb_array_length(v_all));
    return next;

    -- ── 3. Asked, only what has a selling price today ───────────────────────
    v_cases := v_cases + 1;
    case_name := 'asked, the list holds the products on the sales list, under a contract or on promotion today, '
                 'and none only bought, ended, starting later, unpriced or archived';
    passed := v_codes = 'P1-LIST,P2-CONTRACT,P3-PROMO';
    detail := coalesce(v_codes, 'none');
    return next;

    -- ── 4. The search still narrows it ─────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a search narrows the priced list as it narrows the whole one';
    passed := jsonb_array_length(v_search) = 1 and v_search -> 0 ->> 'code' = 'P2-CONTRACT';
    detail := v_search::text;
    return next;

    -- ── 5. Another organisation sees none of them ──────────────────────────
    v_cases := v_cases + 1;
    perform set_config('request.jwt.claims', '', true);
    select * into r2 from erp.provision_tenant(
      'zz-spq-' || v_hex, 'Priced products other',
      'admin@zz-spq-' || v_hex || '.test', 'Other Admin');
    insert into auth.users (id, email) values (a2, 'admin@zz-spq-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    v_other := public.erp_items(null, 200, true);
    case_name := 'another organisation''s priced list holds none of these products';
    passed := not exists (select 1 from jsonb_array_elements(v_other) e
                           where (e ->> 'item_id')::uuid in (v_list, v_contract, v_promo));
    detail := format('%s product(s) listed there', jsonb_array_length(v_other));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_SALES_PRICED_PRODUCTS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.sales_priced_products_suite() from public, anon;

comment on function erp_test.sales_priced_products_suite() is
  'Find a price offers only priced products (20261007101000): asked, erp_items lists the products with a selling price '
  'in force today and no other; not asked, it lists every product as before; and another organisation sees none.';

create or replace function erp_test.assert_sales_priced_products_suite()
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
    from erp_test.sales_priced_products_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SALES_PRICED_PRODUCTS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Find a price would offer a product nothing prices, or miss one that is priced. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_SALES_PRICED_PRODUCTS_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('sales priced products: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_sales_priced_products_suite() from public, anon;

comment on function erp_test.assert_sales_priced_products_suite() is
  'Find a price offers only the products with a selling price in force today (20261007101000).';

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
