set lock_timeout = '30s';

-- =============================================================================
-- 20261007070000  A supplier's price can be set
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-108). No door writes a
-- price a supplier charges for a product. A purchase price reaches
-- erp.item_price only through the product file under Imports (on its first
-- load, and for no supplier in particular) and through a demonstration's seed.
-- Yet "Find a purchase price", when it finds nothing, tells the buyer to "add
-- one to the supplier's price list", which is a screen that did not exist.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Six refusals: a party that is not a supplier, a price that is not one
--      (below nothing, finer than the currency's smallest coin, a minimum
--      quantity below nothing, a currency nobody keeps), a second currency
--      beside one that stands, dates that start in the past or end before
--      they start, a supplier price that is not this organisation's, and one
--      that has ended already.
--   B. erp.set_supplier_price and its door public.erp_set_supplier_price. It
--      writes the row erp.resolve_purchase_price already reads first among
--      purchase lists: price kind purchase_list, on the supplier's own role,
--      for no site and no company, per one stock unit, with the currency,
--      minimum quantity and validity dates the table has always held. The
--      price it replaces (same product, supplier, currency and minimum
--      quantity) ends the day before the new one starts; the same day twice
--      is a correction of that day's price. A price is never backdated: what
--      a supplier charged on a day that has gone is history.
--   C. erp.end_supplier_price and its door public.erp_end_supplier_price: a
--      supplier price stops applying on a day. One that has not started is
--      withdrawn, and the price before it runs on as it would have.
--   D. public.erp_supplier_prices, which lists them for the Product-suppliers
--      screen, on procurement.read like erp_item_suppliers beside it.
--   E. Their write allowances, their place in the screen's help, and the
--      words the screen says.
--   F. erp_test.supplier_price_suite.
--
-- ── THE PERMISSION ───────────────────────────────────────────────────────────
--
-- master_data.write. It is what governs a supplier's terms for a product
-- today: erp_set_item_supplier and erp_end_item_supplier (lead time, minimum
-- order, the supplier's own code, approved for use) on the same screen, and
-- the party and product files that load a supplier's terms. A buyer holding
-- procurement.order prices a line by typing it, as before, and sees these
-- prices; setting the price list stays with whoever keeps the supplier's
-- terms, so the person raising an order is not also the one who sets what it
-- costs.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- A document line carries its own price (unit_price_minor), taken when the
-- line was written. Setting, replacing or ending a supplier price changes no
-- line on any order, bill or receipt: a line is priced again only when
-- somebody asks for it on a draft (erp.price_document_line). The suite proves
-- a line already priced keeps its price. erp.resolve_purchase_price, the
-- product and party files and the demonstration's seed are unchanged.
--
-- On production: three functions, three doors and their registrations are
-- added. No table is altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NOT_A_SUPPLIER',
  'Setting a supplier''s terms or price for a business partner the organisation does not buy from.',
  'Only a supplier is ordered from, so terms and prices for anybody else would never be read.',
  'Give the business partner the supplier role first, or choose a supplier.');

select erp.register_refusal('CLOVEERP_SUPPLIER_PRICE_INVALID',
  'Setting a supplier''s price below nothing, finer than the currency''s smallest coin, in a currency nobody keeps, or from a quantity below nothing.',
  'An order line takes this price as it stands, so it has to be one the supplier could charge.',
  'Type the price each, in the currency''s own units, such as 12.50, and a minimum quantity of nought or more.');

select erp.register_refusal('CLOVEERP_SUPPLIER_PRICE_OTHER_CURRENCY',
  'Setting a supplier''s price for a product in a second currency while a price in another stands or is due.',
  'An order line is priced from one of the supplier''s prices; two currencies at once would leave it to chance which one an order takes.',
  'End the price in the other currency first, from the day the new one starts, then set the new one.');

select erp.register_refusal('CLOVEERP_SUPPLIER_PRICE_DATES',
  'A supplier''s price that starts or ends before today, or ends before it starts.',
  'What a supplier charged on a day that has gone is history; changing it would change what that day''s prices were.',
  'Start the price today or later, and end it after it starts, or leave the end empty.');

select erp.register_refusal('CLOVEERP_SUPPLIER_PRICE_NOT_FOUND',
  'Ending a supplier''s price that is not one in this organisation.',
  'Only a price a supplier charges for a product can be ended here.',
  'Choose the price from the list of supplier prices on the Product-suppliers screen.');

