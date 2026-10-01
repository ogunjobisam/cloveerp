-- =============================================================================
-- A customer is priced from their list, and a price per N is a price per N
--
-- erp.item_price carries two columns that every writer fills and no reader
-- consults when a line is priced.
--
-- price_list_code. erp.resolve_price() (20260829280000) returns it and never
-- ranks by it, so every sales-list price competes and the ordering has no
-- list term: an item priced on TIER1 to TIER10 is charged whichever of the ten
-- `limit 1` happens to meet first. erp.party_role_terms.price_list_code has
-- existed since B7 to say which list a customer is on, and nothing has ever
-- joined it. erp.resolve_purchase_price() (20260906130000) has the same shape
-- on the buying side with the supplier's terms.
--
-- per_quantity, "price per N units", default 1. Nothing divides by it. Every
-- caller — erp.price_document_line(), both routes of erp.add_document_line(),
-- the receipt path — takes the resolver's amount_minor as the price of one,
-- so 43 per 1,000 is charged 43 each.
--
-- Every line in the product is priced through these two resolvers, so they are
-- where both are mended, with their signatures and their callers unchanged.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Which list
--
-- A party's list is the price_list_code on their terms in force on the day, in
-- the company the site belongs to (terms are per company). Among list prices —
-- sales_list for a customer, purchase_list for a supplier — the order is:
--
--   0  their own list, or a list price bound to them by party_role_id
--   1  a price on no list at all
--   2  a price on another list, and only for a party who names none
--
-- A party who names a list is never priced from somebody else's: a TIER1
-- customer is not charged TIER3 because TIER1 forgot the item. Rank 2 exists
-- because a single named list with nobody on it is how a tenant writes "the
-- price" today (three suites price that way), and it stays a price only while
-- it is the only one: two or more other lists competing for a party on none is
-- refused by name, since choosing between them is the arbitrary answer this
-- file exists to remove. Contract, promotion and last cost still come first,
-- exactly as before; the list term orders list prices only.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The rounding rule is that there is none
--
-- The unit price is amount_minor / per_quantity when that is a whole number of
-- minor units — 1,200 per 12 is 100 each — and refused by name when it is not.
-- A document line carries its unit price in whole minor units, and net is
-- quantity times it; 43 per 1,000 is 0.043 of a penny each, which that line
-- can only say as 0 (the goods given away) or 43 (a thousand times over).
-- Either is a wrong invoice, so neither is written.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The refusals
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_PRICE_LIST_AMBIGUOUS',
  'Pricing an item for a customer or supplier when more than one price list could price it and nothing says which.',
  'A party on no list is priced from the price on no list, or from the one list the item is on; with two or more lists and nothing naming one, any choice would be arbitrary, and a price nobody chose is a price nobody can explain.',
  'Name the list on the party''s terms, or give the item a price on no list, or type the price on the line.');

select erp.register_refusal('CLOVEERP_PRICE_FINER_THAN_A_MINOR_UNIT',
  'Pricing a line from a price per N units that does not come to a whole minor unit each.',
  'A line carries its unit price in whole minor units, so a price such as 43 per 1,000 could only be written as nothing or as a thousand times over.',
  'Restate the price per a quantity it divides into whole minor units, or type the price on the line.');

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The resolvers
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare
  v_sale text := pg_get_functiondef('erp.resolve_price(uuid,uuid,numeric,date,uuid)'::regprocedure);
  v_buy  text := pg_get_functiondef('erp.resolve_purchase_price(uuid,uuid,numeric,date,uuid)'::regprocedure);
begin
  if position('when ''contract'' then 0 when ''promotion'' then 1 else 2 end' in v_sale) = 0
     or position('per_quantity' in v_sale) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.resolve_price is not the 20260829280000 body';
  end if;
  if position('when ''contract'' then 0 when ''purchase_list'' then 1 else 2 end' in v_buy) = 0
     or position('per_quantity' in v_buy) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.resolve_purchase_price is not the 20260906130000 body';
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
  w        record;
