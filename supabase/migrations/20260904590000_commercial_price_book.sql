-- =============================================================================
-- Part 17 §17.5 and §17.6: the commercial control plane, and the price book
--
-- Specification v1.5 adds the half of Part 17 that describes the platform's own
-- commercial process. §17.5 fixes the design principle for all of it:
--
--   "the platform runs its own commercial process on its own primitives. Price
--   books are configuration objects. Quotes and contracts are documents on the
--   document spine with their own state machines. Discount approval uses the
--   approval engine in §7.16. Order forms and invoices render through the
--   output subsystem in Part 14. ... running the commercial process on the
--   product is the most honest test of whether the product works."
--
-- Which means the platform owner needs an organisation of its own — one tenant
-- on the deployment that IS the platform, where its price items are products,
-- its quotes are quotations, its approvals are approval chains and its order
-- forms are output templates. erp_meta.platform_organisation names it. What the
-- control plane holds in erp_meta is only what belongs to the platform and to
-- no organisation: which organisation is the platform's, and (in the next
-- migrations) the contracts and what they provision.
--
-- §17.6, in the platform organisation:
--
--   price_book  — a configuration object (erp_ref.config_type
--                 commercial.price_book), versioned and effective-dated through
--                 the configuration engine like every other policy, so a quote
--                 can name the version in force when it was raised
--   price_item  — an item of the platform organisation with a commercial
--                 shape: which plan tier, capability, band, environment, support
--                 tier, service or legislation pack it sells. Expressed against
--                 the objects the product already has (erp_meta.plan,
--                 erp_ref.capability, erp_meta.entitlement_kind,
--                 erp_ref.support_severity, erp_ref.legislation_pack)
--   rate_card   — erp.item_price rows, one per currency per term, "each
--                 maintained rather than converted at quote time"
--   cost_model  — the internal cost per price item, split as §17.6 says:
--                 infrastructure, support load, third-party pass-through
--
-- And one price the register refuses to let anybody set: "legislation packs,
-- priced at nil by default — because charging annually for a jurisdiction is
-- the practice this product exists to end, and the price book should make that
-- visible rather than tacit." A legislation pack price item is on the book, at
-- zero, and erp.set_rate() refuses any other figure.
-- =============================================================================

-- ── The module ───────────────────────────────────────────────────────────────

insert into erp_ref.module (code, name_key, sort_order) values ('commercial', 'module.commercial', 120)
on conflict (code) do nothing;

-- ── §17.5 the platform's own organisation ────────────────────────────────────

create table if not exists erp_meta.platform_organisation (
  -- No foreign key to erp.tenant, for the reason every erp_meta commercial
  -- table gives: the platform's record must not cascade away with a tenant row.
  tenant_id      uuid primary key,
  tenant_code    text not null,
  designated_at  timestamptz not null default now(),
  designated_by  text not null,
  reason         text
);

-- One platform, one organisation. A deployment with two "platform
-- organisations" would have two price books that both claim to be the list.
create unique index if not exists platform_organisation_is_singular
  on erp_meta.platform_organisation ((true));

comment on table erp_meta.platform_organisation is
  'Specification v1.5 §17.5: the one organisation on this deployment that is '
  'the platform itself. Its products are price items, its quotations are '
  'commercial quotes, its approval chains route discounts and its output '
  'templates render order forms. Designated by a platform owner and recorded '
  'in the platform log.';

create or replace function erp.is_platform_organisation(p_tenant_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from erp_meta.platform_organisation po
                  where po.tenant_id = coalesce(p_tenant_id, erp.current_tenant_id()))
$$;

comment on function erp.is_platform_organisation is
  'Whether the organisation in context is the platform''s own. Security definer '
  'because erp_meta is platform-internal; answers one boolean about the caller''s '
  'own organisation and nothing about any other.';

create or replace function erp.require_platform_organisation()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not erp.is_platform_organisation(erp.require_tenant_id()) then
    raise exception
      'ERPWARE_NOT_THE_PLATFORM_ORGANISATION: the commercial control plane belongs to the platform''s own organisation'
      using errcode = '42501',
            hint = 'A platform owner designates which organisation is the platform''s from the console. '
                   'Every other organisation sees its own agreement under Plan and usage.';
  end if;
end;
$$;

create or replace function erp.designate_platform_organisation(p_tenant_code text, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff  erp_meta.platform_staff;
  v_tenant erp.tenant%rowtype;
  v_prior  text;
begin
  v_staff := erp_meta.require_platform('owner');
  select * into v_tenant from erp.tenant t where t.code = p_tenant_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_TENANT: % is not an organisation on this deployment', p_tenant_code
      using errcode = '23503';
  end if;
  if v_tenant.status::text <> 'active' then
    raise exception 'ERPWARE_PLATFORM_ORGANISATION_NOT_ACTIVE: % is %, and the platform''s own organisation must be active',
      p_tenant_code, v_tenant.status using errcode = '23514';
  end if;

  select po.tenant_code into v_prior from erp_meta.platform_organisation po;
  if v_prior is not null and v_prior <> p_tenant_code and coalesce(btrim(p_reason), '') = '' then
    raise exception
      'ERPWARE_PLATFORM_ORGANISATION_ALREADY_DESIGNATED: % is the platform''s organisation; moving it to % states why',
      v_prior, p_tenant_code using errcode = '23514';
  end if;

  delete from erp_meta.platform_organisation;
  insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_by, reason)
  values (v_tenant.id, v_tenant.code, v_staff.email, nullif(btrim(p_reason), ''));

  perform erp_meta.platform_log(
    v_staff, 'platform.organisation_designated', v_tenant.id, p_tenant_code,
    coalesce(p_reason, 'designated as the platform''s own organisation'),
    jsonb_build_object('previous', v_prior));
  return v_tenant.id;
end;
$$;

comment on function erp.designate_platform_organisation is
  'Specification v1.5 §17.5: names the organisation that is the platform. '
  'Owner only, one at a time, and moving it states why; the platform log '
  'records every designation.';

