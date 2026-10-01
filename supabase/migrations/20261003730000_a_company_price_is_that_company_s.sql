-- =============================================================================
-- A company's price is that company's
--
-- erp.item_price.entity_id has been on the table since B7: a price that one
-- company in the organisation charges or pays. Neither resolver has ever read
-- it. erp.resolve_price() and erp.resolve_purchase_price() match every price
-- row whatever its company, so in an organisation of two companies each is
-- priced from the other's list as readily as its own, and a price meant for
-- one company alone prices a sale the other makes.
--
-- 20261003720000 already reads the company from the site, to find which of a
-- party's terms apply. This reads it once and uses it for the price as well:
--
--   * A price for a company applies only where the line's site belongs to
--     that company.
--   * It beats a price for no company, as a price for a site beats a price for
--     no site; a price for the site beats both, being the narrower.
--   * With no site, the company is not known, and only a price for no company
--     applies. Both resolvers take the site and not the company, and every
--     caller passes the document's site; adding the company to the signature
--     would change every caller for a case the site already answers.
--
-- Nothing else moves: contracts, lists, quantity breaks and price per N are
-- ordered exactly as 20261003720000 left them.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The resolvers
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare
  v_sale text := pg_get_functiondef('erp.resolve_price(uuid,uuid,numeric,date,uuid)'::regprocedure);
  v_buy  text := pg_get_functiondef('erp.resolve_purchase_price(uuid,uuid,numeric,date,uuid)'::regprocedure);
begin
  if position('c.list_rank,' in v_sale) = 0 or position('p.entity_id' in v_sale) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.resolve_price is not the 20261003720000 body';
  end if;
  if position('c.list_rank,' in v_buy) = 0 or position('p.entity_id' in v_buy) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.resolve_purchase_price is not the 20261003720000 body';
  end if;
end $$;

