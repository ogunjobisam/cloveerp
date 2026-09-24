set lock_timeout = '30s';

-- =============================================================================
-- 20260924200000  An invoice's legal details are set from the desk
-- -----------------------------------------------------------------------------
-- A sales invoice is refused at issue without the issuing company's
-- registration number and registered office, its VAT number when it is
-- VAT-registered, and the customer's invoice address
-- (erp.validate_sales_invoice_issue). No public door wrote any of them: only
-- the demonstration's configuration and the suites' fixtures did. So an
-- organisation set up from the desk could not issue its first invoice, which
-- the order-to-cash walk found (20260924100000) and papered over with a
-- fixture.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp_set_company_invoice_details: a company's registration number, its
--     registered office and its VAT number, on the Organisation screen,
--     against administration.configure, as a company is created.
--   * erp_set_party_address: a business partner's address of one kind
--     (billing, delivery and the rest), on the Common data screen, against
--     master_data.write, as a partner is created.
--
-- An address is never overwritten: a new one of the same kind becomes the
-- default and the one before it is kept, marked no longer the default and
-- ended, so an invoice already issued still says where it was sent. A
-- company's own address and its registered office are set only with its
-- invoice details, against administration.configure: the partner door
-- refuses them (found on review). A VAT number given for a company already
-- registered corrects that registration's number; for one not registered it
-- registers the company from the date given, never over a registration that
-- has ended nor over invoices already issued without VAT. Deregistering, and
-- a new registration replacing one, are not doors here.
--
-- The order-to-cash walk now sets these through the doors, as a person would.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals, in plain words
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_INVOICE_DETAILS_EMPTY',
  'Setting a company''s invoice details with nothing to set.',
  'Nothing was given: no registration number, no registered office and no VAT number.',
  'Give the company''s registration number, its registered office, its VAT number, or any of them.');

select erp.register_refusal('CLOVEERP_ADDRESS_INCOMPLETE',
  'Recording an address with no first line, or no town and no postcode.',
  'An address an invoice or a delivery can be sent to needs a first line and a town or a postcode.',
  'Give the first line of the address and its town or postcode.');

select erp.register_refusal('CLOVEERP_COMPANY_ADDRESS_ELSEWHERE',
  'Recording a company''s own address, or a registered office, as a business partner''s address.',
  'A company''s registered office is printed on every invoice it issues, so it is set with the company''s invoice details, by somebody who may configure the organisation.',
  'Set it on the Organisation screen with Set a company''s invoice details.');

select erp.register_refusal('CLOVEERP_UNKNOWN_COUNTRY',
  'Recording an address in a country the product does not list.',
  'An address names its country by its two-letter code, one of the countries the product lists.',
  'Choose the country from the list.');

select erp.register_refusal('CLOVEERP_PARTNER_MERGED',
  'Recording an address for a business partner merged into another.',
  'A merged partner''s documents and details belong to the partner it was merged into.',
  'Record the address on the partner it was merged into.');

select erp.register_refusal('CLOVEERP_VAT_DATE_DISAGREES',
  'Registering a company for VAT from a date that disagrees with the registration it already has.',
  'The company is already registered, or will be, from another date, and one company holds one VAT registration at a time.',
  'Leave the date empty to correct the number of the registration it has, or give the date that registration starts.');

select erp.register_refusal('CLOVEERP_VAT_BACKDATED_OVER_ISSUED',
  'Registering a company for VAT from a date its invoices were already issued after, without VAT.',
  'An invoice issued is not changed, and those invoices were issued as from a company not registered for VAT.',
  'Register the company from the day after its last invoice issued, and credit and reissue any invoice that should have carried VAT.');