-- ── §17.6 the price book as a configuration object ───────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema, max_scope_level, is_singleton, default_value, consequence)
values
  ('commercial.price_book', 'policy', 'commercial', 'config.commercial.price_book',
   'A price book: the list in force from a date, per currency. A quote references the version in force when it was raised, so a historical quote can always be explained. Rates are held per currency on the rate card rather than converted at quote time.',
   '{"type": "object", "required": ["name", "currencies"], "additionalProperties": false,
     "properties": {
       "name": {"type": "string", "minLength": 1},
       "currencies": {"type": "array", "minItems": 1, "items": {"type": "string", "pattern": "^[A-Z]{3}$"}},
       "note": {"type": "string"}}}'::jsonb,
   'tenant', false, null,
   'Opening a new version closes the previous one from its effective date. Quotes already raised keep the version they named; new quotes take the version in force.')
on conflict (code) do update set
  description = excluded.description, value_schema = excluded.value_schema,
  consequence = excluded.consequence, module_code = excluded.module_code;

-- ── §17.6 what can be sold ───────────────────────────────────────────────────

create table if not exists erp.price_item (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references erp.tenant (id) on delete cascade,
  item_id                uuid not null,
  kind                   text not null,
  plan_code              text,
  capability_code        text,
  entitlement_code       text,
  band_from              numeric,
  band_to                numeric,
  legislation_pack_code  text,
  support_severity_code  text,
  description            text,
  status                 text not null default 'active',
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  updated_by             uuid,
  constraint price_item_kind_known check (kind in
    ('plan_tier', 'capability_addon', 'user_band', 'company_band', 'site_band', 'volume_band',
     'storage_band', 'retention_band', 'environment', 'support_tier', 'service', 'legislation_pack')),
  constraint price_item_status_known check (status in ('active', 'inactive')),
  constraint price_item_band_ordered check (band_from is null or band_to is null or band_to >= band_from),
  constraint price_item_names_its_object check (
    (kind = 'plan_tier' and plan_code is not null)
    or (kind = 'capability_addon' and capability_code is not null)
    or (kind in ('user_band', 'company_band', 'site_band', 'volume_band', 'storage_band', 'retention_band', 'environment')
        and entitlement_code is not null and band_to is not null)
    or (kind = 'support_tier' and support_severity_code is not null)
    or (kind = 'legislation_pack' and legislation_pack_code is not null)
    or (kind = 'service')),
  constraint price_item_one_per_item unique (tenant_id, item_id),
  constraint price_item_tenant_id_key unique (tenant_id, id),
  constraint price_item_item_fk foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade
);

comment on table erp.price_item is
  'Specification v1.5 §17.6: what can be sold, "expressed against objects the '
  'product already has" — a plan tier, a capability, a band of an entitlement, '
  'an environment, a support tier, a fixed-price service, or a legislation pack '
  'at nil. The item it extends is an ordinary product of the platform '
  'organisation, so a quote line is an ordinary document line.';

create table if not exists erp.cost_model (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references erp.tenant (id) on delete cascade,
  item_id               uuid not null,
  currency              char(3) not null,
  infrastructure_minor  bigint not null default 0,
  support_minor         bigint not null default 0,
  pass_through_minor    bigint not null default 0,
  basis                 text,
  effective_from        date not null default current_date,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint cost_model_non_negative check (infrastructure_minor >= 0 and support_minor >= 0 and pass_through_minor >= 0),
  constraint cost_model_once unique (tenant_id, item_id, currency),
  constraint cost_model_tenant_id_key unique (tenant_id, id),
  constraint cost_model_item_fk foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade
);

comment on table erp.cost_model is
  'Specification v1.5 §17.6: "the internal cost per price item: infrastructure, '
  'support load, third-party pass-through. Held alongside price so margin is '
  'visible at the point of quoting, not discovered at year end." Per currency, '
  'like the rate card, so margin is a subtraction and never a conversion.';

-- ── The writers ──────────────────────────────────────────────────────────────

create or replace function erp.commercial_uom()
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_id uuid;
begin
  select u.id into v_id from erp.uom u where u.tenant_id = v_tenant and u.code = 'EA';
  if v_id is null then
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (v_tenant, 'EA', 'Each', 'quantity', 0, true, 'active')
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

