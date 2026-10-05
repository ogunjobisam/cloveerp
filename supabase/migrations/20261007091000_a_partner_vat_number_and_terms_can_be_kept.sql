set lock_timeout = '30s';

-- =============================================================================
-- 20261007091000  A business partner's VAT number and payment terms can be kept
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-107). A business
-- partner has a VAT number (erp.party.tax_identifier) and payment terms
-- (erp.party_role_terms.payment_terms_code and payment_days), and no door
-- writes either. The VAT number reaches a partner only through the party
-- file under Imports; it is what a sales invoice prints for the customer and
-- what tax determination reads to tell a registered business from a consumer.
-- Payment terms reach a partner only through the same file and a
-- demonstration's seed. The only door that writes a partner's terms row is
-- erp_set_credit_limit on Sales, and it writes the credit limit alone.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Four refusals: a VAT number that is not one, a VAT number for one of
--      the organisation's own companies, payment terms the list does not
--      hold, and payment terms for a role that neither pays nor is paid. Two
--      registered refusals are widened to say what they now also refuse:
--      CLOVEERP_NOT_A_CUSTOMER (credit, and now payment terms) and
--      CLOVEERP_PARTNER_MERGED (an address, and now a VAT number, payment
--      terms or a contact).
--   B. erp.set_party_tax_identifier and its door
--      public.erp_set_party_tax_identifier. It keeps the number as letters
--      and digits, upper case, without the spaces, dots and dashes people
--      type into it; empty clears it.
--   C. erp.set_party_payment_terms and its door
--      public.erp_set_party_payment_terms, for the customer or the supplier
--      role. It writes the terms row the credit limit door writes, by the
--      same rule: the row in force today, most recently begun, is changed in
--      place, and the credit limit, hold and currency on it are left alone;
--      with no row in force, one is begun today with the organisation's
--      first company and its currency, and ends where a row already dated to
--      begin later begins, so two rows never overlap. payment_days is the
--      number of days the chosen terms give, as the party file writes it.
--      Empty clears the terms and leaves the row.
--   D. public.erp_party_details, which reads a partner's VAT number, whether
--      it is one of the organisation's own companies, and its payment terms
--      in each role, for the partner record on Common data.
--   E. Their write allowances, their place in the screen's help, and the
--      words the record says, and public.erp_payment_terms, the list of
--      payment terms the product holds, for the record to pick from.
--   F. erp_test.party_terms_suite.
--
-- ── THE PERMISSION ───────────────────────────────────────────────────────────
--
-- master_data.write, which governs the party file today: erp_create_party,
-- erp_create_party_with_roles, erp_add_party_role and erp_set_party_address
-- all authorise it. The read authorises master_data.read, which every role
-- that sees Common data holds. A customer's credit limit and hold stay on
-- sales.credit_release, on Sales: setting terms here never touches them.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- A document already raised keeps the tax it was determined with and the due
-- date it was given. A VAT number set or cleared changes how the next
-- determination for that customer reads them, as a number loaded from the
-- party file always has. No bill or invoice reads payment_days yet; this
-- keeps the terms where the party file and the demonstration already keep
-- them.
--
-- On production: three functions, four doors and their registrations are
-- added, and the texts of two registered refusals are widened. No table is
-- altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_TAX_IDENTIFIER_INVALID',
  'Recording a VAT number that is not one: too short, too long, without a digit, or with characters a VAT number does not have.',
  'The VAT number is printed on the invoices the partner receives and tells a registered business from a consumer, so it has to be the number they are registered under.',
  'Type the number as the partner gives it, in letters and digits, such as GB123456789, or leave it empty to clear it.');

select erp.register_refusal('CLOVEERP_COMPANY_VAT_NUMBER_ELSEWHERE',
  'Recording a VAT number on the business partner that stands for one of the organisation''s own companies.',
  'A company''s own VAT number is kept with its invoice details, which print it on every invoice the company issues.',
  'Set it on the Organisation screen with Set a company''s invoice details.');

select erp.register_refusal('CLOVEERP_PAYMENT_TERMS_UNKNOWN',
  'Setting payment terms that are not in the list of payment terms.',
  'Terms are read by their code, and terms the list does not hold say nothing about when a payment is due.',
  'Choose the terms from the list, or leave them empty to clear them.');

