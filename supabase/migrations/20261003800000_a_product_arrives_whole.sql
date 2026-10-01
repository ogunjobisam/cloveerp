-- ═════════════════════════════════════════════════════════════════════════════
-- A product arrives whole
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A product imported through the master-data pipeline arrived as a code, a
-- name, a description and a group, stocked in whichever base unit sorted
-- first. Its tracking, barcode, prices, supplier and reorder levels were keyed
-- by hand afterwards, one product at a time.
--
-- The item_profile import object carries one legacy product whole: the item in
-- its own stock unit, its purchase unit where the two convert, batch, serial
-- and expiry tracking, a primary barcode, its weight, a purchase price and a
-- sales price, its default supplier, and its reorder levels per site. One
-- Unleashed product is one row.
--
-- Loading is additive, as party_profile's is. An item that exists gains what
-- it lacks — a primary barcode when it has none, a price of a kind none of
-- which is in force, a default supplier, a policy for a site it has none at,
-- tracking turned on while it holds no stock — and nothing it has changes:
-- not its units, not a price somebody set. Rollback removes exactly what the
-- batch added, recorded on each row, and refuses once anything else has
-- attached itself.
--
-- Three things the pricing code does not do shape what is loaded:
--
--   * erp.resolve_price does not read price_list_code, so every sales-list
--     price competes for a line. One sales price per item is loaded, the
--     product's default; Unleashed's ten sell-price tiers are not.
--   * Nothing reads per_quantity, so a price is loaded per unit in whole
--     minor units: the file rounds a sub-penny price and says so.
--   * No desk door writes item prices, so the import is the only writer and
--     holds its own gate: sales.price, on top of master_data.write.
--
-- Tracking goes through erp.set_item_controls, which refuses once an item
-- holds stock; the item goes through erp.create_item, and is returned to
-- draft, since imported records are activated together once reviewed.
--
-- Proof: erp_test.item_profile_suite() (9 cases).

set lock_timeout = '30s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The register
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.import_object (object_type, name_key, module_code, validate_function, load_function, rollback_function, description, seq) values
  ('item_profile', 'import_object.item_profile.name', 'master_data',
   'erp.validate_item_profile_import', 'erp.load_item_profile_import', 'erp.rollback_item_profile_import',
   'A legacy product whole: units, tracking, barcode, weight, prices, default supplier and reorder levels. Additive: an item that exists gains what it lacks and keeps everything it has.', 40)
on conflict (object_type) do update
  set name_key = excluded.name_key, module_code = excluded.module_code,
      validate_function = excluded.validate_function, load_function = excluded.load_function,
      rollback_function = excluded.rollback_function, description = excluded.description, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('import_object.item_profile.name', 'en', 'Products', 'master_data'),
  ('import_object.item_profile.name', 'de', 'Artikel', 'master_data')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