create or replace function erp.upsert_price_item(
  p_code text, p_name text, p_kind text,
  p_plan_code text default null, p_capability_code text default null,
  p_entitlement_code text default null, p_band_from numeric default null, p_band_to numeric default null,
  p_legislation_pack_code text default null, p_support_severity_code text default null,
  p_description text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_item   uuid;
  v_id     uuid;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.price', null, null, null, 'price_item', null);

  -- Every kind names the product object it sells, and that object must exist.
  -- A price item for a plan the product does not offer is a line on an order
  -- form that provisions nothing.
  case p_kind
    when 'plan_tier' then
      if not exists (select 1 from erp_meta.plan p where p.code = p_plan_code) then
        raise exception 'ERPWARE_UNKNOWN_PLAN: % is not a plan the product offers', p_plan_code using errcode = '23503';
      end if;
    when 'capability_addon' then
      if not exists (select 1 from erp_ref.capability c where c.code = p_capability_code) then
        raise exception 'ERPWARE_UNKNOWN_CAPABILITY: % is not a capability this product has', p_capability_code using errcode = '23503';
      end if;
    when 'user_band', 'company_band', 'site_band', 'volume_band', 'storage_band', 'retention_band', 'environment' then
      if not exists (select 1 from erp_meta.entitlement_kind k where k.code = p_entitlement_code) then
        raise exception 'ERPWARE_UNKNOWN_ENTITLEMENT: % is not a registered entitlement kind', p_entitlement_code using errcode = '23503';
      end if;
      if p_band_to is null or p_band_to <= 0 then
        raise exception 'ERPWARE_BAND_HAS_NO_CEILING: a band states the quantity it entitles' using errcode = '23514';
      end if;
    when 'support_tier' then
      if not exists (select 1 from erp_ref.support_severity s where s.code = p_support_severity_code) then
        raise exception 'ERPWARE_UNKNOWN_SEVERITY: % is not a published severity', p_support_severity_code using errcode = '23503';
      end if;
    when 'legislation_pack' then
      if not exists (select 1 from erp_ref.legislation_pack l where l.code = p_legislation_pack_code) then
        raise exception 'ERPWARE_UNKNOWN_LEGISLATION_PACK: %', p_legislation_pack_code using errcode = '23503';
      end if;
    when 'service' then
      null;
    else
      raise exception 'ERPWARE_UNKNOWN_PRICE_ITEM_KIND: %', p_kind using errcode = '23514';
  end case;

  insert into erp.item (tenant_id, code, name, item_class, lifecycle, stock_uom_id, status)
  values (v_tenant, p_code, p_name, 'commercial', 'active', erp.commercial_uom(), 'active')
  on conflict (tenant_id, code) do update set name = excluded.name, updated_at = now()
  returning id into v_item;

  insert into erp.price_item
    (tenant_id, item_id, kind, plan_code, capability_code, entitlement_code, band_from, band_to,
     legislation_pack_code, support_severity_code, description)
  values (v_tenant, v_item, p_kind, p_plan_code, p_capability_code, p_entitlement_code, p_band_from, p_band_to,
          p_legislation_pack_code, p_support_severity_code, p_description)
  on conflict (tenant_id, item_id) do update set
    kind = excluded.kind, plan_code = excluded.plan_code, capability_code = excluded.capability_code,
    entitlement_code = excluded.entitlement_code, band_from = excluded.band_from, band_to = excluded.band_to,
    legislation_pack_code = excluded.legislation_pack_code, support_severity_code = excluded.support_severity_code,
    description = excluded.description, status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

comment on function erp.upsert_price_item is
  'Specification v1.5 §17.6: registers something the platform sells as a '
  'product of the platform organisation with its commercial shape. Security '
  'definer only to read erp_meta.plan and erp_meta.entitlement_kind, which are '
  'platform-internal; refuses any organisation that is not the platform''s.';

create or replace function erp.open_price_book(
  p_code text, p_name text, p_currencies text[],
  p_effective_from date default current_date, p_note text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.price', null, null, null, 'price_book', null);
  if coalesce(cardinality(p_currencies), 0) = 0 then
    raise exception 'ERPWARE_PRICE_BOOK_HAS_NO_CURRENCY: a price book names the currencies its rate card is maintained in'
      using errcode = '23514';
  end if;
  -- A configuration object, so it travels the way every policy does: one
  -- change set carrying one config item. Before go-live the installer promotes
  -- it on the spot; once the platform organisation is live it waits for a
  -- second person, which is D4 applied to the platform's own list.
  return erp.install_module_config(
    'price-book-' || p_code || '-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
    'Price book ' || p_code,
    'Opens ' || p_name || ' from ' || p_effective_from::text || ' in ' || array_to_string(p_currencies, ', ') || '.',
    jsonb_build_array(jsonb_build_object(
      'kind', 'config', 'key', 'commercial.price_book|' || p_code,
      'payload', jsonb_build_object(
        'config_type', 'commercial.price_book', 'code', p_code,
        'value', jsonb_strip_nulls(jsonb_build_object('name', p_name, 'currencies', to_jsonb(p_currencies), 'note', p_note)),
        'effective_from', p_effective_from))));
end;
$$;

comment on function erp.open_price_book is
  'Specification v1.5 §17.6: opens a price book version as a change set with '
  'one configuration item. Returns the change set; promoted immediately before '
  'go-live, and awaiting a second person after it.';

create or replace function erp.price_book_in_force(p_code text, p_on date default null)
returns table(config_object_id uuid, version integer, name text, currencies text[], effective_from date, effective_to date)
language sql
stable
set search_path = ''
as $$
  select co.id, cv.version, cv.value ->> 'name',
         array(select jsonb_array_elements_text(cv.value -> 'currencies')),
         cv.effective_from, cv.effective_to
    from erp.config_object co
    join erp.config_version cv on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id
   where co.tenant_id = erp.require_tenant_id()
     and co.config_type_code = 'commercial.price_book' and co.code = p_code and co.status = 'active'
     and cv.status = 'active'
     and cv.effective_from <= coalesce(p_on, current_date)
     and (cv.effective_to is null or cv.effective_to > coalesce(p_on, current_date))
   order by cv.version desc
   limit 1
$$;

create or replace function erp.set_rate(
  p_price_book_code text, p_item_code text, p_currency char(3), p_amount_minor bigint,
  p_term_kind text default 'annual')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        record;
  v_item   uuid; v_kind text; v_id uuid;
  v_list   text := p_price_book_code || '/' || p_term_kind;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.price', null, null, null, 'price_book', null);
  if p_term_kind not in ('annual', 'multi_year', 'monthly') then
    raise exception 'ERPWARE_UNKNOWN_TERM: % is not annual, multi_year or monthly', p_term_kind using errcode = '23514';
  end if;
  select * into b from erp.price_book_in_force(p_price_book_code);
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PRICE_BOOK: % has no version in force', p_price_book_code using errcode = '23503';
  end if;
  if not (p_currency = any (b.currencies)) then
    raise exception 'ERPWARE_CURRENCY_NOT_ON_BOOK: % is not maintained on %; the rate card is maintained per currency, never converted',
      p_currency, p_price_book_code using errcode = '23514';
  end if;
  select i.id, pi.kind into v_item, v_kind
    from erp.item i join erp.price_item pi on pi.tenant_id = i.tenant_id and pi.item_id = i.id
   where i.tenant_id = v_tenant and i.code = p_item_code;
  if v_item is null then
    raise exception 'ERPWARE_NOT_A_PRICE_ITEM: %', p_item_code using errcode = '23503';
  end if;
  if p_amount_minor < 0 then
    raise exception 'ERPWARE_NEGATIVE_RATE' using errcode = '23514';
  end if;
  -- §17.6: "legislation packs, priced at nil by default — because charging
  -- annually for a jurisdiction is the practice this product exists to end".
  -- Not a default that can be overridden: a position.
  if v_kind = 'legislation_pack' and p_amount_minor <> 0 then
    raise exception
      'ERPWARE_LEGISLATION_IS_NOT_PRICED: a legislation pack is on the price book at nil, and % is not nil', p_amount_minor
      using errcode = '23514',
            hint = 'Charging for a jurisdiction is the practice this product exists to end. The zero on the book is the point.';
  end if;

  update erp.item_price p
     set amount_minor = p_amount_minor, valid_from = b.effective_from, updated_at = now()
   where p.tenant_id = v_tenant and p.item_id = v_item and p.price_kind = 'sales_list'
     and p.price_list_code = v_list and p.currency = p_currency
     and p.party_role_id is null and p.site_id is null
  returning p.id into v_id;
  if v_id is null then
    insert into erp.item_price
      (tenant_id, item_id, price_kind, price_list_code, currency, amount_minor, per_quantity, uom_id, min_quantity, valid_from)
    values (v_tenant, v_item, 'sales_list', v_list, p_currency, p_amount_minor, 1, erp.commercial_uom(), 0, b.effective_from)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

comment on function erp.set_rate is
  'Specification v1.5 §17.6: one rate on the rate card — a price item, a price '
  'book, a currency the book maintains, a term. Refuses a currency the book '
  'does not maintain (rates are maintained, not converted) and any non-nil '
  'price on a legislation pack.';

create or replace function erp.set_cost_model(
  p_item_code text, p_currency char(3),
  p_infrastructure_minor bigint default 0, p_support_minor bigint default 0, p_pass_through_minor bigint default 0,
  p_basis text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_item uuid; v_id uuid;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.price', null, null, null, 'cost_model', null);
  select i.id into v_item from erp.item i
    join erp.price_item pi on pi.tenant_id = i.tenant_id and pi.item_id = i.id
   where i.tenant_id = v_tenant and i.code = p_item_code;
  if v_item is null then
    raise exception 'ERPWARE_NOT_A_PRICE_ITEM: %', p_item_code using errcode = '23503';
  end if;
  insert into erp.cost_model (tenant_id, item_id, currency, infrastructure_minor, support_minor, pass_through_minor, basis)
  values (v_tenant, v_item, p_currency, p_infrastructure_minor, p_support_minor, p_pass_through_minor, p_basis)
  on conflict (tenant_id, item_id, currency) do update set
    infrastructure_minor = excluded.infrastructure_minor, support_minor = excluded.support_minor,
    pass_through_minor = excluded.pass_through_minor, basis = excluded.basis,
    effective_from = current_date, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- ── What the builder reads ───────────────────────────────────────────────────

create or replace function erp.rate_for(p_item_id uuid, p_price_book_code text, p_term_kind text, p_currency char(3), p_on date default null)
returns bigint
language sql
stable
set search_path = ''
as $$
  select p.amount_minor
    from erp.item_price p
   where p.tenant_id = erp.require_tenant_id() and p.item_id = p_item_id
     and p.price_kind = 'sales_list'
     and p.price_list_code = p_price_book_code || '/' || p_term_kind
     and p.currency = p_currency and p.party_role_id is null and p.site_id is null
     and p.valid_from <= coalesce(p_on, current_date)
     and (p.valid_to is null or p.valid_to > coalesce(p_on, current_date))
   order by p.valid_from desc
   limit 1
$$;

create or replace function erp.unit_cost_for(p_item_id uuid, p_currency char(3))
returns bigint
language sql
stable
set search_path = ''
as $$
  select c.infrastructure_minor + c.support_minor + c.pass_through_minor
    from erp.cost_model c
   where c.tenant_id = erp.require_tenant_id() and c.item_id = p_item_id and c.currency = p_currency
$$;

-- ── The findings and the assertion ───────────────────────────────────────────

create or replace function erp.commercial_report()
returns table(finding text, reference text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  -- §17.5: the platform's organisation must be an organisation that exists and
  -- is active; a designation pointing at a purged or suspended tenant is a
  -- price book nobody can open.
  select 'the platform organisation is not an active organisation', po.tenant_code,
         coalesce((select t.status::text from erp.tenant t where t.id = po.tenant_id), 'no such organisation')
    from erp_meta.platform_organisation po
   where not exists (select 1 from erp.tenant t where t.id = po.tenant_id and t.status::text = 'active')
  union all
  -- §17.6: a legislation pack priced above nil. The writer refuses it; this
  -- catches a row that arrived any other way.
  select 'a legislation pack is priced above nil', i.code,
         format('%s %s on %s', p.amount_minor, p.currency, p.price_list_code)
    from erp.price_item pi
    join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
    join erp.item_price p on p.tenant_id = pi.tenant_id and p.item_id = pi.item_id and p.price_kind = 'sales_list'
   where pi.kind = 'legislation_pack' and p.amount_minor <> 0
  union all
  -- §17.6: a rate with no cost beside it is a margin nobody can see, which is
  -- exactly the year-end discovery D36 exists to prevent.
  select 'a rate has no cost model in its currency, so its margin is invisible', i.code,
         format('%s on %s', p.currency, p.price_list_code)
    from erp.price_item pi
    join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
    join erp.item_price p on p.tenant_id = pi.tenant_id and p.item_id = pi.item_id and p.price_kind = 'sales_list'
     and p.price_list_code like '%/%'
   where pi.kind <> 'legislation_pack' and pi.status = 'active'
     and not exists (select 1 from erp.cost_model c
                      where c.tenant_id = pi.tenant_id and c.item_id = pi.item_id and c.currency = p.currency)
  union all
  -- §17.6: a price item naming something the product no longer has.
  select 'a plan tier names a plan the product does not offer', i.code, pi.plan_code
    from erp.price_item pi join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
   where pi.kind = 'plan_tier' and not exists (select 1 from erp_meta.plan p where p.code = pi.plan_code)
  union all
  select 'a capability add-on names a capability the product does not have', i.code, pi.capability_code
    from erp.price_item pi join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
   where pi.kind = 'capability_addon' and not exists (select 1 from erp_ref.capability c where c.code = pi.capability_code)
  union all
  select 'a band names an entitlement the product does not enforce', i.code, pi.entitlement_code
    from erp.price_item pi join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
   where pi.entitlement_code is not null
     and not exists (select 1 from erp_meta.entitlement_kind k where k.code = pi.entitlement_code)
  order by 1, 2
$$;

comment on function erp.commercial_report is
  'Specification v1.5 §17.5 and §17.6. Security definer because it reads '
  'erp_meta.platform_organisation and the plan and entitlement registers, all '
  'platform-internal; reports on the price book alone and names no customer.';

create or replace function erp.assert_commercial_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text; v_items integer; v_designated boolean;
begin
  select count(*), string_agg(format('  %s — %s: %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.commercial_report();
  if v_count > 0 then
    raise exception 'ERPWARE_COMMERCIAL_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§17.6: the price book names only what the product has, legislation packs at nil, and a cost beside every rate.';
  end if;
  select count(*) into v_items from erp.price_item;
  select exists (select 1 from erp_meta.platform_organisation) into v_designated;
  return format('commercial: %s price item(s), platform organisation %s',
                v_items, case when v_designated then 'designated' else 'not yet designated' end);
end;
$$;

create or replace function erp.price_book_report()
returns jsonb
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select jsonb_build_object(
    'is_platform_organisation', erp.is_platform_organisation(),
    'books', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', co.code, 'name', cv.value ->> 'name', 'note', cv.value ->> 'note',
               'currencies', cv.value -> 'currencies', 'version', cv.version,
               'effective_from', cv.effective_from, 'effective_to', cv.effective_to, 'status', cv.status)
             order by co.code, cv.version desc)
        from t
        join erp.config_object co on co.tenant_id = t.tenant_id
         and co.config_type_code = 'commercial.price_book' and co.status = 'active'
        join erp.config_version cv on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id
         and cv.status in ('active', 'superseded')), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', i.code, 'name', i.name, 'kind', pi.kind, 'status', pi.status,
               'plan_code', pi.plan_code, 'capability_code', pi.capability_code,
               'entitlement_code', pi.entitlement_code, 'band_from', pi.band_from, 'band_to', pi.band_to,
               'legislation_pack_code', pi.legislation_pack_code, 'support_severity_code', pi.support_severity_code,
               'description', pi.description,
               'rates', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'price_book_code', split_part(p.price_list_code, '/', 1),
                          'term_kind', split_part(p.price_list_code, '/', 2),
                          'currency', p.currency, 'amount_minor', p.amount_minor,
                          'valid_from', p.valid_from, 'valid_to', p.valid_to,
                          'unit_cost_minor', erp.unit_cost_for(i.id, p.currency),
                          'margin_pct', case when p.amount_minor > 0 and erp.unit_cost_for(i.id, p.currency) is not null
                                             then round(100.0 * (p.amount_minor - erp.unit_cost_for(i.id, p.currency)) / p.amount_minor, 1) end)
                        order by p.price_list_code, p.currency)
                   from erp.item_price p
                  where p.tenant_id = i.tenant_id and p.item_id = i.id and p.price_kind = 'sales_list'
                    and p.party_role_id is null and p.site_id is null
                    and p.price_list_code like '%/%'), '[]'::jsonb),
               'costs', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'currency', c.currency, 'infrastructure_minor', c.infrastructure_minor,
                          'support_minor', c.support_minor, 'pass_through_minor', c.pass_through_minor,
                          'unit_cost_minor', c.infrastructure_minor + c.support_minor + c.pass_through_minor,
                          'basis', c.basis, 'effective_from', c.effective_from)
                        order by c.currency)
                   from erp.cost_model c where c.tenant_id = i.tenant_id and c.item_id = i.id), '[]'::jsonb))
             order by pi.kind, i.code)
        from t
        join erp.price_item pi on pi.tenant_id = t.tenant_id
        join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name) order by p.seq) from erp_meta.plan p), '[]'::jsonb),
    'entitlement_kinds', coalesce((select jsonb_agg(jsonb_build_object('code', k.code, 'title', k.title, 'unit', k.unit) order by k.code) from erp_meta.entitlement_kind k), '[]'::jsonb),
    'capabilities', coalesce((select jsonb_agg(c.code order by c.code) from erp_ref.capability c), '[]'::jsonb),
    'severities', coalesce((select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name) order by s.seq) from erp_ref.support_severity s), '[]'::jsonb),
    'legislation_packs', coalesce((select jsonb_agg(jsonb_build_object('code', l.code, 'jurisdiction', l.jurisdiction) order by l.code) from erp_ref.legislation_pack l where l.is_current), '[]'::jsonb),
    'findings', coalesce((select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
                            from erp.commercial_report() f), '[]'::jsonb))