select erp.register_refusal('CLOVEERP_PAYMENT_TERMS_ROLE',
  'Setting payment terms for a business partner in a role other than customer or supplier.',
  'Payment terms say when a customer pays the organisation or when the organisation pays a supplier, and no other role pays or is paid.',
  'Choose Customer or Supplier.');

select erp.register_refusal('CLOVEERP_NOT_A_CUSTOMER',
  'Setting credit or payment terms for a business partner who is not a customer.',
  'Credit and payment terms are what a customer may owe and when they pay, and they are kept with the customer''s terms.',
  'Choose a customer, or make the business partner a customer first.');

select erp.register_refusal('CLOVEERP_PARTNER_MERGED',
  'Recording an address, a VAT number, payment terms or a contact for a business partner merged into another.',
  'A merged partner''s documents and details belong to the partner it was merged into.',
  'Record it on the partner it was merged into.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The VAT number
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.set_party_tax_identifier(
  p_party_id       uuid,
  p_tax_identifier text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_raw    text := nullif(btrim(coalesce(p_tax_identifier, '')), '');
  v_vat    text;
  p        erp.party%rowtype;
begin
  -- A business partner's VAT number (20261007091000): letters and digits,
  -- upper case, without the spaces, dots and dashes people type into it.
  -- Empty clears it.
  perform erp.authorise('master_data.write', null, null, null, 'party', p_party_id);

  select * into p from erp.party x
   where x.tenant_id = v_tenant and x.id = p_party_id
     for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not a business partner of this organisation', p_party_id
      using errcode = '23503', hint = 'Choose a business partner from the list.';
  end if;
  if p.merged_into_id is not null then
    raise exception 'CLOVEERP_PARTNER_MERGED: % was merged into another business partner', p.code
      using errcode = '23514', hint = 'Record it on the partner it was merged into.';
  end if;
  if exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.party_id = p_party_id) then
    raise exception 'CLOVEERP_COMPANY_VAT_NUMBER_ELSEWHERE: % is one of this organisation''s own companies', p.code
      using errcode = '42501',
            hint = 'Set it on the Organisation screen with Set a company''s invoice details.';
  end if;

  if v_raw is not null then
    v_vat := upper(regexp_replace(v_raw, '[[:space:].-]+', '', 'g'));
    if v_vat !~ '^[A-Z0-9]{4,20}$' or v_vat !~ '[0-9]' then
      raise exception 'CLOVEERP_TAX_IDENTIFIER_INVALID: % is not a VAT number', v_raw
        using errcode = '23514',
              hint = 'Type the number as the partner gives it, in letters and digits, such as GB123456789, or leave it empty to clear it.';
    end if;
  end if;

  update erp.party x
     set tax_identifier = v_vat, updated_at = now()
   where x.tenant_id = v_tenant and x.id = p_party_id;

  return jsonb_build_object('party_id', p_party_id, 'code', p.code,
                            'tax_identifier', v_vat, 'previous_tax_identifier', p.tax_identifier);
end;
$$;

revoke all on function erp.set_party_tax_identifier(uuid, text) from public, anon;

comment on function erp.set_party_tax_identifier(uuid, text) is
  'Keeps a business partner''s VAT number, as letters and digits in upper case, or clears it (20261007091000). '
  'Refuses a merged partner and one of the organisation''s own companies. Authorises master_data.write.';

create or replace function public.erp_set_party_tax_identifier(
  p_party_id       uuid,
  p_tax_identifier text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.set_party_tax_identifier(p_party_id, p_tax_identifier) $$;

revoke all on function public.erp_set_party_tax_identifier(uuid, text) from public, anon;
grant execute on function public.erp_set_party_tax_identifier(uuid, text) to authenticated, service_role;

comment on function public.erp_set_party_tax_identifier(uuid, text) is
  'Keeps or clears a business partner''s VAT number (20261007091000). Authorises master_data.write.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Payment terms
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.set_party_payment_terms(
  p_party_id           uuid,
  p_role               text,
  p_payment_terms_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_kind   text := lower(btrim(coalesce(p_role, '')));
  v_code   text := nullif(upper(btrim(coalesce(p_payment_terms_code, ''))), '');
  p        erp.party%rowtype;
  v_role   uuid;
  v_term   erp_ref.payment_term%rowtype;
  t        erp.party_role_terms%rowtype;
  v_found  boolean;
  v_was    text;
  v_entity uuid;
  v_ccy    char(3);
  v_next   date;
  v_id     uuid;
begin
  -- When a customer pays, or when a supplier is paid (20261007091000). The
  -- row is the one erp_set_credit_limit writes, chosen by the same rule: the
  -- terms in force today, most recently begun. Its credit limit, hold and
  -- currency are left as they are.
  perform erp.authorise('master_data.write', null, null, null, 'party', p_party_id);

  if v_kind not in ('customer', 'supplier') then
    raise exception 'CLOVEERP_PAYMENT_TERMS_ROLE: payment terms are kept for a customer or a supplier, not for %', nullif(v_kind, '')
      using errcode = '23514', hint = 'Choose Customer or Supplier.';
  end if;

  select * into p from erp.party x where x.tenant_id = v_tenant and x.id = p_party_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not a business partner of this organisation', p_party_id
      using errcode = '23503', hint = 'Choose a business partner from the list.';
  end if;
  if p.merged_into_id is not null then
    raise exception 'CLOVEERP_PARTNER_MERGED: % was merged into another business partner', p.code
      using errcode = '23514', hint = 'Record it on the partner it was merged into.';
  end if;

  select pr.id into v_role
    from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = p_party_id
     and pr.role_kind = v_kind::erp.party_role_kind and pr.status = 'active'
   order by pr.created_at
   limit 1;
  if v_role is null and v_kind = 'customer' then
    raise exception 'CLOVEERP_NOT_A_CUSTOMER: % is not a customer here, so it has no customer terms to set', p.code
      using errcode = '23503',
            hint = 'Choose a customer, or make the business partner a customer first.';
  elsif v_role is null then
    raise exception 'CLOVEERP_NOT_A_SUPPLIER: % does not hold the supplier role', p.code
      using errcode = '23514',
            hint = 'Give the business partner the supplier role first, or choose a supplier.';
  end if;

  if v_code is not null then
    select * into v_term from erp_ref.payment_term pt where pt.code = v_code;
    if not found then
      raise exception 'CLOVEERP_PAYMENT_TERMS_UNKNOWN: % is not in the list of payment terms', v_code
        using errcode = '23514', hint = 'Choose the terms from the list, or leave them empty to clear them.';
    end if;
  end if;

  -- One writer at a time for this role's terms.
  perform pg_advisory_xact_lock(hashtextextended(
    'party_role_terms:' || v_tenant::text || ':' || v_role::text, 0));

  select * into t
    from erp.party_role_terms x
   where x.tenant_id = v_tenant and x.party_role_id = v_role
     and x.valid_from <= current_date
     and (x.valid_to is null or x.valid_to > current_date)
   order by x.valid_from desc
   limit 1
     for update;
  v_found := found;

  if v_found then
    v_was := t.payment_terms_code;
    v_id := t.id;
    update erp.party_role_terms x
       set payment_terms_code = v_code,
           payment_days = case when v_code is null then null else v_term.net_days end,
           updated_at = now()
     where x.tenant_id = v_tenant and x.id = t.id;
  elsif v_code is not null then
    select en.id, en.base_currency into v_entity, v_ccy
      from erp.entity en
     where en.tenant_id = v_tenant and en.status = 'active'
     order by en.code
     limit 1;
    if v_entity is null then
      raise exception 'CLOVEERP_NO_ENTITY: this organisation has no company to keep a business partner''s terms with'
        using errcode = '23503',
              hint = 'Set up the organisation''s company first, then set the business partner''s terms.';
    end if;

    -- Terms already dated to begin later end this row where they begin.
    select min(x.valid_from) into v_next
      from erp.party_role_terms x
     where x.tenant_id = v_tenant and x.party_role_id = v_role
       and x.entity_id = v_entity and x.valid_from > current_date;

    insert into erp.party_role_terms
      (tenant_id, party_role_id, entity_id, currency, payment_terms_code, payment_days, valid_from, valid_to)
    values
      (v_tenant, v_role, v_entity, v_ccy, v_code, v_term.net_days, current_date, v_next)
    returning id into v_id;
  end if;

  return jsonb_build_object(
    'party_id', p_party_id, 'code', p.code, 'role', v_kind, 'terms_id', v_id,
    'payment_terms_code', v_code, 'payment_terms_name', v_term.name,
    'payment_days', case when v_code is null then null else v_term.net_days end,
    'previous_payment_terms_code', v_was);
end;
$$;

revoke all on function erp.set_party_payment_terms(uuid, text, text) from public, anon;

comment on function erp.set_party_payment_terms(uuid, text, text) is
  'Sets or clears the payment terms of a business partner as a customer or as a supplier (20261007091000), on the '
  'terms row in force today, most recently begun, or on one begun today that ends where later terms begin. The '
  'credit limit and hold on the row are left alone. Authorises master_data.write.';

create or replace function public.erp_set_party_payment_terms(
  p_party_id           uuid,
  p_role               text,
  p_payment_terms_code text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.set_party_payment_terms(p_party_id, p_role, p_payment_terms_code) $$;

revoke all on function public.erp_set_party_payment_terms(uuid, text, text) from public, anon;
grant execute on function public.erp_set_party_payment_terms(uuid, text, text) to authenticated, service_role;

comment on function public.erp_set_party_payment_terms(uuid, text, text) is
  'Sets or clears a business partner''s payment terms as a customer or a supplier (20261007091000). '
  'Authorises master_data.write.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Reading them
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_party_details(p_party_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  p        erp.party%rowtype;
begin
  -- A business partner's VAT number and payment terms, for its record on
  -- Common data (20261007091000).
  perform erp.authorise('master_data.read', null, null, null, 'party', p_party_id);

  select * into p from erp.party x where x.tenant_id = v_tenant and x.id = p_party_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not a business partner of this organisation', p_party_id
      using errcode = '23503', hint = 'Choose a business partner from the list.';
  end if;

  return jsonb_build_object(
    'party_id', p.id,
    'code', p.code,
    'tax_identifier', p.tax_identifier,
    'is_company', exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.party_id = p.id),
    'is_merged', p.merged_into_id is not null,
    'terms', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role', pr.role_kind::text,
               'payment_terms_code', t.payment_terms_code,
               'payment_terms_name', pt.name,
               'payment_days', t.payment_days,
               'valid_from', t.valid_from,
               'valid_to', t.valid_to)
             order by pr.role_kind::text)
        from erp.party_role pr
        left join lateral (
          select x.payment_terms_code, x.payment_days, x.valid_from, x.valid_to
            from erp.party_role_terms x
           where x.tenant_id = pr.tenant_id and x.party_role_id = pr.id
             and x.valid_from <= current_date
             and (x.valid_to is null or x.valid_to > current_date)
           order by x.valid_from desc
           limit 1) t on true
        left join erp_ref.payment_term pt on pt.code = t.payment_terms_code
       where pr.tenant_id = v_tenant and pr.party_id = p.id
         and pr.status = 'active'
         and pr.role_kind in ('customer', 'supplier')), '[]'::jsonb));