select erp.register_refusal('CLOVEERP_ADDRESS_KIND_UNKNOWN',
  'Recording an address of a kind the product does not know.',
  'An address is a billing, delivery, collection, remittance, returns or registered address.',
  'Choose one of those kinds.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. One address kept, the one before it kept too
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.record_party_address(
  p_party_id uuid, p_address_kind text, p_lines text[], p_locality text,
  p_postcode text, p_country_code text, p_label text default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_lines  text[];
  v_kind   erp.address_kind;
  v_id     uuid;
begin
  begin
    if p_address_kind is null then
      raise invalid_text_representation;
    end if;
    v_kind := p_address_kind::erp.address_kind;
  exception when invalid_text_representation then
    raise exception 'CLOVEERP_ADDRESS_KIND_UNKNOWN: % is not a kind of address', coalesce(p_address_kind, 'nothing')
      using errcode = '22023',
            hint = 'Choose a billing, delivery, collection, remittance, returns or registered address.';
  end;

  select coalesce(array_agg(btrim(l) order by n), '{}'::text[]) into v_lines
    from unnest(coalesce(p_lines, '{}'::text[])) with ordinality u(l, n)
   where coalesce(btrim(l), '') <> '';
  if cardinality(v_lines) = 0
     or (coalesce(btrim(p_locality), '') = '' and coalesce(btrim(p_postcode), '') = '') then
    raise exception 'CLOVEERP_ADDRESS_INCOMPLETE: the address needs a first line and a town or a postcode'
      using errcode = '22023',
            hint = 'Give the first line of the address and its town or postcode.';
  end if;

  if coalesce(btrim(p_country_code), '') <> ''
     and not exists (select 1 from erp_ref.country c where c.code = upper(btrim(p_country_code))) then
    raise exception 'CLOVEERP_UNKNOWN_COUNTRY: % is not a country the product lists', btrim(p_country_code)
      using errcode = '23503', hint = 'Choose the country from the list.';
  end if;

  -- One default of a kind at a time, whoever else is recording one.
  perform 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id for update;

  -- The one before it stays on record: an invoice already issued still says
  -- where it was sent. It is no longer the default, and ends today (an
  -- address's end is the first day it no longer holds); one recorded today
  -- ends tomorrow, having held for its one day, since an address ends after
  -- it begins. The invoice reads the default, whatever the dates say.
  update erp.party_address a
     set is_default = false,
         valid_to = coalesce(a.valid_to, greatest(current_date, a.valid_from + 1)),
         updated_at = now()
   where a.tenant_id = v_tenant and a.party_id = p_party_id
     and a.address_kind = v_kind and a.is_default;

  insert into erp.party_address (tenant_id, party_id, address_kind, label, lines,
                                 locality, postcode, country_code, is_default, valid_from)
  values (v_tenant, p_party_id, v_kind, nullif(btrim(p_label), ''), v_lines,
          nullif(btrim(p_locality), ''), nullif(upper(btrim(p_postcode)), ''),
          nullif(upper(btrim(p_country_code)), '')::character(2), true, current_date)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function erp.record_party_address(uuid, text, text[], text, text, text, text) from public, anon;

comment on function erp.record_party_address(uuid, text, text[], text, text, text, text) is
  'Records a party''s address of one kind as its default, keeping the one before it on '
  'record (20260924200000). Authorises nothing: its doors do.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. A business partner's address
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.set_party_address(
  p_party_id uuid, p_address_kind text, p_lines text[], p_locality text,
  p_postcode text, p_country_code text, p_label text default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'party', p_party_id);

  if not exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id) then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not a business partner of this organisation', p_party_id
      using errcode = '23503', hint = 'Choose a business partner from the list.';
  end if;
  if exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id
                and p.merged_into_id is not null) then
    raise exception 'CLOVEERP_PARTNER_MERGED: this business partner was merged into another'
      using errcode = '23514', hint = 'Record the address on the partner it was merged into.';
  end if;
  -- A company's own address, and a registered office, print on every invoice
  -- it issues: they are set with its invoice details, against
  -- administration.configure, not here against master_data.write (found on
  -- review).
  if p_address_kind = 'registered'
     or exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.party_id = p_party_id) then
    raise exception 'CLOVEERP_COMPANY_ADDRESS_ELSEWHERE: a company''s own address and a registered office are set with the company''s invoice details'
      using errcode = '42501',
            hint = 'Set it on the Organisation screen with Set a company''s invoice details.';
  end if;

  v_id := erp.record_party_address(p_party_id, p_address_kind, p_lines, p_locality,
                                   p_postcode, p_country_code, p_label);
  return jsonb_build_object('address_id', v_id, 'party_id', p_party_id,
                            'address_kind', p_address_kind, 'is_default', true);