$$;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_designate_organisation(p_tenant_code text, p_reason text default null)
returns uuid language sql set search_path = '' as $$
  select erp.designate_platform_organisation(p_tenant_code, p_reason);
$$;

create or replace function public.erp_platform_commercial_state()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  return jsonb_build_object(
    'platform_organisation', (select jsonb_build_object(
        'tenant_code', po.tenant_code, 'designated_at', po.designated_at,
        'designated_by', po.designated_by, 'reason', po.reason,
        'status', (select t.status::text from erp.tenant t where t.id = po.tenant_id))
      from erp_meta.platform_organisation po),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name) order by t.code)
                              from erp.tenant t where t.status::text = 'active'), '[]'::jsonb),
    'price_items', (select count(*) from erp.price_item pi
                     where pi.tenant_id = (select po.tenant_id from erp_meta.platform_organisation po)),
    'findings', coalesce((select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
                            from erp.commercial_report() f), '[]'::jsonb));
end;
$$;

create or replace function public.erp_is_platform_organisation()
returns boolean language sql stable set search_path = '' as $$ select erp.is_platform_organisation(); $$;

create or replace function public.erp_upsert_price_item(
  p_code text, p_name text, p_kind text,
  p_plan_code text default null, p_capability_code text default null,
  p_entitlement_code text default null, p_band_from numeric default null, p_band_to numeric default null,
  p_legislation_pack_code text default null, p_support_severity_code text default null,
  p_description text default null)