-- Whether a unit converts to another, for this item or for every item.
create or replace function erp.uom_converts(p_tenant uuid, p_item_id uuid, p_from uuid, p_to uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_from = p_to
      or exists (select 1 from erp.uom_conversion c
                  where c.tenant_id = p_tenant
                    and (c.item_id is null or c.item_id = p_item_id)
                    and ((c.from_uom_id = p_from and c.to_uom_id = p_to)
                      or (c.from_uom_id = p_to and c.to_uom_id = p_from)))
$$;

revoke all on function erp.uom_converts(uuid, uuid, uuid, uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Validate
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.validate_item_profile_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_find   jsonb;
  v_errors integer := 0;
  v_bad    text;
  v_code   text;
  v_codes  text[] := '{}';
  v_item   erp.item%rowtype;
  v_stock  uuid;
  v_buy    uuid;
  v_stocked boolean;
  v_other  text;
  p        record;
  s        jsonb;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514', hint = 'Stage a new batch; a loaded or rolled-back one is not validated again.';
  end if;

  for r in select * from erp.import_row x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id order by x.row_no loop
    v_find := '[]'::jsonb;
    v_code := btrim(coalesce(r.raw ->> 'code', ''));

    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k not in ('source', 'code', 'name', 'description', 'item_group', 'lifecycle', 'stock_uom',
                     'purchase_uom', 'is_batch_controlled', 'is_serial_controlled', 'has_expiry',
                     'barcode', 'gross_weight_g', 'purchase_price', 'sales_price', 'supplier', 'sites');
    if v_bad is not null then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('unknown field(s): %s', v_bad));
    end if;
    if coalesce(r.raw ->> 'source', '') not in ('xero', 'unleashed') then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'source is xero or unleashed');
    end if;
    if v_code = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'code is the Clove item code, and it is missing');
    elsif v_code = any (v_codes) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is on an earlier row', v_code));
    else
      v_codes := v_codes || v_code;
    end if;
    if coalesce(r.raw ->> 'lifecycle', 'discontinued') <> 'discontinued' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'lifecycle is discontinued or absent');
    end if;

    v_item := null;
    if v_code <> '' then
      select * into v_item from erp.item i where i.tenant_id = v_tenant and i.code = v_code;
    end if;
    v_stocked := v_item.id is not null and exists (
      select 1 from erp.stock_balance sb where sb.tenant_id = v_tenant and sb.item_id = v_item.id and sb.quantity <> 0);

    -- Units.
    v_stock := null;
    if coalesce(r.raw ->> 'stock_uom', '') <> '' then
      select u.id into v_stock from erp.uom u
       where u.tenant_id = v_tenant and upper(u.code) = upper(btrim(r.raw ->> 'stock_uom')) and u.status = 'active';
      if v_stock is null then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a unit of measure here; set it up before loading', r.raw ->> 'stock_uom'));
      end if;
    end if;
    if v_item.id is null then
      if coalesce(btrim(r.raw ->> 'name'), '') = '' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'a new item needs a name');
      end if;
      if coalesce(r.raw ->> 'stock_uom', '') = '' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'a new item needs its stock unit');
      end if;
    else
      v_find := v_find || jsonb_build_object('severity', 'info', 'message',
        format('%s exists: it gains what it lacks and keeps everything it has', v_code));
      if v_stock is not null and v_stock <> v_item.stock_uom_id then
        v_find := v_find || jsonb_build_object('severity', 'warning', 'message',
          format('the file stocks %s in %s; it stays in its own unit', v_code, r.raw ->> 'stock_uom'));
      end if;
    end if;
    if coalesce(r.raw ->> 'purchase_uom', '') <> '' then
      select u.id into v_buy from erp.uom u
       where u.tenant_id = v_tenant and upper(u.code) = upper(btrim(r.raw ->> 'purchase_uom')) and u.status = 'active';
      if v_buy is null then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a unit of measure here', r.raw ->> 'purchase_uom'));
      elsif not erp.uom_converts(v_tenant, v_item.id, v_buy, coalesce(v_item.stock_uom_id, v_stock)) then
        v_find := v_find || jsonb_build_object('severity', 'warning', 'message',
          format('%s does not convert to the stock unit, so the purchase unit is left unset; add the conversion and set it on the item',
                 r.raw ->> 'purchase_uom'));
      end if;
    end if;

    -- Tracking.
    if coalesce((r.raw ->> 'has_expiry')::boolean, false)
       and not coalesce((r.raw ->> 'is_batch_controlled')::boolean, v_item.is_batch_controlled, false) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'expiry needs batch control: an expiry date belongs to a batch');
    end if;
    if v_stocked and (
         (coalesce((r.raw ->> 'is_batch_controlled')::boolean, false) and not v_item.is_batch_controlled)
      or (coalesce((r.raw ->> 'is_serial_controlled')::boolean, false) and not v_item.is_serial_controlled)
      or (coalesce((r.raw ->> 'has_expiry')::boolean, false) and not v_item.has_expiry)) then
      v_find := v_find || jsonb_build_object('severity', 'warning', 'message',
        format('%s holds stock, so its tracking stays as it is', v_code));
    end if;

    -- Barcode.
    if coalesce(btrim(r.raw ->> 'barcode'), '') <> '' then
      select i.code into v_other from erp.item_barcode bc join erp.item i on i.id = bc.item_id
       where bc.tenant_id = v_tenant and bc.barcode = btrim(r.raw ->> 'barcode')
         and i.id is distinct from v_item.id;
      if v_other is not null then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('barcode %s already belongs to %s', btrim(r.raw ->> 'barcode'), v_other));
      end if;
      if exists (select 1 from jsonb_array_elements(coalesce(
                   (select jsonb_agg(x.raw -> 'barcode') from erp.import_row x
                     where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.row_no < r.row_no), '[]')) e
                  where e #>> '{}' = btrim(r.raw ->> 'barcode')) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('barcode %s is on an earlier row', btrim(r.raw ->> 'barcode')));
      end if;
    end if;

    if r.raw ? 'gross_weight_g' and coalesce(r.raw ->> 'gross_weight_g', '') !~ '^[0-9]+(\.[0-9]+)?$' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'gross_weight_g is a weight in grams, zero or more');
    end if;

    -- Prices.
    for p in select * from (values ('purchase_price'), ('sales_price')) v(field) loop
      continue when not (r.raw ? p.field);
      if jsonb_typeof(r.raw -> p.field) <> 'object'
         or coalesce(r.raw -> p.field ->> 'amount_minor', '') !~ '^[0-9]+$' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is an amount in whole minor units of zero or more', p.field));
      elsif coalesce(r.raw -> p.field ->> 'currency', '') <> ''
            and not exists (select 1 from erp_ref.currency c where c.code = upper(r.raw -> p.field ->> 'currency')) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a currency the product lists', r.raw -> p.field ->> 'currency'));
      end if;
    end loop;
    if r.raw ? 'purchase_price' or r.raw ? 'sales_price' then
      v_find := v_find || jsonb_build_object('severity', 'info', 'message',
        'prices are loaded only by somebody who may set prices (sales.price)');
    end if;

    -- The supplier.
    if r.raw ? 'supplier' then
      if jsonb_typeof(r.raw -> 'supplier') <> 'object' or coalesce(btrim(r.raw -> 'supplier' ->> 'party'), '') = '' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'supplier names a party code');
      elsif not exists (select 1 from erp.party pt join erp.party_role pr on pr.tenant_id = pt.tenant_id and pr.party_id = pt.id
                         where pt.tenant_id = v_tenant and pt.code = btrim(r.raw -> 'supplier' ->> 'party')
                           and pr.role_kind = 'supplier') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a supplier here; load the suppliers first', r.raw -> 'supplier' ->> 'party'));
      end if;
      if coalesce(r.raw -> 'supplier' ->> 'min_order_quantity', '0') !~ '^[0-9]+(\.[0-9]+)?$' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'the supplier''s minimum order is a quantity');
      end if;
    end if;

    -- Reorder levels per site.
    if r.raw ? 'sites' then
      if jsonb_typeof(r.raw -> 'sites') <> 'array' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'sites is a list');
      else
        for s in select e from jsonb_array_elements(r.raw -> 'sites') e loop
          if not exists (select 1 from erp.site st where st.tenant_id = v_tenant and upper(st.code) = upper(btrim(coalesce(s ->> 'site', '')))) then
            v_find := v_find || jsonb_build_object('severity', 'error', 'message',
              format('%s is not a site here', coalesce(s ->> 'site', 'nothing')));
          elsif exists (select 1 from jsonb_each_text(s - 'site') kv where kv.value !~ '^[0-9]+(\.[0-9]+)?$'
                          or kv.key not in ('reorder_point', 'order_up_to', 'min_order_quantity')) then
            v_find := v_find || jsonb_build_object('severity', 'error', 'message',
              format('the levels at %s are reorder_point, order_up_to and min_order_quantity, each zero or more', s ->> 'site'));
          end if;
        end loop;
      end if;
    end if;

    update erp.import_row
       set findings = v_find, target_id = null,
           action = case when exists (select 1 from jsonb_array_elements(v_find) f where f ->> 'severity' = 'error') then 'reject'
                         when v_item.id is not null then 'update' else 'insert' end,
           updated_at = now()
     where id = r.id;
    if exists (select 1 from jsonb_array_elements(v_find) f where f ->> 'severity' = 'error') then
      v_errors := v_errors + 1;
    end if;
  end loop;

  update erp.import_batch set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;
  return v_errors;
