set lock_timeout = '30s';

-- =============================================================================
-- 20261007100000  A price is found for the site
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-72). "Find a price"
-- on Sales, and the price a new quotation's line shows before it is saved,
-- both ask public.erp_resolve_price(item, party, quantity). That door had no
-- site, so it called erp.resolve_price with none: the company selling was not
-- known, and a price kept for one company or for one site never matched. The
-- line itself is priced by erp.add_document_line from the document's site,
-- so an organisation that keeps a price per company or per site was told one
-- price on the screen and charged another on the line. The demonstration's
-- thirty sales prices name no company and no site, which is the only reason
-- it agreed there.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_resolve_price takes the site the goods ship from and the
--      day to price on, both optional, and passes them to erp.resolve_price,
--      as public.erp_resolve_purchase_price has done for the buying side since
--      20260906130000. With no site and no day it answers exactly what it
--      answered before, so a caller that sends three arguments is unchanged.
--      The old three-argument door is dropped and the new one created, so
--      the name stays one door.
--   B. erp_test.price_found_for_a_site_suite: the door answers each company's
--      price from that company's site, a site's own price only there, the
--      price for no company when no site is given, the price in force on the
--      day asked, and the price a sales order line at that site takes.
--
-- The screen's half: "Find a price" asks for the site (optional), and the
-- line of a new quotation or sales order passes the site the form or the
-- shell's scope names, as a purchase line already does
-- (src/routes/sales/index.tsx, src/components/erp/documents.tsx).
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- erp.resolve_price, how a line is priced, and who may price one are
-- unchanged. The door reads only, as before, and writes nothing.
--
-- On production: one door is replaced by the same door with two optional
-- arguments. No table is altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The door
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.erp_resolve_price(uuid, uuid, numeric);

create or replace function public.erp_resolve_price(
  p_item_id  uuid,
  p_party_id uuid,
  p_quantity numeric default 1,
  p_site_id  uuid default null,
  p_on       date default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- From the site, the company selling is known, so its own price and the
  -- site's are found as the line finds them (20261007100000).
  select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb)
    from erp.resolve_price(p_item_id, p_party_id, p_quantity, p_on, p_site_id) p
$$;

revoke all on function public.erp_resolve_price(uuid, uuid, numeric, uuid, date) from public, anon;
grant execute on function public.erp_resolve_price(uuid, uuid, numeric, uuid, date) to authenticated, service_role;