returns uuid language sql set search_path = '' as $$
  select erp.upsert_price_item(p_code, p_name, p_kind, p_plan_code, p_capability_code, p_entitlement_code,
                               p_band_from, p_band_to, p_legislation_pack_code, p_support_severity_code, p_description);
$$;

create or replace function public.erp_open_price_book(p_code text, p_name text, p_currencies text[], p_effective_from date default current_date, p_note text default null)
returns uuid language sql set search_path = '' as $$
  select erp.open_price_book(p_code, p_name, p_currencies, p_effective_from, p_note);
$$;

create or replace function public.erp_set_rate(p_price_book_code text, p_item_code text, p_currency text, p_amount_minor bigint, p_term_kind text default 'annual')
returns uuid language sql set search_path = '' as $$
  select erp.set_rate(p_price_book_code, p_item_code, p_currency::char(3), p_amount_minor, p_term_kind);
$$;

create or replace function public.erp_set_cost_model(p_item_code text, p_currency text, p_infrastructure_minor bigint default 0, p_support_minor bigint default 0, p_pass_through_minor bigint default 0, p_basis text default null)
returns uuid language sql set search_path = '' as $$
  select erp.set_cost_model(p_item_code, p_currency::char(3), p_infrastructure_minor, p_support_minor, p_pass_through_minor, p_basis);