create or replace function erp.resolve_price(
  p_item_id  uuid,
  p_party_id uuid,
  p_quantity numeric default 1,
  p_on       date default null,
  p_site_id  uuid default null
) returns table (amount_minor bigint, currency char(3), price_kind erp.price_kind,
                 price_list_code text, source text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_on     date := coalesce(p_on, current_date);
  v_lists  text[];
  v_list   text;
  v_entity uuid;
  w        record;
begin
  -- The company selling or buying is the one the site belongs to; with no
  -- site it is not known, and only a price for no company applies.
  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id;

  -- The list the customer is on: their terms in force on the day, in that
  -- company.
  select array_agg(distinct t.price_list_code order by t.price_list_code)
    into v_lists
    from erp.party_role_terms t
    join erp.party_role r on r.tenant_id = t.tenant_id and r.id = t.party_role_id
   where t.tenant_id = v_tenant
     and r.party_id = p_party_id
     and r.role_kind = 'customer'
     and t.price_list_code is not null
     and t.valid_from <= v_on
     and (t.valid_to is null or t.valid_to > v_on)
     and (v_entity is null or t.entity_id = v_entity);

  if cardinality(v_lists) > 1 then
    raise exception
      'CLOVEERP_PRICE_LIST_AMBIGUOUS: this customer''s terms name % in different companies, and nothing says which company is selling',
      array_to_string(v_lists, ' and ')
      using errcode = '21000',
            hint = 'Price the line from a site, whose company says which terms apply.';
  end if;
  v_list := v_lists[1];

  -- Specificity, in one ordering, so there is one answer and it can be
  -- explained. A contract beats a promotion because a contract is a promise
  -- and a promotion is an offer; both beat the list, and among list prices the
  -- customer's own list beats the price on no list, which beats another list.
  with candidate as (
    select p.*,
           case when p.price_kind <> 'sales_list' or p.party_role_id is not null
                     or p.price_list_code = v_list then 0
                when p.price_list_code is null then 1
                else 2
           end as list_rank
      from erp.item_price p
      left join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.id = p.party_role_id
     where p.tenant_id = v_tenant
       and p.item_id = p_item_id
       and p.price_kind in ('contract', 'promotion', 'sales_list')
       and (p.party_role_id is null or pr.party_id = p_party_id)
       and (p.site_id is null or p.site_id = p_site_id)
       -- A company's price is that company's, and nobody else's.
       and (p.entity_id is null or p.entity_id = v_entity)
       and coalesce(p.min_quantity, 0) <= p_quantity
       and p.valid_from <= v_on
       and (p.valid_to is null or p.valid_to > v_on)
       -- A customer on a list is not priced from somebody else's.
       and (v_list is null or p.price_kind <> 'sales_list' or p.party_role_id is not null
            or p.price_list_code is null or p.price_list_code = v_list)
  )
  select c.id, c.amount_minor, c.currency, c.price_kind, c.price_list_code,
         c.per_quantity, c.list_rank,
         (select array_agg(distinct o.price_list_code order by o.price_list_code)
            from candidate o where o.list_rank = 2) as rivals
    into w
    from candidate c
   order by case c.price_kind
              when 'contract' then 0 when 'promotion' then 1 else 2 end,
            c.list_rank,
            (c.party_role_id is not null) desc,
            (c.site_id is not null) desc,
            (c.entity_id is not null) desc,
            -- The most specific quantity break that this line qualifies for.
            coalesce(c.min_quantity, 0) desc,
            c.valid_from desc,
            c.id
   limit 1;

  if not found then
    return;
  end if;

  if w.list_rank = 2 and cardinality(w.rivals) > 1 then
    raise exception
      'CLOVEERP_PRICE_LIST_AMBIGUOUS: % is priced on % and on no list this customer is on',
      (select i.code from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id),
      array_to_string(w.rivals, ' and ')
      using errcode = '21000',
            hint = 'Name the list on the customer''s terms, give the item a price on no list, '
                   'or type the price on the line.';
  end if;

  if w.amount_minor / w.per_quantity <> trunc(w.amount_minor / w.per_quantity) then
    raise exception
      'CLOVEERP_PRICE_FINER_THAN_A_MINOR_UNIT: % is priced at % per %, which is % of a minor unit each',
      (select i.code from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id),
      w.amount_minor, trim_scale(w.per_quantity),
      trim_scale(round(w.amount_minor / w.per_quantity, 6))
      using errcode = '22023',
            hint = 'Restate the price per a quantity it divides into whole minor units, '
                   'or type the price on the line.';
  end if;

  amount_minor    := (w.amount_minor / w.per_quantity)::bigint;
  currency        := w.currency;
  price_kind      := w.price_kind;
  price_list_code := w.price_list_code;
  source          := case w.price_kind
                       when 'contract'  then 'a contract with this customer'
                       when 'promotion' then 'a promotion in force today'
                       else 'the sales list'
                     end
                     || case when w.per_quantity <> 1
                             then format(' (%s per %s)', w.amount_minor, trim_scale(w.per_quantity))
                             else '' end;
  return next;
end;
$$;

comment on function erp.resolve_price(uuid, uuid, numeric, date, uuid) is
  'Spec 5.6: pricing with lists, contracts and promotions. One ordering, so '
  'there is one answer and it can be explained — a contract beats a promotion '
  'because a contract is a promise and a promotion is an offer. Among list prices '
  'the customer''s own list (their terms in force) beats the price on no list, '
  'which beats the one other list an item is on; several other lists refuse '
  '(20261003720000). A price for a company applies only where the site is '
  'that company''s, and beats a general one (20261003730000). The amount is per one unit: a price per N divides when it '
  'comes to whole minor units and refuses when it does not.';

create or replace function erp.resolve_purchase_price(p_item_id uuid,
                                                       p_party_id uuid,
                                                       p_quantity numeric default 1,
                                                       p_on date default null,
                                                       p_site_id uuid default null)
returns table(amount_minor bigint, currency character(3), price_kind erp.price_kind,
              price_list_code text, source text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_on     date := coalesce(p_on, current_date);
  v_lists  text[];
  v_list   text;
  v_entity uuid;
  w        record;
begin
  -- The company selling or buying is the one the site belongs to; with no
  -- site it is not known, and only a price for no company applies.
  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id;

  -- The list the supplier is on: their terms in force on the day, in that
  -- company.
  select array_agg(distinct t.price_list_code order by t.price_list_code)
    into v_lists
    from erp.party_role_terms t
    join erp.party_role r on r.tenant_id = t.tenant_id and r.id = t.party_role_id
   where t.tenant_id = v_tenant
     and r.party_id = p_party_id
     and r.role_kind = 'supplier'
     and t.price_list_code is not null
     and t.valid_from <= v_on
     and (t.valid_to is null or t.valid_to > v_on)
     and (v_entity is null or t.entity_id = v_entity);

  if cardinality(v_lists) > 1 then
    raise exception
      'CLOVEERP_PRICE_LIST_AMBIGUOUS: this supplier''s terms name % in different companies, and nothing says which company is buying',
      array_to_string(v_lists, ' and ')
      using errcode = '21000',
            hint = 'Price the line from a site, whose company says which terms apply.';
  end if;
  v_list := v_lists[1];

  -- A contract beats a purchase list, which beats the last cost paid; among
  -- purchase lists the supplier's own beats the list on no list, which beats
  -- another list.
  with candidate as (
    select p.*,
           case when p.price_kind <> 'purchase_list' or p.party_role_id is not null
                     or p.price_list_code = v_list then 0
                when p.price_list_code is null then 1
                else 2
           end as list_rank
      from erp.item_price p
      left join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.id = p.party_role_id
     where p.tenant_id = v_tenant
       and p.item_id = p_item_id
       and p.price_kind in ('contract'::erp.price_kind, 'purchase_list'::erp.price_kind,
                            'last_cost'::erp.price_kind)
       and (p.party_role_id is null or pr.party_id = p_party_id)
       and (p.site_id is null or p_site_id is null or p.site_id = p_site_id)
       -- A company's price is that company's, and nobody else's.
       and (p.entity_id is null or p.entity_id = v_entity)
       and coalesce(p.min_quantity, 0) <= coalesce(p_quantity, 1)
       and p.valid_from <= v_on
       and (p.valid_to is null or p.valid_to > v_on)
       -- A supplier on a list is not priced from somebody else's.
       and (v_list is null or p.price_kind <> 'purchase_list' or p.party_role_id is not null
            or p.price_list_code is null or p.price_list_code = v_list)
  )
  select c.id, c.amount_minor, c.currency, c.price_kind, c.price_list_code,
         c.per_quantity, c.list_rank,
         (select array_agg(distinct o.price_list_code order by o.price_list_code)
            from candidate o where o.list_rank = 2) as rivals
    into w
    from candidate c
   order by case c.price_kind when 'contract' then 0 when 'purchase_list' then 1 else 2 end,
            c.list_rank,
            (c.party_role_id is not null) desc,
            (c.site_id is not null) desc,
            (c.entity_id is not null) desc,
            coalesce(c.min_quantity, 0) desc,
            c.valid_from desc,
            c.id
   limit 1;

  if not found then
    return;
  end if;

  if w.list_rank = 2 and cardinality(w.rivals) > 1 then
    raise exception
      'CLOVEERP_PRICE_LIST_AMBIGUOUS: % is priced on % and on no list this supplier is on',
      (select i.code from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id),
      array_to_string(w.rivals, ' and ')
      using errcode = '21000',
            hint = 'Name the list on the supplier''s terms, give the item a price on no list, '
                   'or type the price on the line.';
  end if;

  if w.amount_minor / w.per_quantity <> trunc(w.amount_minor / w.per_quantity) then
    raise exception
      'CLOVEERP_PRICE_FINER_THAN_A_MINOR_UNIT: % is priced at % per %, which is % of a minor unit each',
      (select i.code from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id),
      w.amount_minor, trim_scale(w.per_quantity),
      trim_scale(round(w.amount_minor / w.per_quantity, 6))
      using errcode = '22023',
            hint = 'Restate the price per a quantity it divides into whole minor units, '
                   'or type the price on the line.';
  end if;

  amount_minor    := (w.amount_minor / w.per_quantity)::bigint;
  currency        := w.currency;
  price_kind      := w.price_kind;
  price_list_code := w.price_list_code;
  source          := case w.price_kind
                       when 'contract' then 'a contract with this supplier'
                       when 'purchase_list' then 'the supplier purchase list'
                       else 'the last cost paid'
                     end
                     || case when w.per_quantity <> 1
                             then format(' (%s per %s)', w.amount_minor, trim_scale(w.per_quantity))
                             else '' end;
  return next;
end;
$$;
revoke all on function erp.resolve_purchase_price(uuid, uuid, numeric, date, uuid) from public, anon, authenticated;

comment on function erp.resolve_purchase_price is
  'Specification v1.6 §5.3: what this supplier charges for this item, on this '
  'date, at this quantity, for this site. A contract beats a purchase list, '
  'which beats the last cost paid; among purchase lists the supplier''s own '
  '(their terms in force) beats the list on no list, which beats the one other '
  'list an item is on, and several other lists refuse (20261003720000). A price '
  'for the supplier beats a general one; a price for the site beats a general '
  'one; a price for a company applies only where the site is that company''s and '
  'beats a general one (20261003730000); the biggest quantity break the line satisfies wins. The amount is per '
  'one unit: a price per N divides when it comes to whole minor units and '
  'refuses when it does not. Returns no row when the catalogue has nothing.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.price_by_company_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record; p record;
  v_cs     uuid;
  v_uom uuid; v_site uuid; v_co2 uuid; v_site2 uuid;
  v_cust uuid; v_sup uuid;
  v_gear uuid; v_theirs uuid; v_bolt uuid; v_nut uuid;
  v_so uuid; v_po uuid; v_line uuid;
  v_ok boolean; v_msg text; v_a bigint; v_b bigint; v_c bigint;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-pbc-' || v_hex, 'Price by company suite',
    'admin@zz-pbc-' || v_hex || '.test', 'Price Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();            perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_sales();              perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_procurement(1000000); perform erp_test.promote_if_pending(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;

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
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active');

  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'GEAR', 'Priced by both companies', v_uom, 'active') returning id into v_gear;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'THEIRS', 'Priced by the second company only', v_uom, 'active') returning id into v_theirs;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'BOLT', 'Bought by both companies', v_uom, 'active') returning id into v_bolt;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'NUT', 'Bought by the second company only', v_uom, 'active') returning id into v_nut;

  -- The price for no company goes in first, so a resolver that ignores the
  -- company meets it first and cannot pass case 1 by luck.
  insert into erp.item_price (tenant_id, item_id, price_kind, entity_id, currency,
                              amount_minor, per_quantity, valid_from)
  values (r.tenant_id, v_gear,   'sales_list',    null,        'GBP', 1000, 1, current_date - 10),
         (r.tenant_id, v_gear,   'sales_list',    r.entity_id, 'GBP',  900, 1, current_date - 10),
         (r.tenant_id, v_gear,   'sales_list',    v_co2,       'GBP',  800, 1, current_date - 10),
         (r.tenant_id, v_theirs, 'sales_list',    v_co2,       'GBP', 1500, 1, current_date - 10),
         (r.tenant_id, v_bolt,   'purchase_list', null,        'GBP',  700, 1, current_date - 10),
         (r.tenant_id, v_bolt,   'purchase_list', r.entity_id, 'GBP',  650, 1, current_date - 10),
         (r.tenant_id, v_bolt,   'purchase_list', v_co2,       'GBP',  600, 1, current_date - 10),
         (r.tenant_id, v_nut,    'purchase_list', v_co2,       'GBP',  310, 1, current_date - 10);

  -- ── 1. Each company its own price ─────────────────────────────────────────
  v_cases := v_cases + 1;
  v_a := (select x.amount_minor from erp.resolve_price(v_gear, v_cust, 1, null, v_site) x);
  v_b := (select x.amount_minor from erp.resolve_price(v_gear, v_cust, 1, null, v_site2) x);
  case_name := 'each company sells at its own price, not the other''s or the general one';
  passed := v_a = 900 and v_b = 800;
  detail := format('%s from Main, %s from North', v_a, v_b);
  return next;

  -- ── 2. And so does the line ───────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_so := erp.open_document('sales_order', v_cust, r.entity_id, v_site);
  v_line := erp.add_document_line(v_so, v_gear, 5, null, 'gears');
  v_a := (select l.unit_price_minor from erp.document_line l where l.id = v_line);
  update erp.document_line set unit_price_minor = 0, net_minor = 0 where id = v_line;
  v_b := erp.price_document_line(v_line);
  case_name := 'an unpriced sales line takes its company''s price, and pricing it again agrees';
  passed := v_a = 900 and v_b = 900
        and (select l.net_minor from erp.document_line l where l.id = v_line) = 4500;
  detail := format('added at %s, priced at %s', v_a, v_b);
  return next;

  -- ── 3. No site, no company ────────────────────────────────────────────────
  v_cases := v_cases + 1;
  select * into p from erp.resolve_price(v_gear, v_cust, 1, null, null);
  case_name := 'with no site the company is not known, and only the price for no company applies';
  passed := p.amount_minor = 1000;
  detail := format('%s with no site', p.amount_minor);
  return next;

  -- ── 4. Another company's price is not a price ─────────────────────────────
  v_cases := v_cases + 1;
  v_ok := not exists (select 1 from erp.resolve_price(v_theirs, v_cust, 1, null, v_site));
  v_a := (select x.amount_minor from erp.resolve_price(v_theirs, v_cust, 1, null, v_site2) x);
  case_name := 'an item only the second company prices has no price at the first';
  passed := v_ok and v_a = 1500;
  detail := format('Main %s; North %s', case when v_ok then 'has no price' else 'was priced from North' end, v_a);
  return next;

  -- ── 5. A price for the site is narrower still ─────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.item_price (tenant_id, item_id, price_kind, site_id, currency,
                              amount_minor, per_quantity, valid_from)
  values (r.tenant_id, v_gear, 'sales_list', v_site, 'GBP', 950, 1, current_date - 10);
  v_a := (select x.amount_minor from erp.resolve_price(v_gear, v_cust, 1, null, v_site) x);
  v_b := (select x.amount_minor from erp.resolve_price(v_gear, v_cust, 1, null, v_site2) x);
  case_name := 'a price for the site beats its company''s price, and only at that site';
  passed := v_a = 950 and v_b = 800;
  detail := format('%s at Main, %s at North', v_a, v_b);
  return next;

  -- ── 6. The buying side ────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_a := (select x.amount_minor from erp.resolve_purchase_price(v_bolt, v_sup, 1, null, v_site) x);
  v_b := (select x.amount_minor from erp.resolve_purchase_price(v_bolt, v_sup, 1, null, v_site2) x);
  v_c := (select x.amount_minor from erp.resolve_purchase_price(v_bolt, v_sup, 1, null, null) x);
  case_name := 'each company buys at its own price, and with no site at the price for no company';
  passed := v_a = 650 and v_b = 600 and v_c = 700;
  detail := format('Main %s, North %s, no site %s', v_a, v_b, v_c);
  return next;

  -- ── 7. And its purchase order ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_po := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  v_line := erp.add_document_line(v_po, v_bolt, 10, null, 'bolts');
  v_a := (select l.unit_price_minor from erp.document_line l where l.id = v_line);
  v_ok := not exists (select 1 from erp.resolve_purchase_price(v_nut, v_sup, 1, null, v_site));
  case_name := 'a purchase order line takes its company''s price, and the other company''s price is none';
  passed := v_a = 650 and v_ok;
  detail := format('line at %s; NUT at Main %s', v_a,
                   case when v_ok then 'has no price' else 'was priced from North' end);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 8. Undone ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-pbc-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its companies, prices and orders');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PRICE_BY_COMPANY_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_fixture, 'a case was added or lost');
  end if;
end;
$$;

revoke all on function erp_test.price_by_company_suite() from public, anon;

comment on function erp_test.price_by_company_suite() is
  'A price for a company prices only lines at that company''s sites, beats a price for no company '
  'and is beaten by a price for the site; with no site only a price for no company applies, '
  'selling and buying alike (20261003730000).';

create or replace function erp_test.assert_price_by_company_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.price_by_company_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRICE_BY_COMPANY_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A line would be priced from another company''s price. Read the case that failed.';
  end if;
  if v_total <> 8 then
    raise exception 'CLOVEERP_PRICE_BY_COMPANY_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('price by company: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_price_by_company_suite() from public, anon;

comment on function erp_test.assert_price_by_company_suite() is
  'A line is priced from its own company''s price and never another''s (20261003730000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The generators, which are idempotent and run at the end of every migration
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