end;
$$;

revoke all on function erp.set_party_address(uuid, text, text[], text, text, text, text) from public, anon;

comment on function erp.set_party_address(uuid, text, text[], text, text, text, text) is
  'A business partner''s address of one kind, the one an invoice or a delivery is sent to '
  '(20260924200000). Authorises master_data.write.';

create or replace function public.erp_set_party_address(
  p_party_id uuid, p_address_kind text, p_lines text[], p_locality text,
  p_postcode text, p_country_code text, p_label text default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.set_party_address(p_party_id, p_address_kind, p_lines, p_locality,
                               p_postcode, p_country_code, p_label)
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. A company's invoice details
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.set_company_invoice_details(
  p_entity_code text,
  p_registration_number text default null,
  p_office_lines text[] default null,
  p_office_locality text default null,
  p_office_postcode text default null,
  p_office_country_code text default null,
  p_vat_number text default null,
  p_vat_registered_from date default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  e        erp.entity%rowtype;
  v_party  uuid;
  v_vat    text := nullif(upper(regexp_replace(coalesce(p_vat_number, ''), '\s', '', 'g')), '');
  v_reg    text := nullif(btrim(coalesce(p_registration_number, '')), '');
  v_office boolean := exists (select 1 from unnest(coalesce(p_office_lines, '{}'::text[])) l
                               where coalesce(btrim(l), '') <> '')
                      or coalesce(btrim(p_office_locality), '') <> ''
                      or coalesce(btrim(p_office_postcode), '') <> '';
  v_open   uuid;
  v_open_from date;
  v_from   date;
begin
  select * into e from erp.entity x where x.tenant_id = v_tenant and x.code = p_entity_code;
  perform erp.authorise('administration.configure', e.id, null, null, 'entity', e.id);
  if e.id is null then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not a company of this organisation', coalesce(p_entity_code, 'nothing')
      using errcode = '23503', hint = 'erp_entities() lists the companies by code.';
  end if;

  if v_reg is null and not v_office and v_vat is null then
    raise exception 'CLOVEERP_INVOICE_DETAILS_EMPTY: nothing was given to set for %', e.code
      using errcode = '22023',
            hint = 'Give the company''s registration number, its registered office, its VAT number, or any of them.';
  end if;

  if v_reg is not null then
    update erp.entity x set registration_number = v_reg, updated_at = now()
     where x.tenant_id = v_tenant and x.id = e.id;
  end if;

  if v_office then
    v_party := erp.ensure_entity_party(e.id);
    perform erp.record_party_address(v_party, 'registered', p_office_lines, p_office_locality,
                                     p_office_postcode, coalesce(nullif(btrim(p_office_country_code), ''), e.country_code::text),
                                     'Registered office');
  end if;

  if v_vat is not null then
    -- Registered already, or from a date to come: that registration's number
    -- is corrected, a typing error being the only change a number has here.
    -- An invoice already issued keeps the number it was issued with: its
    -- contract was frozen at issue (erp.document_issue.contract_snapshot). A
    -- new registration, a VAT group joined say, is not a door here.
    select r.id, r.valid_from into v_open, v_open_from
      from erp.entity_tax_registration r
     where r.tenant_id = v_tenant and r.entity_id = e.id
       and upper(r.registration_type) like 'VAT%'
       and (r.valid_to is null or r.valid_to >= current_date)
     order by r.valid_from
     limit 1;
    if v_open is not null then
      if p_vat_registered_from is not null and p_vat_registered_from <> v_open_from then
        raise exception 'CLOVEERP_VAT_DATE_DISAGREES: % is registered for VAT from %, not %',
          e.code, v_open_from, p_vat_registered_from
          using errcode = '23514',
                hint = 'Leave the date empty to correct the number of the registration it has, or give the date that registration starts.';
      end if;
      update erp.entity_tax_registration r
         set registration_number = v_vat, updated_at = now()
       where r.tenant_id = v_tenant and r.id = v_open;
    else
      v_from := coalesce(p_vat_registered_from, current_date);
      -- Not over a registration that has ended, nor over invoices already
      -- issued as from a company not registered for VAT.
      if exists (select 1 from erp.entity_tax_registration r
                  where r.tenant_id = v_tenant and r.entity_id = e.id
                    and upper(r.registration_type) like 'VAT%'
                    and r.valid_to is not null and r.valid_to >= v_from) then
        raise exception 'CLOVEERP_VAT_DATE_DISAGREES: % was registered for VAT until after %', e.code, v_from
          using errcode = '23514',
                hint = 'Leave the date empty to correct the number of the registration it has, or give the date that registration starts.';
      end if;
      if exists (select 1 from erp.document_issue di
                   join erp.document d on d.tenant_id = di.tenant_id and d.id = di.source_document_id
                  where di.tenant_id = v_tenant and d.entity_id = e.id
                    and di.status not in ('voided', 'reserved')
                    and coalesce(d.tax_point, d.document_date) >= v_from) then
        raise exception 'CLOVEERP_VAT_BACKDATED_OVER_ISSUED: % has issued invoices dated on or after %, without VAT', e.code, v_from
          using errcode = '23514',
                hint = 'Register the company from the day after its last invoice issued, and credit and reissue any invoice that should have carried VAT.';
      end if;
      insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                               registration_type, registration_number, valid_from)
      values (v_tenant, e.id, coalesce(e.country_code::text, 'GB'), 'VAT', v_vat, v_from);
    end if;
  end if;

  return jsonb_build_object(
    'entity', e.code,
    'registration_number', (select x.registration_number from erp.entity x where x.tenant_id = v_tenant and x.id = e.id),
    'registered_office_set', v_office,
    -- The registration in force today, or the next to come.
    'vat_number', (select r.registration_number
                     from erp.entity_tax_registration r
                    where r.tenant_id = v_tenant and r.entity_id = e.id
                      and upper(r.registration_type) like 'VAT%'
                      and (r.valid_to is null or r.valid_to >= current_date)
                    order by r.valid_from limit 1));
end;
$$;

revoke all on function erp.set_company_invoice_details(text, text, text[], text, text, text, text, date) from public, anon;

comment on function erp.set_company_invoice_details(text, text, text[], text, text, text, text, date) is
  'A company''s registration number, registered office and VAT number: what its invoices '
  'must carry (20260924200000). Authorises administration.configure.';

create or replace function public.erp_set_company_invoice_details(
  p_entity_code text,
  p_registration_number text default null,
  p_office_lines text[] default null,
  p_office_locality text default null,
  p_office_postcode text default null,
  p_office_country_code text default null,
  p_vat_number text default null,
  p_vat_registered_from date default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.set_company_invoice_details(p_entity_code, p_registration_number, p_office_lines,
                                         p_office_locality, p_office_postcode, p_office_country_code,
                                         p_vat_number, p_vat_registered_from)
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_set_party_address(uuid, text, text[], text, text, text, text)',
    'erp_set_company_invoice_details(text, text, text[], text, text, text, text, date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_party_address', 'erp.set_party_address',
   'Records a business partner''s address of one kind as its default, keeping the one before it; authorises master_data.write.'),
  ('erp_set_company_invoice_details', 'erp.set_company_invoice_details',
   'Sets a company''s registration number, registered office and VAT number, which its invoices must carry; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/master-data', array['erp_set_party_address']);
select erp_meta.add_help_actions('/administration/organisation', array['erp_set_company_invoice_details']);

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The order-to-cash walk sets them as a person would
-- ─────────────────────────────────────────────────────────────────────────────

do $walk$
declare
  v_sig constant text := 'erp_test.order_to_cash_walk()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    -- What an invoice must carry by law: the company's number, registered
    -- office and VAT number, and where the customer is billed. These four
    -- stand in for doors the product does not have yet: no public door
    -- writes a company's registration number, its VAT registration or a
    -- party's address, so an organisation cannot set them from the desk
    -- (found on review, queued as its own task).
    update erp.entity set registration_number = '07123456'
     where tenant_id = r.tenant_id and id = r.entity_id;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines,
                                   locality, postcode, country_code, is_default, valid_from)
    select r.tenant_id, e.party_id, 'registered', 'Registered office',
           array['1 Ledger Way'], 'Leeds', 'LS1 1AA', 'GB', true, current_date
      from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines,
                                   locality, postcode, country_code, is_default, valid_from)
    values (r.tenant_id, v_cust, 'billing', 'Invoice to', array['2 Buyer Street'],
            'York', 'YO1 1AA', 'GB', true, current_date);
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                             registration_type, registration_number, valid_from)
    values (r.tenant_id, r.entity_id, 'GB', 'VAT', 'GB123456789', current_date - 365);