$$;

create or replace function public.erp_price_book()
returns jsonb language sql stable set search_path = '' as $$ select erp.price_book_report(); $$;

revoke all on function
  public.erp_platform_designate_organisation(text, text),
  public.erp_platform_commercial_state(),
  public.erp_is_platform_organisation(),
  public.erp_upsert_price_item(text, text, text, text, text, text, numeric, numeric, text, text, text),
  public.erp_open_price_book(text, text, text[], date, text),
  public.erp_set_rate(text, text, text, bigint, text),
  public.erp_set_cost_model(text, text, bigint, bigint, bigint, text),
  public.erp_price_book()
  from public, anon;

grant execute on function
  public.erp_platform_designate_organisation(text, text),
  public.erp_platform_commercial_state(),
  public.erp_is_platform_organisation(),
  public.erp_upsert_price_item(text, text, text, text, text, text, numeric, numeric, text, text, text),
  public.erp_open_price_book(text, text, text[], date, text),
  public.erp_set_rate(text, text, text, bigint, text),
  public.erp_set_cost_model(text, text, bigint, bigint, bigint, text),
  public.erp_price_book()
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta','platform_organisation','platform_internal',
   'Part 17 §17.5. The one organisation that is the platform itself.'),
  ('erp','price_item','tenant_scoped',
   'Part 17 §17.6. What the platform sells, as products of its own organisation with a commercial shape.'),
  ('erp','cost_model','tenant_scoped',
   'Part 17 §17.6. The internal cost per price item, per currency, so margin is a subtraction at the point of quoting.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_designate_organisation', 'erp.designate_platform_organisation',
   'Names the platform''s own organisation. Gated by erp_meta.require_platform at owner and recorded in the platform log.'),
  ('erp_upsert_price_item', 'erp.upsert_price_item',
   'Registers a price item in the platform organisation. Refused outside it; sales.price inside it.'),
  ('erp_open_price_book', 'erp.open_price_book',
   'Opens a price book version as a change set with one configuration item. Refused outside the platform organisation; sales.price to author it, and administration.configure inside erp.install_module_config like every module installer.'),
  ('erp_set_rate', 'erp.set_rate',
   'One rate on the rate card, per currency and term. sales.price in the platform organisation; a legislation pack cannot be priced above nil.'),
  ('erp_set_cost_model', 'erp.set_cost_model',
   'The internal cost per price item. sales.price in the platform organisation.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'is_platform_organisation',
   'Reads erp_meta.platform_organisation, platform-internal, and answers one boolean about the caller''s own organisation.'),
  ('erp', 'designate_platform_organisation',
   'Writes erp_meta.platform_organisation and the platform log. Gated by erp_meta.require_platform(''owner'') on the first line.'),
  ('erp', 'upsert_price_item',
   'Reads erp_meta.plan and erp_meta.entitlement_kind to validate what a price item names; writes only the caller''s own organisation''s rows, and refuses any organisation that is not the platform''s.'),
  ('erp', 'commercial_report',
   'Reads the platform organisation register and the plan and entitlement registers to report on the price book. Names no customer.'),
  ('public', 'erp_platform_commercial_state',
   'Platform console read of the designation and the price book''s findings. Gated by erp_meta.require_platform(''support'') on its first line; reads only, and nothing an organisation wrote.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('commercial', 'Commercial control plane sound', 'assertion', 'platform',
   'erp', 'assert_commercial_sound', '', 'commercial_report', '',
   'Part 17''s price book: the platform organisation is an active organisation, every price item names something the product has, legislation packs are at nil, and every rate has a cost beside it so margin is visible.',
   true, 70)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

-- ── The decisions register, v1.5 ─────────────────────────────────────────────
--
-- Only the decisions this migration can bind to a check are registered here;
-- erp.assert_product_decisions_enforced() refuses a decision nothing enforces.
-- D35 arrives with the contract that provisions entitlement, D38 with the
-- customer's own view, D34 with the refusal register that proves it.

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, spec_reference) values
  ('D36', 36, 'Margin is visible while a quote is being built',
   'Every price item carries an internal cost, and margin shows live per line and in total as a quote is assembled.',
   'A discount decided without knowing its margin is a decision made blind, and discovering it at year end is too late to change anything.',
   'A cost model is maintained per price item and per currency.', 'v1.5 §17.7, Part 22 D36'),
  ('D37', 37, 'The platform runs its own commercial process on its own primitives',
   'Price books are configuration, quotes and contracts are documents with state machines, discounting uses the approval engine, order forms render through the output subsystem.',
   'A second implementation of approvals or documents for internal use would be the first admission that the product is not sufficient for real work.',
   'The platform must operate an organisation of its own on the deployment.', 'v1.5 §17.5, Part 22 D37')