begin
  -- The list the customer is on: their terms in force on the day, in the
  -- company the site belongs to.
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
     and (p_site_id is null
          or t.entity_id = (select s.entity_id from erp.site s
                             where s.tenant_id = v_tenant and s.id = p_site_id));

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
  '(20261003720000). The amount is per one unit: a price per N divides when it '
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
  w        record;
begin
  -- The list the supplier is on: their terms in force on the day, in the
  -- company the site belongs to.
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
     and (p_site_id is null
          or t.entity_id = (select s.entity_id from erp.site s
                             where s.tenant_id = v_tenant and s.id = p_site_id));

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
  'one; the biggest quantity break the line satisfies wins. The amount is per '
  'one unit: a price per N divides when it comes to whole minor units and '
  'refuses when it does not. Returns no row when the catalogue has nothing.';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.price_list_and_per_quantity_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record; p record;
  v_cs     uuid;
  v_uom uuid; v_site uuid;
  v_tier uuid; v_none uuid; v_other uuid; v_lapsed uuid;
  v_sup uuid; v_sup_open uuid;
  v_role uuid;
  v_widget uuid; v_duo uuid; v_solo uuid; v_box uuid; v_fine uuid;
  v_bolt uuid; v_pduo uuid; v_crate uuid; v_screw uuid;
  v_so uuid; v_po uuid; v_line uuid;
  v_ok boolean; v_msg text; v_a bigint; v_b bigint; v_c bigint;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-plq-' || v_hex, 'Price list suite',
    'admin@zz-plq-' || v_hex || '.test', 'Price Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();            perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_sales();              perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_procurement(1000000); perform erp_test.promote_if_pending(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;

  -- Four customers: one on TIER2, one on no list, one on a list that prices
  -- nothing here, and one whose TIER1 terms ended yesterday.
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'TIERED', 'On tier two', 'active') returning id into v_tier;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_tier, 'customer', 'active') returning id into v_role;
  insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, price_list_code, valid_from)
  values (r.tenant_id, v_role, r.entity_id, 'TIER2', current_date - 30);

  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'NOLIST', 'On no list', 'active') returning id into v_none;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_none, 'customer', 'active');

  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'TIER9', 'On tier nine', 'active') returning id into v_other;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_other, 'customer', 'active') returning id into v_role;
  insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, price_list_code, valid_from)
  values (r.tenant_id, v_role, r.entity_id, 'TIER9', current_date - 30);

  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'LAPSED', 'Was on tier one', 'active') returning id into v_lapsed;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_lapsed, 'customer', 'active') returning id into v_role;
  insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, price_list_code, valid_from, valid_to)
  values (r.tenant_id, v_role, r.entity_id, 'TIER1', current_date - 30, current_date);

  -- Two suppliers: one on SUPA, one on no list.
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUPA', 'Supplier on SUPA', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active') returning id into v_role;
  insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, price_list_code, valid_from)
  values (r.tenant_id, v_role, r.entity_id, 'SUPA', current_date - 30);
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUPOPEN', 'Supplier on no list', 'active') returning id into v_sup_open;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup_open, 'supplier', 'active');

  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'WIDGET', 'On no list and three tiers', v_uom, 'active') returning id into v_widget;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'DUO', 'On two tiers only', v_uom, 'active') returning id into v_duo;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'SOLO', 'On one named list only', v_uom, 'active') returning id into v_solo;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'BOX', 'Priced by the dozen', v_uom, 'active') returning id into v_box;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'FINE', 'Priced by the thousand', v_uom, 'active') returning id into v_fine;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'BOLT', 'Bought on three lists', v_uom, 'active') returning id into v_bolt;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'PDUO', 'Bought on two lists only', v_uom, 'active') returning id into v_pduo;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'CRATE', 'Bought by the hundred', v_uom, 'active') returning id into v_crate;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
    (r.tenant_id, 'SCREW', 'Bought by the thousand', v_uom, 'active') returning id into v_screw;

  -- The price on no list goes in first, so a resolver that ignores the list
  -- meets it first and cannot pass case 1 by luck.
  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, currency,
                              amount_minor, per_quantity, valid_from)
  values (r.tenant_id, v_widget, 'sales_list',    null,    'GBP', 1000,    1, current_date - 10),
         (r.tenant_id, v_widget, 'sales_list',    'TIER1', 'GBP',  900,    1, current_date - 10),
         (r.tenant_id, v_widget, 'sales_list',    'TIER2', 'GBP',  800,    1, current_date - 10),
         (r.tenant_id, v_widget, 'sales_list',    'TIER3', 'GBP',  700,    1, current_date - 10),
         (r.tenant_id, v_duo,    'sales_list',    'TIER1', 'GBP', 2100,    1, current_date - 10),
         (r.tenant_id, v_duo,    'sales_list',    'TIER2', 'GBP', 2000,    1, current_date - 10),
         (r.tenant_id, v_solo,   'sales_list',    'RETAIL','GBP', 1500,    1, current_date - 10),
         (r.tenant_id, v_box,    'sales_list',    null,    'GBP', 1200,   12, current_date - 10),
         (r.tenant_id, v_fine,   'sales_list',    null,    'GBP',   43, 1000, current_date - 10),
         (r.tenant_id, v_bolt,   'purchase_list', null,    'GBP',  700,    1, current_date - 10),
         (r.tenant_id, v_bolt,   'purchase_list', 'SUPA',  'GBP',  650,    1, current_date - 10),
         (r.tenant_id, v_bolt,   'purchase_list', 'SUPB',  'GBP',  600,    1, current_date - 10),
         (r.tenant_id, v_pduo,   'purchase_list', 'SUPA',  'GBP',  310,    1, current_date - 10),
         (r.tenant_id, v_pduo,   'purchase_list', 'SUPB',  'GBP',  300,    1, current_date - 10),
         (r.tenant_id, v_crate,  'purchase_list', null,    'GBP', 5000,  100, current_date - 10),
         (r.tenant_id, v_screw,  'purchase_list', null,    'GBP',    7, 1000, current_date - 10);

  -- ── 1. The customer's list ────────────────────────────────────────────────
  v_cases := v_cases + 1;
  select * into p from erp.resolve_price(v_widget, v_tier, 1, null, v_site);
  case_name := 'a customer whose terms name TIER2 is priced from TIER2';
  passed := p.amount_minor = 800 and p.price_list_code = 'TIER2';
  detail := format('%s from %s', p.amount_minor, coalesce(p.price_list_code, 'no list'));
  return next;

  -- ── 2. And so is the line ─────────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_so := erp.open_document('sales_order', v_tier, r.entity_id, v_site);
  v_line := erp.add_document_line(v_so, v_widget, 5, null, 'tiered widget');
  v_a := (select l.unit_price_minor from erp.document_line l where l.id = v_line);
  update erp.document_line set unit_price_minor = 0, net_minor = 0 where id = v_line;
  v_b := erp.price_document_line(v_line);
  case_name := 'an unpriced sales line takes the customer''s list, and pricing it again agrees';
  passed := v_a = 800 and v_b = 800
        and (select l.net_minor from erp.document_line l where l.id = v_line) = 4000;
  detail := format('added at %s, priced at %s', v_a, v_b);
  return next;

  -- ── 3. A customer on no list ──────────────────────────────────────────────
  v_cases := v_cases + 1;
  select * into p from erp.resolve_price(v_widget, v_none, 1, null, v_site);
  case_name := 'a customer on no list is priced from the price on no list, not from a tier';
  passed := p.amount_minor = 1000 and p.price_list_code is null;
  detail := format('%s from %s', p.amount_minor, coalesce(p.price_list_code, 'no list'));
  return next;

  -- ── 4. A list that does not price the item ────────────────────────────────
  v_cases := v_cases + 1;
  select * into p from erp.resolve_price(v_widget, v_other, 1, null, v_site);
  case_name := 'a customer on a list that does not price the item falls back to the price on no list, never another tier';
  passed := p.amount_minor = 1000 and p.price_list_code is null;
  detail := format('%s from %s', p.amount_minor, coalesce(p.price_list_code, 'no list'));
  return next;

  -- ── 5. Terms out of force name nothing ────────────────────────────────────
  v_cases := v_cases + 1;
  select * into p from erp.resolve_price(v_widget, v_lapsed, 1, null, v_site);
  v_a := (select x.amount_minor from erp.resolve_price(v_widget, v_lapsed, 1, current_date - 1, v_site) x);
  case_name := 'terms that have ended name no list, and terms in force on the day do';
  passed := p.amount_minor = 1000 and v_a = 900;
  detail := format('%s today, %s yesterday on TIER1', p.amount_minor, v_a);
  return next;

  -- ── 6. Several other lists refuse ─────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    perform erp.resolve_price(v_duo, v_none, 1, null, v_site);
    v_ok := false; v_msg := 'an item on two tiers was priced for a customer on neither';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PRICE_LIST_AMBIGUOUS%'
            and sqlerrm like '%DUO%' and sqlerrm like '%TIER1 and TIER2%';
    v_msg := left(sqlerrm, 160);
  end;
  case_name := 'an item on two lists and on none the customer is on is refused by name, not priced from either';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 7. One other list prices, and only a customer on no list ──────────────
  v_cases := v_cases + 1;
  v_a := (select x.amount_minor from erp.resolve_price(v_solo, v_none, 1, null, v_site) x);
  v_ok := not exists (select 1 from erp.resolve_price(v_solo, v_tier, 1, null, v_site));
  case_name := 'the one list an item is on prices a customer on no list, and not a customer on another list';
  passed := v_a = 1500 and v_ok;
  detail := format('%s for the customer on no list; the TIER2 customer %s',
                   v_a, case when v_ok then 'is not priced from RETAIL' else 'was priced from RETAIL' end);
  return next;

  -- ── 8. A contract still beats the list ────────────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, party_role_id,
                              currency, amount_minor, per_quantity, valid_from)
  select r.tenant_id, v_widget, 'contract', 'TIERED-2026', pr.id, 'GBP', 750, 1, current_date - 1
    from erp.party_role pr where pr.tenant_id = r.tenant_id and pr.party_id = v_tier and pr.role_kind = 'customer';
  select * into p from erp.resolve_price(v_widget, v_tier, 1, null, v_site);
  case_name := 'a contract with the customer still beats their list';
  passed := p.amount_minor = 750 and p.price_kind = 'contract';
  detail := format('%s from %s', p.amount_minor, p.source);
  return next;

  -- ── 9. A price per twelve ─────────────────────────────────────────────────
  v_cases := v_cases + 1;
  select * into p from erp.resolve_price(v_box, v_none, 1, null, v_site);
  v_so := erp.open_document('sales_order', v_none, r.entity_id, v_site);
  v_line := erp.add_document_line(v_so, v_box, 24, null, 'two dozen');
  v_b := erp.price_document_line(v_line);
  case_name := 'a price of 1200 per 12 is 100 each, and a line of 24 comes to 2400';
  passed := p.amount_minor = 100 and p.source like '%(1200 per 12)%' and v_b = 100
        and (select l.net_minor from erp.document_line l where l.id = v_line) = 2400;
  detail := format('resolved %s from %s, line net %s', p.amount_minor, p.source,
                   (select l.net_minor from erp.document_line l where l.id = v_line));
  return next;

  -- ── 10. A price finer than a penny ────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    v_line := erp.add_document_line(v_so, v_fine, 1000, null, 'a thousand');
    v_ok := false;
    v_msg := format('the line was written at %s each',
                    (select l.unit_price_minor from erp.document_line l where l.id = v_line));
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PRICE_FINER_THAN_A_MINOR_UNIT%' and sqlerrm like '%FINE%';
    v_msg := left(sqlerrm, 160);
  end;
  v_line := erp.add_document_line(v_so, v_fine, 1000, 1, 'typed at a penny');
  case_name := 'a price of 43 per 1000 is refused by name rather than charged 43 or 0 each, and a typed price stands';
  passed := v_ok and (select l.unit_price_minor from erp.document_line l where l.id = v_line) = 1;
  detail := v_msg;
  return next;

  -- ── 11. The supplier's list ───────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_a := (select x.amount_minor from erp.resolve_purchase_price(v_bolt, v_sup, 1, null, v_site) x);
  v_b := (select x.amount_minor from erp.resolve_purchase_price(v_bolt, v_sup_open, 1, null, v_site) x);
  v_po := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
  v_line := erp.add_document_line(v_po, v_bolt, 10, null, 'bolts');
  v_c := (select l.unit_price_minor from erp.document_line l where l.id = v_line);
  case_name := 'a supplier whose terms name SUPA is priced from SUPA, and a supplier on no list from the list on no list';
  passed := v_a = 650 and v_b = 700 and v_c = 650;
  detail := format('SUPA %s, no list %s, purchase order line %s', v_a, v_b, v_c);
  return next;

  -- ── 12. Several other purchase lists refuse ───────────────────────────────
  v_cases := v_cases + 1;
  begin
    perform erp.resolve_purchase_price(v_pduo, v_sup_open, 1, null, v_site);
    v_ok := false; v_msg := 'an item on two supplier lists was priced for a supplier on neither';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PRICE_LIST_AMBIGUOUS%' and sqlerrm like '%SUPA and SUPB%';
    v_msg := left(sqlerrm, 160);
  end;
  v_a := (select x.amount_minor from erp.resolve_purchase_price(v_pduo, v_sup, 1, null, v_site) x);
  case_name := 'an item on two purchase lists refuses a supplier on neither, and prices the supplier on one';
  passed := v_ok and v_a = 310;
  detail := format('%s; SUPA supplier priced at %s', v_msg, v_a);
  return next;

  -- ── 13. Per quantity on the buying side ───────────────────────────────────
  v_cases := v_cases + 1;
  v_line := erp.add_document_line(v_po, v_crate, 200, null, 'two hundred');
  update erp.document_line set unit_price_minor = 0, net_minor = 0 where id = v_line;
  v_a := erp.price_document_line(v_line);
  begin
    perform erp.resolve_purchase_price(v_screw, v_sup, 1000, null, v_site);
    v_ok := false; v_msg := '7 per 1000 was resolved to a unit price';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PRICE_FINER_THAN_A_MINOR_UNIT%' and sqlerrm like '%SCREW%';
    v_msg := left(sqlerrm, 160);
  end;
  case_name := 'a purchase price of 5000 per 100 is 50 each, and 7 per 1000 is refused by name';
  passed := v_a = 50 and v_ok
        and (select l.net_minor from erp.document_line l where l.id = v_line) = 10000;
  detail := format('crate priced at %s, net %s; %s', v_a,
                   (select l.net_minor from erp.document_line l where l.id = v_line), v_msg);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 14. Undone ────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-plq-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its terms, prices and orders');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PRICE_LIST_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_fixture, 'a case was added or lost');
  end if;
end;
$$;

revoke all on function erp_test.price_list_and_per_quantity_suite() from public, anon;

comment on function erp_test.price_list_and_per_quantity_suite() is
  'A customer or supplier is priced from the list their terms name, then the price on no list, then '
  'the one other list an item is on; several other lists refuse, and a contract still comes first. '
  'A price per N is divided when it comes to whole minor units and refused when it does not '
  '(20261003720000).';

create or replace function erp_test.assert_price_list_and_per_quantity_suite()
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
    from erp_test.price_list_and_per_quantity_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRICE_LIST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A line would be priced from a list its customer or supplier is not on, or at a price per N charged per one. Read the case that failed.';
  end if;
  if v_total <> 14 then
    raise exception 'CLOVEERP_PRICE_LIST_SUITE_SHRANK: % case(s), expected 14', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('price lists and per quantity: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_price_list_and_per_quantity_suite() from public, anon;

comment on function erp_test.assert_price_list_and_per_quantity_suite() is
  'A line is priced from the list its party is on and per one unit (20261003720000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The generators, which are idempotent and run at the end of every migration
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
