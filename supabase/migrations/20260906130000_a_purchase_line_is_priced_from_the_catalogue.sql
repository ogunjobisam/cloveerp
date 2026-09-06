-- =============================================================================
-- A purchase line is priced from the catalogue
--
-- Specification v1.6 §5.3 (v1.2), "supplier catalogues with terms and
-- validity". Phase 8 of the outstanding-work programme, file 1 of 10.
--
-- The register said, of 5.3.supplier_catalogues: "Nothing resolves a purchase
-- price from them, so a purchase order is still priced by whoever raises it."
-- Half of that stopped being true on 30 August: public.erp_resolve_purchase_price
-- reads erp.item_price for a supplier (contract, then purchase list, then the
-- last cost paid; party-specific, site-specific and the biggest satisfied
-- quantity break first; within its validity window) and the procurement screen
-- calls it. The migration that built it tried to mark the row built with a
-- predicate on the requirement text, which the text did not match, so the
-- register kept the old sentence. The other half stayed true: the resolver
-- lived only in the door, erp.price_document_line() priced every line as a
-- sale (it authorised sales.price and read the sales catalogue, so a buyer
-- could not price a purchase line at all), and erp.add_document_line() wrote
-- whatever price it was handed, zero included.
--
-- This file moves the resolver into erp.resolve_purchase_price(), makes the
-- door a wrapper with the shape the screen already reads, teaches
-- price_document_line() which side of the trade a line is on (a purchase line
-- is priced from the supplier catalogue under the document's own permission,
-- with no margin check, and refuses by name when the supplier has no price),
-- and defaults an unpriced purchase order line from the catalogue when it is
-- added. The register row is then marked built with the artefacts that make it
-- so.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The resolver, in the product schema
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.resolve_purchase_price(p_item_id uuid,
                                                       p_party_id uuid,
                                                       p_quantity numeric default 1,
                                                       p_on date default null,
                                                       p_site_id uuid default null)
returns table(amount_minor bigint, currency character(3), price_kind erp.price_kind,
              price_list_code text, source text)
language sql
stable
set search_path = ''
as $$
  select p.amount_minor, p.currency, p.price_kind, p.price_list_code,
         case p.price_kind
           when 'contract' then 'a contract with this supplier'
           when 'purchase_list' then 'the supplier purchase list'
           else 'the last cost paid'
         end
    from erp.item_price p
    left join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.id = p.party_role_id
   where p.tenant_id = erp.current_tenant_id()
     and p.item_id = p_item_id
     and p.price_kind in ('contract'::erp.price_kind, 'purchase_list'::erp.price_kind,
                          'last_cost'::erp.price_kind)
     and (p.party_role_id is null or pr.party_id = p_party_id)
     and (p.site_id is null or p_site_id is null or p.site_id = p_site_id)
     and coalesce(p.min_quantity, 0) <= coalesce(p_quantity, 1)
     and p.valid_from <= coalesce(p_on, current_date)
     and (p.valid_to is null or p.valid_to > coalesce(p_on, current_date))
   order by case p.price_kind when 'contract' then 0 when 'purchase_list' then 1 else 2 end,
            (p.party_role_id is not null) desc,
            (p.site_id is not null) desc,
            coalesce(p.min_quantity, 0) desc
   limit 1
$$;
revoke all on function erp.resolve_purchase_price(uuid, uuid, numeric, date, uuid) from public, anon, authenticated;

comment on function erp.resolve_purchase_price is
  'Specification v1.6 §5.3: what this supplier charges for this item, on this '
  'date, at this quantity, for this site. A contract beats a purchase list, '
  'which beats the last cost paid; a price for the supplier beats a general '
  'one; a price for the site beats a general one; the biggest quantity break '
  'the line satisfies wins. Returns no row when the catalogue has nothing.';

-- The door keeps its signature and its shape: the procurement screen reads it.
create or replace function public.erp_resolve_purchase_price(p_item_id uuid,
                                                              p_party_id uuid,
                                                              p_quantity numeric default 1,
                                                              p_site_id uuid default null,
                                                              p_on date default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object(
              'amount_minor', r.amount_minor, 'currency', r.currency,
              'price_kind', r.price_kind, 'price_list_code', r.price_list_code,
              'source', r.source)
       from erp.resolve_purchase_price(p_item_id, p_party_id, p_quantity, p_on, p_site_id) r),
    jsonb_build_object('amount_minor', null, 'source', 'no price is on record for this supplier and item'));