select erp.register_refusal('CLOVEERP_SUPPLIER_PRICE_ALREADY_ENDED',
  'Ending a supplier''s price that has ended already.',
  'It applies to no order on or after that day already.',
  'Set a new price for the supplier if they are charging again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Setting a price
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.set_supplier_price(
  p_item_id      uuid,
  p_party_id     uuid,
  p_unit_price   numeric,
  p_currency     text,
  p_min_quantity numeric default 0,
  p_valid_from   date default null,
  p_valid_to     date default null,
  p_reason       text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_item   erp.item%rowtype;
  v_role   uuid;
  v_party  text;
  v_ccy    character(3) := upper(btrim(coalesce(p_currency, '')));
  v_units  smallint;
  v_minor  numeric;
  v_min    numeric := coalesce(p_min_quantity, 0);
  v_from   date := coalesce(p_valid_from, current_date);
  v_to     date := p_valid_to;
  v_other  text;
  v_id     uuid;
  v_ended  integer := 0;
  v_actor  uuid := erp.current_principal_id();
  v_kind   erp.principal_kind;
  v_label  text;
begin
  -- What a supplier charges for a product, from a day (20261007070000). The
  -- row is the one erp.resolve_purchase_price reads first among purchase
  -- lists: purchase_list on the supplier's own role, for no site and no
  -- company, per one stock unit. A line already written keeps its price.
  perform erp.authorise('master_data.write');

  select * into v_item from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: no product % in this organisation', p_item_id
      using errcode = '23503', hint = 'Choose the product from the list.';
  end if;

  select r.id, p.name into v_role, v_party
    from erp.party_role r
    join erp.party p on p.tenant_id = r.tenant_id and p.id = r.party_id
   where r.tenant_id = v_tenant and r.party_id = p_party_id
     and r.role_kind = 'supplier' and r.status = 'active';
  if v_role is null then
    raise exception 'CLOVEERP_NOT_A_SUPPLIER: that business partner does not hold the supplier role'
      using errcode = '23514',
            hint = 'Give the business partner the supplier role first, or choose a supplier.';
  end if;

  select c.minor_units into v_units from erp_ref.currency c where c.code = v_ccy and c.is_active;
  if v_units is null then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_INVALID: % is not a currency this organisation can price in', nullif(v_ccy, '')
      using errcode = '23514', hint = 'Choose the currency from the list.';
  end if;

  v_minor := p_unit_price * power(10::numeric, v_units);
  if p_unit_price is null or p_unit_price < 0 then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_INVALID: a price each of % is not one a supplier charges', p_unit_price
      using errcode = '23514', hint = 'Type the price each, such as 12.50, or 0 for a product the supplier gives.';
  end if;
  if v_minor <> trunc(v_minor) then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_INVALID: % % is finer than the smallest coin of %', p_unit_price, v_ccy, v_ccy
      using errcode = '23514', hint = 'Type the price each to the currency''s smallest coin.';
  end if;
  if v_min < 0 then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_INVALID: a minimum quantity of % is below nothing', v_min
      using errcode = '23514', hint = 'Leave the minimum quantity empty for any quantity.';
  end if;

  if v_from < current_date then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_DATES: a price starting on % starts in the past', v_from
      using errcode = '23514', hint = 'Start the price today or later.';
  end if;
  if v_to is not null and v_to <= v_from then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_DATES: a price starting on % cannot stop applying on %', v_from, v_to
      using errcode = '23514', hint = 'End the price after it starts, or leave the end empty.';
  end if;

  -- One writer at a time for this product and supplier.
  perform pg_advisory_xact_lock(hashtextextended(
    'supplier_price:' || v_tenant::text || ':' || p_item_id::text || ':' || v_role::text, 0));

  -- One currency at a time: erp.resolve_purchase_price picks one price and
  -- the line takes it only in the document's currency.
  select string_agg(distinct x.currency::text, ', ') into v_other
    from erp.item_price x
   where x.tenant_id = v_tenant and x.item_id = p_item_id
     and x.price_kind = 'purchase_list' and x.party_role_id = v_role
     and x.currency <> v_ccy
     and (x.valid_to is null or x.valid_to > v_from)
     and (v_to is null or x.valid_from < v_to);
  if v_other is not null then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_OTHER_CURRENCY: % charges for % in % on or after %',
      v_party, v_item.code, v_other, v_from
      using errcode = '23514',
            hint = 'End the price in the other currency first, from the day the new one starts, then set the new one.';
  end if;

  -- A price due later bounds this one, unless an end was given.
  if v_to is null then
    select min(x.valid_from) into v_to
      from erp.item_price x
     where x.tenant_id = v_tenant and x.item_id = p_item_id
       and x.price_kind = 'purchase_list' and x.party_role_id = v_role
       and x.currency = v_ccy and x.min_quantity = v_min
       and x.site_id is null and x.entity_id is null and x.price_list_code is null
       and x.valid_from > v_from;
  end if;

  -- The price this replaces stops applying the day the new one starts.
  update erp.item_price x
     set valid_to = v_from, updated_at = now()
   where x.tenant_id = v_tenant and x.item_id = p_item_id
     and x.price_kind = 'purchase_list' and x.party_role_id = v_role
     and x.currency = v_ccy and x.min_quantity = v_min
     and x.site_id is null and x.entity_id is null and x.price_list_code is null
     and x.valid_from < v_from
     and (x.valid_to is null or x.valid_to > v_from);
  get diagnostics v_ended = row_count;

  -- The same day twice corrects that day's price.
  update erp.item_price x
     set amount_minor = v_minor::bigint, per_quantity = 1, valid_to = v_to, updated_at = now()
   where x.tenant_id = v_tenant and x.item_id = p_item_id
     and x.price_kind = 'purchase_list' and x.party_role_id = v_role
     and x.currency = v_ccy and x.min_quantity = v_min
     and x.site_id is null and x.entity_id is null and x.price_list_code is null
     and x.valid_from = v_from
  returning x.id into v_id;

  if v_id is null then
    insert into erp.item_price (tenant_id, item_id, price_kind, party_role_id, currency,
                                amount_minor, per_quantity, uom_id, min_quantity, valid_from, valid_to)
    values (v_tenant, p_item_id, 'purchase_list', v_role, v_ccy,
            v_minor::bigint, 1, v_item.stock_uom_id, v_min, v_from, v_to)
    returning id into v_id;
  end if;

  -- Why, where an auditor reads it, beside the row's own audit.
  if nullif(btrim(coalesce(p_reason, '')), '') is not null then
    if v_actor is not null then
      select u.kind, u.display_name into v_kind, v_label from erp.app_user u where u.id = v_actor;
    end if;
    insert into erp.audit_entry (
      tenant_id, actor_id, actor_kind, actor_label, action, object_schema, object_type,
      object_id, object_key, after_state, reason, correlation_id, source)
    values (
      v_tenant, v_actor, coalesce(v_kind, 'service'), coalesce(v_label, 'system'), 'execute',
      'erp', 'item_price', v_id, v_item.code,
      jsonb_build_object('supplier', v_party, 'amount_minor', v_minor::bigint, 'currency', v_ccy,
                         'min_quantity', v_min, 'valid_from', v_from, 'valid_to', v_to),
      btrim(p_reason), erp.current_correlation_id(), erp.current_source());
  end if;

  return jsonb_build_object('item_price_id', v_id, 'item_code', v_item.code, 'supplier', v_party,
                            'amount_minor', v_minor::bigint, 'currency', v_ccy, 'min_quantity', v_min,
                            'valid_from', v_from, 'valid_to', v_to, 'ended', v_ended);
end;
$$;

revoke all on function erp.set_supplier_price(uuid, uuid, numeric, text, numeric, date, date, text) from public, anon;

comment on function erp.set_supplier_price(uuid, uuid, numeric, text, numeric, date, date, text) is
  'Sets what a supplier charges for a product, per stock unit, in a currency, from a minimum quantity and a day '
  '(20261007070000): the supplier purchase-list row erp.resolve_purchase_price reads. The price it replaces ends the '
  'day before; no line already written changes. Authorises master_data.write.';

create or replace function public.erp_set_supplier_price(
  p_item_id      uuid,
  p_party_id     uuid,
  p_unit_price   numeric,
  p_currency     text,
  p_min_quantity numeric default 0,
  p_valid_from   date default null,
  p_valid_to     date default null,
  p_reason       text default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.set_supplier_price(p_item_id, p_party_id, p_unit_price, p_currency,
                                p_min_quantity, p_valid_from, p_valid_to, p_reason)
$$;

revoke all on function public.erp_set_supplier_price(uuid, uuid, numeric, text, numeric, date, date, text) from public, anon;
grant execute on function public.erp_set_supplier_price(uuid, uuid, numeric, text, numeric, date, date, text) to authenticated, service_role;

comment on function public.erp_set_supplier_price(uuid, uuid, numeric, text, numeric, date, date, text) is
  'Sets what a supplier charges for a product from a day, ending the price it replaces (20261007070000). '
  'Authorises master_data.write.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Ending a price
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.end_supplier_price(
  p_item_price_id uuid,
  p_on            date default null,
  p_reason        text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  x        erp.item_price%rowtype;
  v_on     date := coalesce(p_on, current_date);
  v_code   text;
  v_party  text;
  v_gone   boolean := false;
  v_actor  uuid := erp.current_principal_id();
  v_kind   erp.principal_kind;
  v_label  text;
begin
  -- A supplier's price stops applying on a day (20261007070000). One that has
  -- not started is withdrawn, and the price it would have replaced runs on.
  perform erp.authorise('master_data.write');

  select p.* into x
    from erp.item_price p
    join erp.party_role r on r.tenant_id = p.tenant_id and r.id = p.party_role_id
   where p.tenant_id = v_tenant and p.id = p_item_price_id
     and p.price_kind = 'purchase_list' and r.role_kind = 'supplier'
     for update of p;
  if not found then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_NOT_FOUND: no supplier price % in this organisation', p_item_price_id
      using errcode = '23503',
            hint = 'Choose the price from the list of supplier prices on the Product-suppliers screen.';
  end if;

  if v_on < current_date then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_DATES: a price cannot stop applying on %, which has gone', v_on
      using errcode = '23514', hint = 'End the price today or later.';
  end if;
  if x.valid_to is not null and x.valid_to <= v_on then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_ALREADY_ENDED: this price stopped applying on %', x.valid_to
      using errcode = '23514', hint = 'Set a new price for the supplier if they are charging again.';
  end if;

  select i.code into v_code from erp.item i where i.tenant_id = v_tenant and i.id = x.item_id;
  select p.name into v_party
    from erp.party_role r join erp.party p on p.tenant_id = r.tenant_id and p.id = r.party_id
   where r.tenant_id = v_tenant and r.id = x.party_role_id;

  if x.valid_from >= v_on then
    -- Not started before the day it would stop: it applies to no day from
    -- here on, so it goes (the row's audit keeps it, and a line it priced
    -- today keeps its price), and the price it would have ended runs on to
    -- where it would have.
    delete from erp.item_price p where p.tenant_id = v_tenant and p.id = x.id;
    update erp.item_price p
       set valid_to = x.valid_to, updated_at = now()
     where p.tenant_id = v_tenant and p.item_id = x.item_id
       and p.price_kind = 'purchase_list' and p.party_role_id = x.party_role_id
       and p.currency = x.currency and p.min_quantity = x.min_quantity
       and p.site_id is not distinct from x.site_id and p.entity_id is not distinct from x.entity_id
       and p.price_list_code is not distinct from x.price_list_code
       and p.valid_to = x.valid_from;
    v_gone := true;
  else
    update erp.item_price p set valid_to = v_on, updated_at = now()
     where p.tenant_id = v_tenant and p.id = x.id;
  end if;

  if v_actor is not null then
    select u.kind, u.display_name into v_kind, v_label from erp.app_user u where u.id = v_actor;
  end if;
  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action, object_schema, object_type,
    object_id, object_key, after_state, reason, correlation_id, source)
  values (
    v_tenant, v_actor, coalesce(v_kind, 'service'), coalesce(v_label, 'system'), 'execute',
    'erp', 'item_price', x.id, v_code,
    jsonb_build_object('supplier', v_party, 'amount_minor', x.amount_minor, 'currency', x.currency,
                       'valid_from', x.valid_from, 'ends', v_on, 'withdrawn', v_gone),
    nullif(btrim(coalesce(p_reason, '')), ''), erp.current_correlation_id(), erp.current_source());

  return jsonb_build_object('item_price_id', x.id, 'item_code', v_code, 'supplier', v_party,
                            'valid_to', case when v_gone then null else v_on end,
                            'withdrawn', v_gone);
end;
$$;

revoke all on function erp.end_supplier_price(uuid, date, text) from public, anon;

comment on function erp.end_supplier_price(uuid, date, text) is
  'Ends a supplier''s price on a day, today or later (20261007070000); one not yet started is withdrawn and the price '
  'before it runs on. No line already written changes. Authorises master_data.write.';

create or replace function public.erp_end_supplier_price(
  p_item_price_id uuid,
  p_on            date default null,
  p_reason        text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.end_supplier_price(p_item_price_id, p_on, p_reason) $$;

revoke all on function public.erp_end_supplier_price(uuid, date, text) from public, anon;
grant execute on function public.erp_end_supplier_price(uuid, date, text) to authenticated, service_role;

comment on function public.erp_end_supplier_price(uuid, date, text) is
  'Ends a supplier''s price on a day, or withdraws one not yet started (20261007070000). Authorises master_data.write.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Reading them
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_supplier_prices(
  p_item_id  uuid default null,
  p_party_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_out    jsonb;
begin
  -- What each supplier charges for each product (20261007070000), on the
  -- permission the product-supplier list beside it reads on.
  perform erp.authorise('procurement.read');
  select coalesce(jsonb_agg(q.x order by q.item_code, q.supplier, q.currency, q.min_quantity, q.valid_from desc), '[]'::jsonb)
    into v_out
    from (
      select i.code as item_code, pt.name as supplier, p.currency::text as currency,
             p.min_quantity, p.valid_from,
             jsonb_build_object(
               'item_price_id', p.id, 'item_id', p.item_id, 'item_code', i.code, 'item_name', i.name,
               'party_id', pt.id, 'supplier', pt.name,
               'amount_minor', p.amount_minor, 'currency', p.currency,
               'minor_units', coalesce(c.minor_units, 2),
               'per_quantity', p.per_quantity, 'min_quantity', p.min_quantity,
               'valid_from', p.valid_from, 'valid_to', p.valid_to,
               'state', case when p.valid_from > current_date then 'starts_later'
                             when p.valid_to is not null and p.valid_to <= current_date then 'ended'
                             else 'in_force' end) as x
        from erp.item_price p
        join erp.party_role r on r.tenant_id = p.tenant_id and r.id = p.party_role_id
                             and r.role_kind = 'supplier'
        join erp.party pt on pt.tenant_id = r.tenant_id and pt.id = r.party_id
        join erp.item i on i.tenant_id = p.tenant_id and i.id = p.item_id
        left join erp_ref.currency c on c.code = p.currency
       where p.tenant_id = v_tenant
         and p.price_kind = 'purchase_list'
         and (p_item_id is null or p.item_id = p_item_id)
         and (p_party_id is null or r.party_id = p_party_id)) q;
  return v_out;
end;
$$;

revoke all on function public.erp_supplier_prices(uuid, uuid) from public, anon;
grant execute on function public.erp_supplier_prices(uuid, uuid) to authenticated, service_role;

comment on function public.erp_supplier_prices(uuid, uuid) is
  'What each supplier charges for each product, with the dates each price applies and whether it is in force, '
  'starts later or has ended (20261007070000). Authorises procurement.read.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Their registrations and their words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_supplier_price', 'erp.set_supplier_price',
   'Sets what a supplier charges for a product from a day, ending the price it replaces; authorises master_data.write and changes no line already written.'),
  ('erp_end_supplier_price', 'erp.end_supplier_price',
   'Ends a supplier''s price on a day, today or later, or withdraws one not yet started; authorises master_data.write.'),
  ('erp_supplier_prices', 'erp.authorise',
   'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/master-data/item-supply',
                                 array['erp_set_supplier_price', 'erp_end_supplier_price']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A supplier''s price on the Product-suppliers screen (20261007070000).'
  from (values
    ('Supplier prices'),
    ('What a supplier charges for a product, from a day. A purchase order line left without a price takes it; a line already on an order keeps the price it has.'),
    ('Set the supplier''s price'),
    ('End a supplier''s price'),
    ('In the currency below, for one stock unit of the product.'),
    ('Minimum quantity'),
    ('The price applies to an order line of at least this many. Leave empty for any quantity.'),
    ('Today if left empty. A price cannot start in the past.'),
    ('Leave empty for no end. The price stops applying on this day.'),
    ('Price to end'),
    ('Stops applying on'),
    ('Today if left empty. One that has not started yet is withdrawn.'),
    ('The price a purchase order line takes when nobody types one, by supplier and from the day it applies. Find a purchase price answers the same.'),
    ('No supplier has a price yet, so a purchase order line takes none unless one is typed. Set one under Supplier prices above.'),
    ('Starts later'),
    ('Ended')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.supplier_price_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  rb2      record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_supp uuid; v_cust uuid;
  v_ccy    text; v_other text;
  v_po uuid; v_line1 uuid; v_line2 uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_out  jsonb; v_list jsonb;
  v_n    integer; v_n2 integer;
  v_err  text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text;
  a      bigint; b bigint; c bigint;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with an administrator, a buyer, a product and a supplier';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzspr-' || v_tag, 'Supplier Price Suite',
      'admin@zzspr-' || v_tag || '.test', 'Price Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzspr-' || v_tag || '.test'),
           (s_buy, 'buyer@zzspr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('buyer@zzspr-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id, e.base_currency into v_entity, v_ccy from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    v_other := case when v_ccy = 'USD' then 'EUR' else 'USD' end;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZSPRBOLT', 'Priced Bolt', v_uom, 'active') returning id into v_item;
    v_supp := erp_test.cash_payment_supplier('ZSPRSUP');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZSPRCUST', 'Only A Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the three doors are allowed and gated, the two that write are in the screen''s help, and the six refusals and the words are registered';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance w
                where (w.function_name, w.gate) in (('erp_set_supplier_price', 'erp.set_supplier_price'),
                                                    ('erp_end_supplier_price', 'erp.end_supplier_price'),
                                                    ('erp_supplier_prices', 'erp.authorise'))) = 3
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/master-data/item-supply'
                         and h.actions @> array['erp_set_supplier_price', 'erp_end_supplier_price'])
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_NOT_A_SUPPLIER', 'CLOVEERP_SUPPLIER_PRICE_INVALID',
                                 'CLOVEERP_SUPPLIER_PRICE_OTHER_CURRENCY', 'CLOVEERP_SUPPLIER_PRICE_DATES',
                                 'CLOVEERP_SUPPLIER_PRICE_NOT_FOUND', 'CLOVEERP_SUPPLIER_PRICE_ALREADY_ENDED')
                  and coalesce(f.next_action, '') <> '') = 6
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en'
                  and x.key in (erp_ref.ui_key('Supplier prices'), erp_ref.ui_key('Set the supplier''s price'),
                                erp_ref.ui_key('End a supplier''s price'))) = 3;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Set, it is what Find a purchase price answers ────────────────────
    v_step := 'a price set for the supplier';
    v_out := public.erp_set_supplier_price(v_item, v_supp, 12.50, lower(v_ccy), null, null, null, 'their list of 1 October');
    v_p1 := (v_out ->> 'item_price_id')::uuid;
    res := public.erp_resolve_purchase_price(v_item, v_supp, 10);
    v_list := public.erp_supplier_prices(v_item);
    v_cases := v_cases + 1;
    case_name := 'a price set for a supplier is what Find a purchase price answers, and the screen lists it in force';
    passed := v_state is null
          and (res ->> 'amount_minor')::bigint = 1250
          and res ->> 'currency' = v_ccy
          and res ->> 'source' = 'the supplier purchase list'
          and jsonb_array_length(v_list) = 1
          and v_list -> 0 ->> 'state' = 'in_force'
          and (v_list -> 0 ->> 'amount_minor')::bigint = 1250
          and v_list -> 0 ->> 'supplier' = 'Cash Payment ZSPRSUP'
          and (v_list -> 0 ->> 'valid_from')::date = current_date
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = rb.tenant_id and ae.object_type = 'item_price'
                         and ae.object_id = v_p1 and ae.reason = 'their list of 1 October');
    detail := coalesce(v_state, left(res::text || ' / ' || v_list::text, 400));
    return next;

    -- ── 3. A line already priced keeps its price ────────────────────────────
    v_step := 'an order line priced from it, then the price corrected the same day';
    v_po := erp.open_document('purchase_order', v_supp, v_entity, v_site);
    v_line1 := erp.add_document_line(v_po, v_item, 10, 0, 'first line');
    v_out := public.erp_set_supplier_price(v_item, v_supp, 13.40, v_ccy);
    v_line2 := erp.add_document_line(v_po, v_item, 10, 0, 'second line');
    select count(*) into v_n from erp.item_price p
     where p.tenant_id = rb.tenant_id and p.item_id = v_item and p.price_kind = 'purchase_list';
    a := (select l.unit_price_minor from erp.document_line l where l.id = v_line1);
    b := (select l.unit_price_minor from erp.document_line l where l.id = v_line2);
    v_cases := v_cases + 1;
    case_name := 'a new price changes no line already on an order: the first line keeps 12.50, the next takes 13.40, and the same day twice is one price corrected';
    passed := v_state is null
          and a = 1250 and b = 1340
          and v_n = 1
          and (v_out ->> 'item_price_id')::uuid = v_p1
          and (select l.net_minor from erp.document_line l where l.id = v_line1) = 12500;
    detail := coalesce(v_state, format('first %s, second %s, %s price row(s)', a, b, v_n));
    return next;

    -- ── 4. A later price ends the current one the day before ────────────────
    v_step := 'a price from a week today';
    v_out := public.erp_set_supplier_price(v_item, v_supp, 14, v_ccy, 0, current_date + 7);
    v_p2 := (v_out ->> 'item_price_id')::uuid;
    a := (public.erp_resolve_purchase_price(v_item, v_supp, 10, null, current_date + 6) ->> 'amount_minor')::bigint;
    b := (public.erp_resolve_purchase_price(v_item, v_supp, 10, null, current_date + 7) ->> 'amount_minor')::bigint;
    v_list := public.erp_supplier_prices(v_item, v_supp);
    v_cases := v_cases + 1;
    case_name := 'a price from a later day ends the one in force the day before, and each day is priced by its own';
    passed := v_state is null
          and (v_out ->> 'ended')::integer = 1
          and (select p.valid_to from erp.item_price p where p.id = v_p1) = current_date + 7
          and a = 1340 and b = 1400
          and (select count(*) from jsonb_array_elements(v_list) e where e ->> 'state' = 'in_force') = 1
          and (select count(*) from jsonb_array_elements(v_list) e where e ->> 'state' = 'starts_later') = 1;
    detail := coalesce(v_state, format('day 6 %s, day 7 %s; %s', a, b, left(v_list::text, 300)));
    return next;

    -- ── 5. From a quantity, and in one currency at a time ───────────────────
    v_step := 'a price from 100, then a price in a second currency';
    v_out := public.erp_set_supplier_price(v_item, v_supp, 12, v_ccy, 100);
    v_p3 := (v_out ->> 'item_price_id')::uuid;
    a := (public.erp_resolve_purchase_price(v_item, v_supp, 10) ->> 'amount_minor')::bigint;
    b := (public.erp_resolve_purchase_price(v_item, v_supp, 100) ->> 'amount_minor')::bigint;
    v_err := null;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 15, v_other); v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a price from a quantity applies from that quantity, and a second currency is refused while one stands';
    passed := v_state is null
          and a = 1340 and b = 1200
          and v_err like 'CLOVEERP_SUPPLIER_PRICE_OTHER_CURRENCY%'
          and not exists (select 1 from erp.item_price p
                           where p.tenant_id = rb.tenant_id and p.item_id = v_item and p.currency = v_other);
    detail := coalesce(v_state, format('10 at %s, 100 at %s; %s', a, b, v_err));
    return next;

    -- ── 6. What is not a price is refused, and nothing is written ───────────
    v_step := 'prices that are not prices';
    select count(*) into v_n from erp.item_price p where p.tenant_id = rb.tenant_id and p.item_id = v_item;
    begin perform public.erp_set_supplier_price(v_item, v_supp, -1, v_ccy); v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 12.345, v_ccy); v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 12, v_ccy, 0, current_date - 1); v_err3 := 'set';
    exception when others then v_err3 := sqlerrm; end;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 12, v_ccy, 0, current_date + 3, current_date + 3); v_err4 := 'set';
    exception when others then v_err4 := sqlerrm; end;
    begin perform public.erp_set_supplier_price(v_item, v_cust, 12, v_ccy); v_err5 := 'set';
    exception when others then v_err5 := sqlerrm; end;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 12, 'ZZZ'); v_err6 := 'set';
    exception when others then v_err6 := sqlerrm; end;
    select count(*) into v_n2 from erp.item_price p where p.tenant_id = rb.tenant_id and p.item_id = v_item;
    v_cases := v_cases + 1;
    case_name := 'below nothing, finer than a penny, starting yesterday, ending as it starts, a customer and an unknown currency are each refused, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_SUPPLIER_PRICE_INVALID%'
          and v_err2 like 'CLOVEERP_SUPPLIER_PRICE_INVALID%'
          and v_err3 like 'CLOVEERP_SUPPLIER_PRICE_DATES%'
          and v_err4 like 'CLOVEERP_SUPPLIER_PRICE_DATES%'
          and v_err5 like 'CLOVEERP_NOT_A_SUPPLIER%'
          and v_err6 like 'CLOVEERP_SUPPLIER_PRICE_INVALID%'
          and v_n = v_n2;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_err6, v_n || '→' || v_n2));
    return next;

    -- ── 7. Ended, and withdrawn before it starts ────────────────────────────
    v_step := 'the later price withdrawn, then the price in force ended today';
    v_out := public.erp_end_supplier_price(v_p2, null, 'they kept their price');
    v_err := (select p.valid_to::text from erp.item_price p where p.id = v_p1);
    -- As if the price in force had been set a month ago: one set today and
    -- ended today applied to no day, and is withdrawn like one not started.
    update erp.item_price p set valid_from = current_date - 30 where p.id = v_p1;
    res := public.erp_end_supplier_price(v_p1);
    a := (public.erp_resolve_purchase_price(v_item, v_supp, 10) ->> 'amount_minor')::bigint;
    v_err2 := null;
    begin perform public.erp_end_supplier_price(v_p1); v_err2 := 'ended twice';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a price not yet started is withdrawn and the one before runs on; one in force stops applying today, once, and the order''s lines keep their prices';
    passed := v_state is null
          and (v_out ->> 'withdrawn')::boolean
          and not exists (select 1 from erp.item_price p where p.id = v_p2)
          and v_err is null
          and (res ->> 'withdrawn')::boolean = false
          and (select p.valid_to from erp.item_price p where p.id = v_p1) = current_date
          and a is null
          and v_err2 like 'CLOVEERP_SUPPLIER_PRICE_ALREADY_ENDED%'
          and (select l.unit_price_minor from erp.document_line l where l.id = v_line1) = 1250
          and (select l.unit_price_minor from erp.document_line l where l.id = v_line2) = 1340;
    detail := coalesce(v_state, concat_ws(' / ', v_out::text, coalesce(v_err, 'runs on'), res::text, a::text, v_err2));
    return next;

    -- ── 8. A buyer sees the prices and does not set them ────────────────────
    v_step := 'the buyer reads, sets and ends';
    select count(*) into v_n from erp.item_price p where p.tenant_id = rb.tenant_id and p.item_id = v_item;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_list := public.erp_supplier_prices(v_item);
    v_err := null; v_err2 := null;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 1, v_ccy); v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_end_supplier_price(v_p3); v_err2 := 'ended';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n2 from erp.item_price p where p.tenant_id = rb.tenant_id and p.item_id = v_item;
    v_cases := v_cases + 1;
    case_name := 'a buyer sees the supplier''s prices but neither sets nor ends one: that is for whoever keeps the supplier''s terms';
    passed := v_state is null
          and jsonb_array_length(v_list) = 2
          and v_err like 'CLOVEERP_PERMISSION_DENIED%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED%'
          and v_n = v_n2
          and (select p.valid_to from erp.item_price p where p.id = v_p3) is null;
    detail := coalesce(v_state, concat_ws(' / ', jsonb_array_length(v_list)::text, v_err, v_err2));
    return next;

    -- ── 9. Another organisation sees none of it ─────────────────────────────
    v_step := 'a second organisation';
    perform set_config('request.jwt.claims', '', true);
    select * into rb2 from erp.provision_tenant(
      'zzspx-' || v_tag, 'Supplier Price Other',
      'admin@zzspx-' || v_tag || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = rb2.tenant_id and is_self;
    insert into auth.users (id, email) values (a3, 'admin@zzspx-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    v_list := public.erp_supplier_prices();
    v_err := null; v_err2 := null;
    begin perform public.erp_end_supplier_price(v_p3); v_err := 'ended';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_set_supplier_price(v_item, v_supp, 1, v_ccy); v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    c := (public.erp_resolve_purchase_price(v_item, v_supp, 100) ->> 'amount_minor')::bigint;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'another organisation lists none of these prices, cannot end one, cannot price this product, and Find a purchase price answers it nothing';
    passed := v_state is null
          and jsonb_array_length(v_list) = 0
          and v_err like 'CLOVEERP_SUPPLIER_PRICE_NOT_FOUND%'
          and v_err2 like 'CLOVEERP_UNKNOWN_ITEM%'
          and c is null
          and (select p.valid_to from erp.item_price p where p.id = v_p3) is null;
    detail := coalesce(v_state, concat_ws(' / ', v_list::text, v_err, v_err2, c::text));
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
    raise exception 'CLOVEERP_SUPPLIER_PRICE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.supplier_price_suite() from public, anon;

comment on function erp_test.supplier_price_suite() is
  'A supplier''s price can be set and ended (20261007070000): it is what Find a purchase price answers, a line already '
  'priced keeps its price, a later price ends the current one, a quantity break and one currency at a time hold, '
  'what is not a price is refused, a buyer only reads, and another organisation sees none of it.';

create or replace function erp_test.assert_supplier_price_suite()
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
    from erp_test.supplier_price_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A supplier''s price was set, ended or read where it should not be, or changed a line already written. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_SUPPLIER_PRICE_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('supplier price: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_supplier_price_suite() from public, anon;

comment on function erp_test.assert_supplier_price_suite() is
  'A supplier''s price can be set and ended on the Product-suppliers screen without changing any line already '
  'written (20261007070000).';

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