on conflict (code) do update set
  seq = excluded.seq, title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, cost = excluded.cost, spec_reference = excluded.spec_reference;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D37', 'erp', 'assert_commercial_sound',
   'D37 says the platform sells through its own primitives. The assertion reads the price book as products, prices and configuration of the platform organisation; if a second price table ever appeared, this is where it would be missed.'),
  ('D36', 'erp', 'assert_commercial_sound',
   'D36 says margin is visible while quoting, which needs a cost beside every rate; the assertion fails a rate with no cost model in its currency.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence) values
  ('platform_organisation_is_a_tenant',
   'The platform''s commercial process runs inside one designated organisation',
   'v1.5 §17.5, D37',
   'The platform owner designates one active organisation as the platform''s own (erp_meta.platform_organisation). Price items are its products, the price book is its configuration, quotes are its quotations, discount approval is its approval chain and order forms are its output templates. erp_meta holds only what belongs to the platform and to no organisation: the designation, and the contracts and what they provision.',
   '§17.5 forbids a second implementation of anything the product already has, and every one of those things is tenant-scoped by D1. The only way to use them is from inside a tenant, so the platform is one. It is also the honest test §17.5 asks for: the commercial process either works on the product or the product is not finished.',
   'accepted',
   'erp_meta.platform_organisation; erp.require_platform_organisation() on every commercial writer; erp_test.commercial_price_book_suite() proves another organisation is refused.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── Resources, help ──────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description) values
('module.commercial', 'en', 'Commercial', 'The platform''s own commercial module: price book, quotes, contracts.'),
('config.commercial.price_book', 'en', 'Price book',
 'A price book version: the list in force from a date, per currency, maintained rather than converted.'),
('nav.commercial_price_book', 'en', 'Price book',
 'Navigation label for the platform organisation''s price book: what is sold, at what rate per currency and term, and at what cost.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Price book'),
    ('This organisation is not the platform''s. The price book, quotes and contracts belong to the organisation a platform owner designates as the platform; every other organisation sees its own agreement under Plan and usage.'),
    ('Price books'),
    ('A price book is a configuration object: versioned, effective-dated, per currency. A quote names the version in force when it was raised, so a historical quote can always be explained.'),
    ('No price book is open.'),
    ('Open a price book'),
    ('Currencies'),
    ('What is sold'),
    ('Each price item is a product of this organisation with a commercial shape: a plan tier, a feature add-on, a band of an entitlement, an environment, a support tier, a fixed-price service, or a legislation pack at nil. Rates are maintained per currency and term; the cost beside each rate is what makes margin visible while quoting.'),
    ('Nothing is on the price book yet.'),
    ('Add a price item'),
    ('Set a rate'),
    ('Set the cost'),
    ('Kind'),
    ('Plan'),
    ('Feature'),
    ('Entitlement'),
    ('Band from'),
    ('Band to'),
    ('Legislation pack'),
    ('Severity'),
    ('Term'),
    ('Rate'),
    ('Cost'),
    ('Margin'),
    ('Infrastructure'),
    ('Support load'),
    ('Pass-through'),
    ('Basis'),
    ('Legislation packs are priced at nil. Charging annually for a jurisdiction is the practice this product exists to end, and the zero on the book makes that visible rather than tacit.'),
    ('No rate'),
    ('No cost'),
    ('Priced at nil'),
    ('Effective from'),
    ('Annual'),
    ('Multi-year'),
    ('Monthly')
  ) t(text)
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/commercial/price-book', 'nav.commercial_price_book', 'commercial',
   'The platform''s price book, kept inside its own organisation on its own primitives: price items as products with a commercial shape, price books as versioned configuration, the rate card per currency and term, and the cost model beside each rate so margin is visible while quoting. Legislation packs sit on the book at nil.',
   '["Open a price book naming the currencies it maintains; a new version closes the previous one from its date.","Add a price item for each thing that is sold, naming the plan, feature, band, severity or pack it maps to.","Set a rate per currency and term; the rate card is maintained, never converted.","Set the cost beside each rate: infrastructure, support load and pass-through. Margin follows."]',
   'Open a price book, then add the plan tiers.',
   '{erp_open_price_book,erp_upsert_price_item,erp_set_rate,erp_set_cost_model}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.commercial_price_book_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; r2 record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ad2 uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzcpb-' || substr(md5(random()::text), 1, 6);
  v_other uuid; v_other_code text := 'zzcpo-' || substr(md5(random()::text), 1, 6);
  v_ok boolean; v_msg text; res jsonb; v_id uuid; v_item uuid;
begin
  select * into r from erp.provision_tenant(v_code, 'Clove Platform', 'admin@zzcpb.test', 'Platform Admin');
  v_tenant := r.tenant_id;
  select * into r2 from erp.provision_tenant(v_other_code, 'Some Customer', 'admin@zzcpo.test', 'Customer Admin');
  v_other := r2.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzcpb.test'), (ow, 'owner@zzcpb.test'), (ad2, 'admin@zzcpo.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzcpb.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ad2)::text, true);
  perform erp.claim_invitation(r2.admin_token);

  -- ── §17.5 the designation ─────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  begin
    perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
    v_ok := false; v_msg := 'an undesignated organisation registered a price item';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_THE_PLATFORM_ORGANISATION%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'until an organisation is designated as the platform, nobody has a price book', v_ok, v_msg;

  begin
    perform erp.designate_platform_organisation(v_code);
    v_ok := false; v_msg := 'a tenant administrator designated the platform organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM%' or sqlerrm like '%platform%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'designating the platform organisation is an owner''s act', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  v_id := erp.designate_platform_organisation(v_code);
  return query select 'a platform owner designates the platform''s own organisation',
    v_id = v_tenant and exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_tenant),
    'recorded in the platform log';

  begin
    perform erp.designate_platform_organisation(v_other_code);
    v_ok := false; v_msg := 'the designation moved without a reason';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM_ORGANISATION_ALREADY_DESIGNATED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'moving the designation states why', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ad2)::text, true);
  begin
    perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
    v_ok := false; v_msg := 'another organisation registered a price item';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_THE_PLATFORM_ORGANISATION%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and every other organisation is refused the control plane', v_ok, v_msg;

  -- ── §17.6 the price book ──────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_tenant);
  v_id := erp.open_price_book('PB-2026', 'List 2026', array['GBP', 'EUR'], current_date - 1, 'first list');
  perform erp_test.close_bootstrap_window(v_tenant);
  return query select 'a price book is a configuration object with a version in force, opened by a change set',
    v_id is not null and (select b.version from erp.price_book_in_force('PB-2026') b) = 1
    and exists (select 1 from erp.config_object co where co.tenant_id = v_tenant
                 and co.config_type_code = 'commercial.price_book' and co.code = 'PB-2026')
    and exists (select 1 from erp.change_set cs where cs.tenant_id = v_tenant and cs.id = v_id),
    'erp.config_object commercial.price_book PB-2026 v1, promoted';

  begin
    perform erp.upsert_price_item('PLAN-XL', 'Imaginary plan', 'plan_tier', 'imaginary');
    v_ok := false; v_msg := 'a plan the product does not offer was put on the book';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_PLAN%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a price item names something the product has', v_ok, v_msg;

  v_id := erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
  perform erp.upsert_price_item('CAP-LANDED', 'Landed cost', 'capability_addon', null, 'landed_cost');
  perform erp.upsert_price_item('USERS-100', 'Up to 100 users', 'user_band', null, null, 'users', 51, 100);
  perform erp.upsert_price_item('SUP-SEV1', 'Severity 1 support', 'support_tier', null, null, null, null, null, null, 'sev1');
  perform erp.upsert_price_item('SVC-IMPL', 'Implementation', 'service');
  perform erp.upsert_price_item('LEG-VAT', 'Example VAT pack', 'legislation_pack', null, null, null, null, null, 'example_vat');
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.code = 'PLAN-STD';
  return query select 'a price item is a product of the platform organisation with a commercial shape',
    v_item is not null and (select count(*) from erp.price_item pi where pi.tenant_id = v_tenant) = 6
    and (select i.item_class from erp.item i where i.id = v_item) = 'commercial',
    'six items, each an erp.item';

  begin
    perform erp.set_rate('PB-2026', 'PLAN-STD', 'USD', 1200000);
    v_ok := false; v_msg := 'a rate was set in a currency the book does not maintain';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CURRENCY_NOT_ON_BOOK%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'the rate card is maintained per currency, never converted', v_ok, v_msg;

  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000, 'annual');
  perform erp.set_rate('PB-2026', 'PLAN-STD', 'EUR', 1400000, 'annual');
  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 110000, 'monthly');
  perform erp.set_rate('PB-2026', 'CAP-LANDED', 'GBP', 150000, 'annual');
  perform erp.set_rate('PB-2026', 'USERS-100', 'GBP', 300000, 'annual');
  perform erp.set_rate('PB-2026', 'SUP-SEV1', 'GBP', 200000, 'annual');
  perform erp.set_rate('PB-2026', 'SVC-IMPL', 'GBP', 800000, 'annual');
  return query select 'rates are held per currency and per term',
    erp.rate_for(v_item, 'PB-2026', 'annual', 'GBP') = 1200000
    and erp.rate_for(v_item, 'PB-2026', 'annual', 'EUR') = 1400000
    and erp.rate_for(v_item, 'PB-2026', 'monthly', 'GBP') = 110000
    and erp.rate_for(v_item, 'PB-2026', 'multi_year', 'GBP') is null,
    'GBP annual, EUR annual, GBP monthly; multi-year unset';

  begin
    perform erp.set_rate('PB-2026', 'LEG-VAT', 'GBP', 50000);
    v_ok := false; v_msg := 'a legislation pack was priced';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LEGISLATION_IS_NOT_PRICED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a legislation pack cannot be priced above nil', v_ok, v_msg;
  perform erp.set_rate('PB-2026', 'LEG-VAT', 'GBP', 0);
  return query select 'and sits on the book at nil, visibly',
    erp.rate_for((select i.id from erp.item i where i.tenant_id = v_tenant and i.code = 'LEG-VAT'), 'PB-2026', 'annual', 'GBP') = 0,
    'zero, stated';

  -- ── §17.6 the cost model and margin ───────────────────────────────────────

  return query select 'a rate with no cost beside it is a finding, because its margin is invisible',
    exists (select 1 from erp.commercial_report() f where f.finding like 'a rate has no cost model%' and f.reference = 'PLAN-STD'),
    'D36';

  perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000, 'hosting per organisation plus support load');
  perform erp.set_cost_model('PLAN-STD', 'EUR', 350000, 120000, 60000, 'as GBP, maintained');
  perform erp.set_cost_model('CAP-LANDED', 'GBP', 20000, 10000, 0, null);
  perform erp.set_cost_model('USERS-100', 'GBP', 50000, 25000, 0, null);
  perform erp.set_cost_model('SUP-SEV1', 'GBP', 0, 150000, 0, 'on-call rota share');
  perform erp.set_cost_model('SVC-IMPL', 'GBP', 0, 600000, 0, 'twelve consultant days');
  return query select 'the cost model splits infrastructure, support load and pass-through',
    erp.unit_cost_for(v_item, 'GBP') = 450000 and erp.unit_cost_for(v_item, 'EUR') = 530000,
    'GBP 4,500.00 and EUR 5,300.00 per year';

  res := erp.price_book_report();
  return query select 'the book reports margin at list, per rate',
    (select (rt ->> 'margin_pct')::numeric
       from jsonb_array_elements(res -> 'items') x
       cross join jsonb_array_elements(x -> 'rates') rt
      where x ->> 'code' = 'PLAN-STD' and rt ->> 'currency' = 'GBP' and rt ->> 'term_kind' = 'annual') = 62.5
    and jsonb_array_length(res -> 'books') = 1 and (res ->> 'is_platform_organisation')::boolean,
    '(12,000 - 4,500) / 12,000';

  return query select 'and the assertion passes over the book',
    erp.assert_commercial_sound() like 'commercial: 6 price item(s)%', erp.assert_commercial_sound();

  perform erp_test.reopen_bootstrap_window(v_tenant);
  v_id := erp.open_price_book('PB-2026', 'List 2026, revised', array['GBP', 'EUR', 'USD'], current_date, 'USD added');
  perform erp_test.close_bootstrap_window(v_tenant);
  return query select 'a new version of the book closes the previous one from its date',
    (select b.version from erp.price_book_in_force('PB-2026') b) = 2
    and (select cv.effective_to from erp.config_version cv join erp.config_object co on co.id = cv.config_object_id
          where co.tenant_id = v_tenant and co.code = 'PB-2026' and cv.version = 1) = current_date,
    'version 2 in force; version 1 closed today';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_organisation where tenant_id = v_tenant;
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_other);
  delete from erp.tenant where id = v_other;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzcpb.test';
  delete from auth.users where id in (ad, ow, ad2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id in (v_tenant, v_other))
    and not exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_tenant),
    'organisations, designation and staff gone';
end;
$$;

create or replace function erp_test.assert_commercial_price_book_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _commercial_price_book_result on commit drop as
    select * from erp_test.commercial_price_book_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _commercial_price_book_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_COMMERCIAL_PRICE_BOOK_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('commercial price book: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_commercial_sound();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