comment on function public.erp_resolve_price(uuid, uuid, numeric, uuid, date) is
  'What a customer would pay for a product at a quantity: a list of one price, or an empty list. Given the site the '
  'goods ship from, the price kept for that site or its company applies, as it does on the line; with no site only a '
  'price for no company does (20261007100000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.price_found_for_a_site_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record;
  v_cs     uuid;
  v_uom uuid; v_site uuid; v_co2 uuid; v_site2 uuid; v_site3 uuid;
  v_cust uuid; v_gear uuid;
  v_so uuid; v_line uuid;
  res jsonb; res2 jsonb; res3 jsonb;
  v_a bigint; v_b bigint;
  v_state text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    select * into r from erp.provision_tenant(
      'zz-pfs-' || v_hex, 'Price for a site suite',
      'admin@zz-pfs-' || v_hex || '.test', 'Price Admin');
    insert into auth.users (id, email) values (a1, 'admin@zz-pfs-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);

    v_cs := erp.configure_finance(); perform erp_test.promote_if_pending(v_cs);
    v_cs := erp.configure_sales();   perform erp_test.promote_if_pending(v_cs);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'SHOP', 'Shop', 'warehouse', 'active') returning id into v_site3;

    -- A second company, with a site of its own.
    insert into erp.entity (tenant_id, code, name, base_currency, status)
    values (r.tenant_id, 'CO2', 'Second company', 'GBP', 'active') returning id into v_co2;
    perform erp.ensure_entity_party(v_co2);
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, v_co2, 'NORTH', 'North', 'warehouse', 'active') returning id into v_site2;

    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active');

    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'GEAR', 'Priced by company and by site', v_uom, 'active') returning id into v_gear;

    -- The price for no company goes in first, so a door that ignores the site
    -- meets it first and cannot pass by luck.
    insert into erp.item_price (tenant_id, item_id, price_kind, entity_id, site_id, currency,
                                amount_minor, per_quantity, valid_from, valid_to)
    values (r.tenant_id, v_gear, 'sales_list', null,        null,     'GBP', 1000, 1, current_date - 10, null),
           (r.tenant_id, v_gear, 'sales_list', r.entity_id, null,     'GBP',  900, 1, current_date - 10, current_date + 5),
           (r.tenant_id, v_gear, 'sales_list', r.entity_id, null,     'GBP',  880, 1, current_date + 5,  null),
           (r.tenant_id, v_gear, 'sales_list', v_co2,       null,     'GBP',  800, 1, current_date - 10, null),
           (r.tenant_id, v_gear, 'sales_list', null,        v_site3,  'GBP',  950, 1, current_date - 10, null);

    -- ── 1. The door takes a site and a day ─────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the door takes the site and the day, both optional, and is the only door of its name';
    passed := to_regprocedure('public.erp_resolve_price(uuid,uuid,numeric,uuid,date)') is not null
          and to_regprocedure('public.erp_resolve_price(uuid,uuid,numeric)') is null
          and (select count(*) from pg_catalog.pg_proc p
                 join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'erp_resolve_price') = 1
          and has_function_privilege('authenticated', 'public.erp_resolve_price(uuid,uuid,numeric,uuid,date)', 'execute')
          and not has_function_privilege('anon', 'public.erp_resolve_price(uuid,uuid,numeric,uuid,date)', 'execute');
    detail := 'public.erp_resolve_price(uuid,uuid,numeric,uuid,date)';
    return next;

    -- ── 2. Each company its own price, from its site ───────────────────────
    v_cases := v_cases + 1;
    res  := public.erp_resolve_price(v_gear, v_cust, 1, v_site);
    res2 := public.erp_resolve_price(v_gear, v_cust, 1, v_site2);
    case_name := 'from a site, the door answers the price its company keeps, not the other company''s or the general one';
    passed := (res -> 0 ->> 'amount_minor')::bigint = 900
          and (res2 -> 0 ->> 'amount_minor')::bigint = 800;
    detail := format('Main %s, North %s', res, res2);
    return next;

    -- ── 3. No site, no company ─────────────────────────────────────────────
    v_cases := v_cases + 1;
    res  := public.erp_resolve_price(v_gear, v_cust, 1);
    res2 := public.erp_resolve_price(v_gear, v_cust);
    case_name := 'with no site the door answers as it did before: the price for no company';
    passed := jsonb_array_length(res) = 1
          and (res -> 0 ->> 'amount_minor')::bigint = 1000
          and res2 = res;
    detail := format('%s / %s', res, res2);
    return next;

    -- ── 4. A site's own price, only there ──────────────────────────────────
    v_cases := v_cases + 1;
    res  := public.erp_resolve_price(v_gear, v_cust, 1, v_site3);
    res2 := public.erp_resolve_price(v_gear, v_cust, 1, v_site);
    case_name := 'a price kept for one site is the answer at that site and at no other site of the company';
    passed := (res -> 0 ->> 'amount_minor')::bigint = 950
          and (res2 -> 0 ->> 'amount_minor')::bigint = 900;
    detail := format('Shop %s, Main %s', res, res2);
    return next;

    -- ── 5. The day asked ───────────────────────────────────────────────────
    v_cases := v_cases + 1;
    res  := public.erp_resolve_price(v_gear, v_cust, 1, v_site, current_date + 4);
    res2 := public.erp_resolve_price(v_gear, v_cust, 1, v_site, current_date + 5);
    res3 := public.erp_resolve_price(v_gear, v_cust, 1, v_site, current_date - 20);
    case_name := 'given a day, the door answers the price in force that day, and nothing before any price started';
    passed := (res -> 0 ->> 'amount_minor')::bigint = 900
          and (res2 -> 0 ->> 'amount_minor')::bigint = 880
          and res3 = '[]'::jsonb;
    detail := format('day 4 %s, day 5 %s, 20 days ago %s', res, res2, res3);
    return next;

    -- ── 6. What the screen says is what the line takes ─────────────────────
    v_cases := v_cases + 1;
    v_so := erp.open_document('sales_order', v_cust, v_co2, v_site2);
    v_line := erp.add_document_line(v_so, v_gear, 5, null, 'gears');
    v_a := (select l.unit_price_minor from erp.document_line l where l.id = v_line);
    v_b := (public.erp_resolve_price(v_gear, v_cust, 5, v_site2) -> 0 ->> 'amount_minor')::bigint;
    case_name := 'a sales order line at a site takes the price the door answers for that site';
    passed := v_a = 800 and v_b = v_a;
    detail := format('line %s, door %s', v_a, v_b);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
  end;

  -- ── 7. Undone ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-pfs-' || v_hex)
        and v_state is null;
  detail := coalesce('the fixture stopped early: ' || v_state,
                     'the organisation rolled back with its companies, sites, prices and order');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PRICE_FOUND_FOR_A_SITE_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_state, 'a case was added or lost');
  end if;
end;
$$;

revoke all on function erp_test.price_found_for_a_site_suite() from public, anon;

comment on function erp_test.price_found_for_a_site_suite() is
  'Find a price answers for the site (20261007100000): each company''s price from its own site, a site''s price only '
  'there, the price for no company with no site, the price in force on the day asked, and the price a line at that '
  'site takes.';

create or replace function erp_test.assert_price_found_for_a_site_suite()
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
    from erp_test.price_found_for_a_site_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRICE_FOUND_FOR_A_SITE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Find a price would answer a price the line at that site does not take. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_PRICE_FOUND_FOR_A_SITE_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('price found for a site: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_price_found_for_a_site_suite() from public, anon;

comment on function erp_test.assert_price_found_for_a_site_suite() is
  'Find a price answers the price a line at the chosen site takes (20261007100000).';

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