$o$;
  v_new constant text := $n$    -- What an invoice must carry by law: the company's number, registered
    -- office and VAT number, and where the customer is billed, each set
    -- through the door the desk presses (20260924200000).
    perform public.erp_set_company_invoice_details(
      (select e.code from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id),
      '07123456', array['1 Ledger Way'], 'Leeds', 'LS1 1AA', 'GB', 'GB 123 4567 89', current_date - 365);
    perform public.erp_set_party_address(v_cust, 'billing', array['2 Buyer Street'], 'York', 'YO1 1AA', 'GB', 'Invoice to');
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % fixture anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$walk$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. What proves the doors: erp_test.invoice_details_suite()
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.invoice_details_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  s_clerk  uuid := gen_random_uuid();
  r        record;
  res      jsonb;
  u_clerk  uuid;
  v_tok    text;
  v_ecode  text;
  v_cust   uuid;
  v_walk   jsonb;
  v_err    text;
  v_err2   text;
  v_err3   text;
  v_err4   text;
  v_err5   text;
  v_rows   integer;
  v_defaults integer;
  v_old_default boolean;
  v_old_to date;
  v_new_line text;
  v_vat_rows integer;
  v_vat    text;
  v_vat_from date;
  v_reg    text;
  v_office text;
  v_eparty uuid;
  v_merged uuid;
  v_err6   text;
  v_err7   text;
  v_err8   text;
  v_err9   text;