end;
$$;

revoke all on function public.erp_party_details(uuid) from public, anon;
grant execute on function public.erp_party_details(uuid) to authenticated, service_role;

comment on function public.erp_party_details(uuid) is
  'A business partner''s VAT number and its payment terms in force as a customer and as a supplier '
  '(20261007091000). Authorises master_data.read.';

create or replace function public.erp_payment_terms()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The payment terms the product lists, for Set payment terms to pick from
  -- (20261007091000). The product's own reference list, the same for every
  -- organisation: it holds no organisation's data, so it authorises nothing,
  -- as erp_vocabularies, which carries the same list among others, does not
  -- either.
  select coalesce(jsonb_agg(jsonb_build_object('code', pt.code, 'name', pt.name, 'net_days', pt.net_days)
                            order by pt.seq, pt.code), '[]'::jsonb)
    from erp_ref.payment_term pt
$$;

revoke all on function public.erp_payment_terms() from public, anon;
grant execute on function public.erp_payment_terms() to authenticated, service_role;

comment on function public.erp_payment_terms() is
  'The payment terms the product lists, code, name and days, for a business partner''s Set payment terms '
  '(20261007091000). Reference data only; it authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Their registrations and their words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_party_tax_identifier', 'erp.set_party_tax_identifier',
   'Keeps or clears a business partner''s VAT number; authorises master_data.write.'),
  ('erp_set_party_payment_terms', 'erp.set_party_payment_terms',
   'Sets or clears a business partner''s payment terms as a customer or a supplier on the terms row in force, leaving its credit alone; authorises master_data.write.'),
  ('erp_party_details', 'erp.authorise',
   'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/master-data',
                                 array['erp_set_party_tax_identifier', 'erp_set_party_payment_terms']);


insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A business partner''s VAT number and payment terms on its record on '
       'Common data (20261007091000).'
  from (values
    ('Payment terms'),
    ('Set the VAT number'),
    ('As it is printed on the partner''s invoices, such as GB123456789. Spaces, dots and dashes are taken out.'),
    ('Leave it empty to clear the VAT number.'),
    ('Set payment terms'),
    ('When this partner pays the organisation as a customer, or is paid as a supplier. A credit limit is kept separately, on Sales.'),
    ('Customer or supplier: the role these terms are for.'),
    ('Leave empty to clear the terms.'),
    ('As a customer'),
    ('As a supplier'),
    ('Payment terms are kept for a customer or a supplier. Give this partner one of those roles first.'),
    ('One of this organisation''s own companies. Its VAT number is kept with its invoice details.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.party_terms_suite()
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
  v_entity uuid; v_company uuid;
  v_cust uuid; v_supp uuid; v_carr uuid; v_gone uuid;
  v_crole uuid; v_srole uuid;
  v_out  jsonb; v_det jsonb; v_out2 jsonb;
  v_n    integer; v_n2 integer;
  v_err  text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text;
  v_vat  text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with an administrator, a buyer, a customer, a supplier, a carrier and a merged partner';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzptm-' || v_tag, 'Party Terms Suite',
      'admin@zzptm-' || v_tag || '.test', 'Terms Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzptm-' || v_tag || '.test'),
           (s_buy, 'buyer@zzptm-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('buyer@zzptm-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id into v_entity from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select e.party_id into v_company from erp.entity e
     where e.tenant_id = rb.tenant_id and e.party_id is not null order by e.code limit 1;
    v_cust := (public.erp_create_party('ZPTMCUST', 'Terms Customer', 'customer') ->> 'party_id')::uuid;
    v_supp := erp_test.cash_payment_supplier('ZPTMSUP');
    v_carr := (public.erp_create_party('ZPTMCARR', 'Only A Carrier', 'carrier') ->> 'party_id')::uuid;
    v_gone := (public.erp_create_party('ZPTMGONE', 'Merged Away', 'customer') ->> 'party_id')::uuid;
    update erp.party set merged_into_id = v_cust, status = 'inactive' where id = v_gone;
    select pr.id into v_crole from erp.party_role pr where pr.party_id = v_cust and pr.role_kind = 'customer';
    select pr.id into v_srole from erp.party_role pr where pr.party_id = v_supp and pr.role_kind = 'supplier';

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the three doors are allowed and gated, the two that write are in the screen''s help, the payment terms are listed to pick from, the four refusals are registered, the two widened ones say so, and the words are there';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance w
                where (w.function_name, w.gate) in (('erp_set_party_tax_identifier', 'erp.set_party_tax_identifier'),
                                                    ('erp_set_party_payment_terms', 'erp.set_party_payment_terms'),
                                                    ('erp_party_details', 'erp.authorise'))) = 3
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/master-data'
                         and h.actions @> array['erp_set_party_tax_identifier', 'erp_set_party_payment_terms'])
          and (select count(*) from jsonb_array_elements(public.erp_payment_terms()) e
                where e ->> 'code' = 'NET30' and e ->> 'name' = 'Net 30 days' and (e ->> 'net_days')::integer = 30) = 1
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_TAX_IDENTIFIER_INVALID', 'CLOVEERP_COMPANY_VAT_NUMBER_ELSEWHERE',
                                 'CLOVEERP_PAYMENT_TERMS_UNKNOWN', 'CLOVEERP_PAYMENT_TERMS_ROLE')
                  and coalesce(f.next_action, '') <> '') = 4
          and exists (select 1 from erp_ref.refusal f
                       where f.code = 'CLOVEERP_NOT_A_CUSTOMER' and f.refused like '%payment terms%')
          and exists (select 1 from erp_ref.refusal f
                       where f.code = 'CLOVEERP_PARTNER_MERGED' and f.refused like '%VAT number%')
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en'
                  and x.key in (erp_ref.ui_key('Payment terms'), erp_ref.ui_key('Set the VAT number'),
                                erp_ref.ui_key('Set payment terms'))) = 3;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. A VAT number kept as the partner is registered ───────────────────
    v_step := 'a VAT number typed with spaces, dots and a dash, then cleared';
    v_out := public.erp_set_party_tax_identifier(v_cust, ' gb 123.456-789 ');
    v_det := public.erp_party_details(v_cust);
    v_vat := (select p.tax_identifier from erp.party p where p.id = v_cust);
    v_out2 := public.erp_set_party_tax_identifier(v_cust, '  ');
    v_cases := v_cases + 1;
    case_name := 'a VAT number is kept in letters and digits, upper case, the record reads it back, and an empty one clears it';
    passed := v_state is null
          and v_out ->> 'tax_identifier' = 'GB123456789'
          and v_vat = 'GB123456789'
          and v_det ->> 'tax_identifier' = 'GB123456789'
          and (v_det ->> 'is_company')::boolean = false
          and v_out2 ->> 'previous_tax_identifier' = 'GB123456789'
          and (select p.tax_identifier from erp.party p where p.id = v_cust) is null;
    detail := coalesce(v_state, concat_ws(' / ', v_out::text, v_det::text, v_out2::text));
    return next;

    -- ── 3. What is not a VAT number, or not this partner's to have ──────────
    v_step := 'VAT numbers that are not one, a merged partner and the organisation''s own company';
    perform public.erp_set_party_tax_identifier(v_cust, 'GB999999973');
    begin perform public.erp_set_party_tax_identifier(v_cust, 'GB!!12'); v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_set_party_tax_identifier(v_cust, 'ABCDEF'); v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_set_party_tax_identifier(v_cust, repeat('1', 21)); v_err3 := 'set';
    exception when others then v_err3 := sqlerrm; end;
    begin perform public.erp_set_party_tax_identifier(v_gone, 'GB123456789'); v_err4 := 'set';
    exception when others then v_err4 := sqlerrm; end;
    begin perform public.erp_set_party_tax_identifier(v_company, 'GB123456789'); v_err5 := 'set';
    exception when others then v_err5 := sqlerrm; end;
    v_det := public.erp_party_details(v_company);
    v_cases := v_cases + 1;
    case_name := 'a VAT number with a stray character, without a digit or too long is refused, as are a merged partner and the organisation''s own company, and the number kept stands';
    passed := v_state is null
          and v_company is not null
          and v_err like 'CLOVEERP_TAX_IDENTIFIER_INVALID%'
          and v_err2 like 'CLOVEERP_TAX_IDENTIFIER_INVALID%'
          and v_err3 like 'CLOVEERP_TAX_IDENTIFIER_INVALID%'
          and v_err4 like 'CLOVEERP_PARTNER_MERGED%'
          and v_err5 like 'CLOVEERP_COMPANY_VAT_NUMBER_ELSEWHERE%'
          and (v_det ->> 'is_company')::boolean
          and (select p.tax_identifier from erp.party p where p.id = v_cust) = 'GB999999973'
          and (select p.tax_identifier from erp.party p where p.id = v_gone) is null;
    detail := coalesce(v_state, concat_ws(' / ', coalesce(v_company::text, 'no company party'),
                                          v_err, v_err2, v_err3, v_err4, v_err5));
    return next;

    -- ── 4. Terms for a customer with none ───────────────────────────────────
    v_step := 'customer terms set where the customer has no terms row';
    select count(*) into v_n from erp.party_role_terms x where x.party_role_id = v_crole;
    v_out := public.erp_set_party_payment_terms(v_cust, 'Customer', 'net30');
    v_det := public.erp_party_details(v_cust);
    v_cases := v_cases + 1;
    case_name := 'terms set for a customer with no terms begin a row today, with the days the terms give, and the record reads them';
    passed := v_state is null
          and v_n = 0
          and (select count(*) from erp.party_role_terms x where x.party_role_id = v_crole) = 1
          and exists (select 1 from erp.party_role_terms x
                       where x.party_role_id = v_crole and x.payment_terms_code = 'NET30'
                         and x.payment_days = 30 and x.valid_from = current_date and x.valid_to is null
                         and x.entity_id = v_entity and x.currency is not null)
          and v_out ->> 'payment_terms_name' = 'Net 30 days'
          and jsonb_array_length(v_det -> 'terms') = 1
          and v_det -> 'terms' -> 0 ->> 'role' = 'customer'
          and v_det -> 'terms' -> 0 ->> 'payment_terms_code' = 'NET30';
    detail := coalesce(v_state, concat_ws(' / ', v_n::text, v_out::text, v_det::text));
    return next;

    -- ── 5. Terms changed on the row in force leave its credit alone ─────────
    v_step := 'a credit limit set on Sales, then the terms changed and cleared';
    perform public.erp_set_credit_limit(v_cust, 500000, false, 'agreed with the customer');
    v_out := public.erp_set_party_payment_terms(v_cust, 'customer', 'EOM');
    v_n := (select count(*) from erp.party_role_terms x where x.party_role_id = v_crole);
    v_err := (select format('%s/%s/%s', x.payment_terms_code, x.payment_days, x.credit_limit_minor)
                from erp.party_role_terms x where x.party_role_id = v_crole);
    v_out2 := public.erp_set_party_payment_terms(v_cust, 'customer', null);
    v_cases := v_cases + 1;
    case_name := 'terms changed on the row in force change it in place and leave the credit limit; cleared, the row and its credit stay';
    passed := v_state is null
          and v_n = 1
          and v_err = 'EOM/0/500000'
          and v_out ->> 'previous_payment_terms_code' = 'NET30'
          and v_out2 ->> 'previous_payment_terms_code' = 'EOM'
          and (select count(*) from erp.party_role_terms x where x.party_role_id = v_crole) = 1
          and exists (select 1 from erp.party_role_terms x
                       where x.party_role_id = v_crole and x.payment_terms_code is null
                         and x.payment_days is null and x.credit_limit_minor = 500000
                         and x.credit_reason = 'agreed with the customer');
    detail := coalesce(v_state, concat_ws(' / ', v_n::text, v_err, v_out::text, v_out2::text));
    return next;

    -- ── 6. Terms dated to begin later bound the row begun today ─────────────
    v_step := 'supplier terms set while terms are already dated to begin in ten days';
    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, payment_terms_code,
                                      payment_days, valid_from)
    select rb.tenant_id, v_srole, v_entity, e.base_currency, 'NET90', 90, current_date + 10
      from erp.entity e where e.id = v_entity;
    v_out := public.erp_set_party_payment_terms(v_supp, 'supplier', 'NET60');
    v_err := (select string_agg(format('%s/%s/%s/%s', x.payment_terms_code, x.payment_days,
                                       x.valid_from - current_date, coalesce((x.valid_to - current_date)::text, 'open')),
                                ' ' order by x.valid_from)
                from erp.party_role_terms x where x.party_role_id = v_srole);
    v_out2 := public.erp_set_party_payment_terms(v_supp, 'supplier', null);
    v_det := public.erp_party_details(v_supp);
    v_cases := v_cases + 1;
    case_name := 'terms begun today for a supplier end where terms already dated later begin, so two rows never overlap, and cleared they leave the later terms as they were';
    passed := v_state is null
          and v_err = 'NET60/60/0/10 NET90/90/10/open'
          and (select count(*) from erp.party_role_terms x where x.party_role_id = v_srole) = 2
          and exists (select 1 from erp.party_role_terms x
                       where x.party_role_id = v_srole and x.payment_terms_code is null
                         and x.payment_days is null and x.valid_from = current_date
                         and x.valid_to = current_date + 10)
          and exists (select 1 from erp.party_role_terms x
                       where x.party_role_id = v_srole and x.payment_terms_code = 'NET90'
                         and x.valid_from = current_date + 10 and x.valid_to is null)
          and v_out2 ->> 'previous_payment_terms_code' = 'NET60'
          and v_det -> 'terms' -> 0 ->> 'role' = 'supplier'
          and v_det -> 'terms' -> 0 ->> 'payment_terms_code' is null;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_out2::text, v_det::text));
    return next;

    -- ── 7. What is not payment terms, or not this partner's to have ─────────
    v_step := 'unknown terms, a role that is not paid, roles the partner does not hold, and a merged partner';
    select count(*) into v_n from erp.party_role_terms x where x.tenant_id = rb.tenant_id;
    begin perform public.erp_set_party_payment_terms(v_cust, 'customer', 'NET31'); v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_set_party_payment_terms(v_carr, 'carrier', 'NET30'); v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_set_party_payment_terms(v_carr, 'customer', 'NET30'); v_err3 := 'set';
    exception when others then v_err3 := sqlerrm; end;
    begin perform public.erp_set_party_payment_terms(v_carr, 'supplier', 'NET30'); v_err4 := 'set';
    exception when others then v_err4 := sqlerrm; end;
    begin perform public.erp_set_party_payment_terms(v_gone, 'customer', 'NET30'); v_err5 := 'set';
    exception when others then v_err5 := sqlerrm; end;
    v_det := public.erp_party_details(v_carr);
    select count(*) into v_n2 from erp.party_role_terms x where x.tenant_id = rb.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'terms the list does not hold, a carrier''s terms, terms for a role not held and a merged partner are each refused, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_PAYMENT_TERMS_UNKNOWN%'
          and v_err2 like 'CLOVEERP_PAYMENT_TERMS_ROLE%'
          and v_err3 like 'CLOVEERP_NOT_A_CUSTOMER%'
          and v_err4 like 'CLOVEERP_NOT_A_SUPPLIER%'
          and v_err5 like 'CLOVEERP_PARTNER_MERGED%'
          and jsonb_array_length(v_det -> 'terms') = 0
          and v_n = v_n2;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_n || '→' || v_n2));
    return next;

    -- ── 8. A buyer reads them and sets neither ──────────────────────────────
    v_step := 'the buyer reads, then sets a VAT number and terms';
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_det := public.erp_party_details(v_cust);
    v_err := null; v_err2 := null;
    begin perform public.erp_set_party_tax_identifier(v_cust, 'GB123456789'); v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_set_party_payment_terms(v_supp, 'supplier', 'NET7'); v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody who reads common data sees a partner''s VAT number and terms but sets neither: that is for whoever keeps the party file';
    passed := v_state is null
          and v_det ->> 'tax_identifier' = 'GB999999973'
          and v_err like 'CLOVEERP_PERMISSION_DENIED%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED%'
          and (select p.tax_identifier from erp.party p where p.id = v_cust) = 'GB999999973'
          and not exists (select 1 from erp.party_role_terms x
                           where x.party_role_id = v_srole and x.payment_terms_code = 'NET7');
    detail := coalesce(v_state, concat_ws(' / ', v_det::text, v_err, v_err2));
    return next;

    -- ── 9. Another organisation sees none of it ─────────────────────────────
    v_step := 'a second organisation';
    perform set_config('request.jwt.claims', '', true);
    select * into rb2 from erp.provision_tenant(
      'zzptx-' || v_tag, 'Party Terms Other',
      'admin@zzptx-' || v_tag || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = rb2.tenant_id and is_self;
    insert into auth.users (id, email) values (a3, 'admin@zzptx-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    v_err := null; v_err2 := null; v_err3 := null;
    begin perform public.erp_party_details(v_cust); v_err := 'read';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_set_party_tax_identifier(v_cust, 'GB123456789'); v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_set_party_payment_terms(v_cust, 'customer', 'NET7'); v_err3 := 'set';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'another organisation can neither read nor set this partner''s VAT number or terms';
    passed := v_state is null
          and v_err like 'CLOVEERP_UNKNOWN_PARTY%'
          and v_err2 like 'CLOVEERP_UNKNOWN_PARTY%'
          and v_err3 like 'CLOVEERP_UNKNOWN_PARTY%'
          and (select p.tax_identifier from erp.party p where p.id = v_cust) = 'GB999999973'
          and not exists (select 1 from erp.party_role_terms x
                           where x.party_role_id = v_crole and x.payment_terms_code = 'NET7');
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3));
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
    raise exception 'CLOVEERP_PARTY_TERMS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.party_terms_suite() from public, anon;

comment on function erp_test.party_terms_suite() is
  'A business partner''s VAT number and payment terms can be kept (20261007091000): the number is kept in letters and '
  'digits and cleared, what is not one is refused, terms begin a row or change the one in force without touching its '
  'credit, terms dated later bound a new row, what is not terms is refused, a reader only reads, and another '
  'organisation sees none of it.';

create or replace function erp_test.assert_party_terms_suite()
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
    from erp_test.party_terms_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PARTY_TERMS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A business partner''s VAT number or payment terms were kept, refused or read where they should not be. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_PARTY_TERMS_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('party terms: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_party_terms_suite() from public, anon;

comment on function erp_test.assert_party_terms_suite() is
  'A business partner''s VAT number and payment terms can be kept on its record on Common data, on master_data.write, '
  'without touching its credit (20261007091000).';

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
