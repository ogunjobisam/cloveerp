-- ═════════════════════════════════════════════════════════════════════════════
-- A customer arrives whole
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A party imported through the master-data pipeline arrived as a code, a name
-- and a status of draft: no role, no address, no contact, no terms. A migrated
-- customer could not be invoiced, and a migrated supplier could not be ordered
-- from, until somebody keyed the rest by hand.
--
-- The party_profile import object carries one legacy contact whole: the party,
-- its roles, its billing and delivery addresses, a default contact, and its
-- customer and supplier terms with the first company. One Xero contact, or one
-- Unleashed customer or supplier, is one row.
--
-- Loading is additive, and that is the whole design. A party that exists
-- gains what it lacks — a role it does not hold, an address of a kind it has
-- no default for, a contact when it has none, terms when none are in force —
-- and nothing it has is changed: not its name, not its identifiers, not the
-- terms somebody already set. So the first system loaded wins where two
-- disagree, and the pilot runbook loads Xero contacts first (identity,
-- addresses) and Unleashed customers and suppliers after (roles, terms). And
-- so rollback can be exact: it removes precisely the rows the batch added,
-- recorded on each import row, and refuses once anything else has attached
-- itself to them.
--
-- The writers are the product's own. The party is made by erp.create_party
-- (master_data.write) and returned to draft, since imported records are
-- activated together once reviewed; addresses go through
-- erp.record_party_address, which holds them to the same rules as the desk.
-- Terms are kept with the first active company, as erp_set_credit_limit keeps
-- them, and a credit limit needs sales.credit_release, which the desk asks for
-- the same change. The payment term is one of erp_ref.payment_term's codes.
--
-- Each loaded row writes its legacy key into erp.import_crosswalk, so the aged
-- ledgers resolve the contact names they print.
--
-- Proof: erp_test.party_profile_suite() (9 cases).

set lock_timeout = '30s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The register
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.import_object (object_type, name_key, module_code, validate_function, load_function, rollback_function, description, seq) values
  ('party_profile', 'import_object.party_profile.name', 'master_data',
   'erp.validate_party_profile_import', 'erp.load_party_profile_import', 'erp.rollback_party_profile_import',
   'A legacy contact whole: the party, its roles, addresses, default contact and terms. Additive: a party that exists gains what it lacks and keeps everything it has.', 30)