begin
  -- 1. An organisation set up through the doors alone issues its first
  --    invoice: the order-to-cash walk, whose fixture now presses them.
  v_walk := erp_test.order_to_cash_walk();
  return query select 'an organisation whose invoice details were set through the doors alone issues, files and is paid for its first invoice',
    v_walk ->> 'blocked' is null and v_walk ->> 'issue_status' = 'issued' and v_walk ->> 'invoice_state' = 'paid',
    coalesce('blocked at ' || (v_walk ->> 'blocked'), format('issue %s, invoice %s', v_walk ->> 'issue_status', v_walk ->> 'invoice_state'));

  begin
    select * into r from erp.provision_tenant(
      'zz-ids-' || v_hex, 'Invoice details suite',
      'admin@zz-ids-' || v_hex || '.test', 'Details Admin');
    insert into auth.users (id, email)
    values (a1, 'admin@zz-ids-' || v_hex || '.test'), (s_clerk, 'clerk@zz-ids-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    select e.code into v_ecode from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    res := public.erp_invite_principal('clerk@zz-ids-' || v_hex || '.test', 'Cal Clerk');
    u_clerk := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(u_clerk, 'sales', null, null, 'sells, and neither configures nor keeps common data');
    perform set_config('request.jwt.claims', json_build_object('sub', s_clerk)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZIDCUS', 'Details Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active');

    -- 2. Each door is refused to somebody who may not use it.
    perform set_config('request.jwt.claims', json_build_object('sub', s_clerk)::text, true);
    begin
      perform public.erp_set_company_invoice_details(v_ecode, '07123456');
      v_err := 'set';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, 'billing', array['2 Buyer Street'], 'York', 'YO1 1AA', 'GB');
      v_err2 := 'set';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a company''s invoice details need administration.configure, and a partner''s address master_data.write, each refused by name',
      v_err like 'CLOVEERP_PERMISSION_DENIED: administration.configure%'
      and v_err2 like 'CLOVEERP_PERMISSION_DENIED: master_data.write%',
      format('company: %s; address: %s', v_err, v_err2);

    -- 3. A new address of a kind becomes the default; the one before it is
    --    kept, no longer the default, ended (recorded today, it ends tomorrow).
    perform public.erp_set_party_address(v_cust, 'billing', array['2 Buyer Street'], 'York', 'YO1 1AA', 'GB', 'Invoice to');
    perform public.erp_set_party_address(v_cust, 'billing', array['9 New Road', 'Unit 4'], 'Leeds', 'ls2 2bb', 'gb', 'Invoice to');
    select count(*), count(*) filter (where a.is_default) into v_rows, v_defaults
      from erp.party_address a where a.tenant_id = r.tenant_id and a.party_id = v_cust and a.address_kind = 'billing';
    select a.is_default, a.valid_to into v_old_default, v_old_to
      from erp.party_address a where a.tenant_id = r.tenant_id and a.party_id = v_cust
       and a.address_kind = 'billing' and a.lines[1] = '2 Buyer Street';
    select array_to_string(a.lines, ', ') || ' ' || a.postcode || ' ' || a.country_code into v_new_line
      from erp.party_address a where a.tenant_id = r.tenant_id and a.party_id = v_cust
       and a.address_kind = 'billing' and a.is_default;
    return query select 'a new billing address becomes the default and the one before it is kept, no longer the default and ended after its one day',
      v_rows = 2 and v_defaults = 1 and not v_old_default and v_old_to = current_date + 1
      and v_new_line = '9 New Road, Unit 4 LS2 2BB GB',
      format('%s address(es), %s default; the old one default %s, ended %s; the new one %s',
             v_rows, v_defaults, v_old_default, v_old_to, v_new_line);

    -- 4. The company: its number and office; a VAT number registers it from
    --    the date given, and a second corrects that registration; blanks
    --    leave what is there alone.
    perform public.erp_set_company_invoice_details(v_ecode, ' 07123456 ', array['1 Ledger Way'], 'Leeds', 'LS1 1AA', null, null, null);
    perform public.erp_set_company_invoice_details(v_ecode, null, null, null, null, null, 'gb 123 4567 89', current_date - 30);
    perform public.erp_set_company_invoice_details(v_ecode, null, null, null, null, null, 'GB987654321', null);
    select e.registration_number into v_reg from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    select array_to_string(a.lines, ', ') || ' ' || a.locality into v_office
      from erp.party_address a
      join erp.entity e on e.tenant_id = a.tenant_id and e.party_id = a.party_id
     where a.tenant_id = r.tenant_id and e.id = r.entity_id and a.address_kind = 'registered' and a.is_default;
    select count(*), min(t.registration_number), min(t.valid_from) into v_vat_rows, v_vat, v_vat_from
      from erp.entity_tax_registration t
     where t.tenant_id = r.tenant_id and t.entity_id = r.entity_id and t.registration_type = 'VAT';
    return query select 'a company''s number and registered office are set; its VAT number registers it from the date given and a second one corrects that registration; what is left blank is left alone',
      v_reg = '07123456' and v_office = '1 Ledger Way Leeds'
      and v_vat_rows = 1 and v_vat = 'GB987654321' and v_vat_from = current_date - 30,
      format('number %s; office %s; %s VAT registration(s), %s from %s', v_reg, v_office, v_vat_rows, v_vat, v_vat_from);

    -- 5. What cannot be recorded is refused by name.
    begin
      perform public.erp_set_company_invoice_details(v_ecode);
      v_err := 'set';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, 'billing', array['  '], 'York', null, 'GB');
      v_err2 := 'set';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, 'billing', array['3 Lane'], ' ', '', 'GB');
      v_err3 := 'set';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, 'holiday', array['3 Lane'], 'York', null, 'GB');
      v_err4 := 'set';
    exception when others then v_err4 := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_company_invoice_details('ZZ-NO-SUCH', '1');
      v_err5 := 'set';
    exception when others then v_err5 := left(sqlerrm, 200); end;
    return query select 'nothing to set, an address with no first line or with neither town nor postcode, an unknown kind and an unknown company are each refused by name',
      v_err like 'CLOVEERP_INVOICE_DETAILS_EMPTY:%'
      and v_err2 like 'CLOVEERP_ADDRESS_INCOMPLETE:%'
      and v_err3 like 'CLOVEERP_ADDRESS_INCOMPLETE:%'
      and v_err4 like 'CLOVEERP_ADDRESS_KIND_UNKNOWN:%'
      and v_err5 like 'CLOVEERP_UNKNOWN_ENTITY:%',
      format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5);

    -- 6. The partner door does not reach the company's own address, nor a
    --    registered office, nor a merged partner; a null kind and an unknown
    --    country are refused by name.
    select e.party_id into v_eparty from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    insert into erp.party (tenant_id, code, name, status, merged_into_id)
    values (r.tenant_id, 'ZIDOLD', 'Details Suite Merged Customer', 'inactive', v_cust) returning id into v_merged;
    begin
      perform public.erp_set_party_address(v_eparty, 'billing', array['99 Fake Street'], 'York', null, 'GB');
      v_err := 'set';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, 'registered', array['99 Fake Street'], 'York', null, 'GB');
      v_err2 := 'set';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_merged, 'billing', array['3 Lane'], 'York', null, 'GB');
      v_err3 := 'set';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, null, array['3 Lane'], 'York', null, 'GB');
      v_err4 := 'set';
    exception when others then v_err4 := left(sqlerrm, 200); end;
    begin
      perform public.erp_set_party_address(v_cust, 'billing', array['3 Lane'], 'York', null, 'GBR');
      v_err6 := 'set';
    exception when others then v_err6 := left(sqlerrm, 200); end;
    return query select 'the partner door refuses the company''s own address, a registered office and a merged partner, and a missing kind and an unknown country, each by name',
      v_err like 'CLOVEERP_COMPANY_ADDRESS_ELSEWHERE:%'
      and v_err2 like 'CLOVEERP_COMPANY_ADDRESS_ELSEWHERE:%'
      and v_err3 like 'CLOVEERP_PARTNER_MERGED:%'
      and v_err4 like 'CLOVEERP_ADDRESS_KIND_UNKNOWN:%'
      and v_err6 like 'CLOVEERP_UNKNOWN_COUNTRY:%'
      and (select count(*) from erp.party_address a where a.tenant_id = r.tenant_id and a.party_id = v_eparty
             and a.lines[1] = '99 Fake Street') = 0,
      format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err6);

    -- 7. A VAT date that disagrees with the registration held is refused,
    --    and a registration is never laid over one that has ended.
    begin
      perform public.erp_set_company_invoice_details(v_ecode, null, null, null, null, null, 'GB987654321', current_date - 400);
      v_err7 := 'set';
    exception when others then v_err7 := left(sqlerrm, 200); end;
    update erp.entity_tax_registration t set valid_to = current_date - 5
     where t.tenant_id = r.tenant_id and t.entity_id = r.entity_id;
    begin
      perform public.erp_set_company_invoice_details(v_ecode, null, null, null, null, null, 'GB111111111', current_date - 10);
      v_err8 := 'set';
    exception when others then v_err8 := left(sqlerrm, 200); end;
    res := public.erp_set_company_invoice_details(v_ecode, null, null, null, null, null, 'GB222222222', current_date + 3);
    begin
      perform public.erp_set_company_invoice_details(v_ecode, null, null, null, null, null, 'GB333333333', current_date + 9);
      v_err9 := 'set';
    exception when others then v_err9 := left(sqlerrm, 200); end;
    return query select 'a VAT date that disagrees with the registration held or to come is refused, as is one laid over a registration that has ended; a registration to come is the one a later number corrects',
      v_err7 like 'CLOVEERP_VAT_DATE_DISAGREES:%'
      and v_err8 like 'CLOVEERP_VAT_DATE_DISAGREES:%'
      and v_err9 like 'CLOVEERP_VAT_DATE_DISAGREES:%'
      and res ->> 'vat_number' = 'GB222222222'
      and (select count(*) from erp.entity_tax_registration t
            where t.tenant_id = r.tenant_id and t.entity_id = r.entity_id) = 2,
      format('%s | %s | registered to come %s | %s', v_err7, v_err8, res ->> 'vat_number', v_err9);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-ids-' || v_hex);
  detail := 'the organisation, its people, partner and addresses rolled back';
  return next;