end;
$$;

revoke all on function erp.validate_item_profile_import(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Load
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.load_item_profile_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  b         erp.import_batch%rowtype;
  r         record;
  v_ccy     char(3);
  v_item    erp.item%rowtype;
  v_created boolean;
  v_id      uuid;
  v_uom     uuid;
  v_buy     uuid;
  v_values  jsonb;
  v_ref     jsonb;
  v_prices  uuid[];
  v_sites   uuid[];
  v_batch   boolean;
  v_expiry  boolean;
  v_serial  boolean;
  v_policy  text;
  v_n       integer := 0;
  p         record;
  s         jsonb;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('master_data.write', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'previewed' then
    raise exception 'CLOVEERP_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after somebody has looked at it', b.code, b.status
      using errcode = '23514', hint = 'Validate, preview, then load.';
  end if;
  if b.error_count > 0 then
    raise exception 'CLOVEERP_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather than loading the good half', b.error_count, b.code
      using errcode = '23514', hint = 'The findings on each row say what is wrong.';
  end if;
  -- No desk door writes an item price; the import holds the gate a price needs.
  if exists (select 1 from erp.import_row x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id
               and (x.raw ? 'purchase_price' or x.raw ? 'sales_price')) then
    perform erp.authorise('sales.price', null, null, null, 'import_batch', p_batch_id);
  end if;

  select e.base_currency into v_ccy from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x
            where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.action in ('insert', 'update')
            order by x.row_no loop
    v_prices := '{}'; v_sites := '{}';
    v_ref := '{}'::jsonb;

    select * into v_item from erp.item i where i.tenant_id = v_tenant and i.code = btrim(r.raw ->> 'code');
    v_created := v_item.id is null;
    v_values := jsonb_strip_nulls(jsonb_build_object(
      'description', nullif(btrim(r.raw ->> 'description'), ''),
      'item_group', nullif(btrim(r.raw ->> 'item_group'), '')));

    if v_created then
      select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant and upper(u.code) = upper(btrim(r.raw ->> 'stock_uom'));
      v_id := erp.create_item(btrim(r.raw ->> 'code'), btrim(r.raw ->> 'name'), v_uom, null, v_values);
      -- Imported records are activated together once reviewed.
      update erp.item i set status = 'draft', lifecycle = coalesce((r.raw ->> 'lifecycle')::erp.item_lifecycle, 'draft'), updated_at = now()
       where i.id = v_id;
      select * into v_item from erp.item i where i.id = v_id;
    else
      select jsonb_strip_nulls(jsonb_build_object(
               'description', case when i.description is null then v_values ->> 'description' end,
               'item_group', case when i.item_group is null then v_values ->> 'item_group' end))
        into v_values from erp.item i where i.id = v_item.id;
      if v_values <> '{}'::jsonb then
        perform erp.write_master_fields('item', v_item.id, v_values);
      end if;
    end if;

    -- Tracking, only turned on, and only while the item holds no stock.
    if not exists (select 1 from erp.stock_balance sb where sb.tenant_id = v_tenant and sb.item_id = v_item.id and sb.quantity <> 0) then
      v_batch  := case when coalesce((r.raw ->> 'is_batch_controlled')::boolean, false) and not v_item.is_batch_controlled then true end;
      v_expiry := case when coalesce((r.raw ->> 'has_expiry')::boolean, false) and not v_item.has_expiry then true end;
      v_serial := case when coalesce((r.raw ->> 'is_serial_controlled')::boolean, false) and not v_item.is_serial_controlled then true end;
      if v_batch or v_expiry or v_serial then
        perform erp.set_item_controls(v_item.id, v_batch, v_expiry, null, null, null, v_serial);
        v_ref := v_ref || jsonb_build_object('controls', jsonb_strip_nulls(jsonb_build_object(
                   'batch', v_batch, 'expiry', v_expiry, 'serial', v_serial)));
      end if;
    end if;

    if coalesce(r.raw ->> 'purchase_uom', '') <> '' and v_item.purchase_uom_id is null then
      select u.id into v_buy from erp.uom u where u.tenant_id = v_tenant and upper(u.code) = upper(btrim(r.raw ->> 'purchase_uom'));
      if v_buy is not null and erp.uom_converts(v_tenant, v_item.id, v_buy, v_item.stock_uom_id) then
        update erp.item i set purchase_uom_id = v_buy, updated_at = now() where i.id = v_item.id;
        v_ref := v_ref || jsonb_build_object('purchase_uom', true);
      end if;
    end if;

    if r.raw ? 'gross_weight_g' and v_item.gross_weight_g is null then
      update erp.item i set gross_weight_g = (r.raw ->> 'gross_weight_g')::numeric, updated_at = now() where i.id = v_item.id;
      v_ref := v_ref || jsonb_build_object('weight', true);
    end if;

    if coalesce(btrim(r.raw ->> 'barcode'), '') <> ''
       and not exists (select 1 from erp.item_barcode bc where bc.tenant_id = v_tenant and bc.item_id = v_item.id and bc.is_primary)
       and not exists (select 1 from erp.item_barcode bc where bc.tenant_id = v_tenant and bc.barcode = btrim(r.raw ->> 'barcode')) then
      insert into erp.item_barcode (tenant_id, item_id, barcode, barcode_kind, is_primary)
      values (v_tenant, v_item.id, btrim(r.raw ->> 'barcode'),
              case length(btrim(r.raw ->> 'barcode')) when 8 then 'ean8' when 12 then 'upca' else 'ean13' end, true)
      returning id into v_id;
      v_ref := v_ref || jsonb_build_object('barcode', v_id);
    end if;

    for p in select * from (values ('purchase_price', 'purchase_list'), ('sales_price', 'sales_list')) v(field, kind) loop
      continue when not (r.raw ? p.field)
        or exists (select 1 from erp.item_price ip
                    where ip.tenant_id = v_tenant and ip.item_id = v_item.id and ip.price_kind::text = p.kind
                      and ip.party_role_id is null and ip.site_id is null
                      and ip.valid_from <= current_date and (ip.valid_to is null or ip.valid_to > current_date));
      insert into erp.item_price (tenant_id, item_id, price_kind, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from)
      values (v_tenant, v_item.id, p.kind::erp.price_kind,
              coalesce(nullif(upper(r.raw -> p.field ->> 'currency'), ''), v_ccy),
              (r.raw -> p.field ->> 'amount_minor')::bigint, 1, v_item.stock_uom_id, 0, current_date)
      returning id into v_id;
      v_prices := v_prices || v_id;
    end loop;

    if r.raw ? 'supplier'
       and not exists (select 1 from erp.item_supplier isup where isup.tenant_id = v_tenant and isup.item_id = v_item.id and isup.is_default) then
      insert into erp.item_supplier (tenant_id, item_id, party_id, preference_rank, is_default, supplier_item_code, min_order_quantity)
      select v_tenant, v_item.id, pt.id, 1, true,
             nullif(btrim(r.raw -> 'supplier' ->> 'supplier_item_code'), ''),
             nullif(r.raw -> 'supplier' ->> 'min_order_quantity', '')::numeric
        from erp.party pt where pt.tenant_id = v_tenant and pt.code = btrim(r.raw -> 'supplier' ->> 'party')
      returning id into v_id;
      v_ref := v_ref || jsonb_build_object('supplier', v_id);
    end if;

    for s in select e from jsonb_array_elements(coalesce(r.raw -> 'sites', '[]'::jsonb)) e loop
      continue when exists (select 1 from erp.item_site x join erp.site st on st.id = x.site_id
                             where x.tenant_id = v_tenant and x.item_id = v_item.id and upper(st.code) = upper(btrim(s ->> 'site')));
      -- The organisation's own policy of the kind the levels describe.
      select pp.code into v_policy from erp.planning_policy pp
       where pp.tenant_id = v_tenant and pp.status = 'active'
         and pp.reorder_method::text in ('min_max', 'reorder_point', 'order_up_to')
       order by (pp.reorder_method::text = case when s ? 'order_up_to' then 'min_max' else 'reorder_point' end) desc, pp.code
       limit 1;
      insert into erp.item_site (tenant_id, item_id, site_id, planning_policy_code, reorder_point, order_up_to, min_order_quantity)
      select v_tenant, v_item.id, st.id, v_policy,
             (s ->> 'reorder_point')::numeric, (s ->> 'order_up_to')::numeric, (s ->> 'min_order_quantity')::numeric
        from erp.site st where st.tenant_id = v_tenant and upper(st.code) = upper(btrim(s ->> 'site'))
      returning id into v_id;
      v_sites := v_sites || v_id;
    end loop;

    update erp.import_row
       set target_id = v_item.id, loaded = true, before_snapshot = null,
           loaded_ref = v_ref || jsonb_build_object('item_id', v_item.id, 'created', v_created,
                                                    'prices', to_jsonb(v_prices), 'sites', to_jsonb(v_sites)),
           updated_at = now()
     where id = r.id;
    v_n := v_n + 1;
  end loop;

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), loaded_by = erp.current_principal_id(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.load_item_profile_import(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Roll back: exactly what was added, and only while nothing else has joined it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.rollback_item_profile_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_item   uuid;
  v_ids    uuid[];
  v_n      integer := 0;
  v_in_use text;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('master_data.write', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'CLOVEERP_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514', hint = 'Only a loaded batch is rolled back.';
  end if;

  -- An item this batch made or re-tracked may hold no stock and have moved
  -- none; one it made may carry nothing the batch did not give it.
  select string_agg(distinct i.code, ', ') into v_in_use
    from erp.import_row x
    join erp.item i on i.tenant_id = x.tenant_id and i.id = (x.loaded_ref ->> 'item_id')::uuid
   where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded
     and (
       (((x.loaded_ref ->> 'created')::boolean or x.loaded_ref ? 'controls') and (
          exists (select 1 from erp.stock_balance sb where sb.tenant_id = v_tenant and sb.item_id = i.id and sb.quantity <> 0)
          or exists (select 1 from erp.stock_movement sm where sm.tenant_id = v_tenant and sm.item_id = i.id)))
       or ((x.loaded_ref ->> 'created')::boolean and (
          exists (select 1 from erp.item_barcode bc where bc.tenant_id = v_tenant and bc.item_id = i.id
                   and bc.id is distinct from (x.loaded_ref ->> 'barcode')::uuid)
          or exists (select 1 from erp.item_price ip where ip.tenant_id = v_tenant and ip.item_id = i.id
                   and not (to_jsonb(ip.id::text) <@ (x.loaded_ref -> 'prices')))
          or exists (select 1 from erp.item_supplier isup where isup.tenant_id = v_tenant and isup.item_id = i.id
                   and isup.id is distinct from (x.loaded_ref ->> 'supplier')::uuid)
          or exists (select 1 from erp.item_site st where st.tenant_id = v_tenant and st.item_id = i.id
                   and not (to_jsonb(st.id::text) <@ (x.loaded_ref -> 'sites'))))));
  if v_in_use is not null then
    raise exception 'CLOVEERP_ITEM_IMPORT_IN_USE: % hold stock or carry records added since the batch loaded, so the batch stands', v_in_use
      using errcode = '23503',
            hint = 'Correct the items on the desk; an item with stock or later records is not taken back by an import.';
  end if;

  begin
    for r in select * from erp.import_row x
              where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded
              order by x.row_no desc loop
      v_item := (r.loaded_ref ->> 'item_id')::uuid;

      select coalesce(array_agg(e::uuid), '{}') into v_ids from jsonb_array_elements_text(r.loaded_ref -> 'sites') e;
      delete from erp.item_site x where x.tenant_id = v_tenant and x.id = any (v_ids);
      select coalesce(array_agg(e::uuid), '{}') into v_ids from jsonb_array_elements_text(r.loaded_ref -> 'prices') e;
      delete from erp.item_price x where x.tenant_id = v_tenant and x.id = any (v_ids);
      delete from erp.item_supplier x where x.tenant_id = v_tenant and x.id = (r.loaded_ref ->> 'supplier')::uuid;
      delete from erp.item_barcode x where x.tenant_id = v_tenant and x.id = (r.loaded_ref ->> 'barcode')::uuid;

      if (r.loaded_ref ->> 'created')::boolean then
        delete from erp.item i where i.tenant_id = v_tenant and i.id = v_item;
      else
        if r.loaded_ref ? 'controls' then
          perform erp.set_item_controls(v_item,
            case when r.loaded_ref -> 'controls' ? 'batch' then false end,
            case when r.loaded_ref -> 'controls' ? 'expiry' then false end,
            null, null, null,
            case when r.loaded_ref -> 'controls' ? 'serial' then false end);
        end if;
        update erp.item i
           set purchase_uom_id = case when r.loaded_ref ? 'purchase_uom' then null else i.purchase_uom_id end,
               gross_weight_g = case when r.loaded_ref ? 'weight' then null else i.gross_weight_g end,
               updated_at = now()
         where i.tenant_id = v_tenant and i.id = v_item and (r.loaded_ref ? 'purchase_uom' or r.loaded_ref ? 'weight');
      end if;
      v_n := v_n + 1;
    end loop;
  exception when foreign_key_violation then
    raise exception 'CLOVEERP_ITEM_IMPORT_IN_USE: an item % loaded is already on a document, so the batch stands', b.code
      using errcode = '23503',
            hint = 'Correct the item on the desk; an item with history is not removed.';
  end;

  update erp.import_row set loaded = false, target_id = null, updated_at = now()
   where tenant_id = v_tenant and import_batch_id = p_batch_id;
  update erp.import_batch set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.rollback_item_profile_import(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.item_profile_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  ra       record;
  v_new    text := 'ZZIN' || upper(v_tag);
  v_uom    text;
  v_box    text := 'ZB' || upper(substr(v_tag, 1, 4));
  v_site   text;
  v_sup    text;
  v_old    erp.item%rowtype;
  v_stocked erp.item%rowtype;
  v_before jsonb;
  v_good   uuid; v_bad uuid; v_b uuid;
  v_n      integer;
  v_err    text;
  v_i      erp.item%rowtype;
  v_ean    text := '50' || lpad((abs(hashtext(v_tag)) % 100000000000)::text, 11, '0');
begin
  begin
    v_step := 'an organisation with its demonstration configuration';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant(
      'ipa-' || v_tag, 'Item Profile Suite', 'a@ip-' || v_tag || '.test', 'A Admin');
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'a@ip-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.ensure_demo_configuration(ra.tenant_id, ra.admin_user_id);

    select u.code into v_uom from erp.uom u
     where u.tenant_id = ra.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active' order by u.code limit 1;
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base)
    values (ra.tenant_id, v_box, 'Box', 'quantity', 0, false);
    select s.code into v_site from erp.site s where s.tenant_id = ra.tenant_id order by s.code limit 1;
    select p.code into v_sup from erp.party p join erp.party_role pr on pr.party_id = p.id
     where p.tenant_id = ra.tenant_id and pr.role_kind = 'supplier' order by p.code limit 1;
    -- An item that exists with nothing extra, and one that holds stock.
    select * into v_old from erp.item i
     where i.tenant_id = ra.tenant_id and not i.is_batch_controlled and i.purchase_uom_id is null
       and not exists (select 1 from erp.stock_balance sb where sb.item_id = i.id and sb.quantity <> 0)
       and not exists (select 1 from erp.stock_movement sm where sm.item_id = i.id)
       and not exists (select 1 from erp.item_barcode bc where bc.item_id = i.id and bc.is_primary)
     order by i.code limit 1;
    if v_old.id is null then
      perform erp.create_item('ZZIO' || upper(v_tag), 'Plain Item', (select u.id from erp.uom u where u.tenant_id = ra.tenant_id and u.code = v_uom));
      select * into v_old from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZIO' || upper(v_tag);
    end if;
    select * into v_stocked from erp.item i
     where i.tenant_id = ra.tenant_id and not i.is_batch_controlled
       and exists (select 1 from erp.stock_balance sb where sb.item_id = i.id and sb.quantity <> 0)
     order by i.code limit 1;
    select jsonb_build_object(
             'item', (select to_jsonb(i) - 'updated_at' - 'updated_by' from erp.item i where i.id = v_old.id),
             'barcodes', (select count(*) from erp.item_barcode x where x.item_id = v_old.id),
             'prices', (select coalesce(jsonb_agg(x.id order by x.id), '[]') from erp.item_price x where x.item_id = v_old.id),
             'suppliers', (select coalesce(jsonb_agg(x.id order by x.id), '[]') from erp.item_supplier x where x.item_id = v_old.id),
             'sites', (select coalesce(jsonb_agg(x.id order by x.id), '[]') from erp.item_site x where x.item_id = v_old.id))
      into v_before;

    -- 1. A whole product validates clean; an existing one is an update, and a
    --    purchase unit that does not convert is said, not refused.
    v_step := 'staging a good batch';
    v_good := erp.stage_import('item_profile', jsonb_build_array(
      jsonb_build_object('source', 'unleashed', 'code', v_new, 'name', 'New Fixing', 'description', 'M6 fixings',
        'item_group', 'Fixings', 'stock_uom', v_uom, 'purchase_uom', v_box,
        'is_batch_controlled', true, 'has_expiry', true, 'barcode', v_ean, 'gross_weight_g', '4.5',
        'purchase_price', jsonb_build_object('amount_minor', 4), 'sales_price', jsonb_build_object('amount_minor', 9),
        'supplier', jsonb_build_object('party', v_sup, 'min_order_quantity', '1000'),
        'sites', jsonb_build_array(jsonb_build_object('site', v_site, 'reorder_point', '5000', 'order_up_to', '50000'))),
      jsonb_build_object('source', 'unleashed', 'code', v_old.code, 'name', 'Renamed In File', 'stock_uom', v_uom,
        'is_batch_controlled', true, 'gross_weight_g', '100',
        'sites', jsonb_build_array(jsonb_build_object('site', v_site, 'reorder_point', '1'))),
      jsonb_build_object('source', 'unleashed', 'code', coalesce(v_stocked.code, 'ZZIS' || upper(v_tag)),
        'name', 'Stand-in', 'stock_uom', v_uom, 'is_serial_controlled', true)),
      'IPG-' || v_tag, 'suite');
    v_n := erp.validate_import(v_good);
    v_cases := v_cases + 1;
    case_name := 'a whole product validates clean; one that exists is an update; one with stock keeps its tracking, and a purchase unit that does not convert is said';
    passed := v_n = 0
      and (select r.action from erp.import_row r where r.import_batch_id = v_good and r.row_no = 1) = 'insert'
      and (select r.action from erp.import_row r where r.import_batch_id = v_good and r.row_no = 2) = 'update'
      and exists (select 1 from erp.import_row r, jsonb_array_elements(r.findings) f
                   where r.import_batch_id = v_good and r.row_no = 1 and f ->> 'message' like '%does not convert%')
      -- Where the demonstration holds no stock, the third row is a new item instead.
      and (v_stocked.id is null or exists (select 1 from erp.import_row r, jsonb_array_elements(r.findings) f
                   where r.import_batch_id = v_good and r.row_no = 3 and f ->> 'message' like '%holds stock%'));
    detail := coalesce((select string_agg(r.row_no || ': ' || r.findings::text, '; ') from erp.import_row r where r.import_batch_id = v_good), 'no rows');
    return next;

    -- 2. Every wrong field is refused.
    v_step := 'validating a bad batch';
    v_bad := erp.stage_import('item_profile', jsonb_build_array(
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI1' || v_tag, 'name', 'I1', 'stock_uom', 'NOSUCH'),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI2' || v_tag, 'name', 'I2'),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI3' || v_tag, 'name', 'I3', 'stock_uom', v_uom, 'has_expiry', true),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI4' || v_tag, 'name', 'I4', 'stock_uom', v_uom, 'barcode', 'ZZBC' || v_tag),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI5' || v_tag, 'name', 'I5', 'stock_uom', v_uom,
                         'sales_price', jsonb_build_object('amount_minor', 4.3)),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI6' || v_tag, 'name', 'I6', 'stock_uom', v_uom,
                         'supplier', jsonb_build_object('party', 'NOSUCH-' || v_tag)),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI7' || v_tag, 'name', 'I7', 'stock_uom', v_uom,
                         'sites', jsonb_build_array(jsonb_build_object('site', 'NOSUCH'))),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI8' || v_tag, 'name', 'I8', 'stock_uom', v_uom, 'gross_weight_g', '-1'),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZI1' || v_tag, 'name', 'I1 again', 'stock_uom', v_uom),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZIX' || v_tag, 'name', 'I10', 'stock_uom', v_uom, 'barcode', 'ZZBC' || v_tag)),
      'IPB-' || v_tag, 'suite');
    v_n := erp.validate_import(v_bad);
    v_cases := v_cases + 1;
    case_name := 'an unknown unit, a new item with no unit, expiry without batches, a barcode an earlier row holds, a fractional price, an unknown supplier, an unknown site, a negative weight and a repeated code are each refused';
    passed := v_n = 9 and (select bool_and(r.action = 'reject') from erp.import_row r where r.import_batch_id = v_bad and r.row_no <> 4)
      and (select r.action from erp.import_row r where r.import_batch_id = v_bad and r.row_no = 4) = 'insert';
    detail := coalesce((select string_agg(r.row_no || ': ' || coalesce((select string_agg(f ->> 'message', ' / ') from jsonb_array_elements(r.findings) f where f ->> 'severity' = 'error'), 'none'), '; ' order by r.row_no)
                          from erp.import_row r where r.import_batch_id = v_bad), 'no rows');
    return next;

    -- 3. Loaded, the new item is whole and a draft.
    v_step := 'loading the good batch';
    perform erp.preview_import(v_good);
    v_n := erp.load_import(v_good);
    select * into v_i from erp.item i where i.tenant_id = ra.tenant_id and i.code = v_new;
    v_cases := v_cases + 1;
    case_name := 'a new item arrives whole, as a draft: its unit, tracking, barcode, weight, both prices, supplier and reorder levels';
    passed := v_n = 3 and v_i.status::text = 'draft' and v_i.lifecycle::text = 'draft'
      and v_i.is_batch_controlled and v_i.has_expiry and v_i.gross_weight_g = 4.5 and v_i.purchase_uom_id is null
      and v_i.stock_uom_id = (select u.id from erp.uom u where u.tenant_id = ra.tenant_id and u.code = v_uom)
      and v_i.description = 'M6 fixings' and v_i.item_group = 'Fixings'
      and exists (select 1 from erp.item_barcode x where x.item_id = v_i.id and x.barcode = v_ean and x.is_primary)
      and exists (select 1 from erp.item_price x where x.item_id = v_i.id and x.price_kind = 'purchase_list' and x.amount_minor = 4 and x.per_quantity = 1)
      and exists (select 1 from erp.item_price x where x.item_id = v_i.id and x.price_kind = 'sales_list' and x.amount_minor = 9)
      and exists (select 1 from erp.item_supplier x join erp.party p on p.id = x.party_id
                   where x.item_id = v_i.id and p.code = v_sup and x.is_default and x.min_order_quantity = 1000)
      and exists (select 1 from erp.item_site x where x.item_id = v_i.id and x.reorder_point = 5000 and x.order_up_to = 50000);
    detail := format('%s row(s); item %s', v_n, coalesce(v_i.status::text, 'missing'));
    return next;

    -- 4. The existing item gains and keeps; the stocked one keeps its tracking.
    v_cases := v_cases + 1;
    case_name := 'an item that exists gains batch control, a weight and a site policy and keeps its name and unit; one with stock keeps its tracking';
    passed := (select i.name from erp.item i where i.id = v_old.id) = v_old.name
      and (select i.stock_uom_id from erp.item i where i.id = v_old.id) = v_old.stock_uom_id
      and (select i.is_batch_controlled from erp.item i where i.id = v_old.id)
      and (select i.gross_weight_g from erp.item i where i.id = v_old.id) is not distinct from coalesce(v_old.gross_weight_g, 100)
      and exists (select 1 from erp.item_site x join erp.site s on s.id = x.site_id where x.item_id = v_old.id and s.code = v_site)
      and (v_stocked.id is null or not (select i.is_serial_controlled from erp.item i where i.id = v_stocked.id));
    detail := coalesce(v_old.code, 'no plain item') || ' / ' || coalesce(v_stocked.code, 'no stocked item');
    return next;

    -- 5. Prices need the permission that sets prices.
    v_step := 'loading a price without sales.price';
    v_b := erp.stage_import('item_profile', jsonb_build_array(
      jsonb_build_object('source', 'unleashed', 'code', 'ZZIP' || upper(v_tag), 'name', 'Priced', 'stock_uom', v_uom,
                         'sales_price', jsonb_build_object('amount_minor', 100))),
      'IPP-' || v_tag, 'suite');
    perform erp.validate_import(v_b);
    perform erp.preview_import(v_b);
    delete from erp.role_permission rp where rp.tenant_id = ra.tenant_id and rp.role_id = ra.role_id and rp.permission_code = 'sales.price';
    v_err := null;
    begin
      perform erp.load_import(v_b);
    exception when others then v_err := left(sqlerrm, 200); end;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (ra.tenant_id, ra.role_id, 'sales.price') on conflict do nothing;
    v_cases := v_cases + 1;
    case_name := 'a price is refused to somebody who may not set prices';
    passed := v_err like 'CLOVEERP_PERMISSION_DENIED:%sales.price%'
      and not exists (select 1 from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZIP' || upper(v_tag));
    detail := coalesce(v_err, 'it loaded');
    return next;

    -- 6. Loading needs master_data.write as well as the import permission.
    v_step := 'loading without master_data.write';
    delete from erp.role_permission rp where rp.tenant_id = ra.tenant_id and rp.role_id = ra.role_id and rp.permission_code = 'master_data.write';
    v_err := null;
    begin
      perform erp.load_import(v_b);
    exception when others then v_err := left(sqlerrm, 200); end;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (ra.tenant_id, ra.role_id, 'master_data.write') on conflict do nothing;
    v_cases := v_cases + 1;
    case_name := 'loading products needs master_data.write';
    passed := v_err like 'CLOVEERP_PERMISSION_DENIED:%master_data.write%';
    detail := coalesce(v_err, 'it loaded');
    return next;

    -- 7. Something added to an imported item since keeps the batch standing.
    v_step := 'adding a barcode to the imported item';
    insert into erp.item_barcode (tenant_id, item_id, barcode, is_primary)
    values (ra.tenant_id, v_i.id, 'ZZ' || v_tag, false);
    v_err := null;
    begin
      perform erp.rollback_import(v_good);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a batch whose item has gained a record since it loaded cannot be rolled back';
    passed := v_err like 'CLOVEERP_ITEM_IMPORT_IN_USE:%'
      and (select b.status::text from erp.import_batch b where b.id = v_good) = 'loaded';
    detail := coalesce(v_err, 'it rolled back');
    return next;

    -- 8. With that removed, rollback takes exactly what was added.
    v_step := 'rolling back';
    delete from erp.item_barcode x where x.item_id = v_i.id and x.barcode = 'ZZ' || v_tag;
    perform erp.rollback_import(v_good);
    v_cases := v_cases + 1;
    case_name := 'rolling back removes the new item and everything added to the old one, and leaves the old one as it was';
    passed := not exists (select 1 from erp.item i where i.tenant_id = ra.tenant_id and i.code = v_new)
      and jsonb_build_object(
             'item', (select to_jsonb(i) - 'updated_at' - 'updated_by' from erp.item i where i.id = v_old.id),
             'barcodes', (select count(*) from erp.item_barcode x where x.item_id = v_old.id),
             'prices', (select coalesce(jsonb_agg(x.id order by x.id), '[]') from erp.item_price x where x.item_id = v_old.id),
             'suppliers', (select coalesce(jsonb_agg(x.id order by x.id), '[]') from erp.item_supplier x where x.item_id = v_old.id),
             'sites', (select coalesce(jsonb_agg(x.id order by x.id), '[]') from erp.item_site x where x.item_id = v_old.id)) = v_before;
    detail := format('batch is %s', (select b.status::text from erp.import_batch b where b.id = v_good));
    return next;

    -- 9. A purchase unit that converts is set.
    v_step := 'a purchase unit with its conversion';
    insert into erp.uom_conversion (tenant_id, from_uom_id, to_uom_id, factor)
    select ra.tenant_id, bx.id, ea.id, 100
      from erp.uom bx, erp.uom ea
     where bx.tenant_id = ra.tenant_id and bx.code = v_box and ea.tenant_id = ra.tenant_id and ea.code = v_uom;
    v_b := erp.stage_import('item_profile', jsonb_build_array(
      jsonb_build_object('source', 'unleashed', 'code', 'ZZIB' || upper(v_tag), 'name', 'Boxed', 'stock_uom', v_uom, 'purchase_uom', v_box)),
      'IPU-' || v_tag, 'suite');
    perform erp.validate_import(v_b);
    perform erp.preview_import(v_b);
    perform erp.load_import(v_b);
    v_cases := v_cases + 1;
    case_name := 'a purchase unit that converts to the stock unit is set on the item';
    passed := (select i.purchase_uom_id from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZIB' || upper(v_tag))
              = (select u.id from erp.uom u where u.tenant_id = ra.tenant_id and u.code = v_box);
    detail := 'purchase unit ' || coalesce((select u.code from erp.item i join erp.uom u on u.id = i.purchase_uom_id
                                              where i.tenant_id = ra.tenant_id and i.code = 'ZZIB' || upper(v_tag)), 'unset');
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
    raise exception 'CLOVEERP_ITEM_PROFILE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'ipa-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_ITEM_PROFILE_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.item_profile_suite() from public, anon, authenticated;

create or replace function erp_test.assert_item_profile_suite()
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
    from erp_test.item_profile_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ITEM_PROFILE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An import would change an item it should only add to, set a price the importer may not, or roll back somebody''s later work. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_ITEM_PROFILE_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('item profile: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_item_profile_suite() from public, anon;

comment on function erp_test.assert_item_profile_suite() is
  'A product arrives whole, an item that exists only gains, and rollback takes exactly what was added (20261003800000).';

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