on conflict (object_type) do update
  set name_key = excluded.name_key, module_code = excluded.module_code,
      validate_function = excluded.validate_function, load_function = excluded.load_function,
      rollback_function = excluded.rollback_function, description = excluded.description, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('import_object.party_profile.name', 'en', 'Customers and suppliers', 'master_data'),
  ('import_object.party_profile.name', 'de', 'Kunden und Lieferanten', 'master_data')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Validate
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.validate_party_profile_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_entity uuid;
  v_find   jsonb;
  v_errors integer := 0;
  v_bad    text;
  v_code   text;
  v_key    text;
  v_party  erp.party%rowtype;
  v_roles  text[];
  v_have   text[];
  v_codes  text[] := '{}';
  v_keys   text[] := '{}';
  a        jsonb;
  t        record;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514', hint = 'Stage a new batch; a loaded or rolled-back one is not validated again.';
  end if;

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id order by x.row_no loop
    v_find := '[]'::jsonb;
    v_code := btrim(coalesce(r.raw ->> 'code', ''));
    v_key := lower(btrim(coalesce(r.raw ->> 'legacy_key', '')));

    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k not in ('source', 'legacy_key', 'code', 'name', 'legal_name', 'tax_identifier',
                     'registration_number', 'country_code', 'roles', 'addresses', 'contact',
                     'customer_terms', 'supplier_terms');
    if v_bad is not null then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('unknown field(s): %s', v_bad));
    end if;
    if coalesce(r.raw ->> 'source', '') not in ('xero', 'unleashed') then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'source is xero or unleashed');
    end if;

    if v_code = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'code is the Clove party code, and it is missing');
    elsif v_code = any (v_codes) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is on an earlier row', v_code));
    else
      v_codes := v_codes || v_code;
    end if;
    if v_key = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'legacy_key names the contact in the old system, and it is missing');
    elsif v_key = any (v_keys) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('the legacy contact %s is on an earlier row', r.raw ->> 'legacy_key'));
    else
      v_keys := v_keys || v_key;
    end if;

    v_party := null;
    if v_code <> '' then
      select * into v_party from erp.party p where p.tenant_id = v_tenant and p.code = v_code;
    end if;
    if v_party.id is null and coalesce(btrim(r.raw ->> 'name'), '') = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'a new party needs a name');
    end if;
    if v_party.id is not null then
      v_find := v_find || jsonb_build_object('severity', 'info', 'message',
        format('%s exists: it gains what it lacks and keeps everything it has', v_code));
      if coalesce(btrim(r.raw ->> 'name'), v_party.name) <> v_party.name then
        v_find := v_find || jsonb_build_object('severity', 'warning', 'message',
          format('the file calls %s "%s"; it stays "%s"', v_code, btrim(r.raw ->> 'name'), v_party.name));
      end if;
    end if;

    if coalesce(btrim(r.raw ->> 'country_code'), '') <> ''
       and not exists (select 1 from erp_ref.country c where c.code = upper(btrim(r.raw ->> 'country_code'))) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is not a country the product lists', r.raw ->> 'country_code'));
    end if;

    -- Roles: the ones the row asks for, and the ones the party already holds.
    v_roles := '{}';
    if r.raw ? 'roles' then
      if jsonb_typeof(r.raw -> 'roles') <> 'array'
         or exists (select 1 from jsonb_array_elements(r.raw -> 'roles') e
                     where jsonb_typeof(e) <> 'string' or e #>> '{}' not in ('customer', 'supplier')) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'roles is a list of customer and supplier');
      else
        select coalesce(array_agg(e #>> '{}'), '{}') into v_roles from jsonb_array_elements(r.raw -> 'roles') e;
      end if;
    end if;
    v_have := '{}';
    if v_party.id is not null then
      select coalesce(array_agg(pr.role_kind::text), '{}') into v_have
        from erp.party_role pr where pr.tenant_id = v_tenant and pr.party_id = v_party.id;
    end if;

    -- Addresses.
    if r.raw ? 'addresses' then
      if jsonb_typeof(r.raw -> 'addresses') <> 'array' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'addresses is a list');
      else
        for a in select e from jsonb_array_elements(r.raw -> 'addresses') e loop
          if jsonb_typeof(a) <> 'object' or coalesce(a ->> 'kind', '') not in ('billing', 'delivery', 'registered', 'remittance') then
            v_find := v_find || jsonb_build_object('severity', 'error', 'message',
              format('an address kind is billing, delivery, registered or remittance, not %s', coalesce(a ->> 'kind', 'nothing')));
          elsif jsonb_typeof(a -> 'lines') is distinct from 'array'
             or coalesce(btrim(a -> 'lines' ->> 0), '') = ''
             or (coalesce(btrim(a ->> 'locality'), '') = '' and coalesce(btrim(a ->> 'postcode'), '') = '') then
            v_find := v_find || jsonb_build_object('severity', 'error', 'message',
              format('the %s address needs a first line and a town or a postcode', a ->> 'kind'));
          elsif coalesce(btrim(a ->> 'country_code'), '') <> ''
             and not exists (select 1 from erp_ref.country c where c.code = upper(btrim(a ->> 'country_code'))) then
            v_find := v_find || jsonb_build_object('severity', 'error', 'message',
              format('the %s address is in %s, which is not a country the product lists', a ->> 'kind', a ->> 'country_code'));
          elsif v_party.id is not null and exists (
              select 1 from erp.party_address pa
               where pa.tenant_id = v_tenant and pa.party_id = v_party.id and pa.is_default
                 and pa.address_kind::text = a ->> 'kind') then
            v_find := v_find || jsonb_build_object('severity', 'info', 'message',
              format('%s already has a %s address, which is kept', v_code, a ->> 'kind'));
          end if;
        end loop;
      end if;
    end if;

    -- The contact.
    if r.raw ? 'contact' then
      if jsonb_typeof(r.raw -> 'contact') <> 'object'
         or (coalesce(btrim(r.raw -> 'contact' ->> 'name'), '') = '' and coalesce(btrim(r.raw -> 'contact' ->> 'email'), '') = '') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'a contact needs a name or an email address');
      elsif coalesce(btrim(r.raw -> 'contact' ->> 'email'), '') <> ''
            and not erp.email_address_usable(r.raw -> 'contact' ->> 'email') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not an email address', r.raw -> 'contact' ->> 'email'));
      end if;
    end if;

    -- Terms, for each role that carries them.
    for t in select * from (values ('customer', 'customer_terms'), ('supplier', 'supplier_terms')) v(role, field) loop
      continue when not (r.raw ? t.field);
      if jsonb_typeof(r.raw -> t.field) <> 'object' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is an object', t.field));
        continue;
      end if;
      if not (t.role = any (v_roles) or t.role = any (v_have)) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s are given, but the party is not a %s; add the role', t.field, t.role));
      end if;
      if coalesce(r.raw -> t.field ->> 'payment_terms_code', '') <> ''
         and not exists (select 1 from erp_ref.payment_term pt where pt.code = r.raw -> t.field ->> 'payment_terms_code') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a payment term the product lists', r.raw -> t.field ->> 'payment_terms_code'));
      end if;
      if coalesce(r.raw -> t.field ->> 'currency', '') <> ''
         and not exists (select 1 from erp_ref.currency c where c.code = upper(r.raw -> t.field ->> 'currency')) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a currency the product lists', r.raw -> t.field ->> 'currency'));
      end if;
      if r.raw -> t.field ? 'credit_limit_minor' then
        if t.role <> 'customer' or coalesce(r.raw -> t.field ->> 'credit_limit_minor', '') !~ '^[0-9]+$' then
          v_find := v_find || jsonb_build_object('severity', 'error', 'message',
            'a credit limit is a customer''s, in whole minor units of zero or more');
        else
          v_find := v_find || jsonb_build_object('severity', 'info', 'message',
            'a credit limit is loaded only by somebody who may release credit (sales.credit_release)');
        end if;
      end if;
      if v_party.id is not null and exists (
          select 1 from erp.party_role pr join erp.party_role_terms x
                 on x.tenant_id = pr.tenant_id and x.party_role_id = pr.id
           where pr.tenant_id = v_tenant and pr.party_id = v_party.id and pr.role_kind::text = t.role
             and x.entity_id = v_entity and x.valid_from <= current_date
             and (x.valid_to is null or x.valid_to > current_date)) then
        v_find := v_find || jsonb_build_object('severity', 'warning', 'message',
          format('%s already has %s terms in force, which are kept; change them on the party if the file is right', v_code, t.role));
      end if;
    end loop;

    update erp.import_row
       set findings = v_find, target_id = null,
           action = case when exists (select 1 from jsonb_array_elements(v_find) f where f ->> 'severity' = 'error') then 'reject'
                         when v_party.id is not null then 'update' else 'insert' end,
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

revoke all on function erp.validate_party_profile_import(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Load
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.load_party_profile_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  b         erp.import_batch%rowtype;
  r         record;
  v_entity  uuid;
  v_ccy     char(3);
  v_party   uuid;
  v_created boolean;
  v_role    uuid;
  v_id      uuid;
  v_roles   uuid[];
  v_terms   uuid[];
  v_addrs   uuid[];
  v_contacts uuid[];
  v_values  jsonb;
  v_n       integer := 0;
  kind      text;
  a         jsonb;
  t         record;
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
  -- A credit limit is the same change the desk gates; the import is not a way round it.
  if exists (select 1 from erp.import_row x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id
               and x.raw -> 'customer_terms' ? 'credit_limit_minor') then
    perform erp.authorise('sales.credit_release', null, null, null, 'import_batch', p_batch_id);
  end if;

  select e.id, e.base_currency into v_entity, v_ccy from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x
            where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.action in ('insert', 'update')
            order by x.row_no loop
    v_roles := '{}'; v_terms := '{}'; v_addrs := '{}'; v_contacts := '{}';

    select p.id into v_party from erp.party p where p.tenant_id = v_tenant and p.code = btrim(r.raw ->> 'code');
    v_created := v_party is null;
    v_values := jsonb_strip_nulls(jsonb_build_object(
      'tax_identifier', nullif(btrim(r.raw ->> 'tax_identifier'), ''),
      'registration_number', nullif(btrim(r.raw ->> 'registration_number'), '')));

    if v_created then
      v_party := erp.create_party(btrim(r.raw ->> 'code'), btrim(r.raw ->> 'name'), '{}',
        nullif(upper(btrim(r.raw ->> 'country_code')), '')::char(2),
        nullif(btrim(r.raw ->> 'legal_name'), ''), v_values);
      -- Imported records are activated together once reviewed.
      update erp.party p set status = 'draft', updated_at = now() where p.id = v_party;
    else
      -- What the party lacks, and only that.
      select jsonb_strip_nulls(jsonb_build_object(
               'legal_name', case when p.legal_name is null then nullif(btrim(r.raw ->> 'legal_name'), '') end,
               'tax_identifier', case when p.tax_identifier is null then nullif(btrim(r.raw ->> 'tax_identifier'), '') end,
               'registration_number', case when p.registration_number is null then nullif(btrim(r.raw ->> 'registration_number'), '') end,
               'country_code', case when p.country_code is null then nullif(upper(btrim(r.raw ->> 'country_code')), '') end))
        into v_values
        from erp.party p where p.id = v_party;
      if v_values <> '{}'::jsonb then
        perform erp.write_master_fields('party', v_party, v_values);
      end if;
    end if;

    for kind in select e #>> '{}' from jsonb_array_elements(coalesce(r.raw -> 'roles', '[]'::jsonb)) e loop
      if not exists (select 1 from erp.party_role pr
                      where pr.tenant_id = v_tenant and pr.party_id = v_party and pr.role_kind::text = kind) then
        insert into erp.party_role (tenant_id, party_id, role_kind, status)
        values (v_tenant, v_party, kind::erp.party_role_kind, 'active')
        returning id into v_id;
        v_roles := v_roles || v_id;
      end if;
    end loop;

    for t in select * from (values ('customer', 'customer_terms'), ('supplier', 'supplier_terms')) v(role, field) loop
      continue when not (r.raw ? t.field);
      select pr.id into v_role from erp.party_role pr
       where pr.tenant_id = v_tenant and pr.party_id = v_party and pr.role_kind::text = t.role;
      continue when v_role is null
        or exists (select 1 from erp.party_role_terms x
                    where x.tenant_id = v_tenant and x.party_role_id = v_role and x.entity_id = v_entity
                      and x.valid_from <= current_date and (x.valid_to is null or x.valid_to > current_date));
      insert into erp.party_role_terms
        (tenant_id, party_role_id, entity_id, currency, payment_terms_code, payment_days,
         credit_limit_minor, credit_reason, valid_from, valid_to)
      values (v_tenant, v_role, v_entity,
              coalesce(nullif(upper(r.raw -> t.field ->> 'currency'), ''), v_ccy),
              nullif(r.raw -> t.field ->> 'payment_terms_code', ''),
              (select pt.net_days from erp_ref.payment_term pt where pt.code = r.raw -> t.field ->> 'payment_terms_code'),
              (r.raw -> t.field ->> 'credit_limit_minor')::bigint,
              case when r.raw -> t.field ? 'credit_limit_minor' then format('Imported with %s', b.code) end,
              current_date,
              (select min(x.valid_from) from erp.party_role_terms x
                where x.tenant_id = v_tenant and x.party_role_id = v_role and x.entity_id = v_entity
                  and x.valid_from > current_date))
      returning id into v_id;
      v_terms := v_terms || v_id;
    end loop;

    for a in select e from jsonb_array_elements(coalesce(r.raw -> 'addresses', '[]'::jsonb)) e loop
      continue when exists (select 1 from erp.party_address pa
                             where pa.tenant_id = v_tenant and pa.party_id = v_party and pa.is_default
                               and pa.address_kind::text = a ->> 'kind');
      v_id := erp.record_party_address(v_party, a ->> 'kind',
        array(select btrim(l #>> '{}') from jsonb_array_elements(a -> 'lines') l
              union all select btrim(a ->> 'region') where coalesce(btrim(a ->> 'region'), '') <> ''),
        a ->> 'locality', a ->> 'postcode', a ->> 'country_code');
      v_addrs := v_addrs || v_id;
    end loop;

    if r.raw ? 'contact' and not exists (
        select 1 from erp.party_contact pc where pc.tenant_id = v_tenant and pc.party_id = v_party and pc.is_default) then
      insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, phone, is_default)
      values (v_tenant, v_party, 'commercial',
              nullif(btrim(r.raw -> 'contact' ->> 'name'), ''),
              nullif(btrim(r.raw -> 'contact' ->> 'email'), ''),
              nullif(btrim(r.raw -> 'contact' ->> 'phone'), ''), true)
      returning id into v_id;
      v_contacts := v_contacts || v_id;
    end if;

    insert into erp.import_crosswalk
      (tenant_id, import_batch_id, source_system, object_type, legacy_key, legacy_name, clove_code, resolution)
    values (v_tenant, p_batch_id, r.raw ->> 'source', 'party', btrim(r.raw ->> 'legacy_key'),
            nullif(btrim(r.raw ->> 'name'), ''), btrim(r.raw ->> 'code'),
            case when v_created then 'create' else 'map' end);

    update erp.import_row
       set target_id = v_party, loaded = true, before_snapshot = null,
           loaded_ref = jsonb_build_object('party_id', v_party, 'created', v_created,
                                           'roles', to_jsonb(v_roles), 'terms', to_jsonb(v_terms),
                                           'addresses', to_jsonb(v_addrs), 'contacts', to_jsonb(v_contacts)),
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

revoke all on function erp.load_party_profile_import(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Roll back: exactly what was added, and only while nothing else has joined it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.rollback_party_profile_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_party  uuid;
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

  -- A party the batch made may carry nothing the batch did not give it; a role
  -- the batch added may carry no terms it did not add. Anything else is
  -- somebody's work since, and a cascade would take it without asking.
  select string_agg(distinct p.code, ', ') into v_in_use
    from erp.import_row x
    join erp.party p on p.tenant_id = x.tenant_id and p.id = (x.loaded_ref ->> 'party_id')::uuid
   where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded
     and (
       ((x.loaded_ref ->> 'created')::boolean and (
          exists (select 1 from erp.party_role pr where pr.tenant_id = v_tenant and pr.party_id = p.id
                   and not (to_jsonb(pr.id::text) <@ (x.loaded_ref -> 'roles')))
          or exists (select 1 from erp.party_address pa where pa.tenant_id = v_tenant and pa.party_id = p.id
                   and not (to_jsonb(pa.id::text) <@ (x.loaded_ref -> 'addresses')))
          or exists (select 1 from erp.party_contact pc where pc.tenant_id = v_tenant and pc.party_id = p.id
                   and not (to_jsonb(pc.id::text) <@ (x.loaded_ref -> 'contacts')))
          or exists (select 1 from erp.match_tolerance mt where mt.tenant_id = v_tenant and mt.party_id = p.id)
          or exists (select 1 from erp.receipt_tolerance rt where rt.tenant_id = v_tenant and rt.party_id = p.id)))
       or exists (select 1 from erp.party_role_terms tt
                   where tt.tenant_id = v_tenant
                     and to_jsonb(tt.party_role_id::text) <@ (x.loaded_ref -> 'roles')
                     and not (to_jsonb(tt.id::text) <@ (x.loaded_ref -> 'terms'))));
  if v_in_use is not null then
    raise exception 'CLOVEERP_PARTY_IMPORT_IN_USE: % carry records added since the batch loaded, so the batch stands', v_in_use
      using errcode = '23503',
            hint = 'Remove what was added to those parties since, or leave the batch and correct the parties on the desk.';
  end if;

  begin
    for r in select * from erp.import_row x
              where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.loaded
              order by x.row_no desc loop
      v_party := (r.loaded_ref ->> 'party_id')::uuid;

      select coalesce(array_agg(e::uuid), '{}') into v_ids from jsonb_array_elements_text(r.loaded_ref -> 'contacts') e;
      delete from erp.party_contact c where c.tenant_id = v_tenant and c.id = any (v_ids);
      select coalesce(array_agg(e::uuid), '{}') into v_ids from jsonb_array_elements_text(r.loaded_ref -> 'addresses') e;
      delete from erp.party_address c where c.tenant_id = v_tenant and c.id = any (v_ids);
      select coalesce(array_agg(e::uuid), '{}') into v_ids from jsonb_array_elements_text(r.loaded_ref -> 'terms') e;
      delete from erp.party_role_terms c where c.tenant_id = v_tenant and c.id = any (v_ids);
      select coalesce(array_agg(e::uuid), '{}') into v_ids from jsonb_array_elements_text(r.loaded_ref -> 'roles') e;
      delete from erp.party_role c where c.tenant_id = v_tenant and c.id = any (v_ids);
      if (r.loaded_ref ->> 'created')::boolean then
        delete from erp.party p where p.tenant_id = v_tenant and p.id = v_party;
      end if;
      v_n := v_n + 1;
    end loop;
  exception when foreign_key_violation then
    raise exception 'CLOVEERP_PARTY_IMPORT_IN_USE: a party % loaded is already used on a document or in the ledgers, so the batch stands', b.code
      using errcode = '23503',
            hint = 'Correct the party on the desk; a party with history is not removed.';
  end;

  update erp.import_row set loaded = false, target_id = null, updated_at = now()
   where tenant_id = v_tenant and import_batch_id = p_batch_id;
  update erp.import_batch set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.rollback_party_profile_import(uuid) from public, anon, authenticated;

-- The upload screen's contacts now load as party_profile rows, which write their
-- own crosswalk entries as they load. The door that staged names beside a bare
-- party batch stays for a caller loading parties through the API that way.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_stage_import_crosswalk', 'integration', null,
   'Stages legacy name to party code entries beside a bare party import batch, for an integration that loads parties through the API. The upload screen loads contacts as party_profile rows instead, which write their own entries (20261003700000).')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.party_profile_suite()
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
  v_new    text := 'ZZPN' || upper(v_tag);
  v_old    text := 'ZZPO' || upper(v_tag);
  v_oldid  uuid;
  v_oldaddr uuid;
  v_before jsonb;
  v_good   uuid; v_bad uuid; v_cred uuid; v_b uuid;
  v_n      integer;
  v_err    text;
  v_p      erp.party%rowtype;
  v_role_perm boolean;
begin
  begin
    v_step := 'an organisation with its administrator signed in';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant(
      'ppa-' || v_tag, 'Party Profile Suite', 'a@pp-' || v_tag || '.test', 'A Admin');
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'a@pp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);

    -- A party that already exists, as a person keyed it: a customer on NET30
    -- with a billing address.
    v_oldid := erp.create_party(v_old, 'Kept Name Ltd', array['customer']::erp.party_role_kind[], 'GB');
    v_oldaddr := erp.record_party_address(v_oldid, 'billing', array['1 Old Street'], 'Leeds', 'LS1 1AA', 'GB');
    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, payment_terms_code, valid_from)
    select ra.tenant_id, pr.id, ra.entity_id, 'GBP', 'NET30', current_date
      from erp.party_role pr where pr.party_id = v_oldid and pr.role_kind = 'customer';
    select jsonb_build_object(
             'party', (select to_jsonb(p) - 'updated_at' - 'updated_by' from erp.party p where p.id = v_oldid),
             'roles', (select count(*) from erp.party_role x where x.party_id = v_oldid),
             'addresses', (select jsonb_agg(x.id order by x.id) from erp.party_address x where x.party_id = v_oldid),
             'contacts', (select count(*) from erp.party_contact x where x.party_id = v_oldid),
             'terms', (select jsonb_agg(t.payment_terms_code) from erp.party_role_terms t
                         join erp.party_role pr on pr.id = t.party_role_id where pr.party_id = v_oldid))
      into v_before;

    -- 1. A whole contact validates clean; an existing one is an update.
    v_step := 'staging a good batch';
    v_good := erp.stage_import('party_profile', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_key', 'New Customer ' || v_tag, 'code', v_new,
        'name', 'New Customer ' || v_tag, 'tax_identifier', 'GB123456789', 'country_code', 'GB',
        'roles', jsonb_build_array('customer'),
        'addresses', jsonb_build_array(
          jsonb_build_object('kind', 'billing', 'lines', jsonb_build_array('Unit 4', 'Mill Lane'), 'locality', 'Leeds', 'postcode', 'ls1 4ab', 'country_code', 'GB'),
          jsonb_build_object('kind', 'delivery', 'lines', jsonb_build_array('Dock 2'), 'postcode', 'LS2 2BB', 'region', 'West Yorkshire')),
        'contact', jsonb_build_object('name', 'Hannah Smith', 'email', 'hannah@new.test', 'phone', '0113 496 0000'),
        'customer_terms', jsonb_build_object('payment_terms_code', 'NET60')),
      jsonb_build_object('source', 'unleashed', 'legacy_key', v_old, 'code', v_old, 'name', 'Renamed In File',
        'roles', jsonb_build_array('customer', 'supplier'),
        'addresses', jsonb_build_array(
          jsonb_build_object('kind', 'billing', 'lines', jsonb_build_array('9 New Street'), 'locality', 'York'),
          jsonb_build_object('kind', 'delivery', 'lines', jsonb_build_array('Yard 1'), 'locality', 'York')),
        'customer_terms', jsonb_build_object('payment_terms_code', 'NET60'),
        'supplier_terms', jsonb_build_object('payment_terms_code', 'EOM30', 'currency', 'EUR'))),
      'PPG-' || v_tag, 'suite');
    v_n := erp.validate_import(v_good);
    v_cases := v_cases + 1;
    case_name := 'a whole contact validates clean, and one that exists is an update with its differences said';
    passed := v_n = 0
      and (select r.action from erp.import_row r where r.import_batch_id = v_good and r.row_no = 1) = 'insert'
      and (select r.action from erp.import_row r where r.import_batch_id = v_good and r.row_no = 2) = 'update'
      and (select count(*) from erp.import_row r, jsonb_array_elements(r.findings) f
            where r.import_batch_id = v_good and r.row_no = 2 and f ->> 'severity' = 'warning') = 2;
    detail := coalesce((select string_agg(r.row_no || ': ' || r.findings::text, '; ') from erp.import_row r where r.import_batch_id = v_good), 'no rows');
    return next;

    -- 2. Every wrong field is refused.
    v_step := 'validating a bad batch';
    v_bad := erp.stage_import('party_profile', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_key', 'b1', 'code', 'ZZB1' || v_tag, 'name', 'B1', 'roles', jsonb_build_array('customer'),
                         'customer_terms', jsonb_build_object('payment_terms_code', 'NET20')),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b2', 'code', 'ZZB2' || v_tag, 'name', 'B2', 'roles', jsonb_build_array('supplier'),
                         'supplier_terms', jsonb_build_object('currency', 'QQQ')),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b3', 'code', 'ZZB3' || v_tag, 'name', 'B3',
                         'addresses', jsonb_build_array(jsonb_build_object('kind', 'billing', 'lines', jsonb_build_array('1 Road'), 'locality', 'X', 'country_code', 'QQ'))),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b4', 'code', 'ZZB4' || v_tag, 'name', 'B4',
                         'contact', jsonb_build_object('email', 'not-an-email')),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b5', 'code', 'ZZB5' || v_tag, 'name', 'B5', 'roles', jsonb_build_array('customer'),
                         'customer_terms', jsonb_build_object('credit_limit_minor', -5)),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b6', 'code', 'ZZB6' || v_tag, 'name', 'B6',
                         'customer_terms', jsonb_build_object('payment_terms_code', 'NET30')),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b7', 'code', 'ZZB7' || v_tag, 'name', 'B7', 'roles', jsonb_build_array('carrier')),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b8', 'code', 'ZZB8' || v_tag, 'name', 'B8',
                         'addresses', jsonb_build_array(jsonb_build_object('kind', 'delivery', 'lines', jsonb_build_array(''), 'locality', 'X'))),
      jsonb_build_object('source', 'xero', 'legacy_key', 'b1', 'code', 'ZZB1' || v_tag, 'name', 'B1 again')),
      'PPB-' || v_tag, 'suite');
    v_n := erp.validate_import(v_bad);
    v_cases := v_cases + 1;
    case_name := 'an unknown term, currency or country, a bad email, a negative limit, terms without the role, an unknown role, an address without a first line and a repeated contact are each refused';
    passed := v_n = 9 and (select bool_and(r.action = 'reject') from erp.import_row r where r.import_batch_id = v_bad);
    detail := coalesce((select string_agg(r.row_no || ': ' || coalesce((select string_agg(f ->> 'message', ' / ') from jsonb_array_elements(r.findings) f where f ->> 'severity' = 'error'), 'none'), '; ' order by r.row_no)
                          from erp.import_row r where r.import_batch_id = v_bad), 'no rows');
    return next;

    -- 3. Loaded, the new party is whole and a draft.
    v_step := 'loading the good batch';
    perform erp.preview_import(v_good);
    v_n := erp.load_import(v_good);
    select * into v_p from erp.party p where p.tenant_id = ra.tenant_id and p.code = v_new;
    v_cases := v_cases + 1;
    case_name := 'a new party arrives whole, as a draft: its role, both addresses, its contact, its terms and its crosswalk entry';
    passed := v_n = 2 and v_p.status::text = 'draft' and v_p.tax_identifier = 'GB123456789'
      and exists (select 1 from erp.party_role x where x.party_id = v_p.id and x.role_kind = 'customer')
      and (select count(*) from erp.party_address x where x.party_id = v_p.id and x.is_default) = 2
      and exists (select 1 from erp.party_address x where x.party_id = v_p.id and x.address_kind = 'delivery'
                     and x.lines = array['Dock 2', 'West Yorkshire'])
      and exists (select 1 from erp.party_contact x where x.party_id = v_p.id and x.is_default and x.email = 'hannah@new.test')
      and exists (select 1 from erp.party_role_terms t join erp.party_role pr on pr.id = t.party_role_id
                   where pr.party_id = v_p.id and t.payment_terms_code = 'NET60' and t.payment_days = 60
                     and t.currency is not distinct from (select e.base_currency from erp.entity e where e.id = ra.entity_id))
      and erp.import_crosswalk('xero', 'party') @> jsonb_build_array(jsonb_build_object('clove_code', v_new, 'resolution', 'create'));
    detail := format('%s row(s), party %s', v_n, coalesce(v_p.status::text, 'missing'));
    return next;

    -- 4. The existing party gains what it lacked and keeps what it had.
    v_cases := v_cases + 1;
    case_name := 'a party that exists gains the supplier role, supplier terms and a delivery address, and keeps its name, its billing address and its NET30 terms';
    passed := (select to_jsonb(p) - 'updated_at' - 'updated_by' from erp.party p where p.id = v_oldid) = v_before -> 'party'
      and exists (select 1 from erp.party_address x where x.id = v_oldaddr and x.is_default and x.valid_to is null)
      and exists (select 1 from erp.party_address x where x.party_id = v_oldid and x.address_kind = 'delivery')
      and exists (select 1 from erp.party_role x where x.party_id = v_oldid and x.role_kind = 'supplier')
      and (select t.payment_terms_code from erp.party_role_terms t join erp.party_role pr on pr.id = t.party_role_id
            where pr.party_id = v_oldid and pr.role_kind = 'customer') = 'NET30'
      and (select t.currency || ' ' || t.payment_terms_code from erp.party_role_terms t join erp.party_role pr on pr.id = t.party_role_id
            where pr.party_id = v_oldid and pr.role_kind = 'supplier') = 'EUR EOM30';
    detail := (select jsonb_build_object('roles', count(*))::text from erp.party_role x where x.party_id = v_oldid);
    return next;

    -- 5. A credit limit needs the permission the desk asks for.
    v_step := 'loading a credit limit without sales.credit_release';
    v_cred := erp.stage_import('party_profile', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_key', 'credit ' || v_tag, 'code', 'ZZPC' || upper(v_tag), 'name', 'Credit Ltd',
        'roles', jsonb_build_array('customer'), 'customer_terms', jsonb_build_object('credit_limit_minor', 500000))),
      'PPC-' || v_tag, 'suite');
    perform erp.validate_import(v_cred);
    perform erp.preview_import(v_cred);
    delete from erp.role_permission rp where rp.tenant_id = ra.tenant_id and rp.role_id = ra.role_id
       and rp.permission_code = 'sales.credit_release';
    v_err := null;
    begin
      perform erp.load_import(v_cred);
    exception when others then v_err := left(sqlerrm, 200); end;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (ra.tenant_id, ra.role_id, 'sales.credit_release') on conflict do nothing;
    v_n := erp.load_import(v_cred);
    v_cases := v_cases + 1;
    case_name := 'a credit limit is refused to somebody who may not release credit, and loads for somebody who may';
    passed := v_err like 'CLOVEERP_PERMISSION_DENIED:%sales.credit_release%' and v_n = 1
      and exists (select 1 from erp.party_role_terms t join erp.party_role pr on pr.id = t.party_role_id
                    join erp.party p on p.id = pr.party_id
                   where p.code = 'ZZPC' || upper(v_tag) and t.credit_limit_minor = 500000 and t.credit_reason like 'Imported with%');
    detail := coalesce(v_err, 'it loaded without the permission');
    return next;

    -- 6. Something added to an imported party since keeps the batch standing.
    v_step := 'adding a contact to the imported party';
    insert into erp.party_contact (tenant_id, party_id, contact_kind, name, is_default)
    values (ra.tenant_id, v_p.id, 'commercial', 'Added Later', false);
    v_err := null;
    begin
      perform erp.rollback_import(v_good);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a batch whose party has gained a record since it loaded cannot be rolled back';
    passed := v_err like 'CLOVEERP_PARTY_IMPORT_IN_USE:%'
      and (select b.status::text from erp.import_batch b where b.id = v_good) = 'loaded';
    detail := coalesce(v_err, 'it rolled back');
    return next;

    -- 7. Nor may a party the batch made be rolled back once a later record hangs off its role.
    v_step := 'adding terms to the imported role';
    delete from erp.party_contact x where x.party_id = v_p.id and x.name = 'Added Later';
    -- Terms that ended before the batch's began: history on the role, which
    -- no exclusion refuses and a cascade would silently take.
    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, payment_terms_code, valid_from, valid_to)
    select ra.tenant_id, pr.id, ra.entity_id, 'GBP', 'NET7', current_date - 10, current_date
      from erp.party_role pr where pr.party_id = v_oldid and pr.role_kind = 'supplier';
    v_err := null;
    begin
      perform erp.rollback_import(v_good);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a role the batch added that has since gained terms keeps the batch standing';
    passed := v_err like 'CLOVEERP_PARTY_IMPORT_IN_USE:%';
    detail := coalesce(v_err, 'it rolled back');
    return next;

    -- 8. With those removed, rollback takes exactly what the batch added.
    v_step := 'rolling back';
    delete from erp.party_role_terms t using erp.party_role pr
     where pr.id = t.party_role_id and pr.party_id = v_oldid and pr.role_kind = 'supplier' and t.payment_terms_code = 'NET7';
    perform erp.rollback_import(v_good);
    v_cases := v_cases + 1;
    case_name := 'rolling back removes the new party and everything added to the old one, and leaves the old one as it was';
    passed := not exists (select 1 from erp.party p where p.tenant_id = ra.tenant_id and p.code = v_new)
      and jsonb_build_object(
             'party', (select to_jsonb(p) - 'updated_at' - 'updated_by' from erp.party p where p.id = v_oldid),
             'roles', (select count(*) from erp.party_role x where x.party_id = v_oldid),
             'addresses', (select jsonb_agg(x.id order by x.id) from erp.party_address x where x.party_id = v_oldid),
             'contacts', (select count(*) from erp.party_contact x where x.party_id = v_oldid),
             'terms', (select jsonb_agg(t.payment_terms_code) from erp.party_role_terms t
                         join erp.party_role pr on pr.id = t.party_role_id where pr.party_id = v_oldid)) = v_before
      and not exists (select 1 from erp.import_crosswalk x where x.import_batch_id = v_good);
    detail := format('batch is %s', (select b.status::text from erp.import_batch b where b.id = v_good));
    return next;

    -- 9. The import doors refuse somebody who may not write master data.
    v_step := 'loading without master_data.write';
    v_b := erp.stage_import('party_profile', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_key', 'w ' || v_tag, 'code', 'ZZPW' || upper(v_tag), 'name', 'Write Ltd')),
      'PPW-' || v_tag, 'suite');
    perform erp.validate_import(v_b);
    perform erp.preview_import(v_b);
    delete from erp.role_permission rp where rp.tenant_id = ra.tenant_id and rp.role_id = ra.role_id
       and rp.permission_code = 'master_data.write';
    v_err := null;
    begin
      perform erp.load_import(v_b);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'loading parties needs master_data.write as well as the import permission';
    passed := v_err like 'CLOVEERP_PERMISSION_DENIED:%master_data.write%'
      and not exists (select 1 from erp.party p where p.tenant_id = ra.tenant_id and p.code = 'ZZPW' || upper(v_tag));
    detail := coalesce(v_err, 'it loaded');
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
    raise exception 'CLOVEERP_PARTY_PROFILE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'ppa-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_PARTY_PROFILE_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.party_profile_suite() from public, anon, authenticated;

create or replace function erp_test.assert_party_profile_suite()
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
    from erp_test.party_profile_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PARTY_PROFILE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An import would change a party it should only add to, load a limit the desk would refuse, or roll back somebody''s later work. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_PARTY_PROFILE_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('party profile: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_party_profile_suite() from public, anon;

comment on function erp_test.assert_party_profile_suite() is
  'A customer arrives whole, a party that exists only gains, and rollback takes exactly what was added (20261003700000).';

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