end;
$function$;

create or replace function erp_test.assert_invoice_details_suite()
returns void
language plpgsql
security definer
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
    from erp_test.invoice_details_suite() s;
  if v_total <> 8 then
    raise exception 'CLOVEERP_INVOICE_DETAILS_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_INVOICE_DETAILS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An organisation that cannot set what its invoices must carry cannot issue one. Read the case that failed.';
  end if;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The words the screens say for them
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Invoice details set from the desk (20260924200000).'
  from (values
    ('Set a company''s invoice details'),
    ('The registration number, registered office and VAT number every invoice the company issues must carry. What is left empty keeps what is recorded; an office given replaces the one recorded.'),
    ('Company'),
    ('Company registration number'),
    ('Registered office, first line'),
    ('Registered office, second line'),
    ('Town'),
    ('Postcode'),
    ('Country'),
    ('VAT number'),
    ('VAT registered from'),
    ('For a company not yet registered: the date its registration took effect. Left empty, today.'),
    ('Set a business partner''s address'),
    ('Where invoices, deliveries or remittances go. A new address of the same kind replaces the one before as the default; the old one is kept on record.'),
    ('Business partner'),
    ('Kind of address'),
    ('Billing'),
    ('Delivery'),
    ('Collection'),
    ('Remittance'),
    ('Returns'),
    ('Address, first line'),
    ('Address, second line'),
    ('Label'),
    -- Three the Organisation screen has drawn through ui() with no row, so no
    -- organisation could rename them; the check reads that screen's sites
    -- bar now and found them.
    ('Add a site'),
    ('Kind of site'),
    ('Sites — the places this organisation works from. Stock, receipts and despatches all happen at one.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. What an address carries is printed, not decided on
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.write_only_column (schema_name, table_name, column_name, rationale) values
  ('erp', 'party_address', 'lines',
   'Deliberate. The street lines of an address, carried onto the invoice (erp.sales_invoice_contract) and printed where a person or the post reads them. Nothing is supposed to branch on the words of a street; whether an address is there at all is decided on its locality and postcode (20260924200000).'),
  ('erp', 'party_address', 'postcode',
   'Deliberate. Carried onto the invoice and printed with the address (erp.sales_invoice_contract); nothing prices, routes or taxes by postcode today (20260924200000).'),
  ('erp', 'party_address', 'country_code',
   'Deliberate, for now. Carried onto the invoice and printed with the address (erp.sales_invoice_contract). Where a supply is taxed is decided on the parties'' own country and their VAT registrations, not on an address''s country (20260924200000).'),
  ('erp', 'party_address', 'label',
   'Deliberate. What a person calls the address, such as Accounts payable, shown with it and printed on the invoice; the product is not supposed to branch on a name (20260924200000).')
on conflict do nothing;

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