$$;
revoke all on function public.erp_resolve_purchase_price(uuid, uuid, numeric, uuid, date) from public, anon;
grant execute on function public.erp_resolve_purchase_price(uuid, uuid, numeric, uuid, date) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A line is priced from the side of the trade it is on
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.price_document_line(uuid)'::regprocedure);
begin
  if position('perform erp.authorise(''sales.price'', d.entity_id, d.site_id, null,' in v_src) = 0
     or position('from erp.resolve_price(l.item_id, d.party_id, l.quantity,' in v_src) = 0
     or position('resolve_purchase_price' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.price_document_line is not the 20260829280000 body';
  end if;
end $$;

create or replace function erp.price_document_line(p_line_id uuid)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  v_base   text;
  v_perm   text;
  pr       record;
  m        record;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_line_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  select bt.code, coalesce(dt.create_permission, bt.create_permission)
    into v_base, v_perm
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if v_base in ('purchase_order', 'requisition', 'return_to_supplier') then
    -- A purchase line is priced by what the supplier charges, under the
    -- permission that raised the document. There is no margin to check on a
    -- price we pay.
    perform erp.authorise(v_perm, d.entity_id, d.site_id, null, 'document_line', p_line_id);

    select * into pr from erp.resolve_purchase_price(l.item_id, d.party_id, l.quantity,
                                                     d.document_date, d.site_id);
    if not found then
      raise exception
        'CLOVEERP_NO_PURCHASE_PRICE: nothing prices % from this supplier on %',
        l.item_id, coalesce(d.document_date, current_date)
        using errcode = '23503',
              hint = 'Add a purchase list or contract price for this supplier in '
                     'erp.item_price (price_kind purchase_list or contract), or '
                     'receive the item once so a last cost is on record.';
    end if;
  else
    perform erp.authorise('sales.price', d.entity_id, d.site_id, null,
                          'document_line', p_line_id);

    select * into pr from erp.resolve_price(l.item_id, d.party_id, l.quantity,
                                            d.document_date, d.site_id);
    if not found then
      raise exception
        'CLOVEERP_NO_PRICE: nothing prices % for this customer on %',
        l.item_id, coalesce(d.document_date, current_date)
        using errcode = '23503',
        hint = 'A price typed onto the line by whoever raised it is not a price '
               'list; configure one.';
    end if;

    select * into m from erp.check_margin(l.item_id, d.site_id, pr.amount_minor);
  end if;

  update erp.document_line
     set unit_price_minor = pr.amount_minor,
         net_minor = round(l.quantity * pr.amount_minor
                           * (1 - coalesce(l.discount_pct, 0) / 100.0))::bigint,
         currency = coalesce(pr.currency, l.currency),
         updated_at = now()
   where id = p_line_id;

  return pr.amount_minor;
end;
$$;

comment on function erp.price_document_line is
  'Prices one line from the catalogue for the side of the trade it is on: a '
  'sales line from the sales catalogue under sales.price with the margin '
  'checked, a purchase line from the supplier catalogue under the permission '
  'that raised the document. Either refuses by name when nothing prices it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. An unpriced purchase order line takes the catalogue's price
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.add_document_line(uuid,uuid,numeric,bigint,text,date)'::regprocedure);
begin
  if position('p_unit_price_minor, round(p_quantity * p_unit_price_minor)::bigint,' in v_src) = 0
     or position('select coalesce(dt.create_permission, bt.create_permission) into v_perm' in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.add_document_line is not the 20260904150000 body';
  end if;
end $$;

create or replace function erp.add_document_line(p_document_id uuid,
                                                  p_item_id uuid,
                                                  p_quantity numeric,
                                                  p_unit_price_minor bigint default 0,
                                                  p_description text default null,
                                                  p_required_date date default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_state  text;
  v_perm   text;
  v_base   text;
  v_line   integer;
  v_id     uuid;
  v_price  bigint := coalesce(p_unit_price_minor, 0);
  pr       record;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  -- The same permission that raising this document required, read from the
  -- same place. A constant here meant a principal could be allowed to open a
  -- sales order and then refused a line on it.
  select coalesce(dt.create_permission, bt.create_permission), bt.code into v_perm, v_base
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  perform erp.authorise(v_perm, d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- A committed document is one the outside world has seen. Changing what it
  -- says after the fact is what amendment and reversal are for.
  select s.is_committed::text into v_state
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  if v_state = 'true' then
    raise exception
      'CLOVEERP_DOCUMENT_COMMITTED: % has been committed; amend or reverse it '
      'rather than editing its lines', d.document_number
      using errcode = '42501';
  end if;

  -- §5.3: a purchase order line nobody priced takes what the supplier's
  -- catalogue says, in the document's currency. A price somebody typed is
  -- kept; a draft may stay unpriced when the catalogue is silent — pricing
  -- the line is where that is refused by name.
  if v_base = 'purchase_order' and v_price = 0 then
    select * into pr from erp.resolve_purchase_price(p_item_id, d.party_id, p_quantity,
                                                     d.document_date, d.site_id);
    if found and (pr.currency is null or pr.currency = d.currency) then
      v_price := pr.amount_minor;
    end if;
  end if;

  select coalesce(max(l.line_no), 0) + 10 into v_line
    from erp.document_line l where l.tenant_id = v_tenant and l.document_id = p_document_id;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity,
    unit_price_minor, net_minor, currency, required_date)
  values (
    v_tenant, p_document_id, v_line, p_item_id, p_description, p_quantity,
    v_price, round(p_quantity * v_price)::bigint,
    d.currency, p_required_date)
  returning id into v_id;

  return v_id;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The register says what is now true
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.item_price', 'erp.party_role_terms',
                         'erp.resolve_purchase_price(uuid,uuid,numeric,date,uuid)',
                         'public.erp_resolve_purchase_price(uuid,uuid,numeric,uuid,date)',
                         'erp.price_document_line(uuid)',
                         'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)']
 where code = '5.3.supplier_catalogues';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.purchase_pricing_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid;
  v_second uuid; v_buyer uuid; v_tok text; v_btok text; res jsonb;
  v_uom uuid; v_site uuid; v_site2 uuid; v_sup uuid; v_sup_role uuid; v_cust uuid; v_item uuid; v_role uuid;
  v_po uuid; v_pol uuid; v_so uuid; v_sol uuid; v_typed uuid;
  p record; v_ok boolean; v_msg text; v_price bigint;
begin
  begin
    select * into r from erp.provision_tenant('zzppr', 'Purchase Pricing', 'a@zzppr.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zzppr.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    css := erp.configure_sales(15);

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(css); perform erp.promote_change_set(css);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'NORTH', 'North', 'warehouse', 'active') returning id into v_site2;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active') returning id into v_sup_role;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'BOLT', 'Bolt', v_uom, 'active') returning id into v_item;

    -- A buyer: procurement, and nothing of sales. Roles are configuration and
    -- the provisioned environment is live, so the rows are written the way a
    -- promotion writes them — inside a promotion window, transaction-local.
    perform set_config('erp.promotion_id', gen_random_uuid()::text, true);
    insert into erp.role (tenant_id, code, name, description, status)
    values (r.tenant_id, 'buyer', 'Buyer', 'Raises and prices purchase orders', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (r.tenant_id, v_role, 'procurement.order'), (r.tenant_id, v_role, 'procurement.read'),
           (r.tenant_id, v_role, 'master_data.read');
    perform set_config('erp.promotion_id', '', true);
    res := public.erp_invite_principal('buyer@zzppr.test', 'The Buyer');
    v_buyer := (res ->> 'app_user_id')::uuid; v_btok := res ->> 'token';
    perform erp.grant_role(v_buyer, 'buyer', null, null, 'the purchasing desk');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_btok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 1. Nothing on record.
    select * into p from erp.resolve_purchase_price(v_item, v_sup, 1);
    return query select 'a supplier with no price on record resolves nothing',
      not found, 'no row, not a zero';

    -- 2. Last cost, then a list, then a contract.
    insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from)
    values (r.tenant_id, v_item, 'last_cost', 'LAST', 'GBP', 900, 1, v_uom, 0, current_date - 30);
    select * into p from erp.resolve_purchase_price(v_item, v_sup, 1);
    return query select 'the last cost paid is a price where nothing else is',
      p.amount_minor = 900 and p.price_kind = 'last_cost', format('%s from %s', p.amount_minor, p.source);

    insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, party_role_id, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from)
    values (r.tenant_id, v_item, 'purchase_list', 'SUP-LIST', v_sup_role, 'GBP', 1000, 1, v_uom, 0, current_date - 10);
    select * into p from erp.resolve_purchase_price(v_item, v_sup, 1);
    return query select 'the supplier''s purchase list beats the last cost, even when dearer',
      p.amount_minor = 1000 and p.price_kind = 'purchase_list', format('%s from %s', p.amount_minor, p.source);

    insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, party_role_id, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from, valid_to)
    values (r.tenant_id, v_item, 'contract', 'SUP-2026', v_sup_role, 'GBP', 1100, 1, v_uom, 0, current_date - 5, current_date + 90);
    select * into p from erp.resolve_purchase_price(v_item, v_sup, 1);
    return query select 'and a contract beats the list',
      p.amount_minor = 1100 and p.price_kind = 'contract', 'a contract is what was agreed';

    -- 3. Quantity breaks and validity.
    insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, party_role_id, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from, valid_to)
    values (r.tenant_id, v_item, 'contract', 'SUP-2026', v_sup_role, 'GBP', 950, 1, v_uom, 100, current_date - 5, current_date + 90);
    return query select 'the biggest quantity break the line satisfies wins',
      (select x.amount_minor from erp.resolve_purchase_price(v_item, v_sup, 150) x) = 950
      and (select x.amount_minor from erp.resolve_purchase_price(v_item, v_sup, 50) x) = 1100,
      '950 at 150, 1100 at 50';
    return query select 'a price outside its validity is not a price',
      (select x.amount_minor from erp.resolve_purchase_price(v_item, v_sup, 1, current_date + 120) x) = 1000,
      'the contract ends in ninety days; the list carries on';

    -- 4. Site-specific beats general.
    insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code, party_role_id, site_id, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from)
    values (r.tenant_id, v_item, 'contract', 'SUP-2026-N', v_sup_role, v_site2, 'GBP', 1050, 1, v_uom, 0, current_date - 5);
    return query select 'a price for the site beats the general one, and only there',
      (select x.amount_minor from erp.resolve_purchase_price(v_item, v_sup, 1, null, v_site2) x) = 1050
      and (select x.amount_minor from erp.resolve_purchase_price(v_item, v_sup, 1, null, v_site) x) = 1100,
      '1050 at North, 1100 at Main';

    -- 5. The purchase order: an unpriced line takes the catalogue; a typed price is kept.
    v_po := erp.open_document('purchase_order', v_sup, r.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 10);
    v_typed := erp.add_document_line(v_po, v_item, 10, 1234);
    return query select 'an unpriced purchase order line takes the catalogue price; a typed price is kept',
      (select l.unit_price_minor from erp.document_line l where l.id = v_pol) = 1100
      and (select l.net_minor from erp.document_line l where l.id = v_pol) = 11000
      and (select l.unit_price_minor from erp.document_line l where l.id = v_typed) = 1234,
      'catalogue 1100 on the blank line, 1234 where somebody typed it';

    -- 6. The buyer prices a purchase line without sales.price, and cannot price a sales line.
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    update erp.document_line set unit_price_minor = 0, net_minor = 0 where id = v_pol;
    v_price := erp.price_document_line(v_pol);
    return query select 'a buyer prices a purchase line under procurement.order, from the supplier catalogue',
      v_price = 1100 and (select l.unit_price_minor from erp.document_line l where l.id = v_pol) = 1100,
      'no sales.price needed to price what we pay';

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_so := erp.open_document('sales_order', v_cust, r.entity_id, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 1, 0);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    begin
      perform erp.price_document_line(v_sol);
      v_ok := false; v_msg := 'a buyer priced a sales line';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'a sales line still needs sales.price', v_ok, v_msg;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 7. No purchase price: refused by name, with the next action.
    delete from erp.item_price where tenant_id = r.tenant_id and item_id = v_item;
    begin
      perform erp.price_document_line(v_pol);
      v_ok := false; v_msg := 'a line was priced from nothing';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NO_PURCHASE_PRICE%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'a supplier with no price refuses the line by name', v_ok, v_msg;

    -- 8. The register.
    return query select 'the register says supplier catalogues are built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.3.supplier_catalogues') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.3.supplier_catalogues'),
      '5.3.supplier_catalogues';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zzppr');
  detail := 'the organisation and its prices rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_purchase_pricing_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 13;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _purchase_pricing on commit drop as
    select * from erp_test.purchase_pricing_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _purchase_pricing;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PURCHASE_PRICING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_PURCHASE_PRICING_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('purchase pricing: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_purchase_pricing_suite() from public, anon, authenticated;
revoke all on function erp_test.purchase_pricing_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_purchase_pricing_suite();
select erp_test.assert_sales_depth_suite();
select erp_test.assert_procurement_suite();
select erp.assert_part5_coverage();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
