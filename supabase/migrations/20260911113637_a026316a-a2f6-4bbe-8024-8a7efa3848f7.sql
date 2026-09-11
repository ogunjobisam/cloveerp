set lock_timeout = '30s';

-- ---------------------------------------------------------------------------
-- 1. A refusal for an invoice with nothing on it
-- ---------------------------------------------------------------------------

insert into erp_ref.refusal (code, refused, why, next_action) values
  ('CLOVEERP_INVOICE_NO_LINES',
   'This invoice cannot be issued because it has no lines.',
   'An invoice with nothing on it states no amount, so there is nothing to issue.',
   'Open the invoice and add at least one line, then issue again.')
on conflict (code) do update
  set refused = excluded.refused, why = excluded.why, next_action = excluded.next_action;

-- ---------------------------------------------------------------------------
-- 2. The roles that already own the work
-- ---------------------------------------------------------------------------

create or replace function erp.standard_role_permissions(p_code text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct p.code order by p.code), '{}')
    from erp_ref.permission p
   where p.module_code = case p_code
                           when 'purchasing'  then 'procurement'
                           when 'despatch'    then 'logistics'
                           when 'master_data' then 'master_data'
                           when 'warehouse'   then null
                           else p_code
                         end
      or p.code = any (case p_code
        when 'inventory'   then array['master_data.read','reporting.read']
        when 'purchasing'  then array['master_data.read','inventory.read','reporting.read']
        -- Whoever raises the invoice issues and reprints it. Managing the
        -- template is a different job and stays out.
        when 'sales'       then array['master_data.read','inventory.read','reporting.read',
                                      'document.issue','document.reprint']
        when 'finance'     then array['master_data.read','reporting.read','reporting.export',
                                      'document.issue','document.reprint']
        when 'production'  then array['inventory.read','master_data.read','reporting.read']
        when 'quality'     then array['inventory.read','production.read','reporting.read']
        when 'despatch'    then array['inventory.read','sales.read','reporting.read']
        when 'planning'    then array['inventory.read','procurement.read','production.read','reporting.read']
        when 'reporting'   then array['master_data.read']
        -- The template is reference material, kept by the people who keep the
        -- rest of it. Issuing is not theirs.
        when 'master_data' then array['reporting.read','document.template_manage']
        when 'warehouse'   then array[
                                'inventory.read','inventory.move','inventory.count',
                                'logistics.read','logistics.despatch',
                                'sales.read','sales.despatch',
                                'master_data.read','reporting.read']
        else '{}'::text[]
      end)
$$;

comment on function erp.standard_role_permissions is
  'What one job needs, by role code. Roles combine, so a person doing two jobs '
  'holds both roles rather than a third role made for the pair. Issuing and '
  'reprinting a document sit with the roles that already raise it; managing the '
  'template sits with master data.';

-- Organisations already on file: the seeded roles keep the shape they are given
-- above, without touching a role somebody has narrowed by hand.
insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
select r.tenant_id, r.id, perm, '{}'
  from erp.role r
  cross join lateral unnest(erp.standard_role_permissions(r.code)) perm
 where r.code in ('sales', 'finance', 'master_data')
   and perm like 'document.%'
   and not exists (
     select 1 from erp.role_permission x
      where x.role_id = r.id and x.permission_code = perm);

-- ---------------------------------------------------------------------------
-- 3. The contract: the organisation's own wording, and where the logo came from
-- ---------------------------------------------------------------------------

create or replace function erp.sales_invoice_contract(p_document_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_doc      erp.document%rowtype;
  v_entity   erp.entity%rowtype;
  v_party    erp.party%rowtype;
  v_vat      text;
  v_vatreg   boolean := false;
  v_office   jsonb;
  v_billing  jsonb;
  v_lines    jsonb;
  v_tax      jsonb;
  v_term     jsonb;
  v_logo     text;
  v_net      bigint;
  v_taxm     bigint;
  v_rate     numeric;
  v_kind     text;
begin
  select d.* into v_doc from erp.document d
   where d.tenant_id = v_tenant and d.id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no such invoice in this organisation' using errcode = 'P0002';
  end if;

  select dt.code into v_kind from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = v_doc.document_type_id;
  if coalesce(v_kind, '') <> 'sales_invoice' then
    raise exception 'CLOVEERP_WRONG_DOCUMENT: only a sales invoice can be issued as a sales invoice'
      using errcode = '23514';
  end if;

  select e.* into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.id = v_doc.entity_id;
  select p.* into v_party from erp.party p
   where p.tenant_id = v_tenant and p.id = v_doc.party_id;

  -- Registered is registered. Whether the number was filled in is a separate
  -- question, and one the refusals are there to ask.
  select true, nullif(btrim(r.registration_number), '')
    into v_vatreg, v_vat
    from erp.entity_tax_registration r
   where r.tenant_id = v_tenant
     and r.entity_id = v_doc.entity_id
     and upper(r.registration_type) like 'VAT%'
     and r.valid_from <= coalesce(v_doc.tax_point, v_doc.posting_date, v_doc.document_date)
     and (r.valid_to is null or r.valid_to >= coalesce(v_doc.tax_point, v_doc.posting_date, v_doc.document_date))
   order by r.valid_from desc
   limit 1;
  v_vatreg := coalesce(v_vatreg, false);

  select jsonb_build_object('label', a.label, 'lines', to_jsonb(a.lines),
                            'locality', a.locality, 'region', a.region,
                            'postcode', a.postcode, 'country_code', a.country_code)
    into v_office
    from erp.party_address a
   where a.tenant_id = v_tenant
     and a.party_id = v_entity.party_id
     and a.address_kind = 'registered'
   order by a.is_default desc nulls last, a.valid_from desc nulls last
   limit 1;

  v_billing := v_doc.address_snapshot;
  if v_billing is null or v_billing = '{}'::jsonb then
    select jsonb_build_object('label', a.label, 'lines', to_jsonb(a.lines),
                              'locality', a.locality, 'region', a.region,
                              'postcode', a.postcode, 'country_code', a.country_code)
      into v_billing
      from erp.party_address a
     where a.tenant_id = v_tenant
       and a.party_id = v_doc.party_id
       and a.address_kind = 'billing'
     order by a.is_default desc nulls last
     limit 1;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', l.line_no,
           'item_code', i.code,
           'item_name', i.name,
           'description', coalesce(l.description, i.name),
           'quantity', l.quantity,
           'unit', u.code,
           'unit_price_minor', l.unit_price_minor,
           'discount_pct', l.discount_pct,
           'net_minor', l.net_minor,
           'tax_code', l.tax_code,
           'tax_rate_pct', l.tax_rate_pct,
           'tax_minor', l.tax_minor,
           'gross_minor', coalesce(l.net_minor, 0) + coalesce(l.tax_minor, 0)
         ) order by l.line_no), '[]'::jsonb)
    into v_lines
    from erp.document_line l
    left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
    left join erp.uom u on u.tenant_id = l.tenant_id and u.id = l.uom_id
   where l.tenant_id = v_tenant and l.document_id = p_document_id
     and coalesce(l.is_cancelled, false) = false;

  select coalesce(jsonb_agg(x order by x ->> 'tax_rate_pct'), '[]'::jsonb) into v_tax from (
    select jsonb_build_object(
             'tax_code', l.tax_code,
             'tax_rate_pct', l.tax_rate_pct,
             'net_minor', sum(coalesce(l.net_minor, 0)),
             'tax_minor', sum(coalesce(l.tax_minor, 0))) as x
      from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and coalesce(l.is_cancelled, false) = false
     group by l.tax_code, l.tax_rate_pct
  ) s;

  select coalesce(sum(coalesce(l.net_minor, 0)), 0), coalesce(sum(coalesce(l.tax_minor, 0)), 0)
    into v_net, v_taxm
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id
     and coalesce(l.is_cancelled, false) = false;

  v_rate := coalesce(v_doc.exchange_rate, 1);

  -- The wording the organisation reads on its own screens, frozen with the
  -- rest: a label reworded after issue does not change what was issued.
  select coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb) into v_term from (
    select r.key,
           coalesce((select o.value from erp.resource_override o
                      where o.tenant_id = v_tenant and o.key = r.key
                        and o.locale = r.locale
                        and o.status = 'active'::erp.record_status
                      limit 1), r.value) as value
      from erp_ref.resource r
     where r.locale = 'en'
       and (r.key like 'document.%' or r.key like 'output.field.%')
  ) t;

  select o.value into v_logo
    from erp.resource_override o
   where o.tenant_id = v_tenant and o.key = 'brand.logo.url'
     and o.status = 'active'::erp.record_status
   order by o.locale
   limit 1;

  return jsonb_build_object(
    'contract', 'sales_invoice',
    'contract_version', 2,
    'frozen_at', now(),
    'header', jsonb_build_object(
      'document_id', v_doc.id,
      'document_number', v_doc.document_number,
      'document_date', v_doc.document_date,
      'posting_date', v_doc.posting_date,
      'due_date', v_doc.due_date,
      'tax_point', coalesce(v_doc.tax_point, v_doc.posting_date, v_doc.document_date),
      'tax_point_is_explicit', v_doc.tax_point is not null,
      'currency', v_doc.currency,
      'exchange_rate', v_rate,
      'our_reference', v_doc.our_reference,
      'their_reference', v_doc.their_reference,
      'notes', v_doc.notes),
    'company', jsonb_build_object(
      'entity_id', v_entity.id,
      'legal_name', coalesce(v_entity.legal_name, v_entity.name),
      'company_registration_number', v_entity.registration_number,
      'vat_registration_number', v_vat,
      'is_vat_registered', v_vatreg,
      'registered_office', v_office,
      'base_currency', v_entity.base_currency,
      'country_code', v_entity.country_code),
    'customer', jsonb_build_object(
      'party_id', v_party.id,
      'code', v_party.code,
      'legal_name', coalesce(v_party.legal_name, v_party.name),
      'trading_name', v_party.name,
      'tax_identifier', v_party.tax_identifier,
      'country_code', v_party.country_code,
      'invoice_address', v_billing),
    'lines', v_lines,
    'tax_summary', v_tax,
    'terminology', v_term,
    'brand', jsonb_build_object(
      'logo_key', 'brand.logo.url',
      'logo_url', v_logo,
      'logo_source', case when v_logo is null then 'wordmark' else 'resource_override' end),
    'totals', jsonb_build_object(
      'net_minor', v_net,
      'tax_minor', v_taxm,
      'gross_minor', v_net + v_taxm,
      'currency', v_doc.currency,
      'vat_total_sterling_minor', round(v_taxm * v_rate)::bigint));
end $$;

comment on function erp.sales_invoice_contract is
  'Everything a sales invoice says, resolved from the records as they stand: '
  'header, issuing company and its legal identity, customer and address, lines, '
  'grouped VAT, totals in sterling, the organisation''s own wording and where '
  'its logo came from. Frozen against the issue so the document stays '
  'explainable after any of it changes.';

-- ---------------------------------------------------------------------------
-- 4. Validation: registration decides the VAT questions, nothing else
-- ---------------------------------------------------------------------------

create or replace function erp.validate_sales_invoice_issue(p_document_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_c      jsonb;
  v_bad    jsonb := '[]'::jsonb;
  v_line   jsonb;
  v_vatreg boolean;
begin
  v_c := erp.sales_invoice_contract(p_document_id);
  v_vatreg := coalesce((v_c -> 'company' ->> 'is_vat_registered')::boolean, false);

  -- Required of everybody. A company that is not VAT registered still has to
  -- say who it is, where it is, when the supply happened, who it billed and
  -- what for.
  if coalesce(btrim(v_c -> 'company' ->> 'company_registration_number'), '') = '' then
    v_bad := v_bad || jsonb_build_object('field', 'Company registration number',
      'refusal', 'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING');
  end if;
  if v_c -> 'company' -> 'registered_office' is null
     or v_c -> 'company' -> 'registered_office' = 'null'::jsonb then
    v_bad := v_bad || jsonb_build_object('field', 'Registered office',
      'refusal', 'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING');
  end if;
  if v_c -> 'header' ->> 'tax_point' is null then
    v_bad := v_bad || jsonb_build_object('field', 'Tax point',
      'refusal', 'CLOVEERP_INVOICE_TAX_POINT_MISSING');
  end if;
  if v_c -> 'customer' -> 'invoice_address' is null
     or v_c -> 'customer' -> 'invoice_address' = 'null'::jsonb then
    v_bad := v_bad || jsonb_build_object('field', 'Customer invoice address',
      'refusal', 'CLOVEERP_CUSTOMER_ADDRESS_MISSING');
  end if;
  if jsonb_array_length(v_c -> 'lines') = 0 then
    v_bad := v_bad || jsonb_build_object('field', 'Invoice lines',
      'refusal', 'CLOVEERP_INVOICE_NO_LINES');
  end if;

  -- Required only of a VAT-registered issuer.
  if v_vatreg then
    if coalesce(btrim(v_c -> 'company' ->> 'vat_registration_number'), '') = '' then
      v_bad := v_bad || jsonb_build_object('field', 'VAT registration number',
        'refusal', 'CLOVEERP_ISSUER_VAT_NUMBER_MISSING');
    end if;
    for v_line in select * from jsonb_array_elements(v_c -> 'lines') loop
      if v_line ->> 'net_minor' is null or v_line ->> 'tax_rate_pct' is null then
        v_bad := v_bad || jsonb_build_object(
          'field', format('Line %s net amount and VAT rate', v_line ->> 'line_no'),
          'refusal', 'CLOVEERP_INVOICE_LINE_TAX_MISSING');
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'document_id', p_document_id,
    'is_vat_registered', v_vatreg,
    'can_issue', jsonb_array_length(v_bad) = 0,
    'missing', v_bad);
end $$;

comment on function erp.validate_sales_invoice_issue is
  'What is still missing before this invoice may be issued, named field by '
  'field with the refusal that says where to fix it. The company, its office, '
  'the tax point, the customer address and at least one line are required of '
  'every issuer; the VAT number and the per-line VAT are required of one that '
  'is VAT registered.';

-- ---------------------------------------------------------------------------
-- 5. The rehearsal: twelve cases, executed
-- ---------------------------------------------------------------------------

create or replace function erp_test.document_issue_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; r2 record;
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  cs1 uuid; cs2 uuid; v_second uuid; v_tok text; res jsonb; t record;
  v_uom uuid; v_site uuid; v_cust uuid; v_item uuid; v_inv uuid; v_empty uuid;
  v_issue uuid; v_issue2 uuid; v_num text; v_num2 text; v_n1 bigint; v_n2 bigint;
  v_env uuid; v_c jsonb; v_v jsonb; v_ok boolean; v_msg text; v_before integer;
begin
  select * into r from erp.provision_tenant('zzdocissue','Document Issue Suite','a@zzdocissue.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzdocissue.test','Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  cs1 := erp.configure_procurement(1000000);
  cs2 := erp.configure_sales(15);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs1); perform erp.promote_change_set(cs1);
  perform erp.approve_change_set(cs2); perform erp.promote_change_set(cs2);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.party (tenant_id, code, name, legal_name, status)
  values (r.tenant_id,'CUST','Customer','Customer Legal Ltd','active') returning id into v_cust;
  insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
  values (r.tenant_id, v_cust,'customer', jsonb_build_object('credit_limit_minor', 100000000),'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id,'WID','Widget', v_uom,'active') returning id into v_item;

  v_inv := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
  perform erp.add_document_line(v_inv, v_item, 2, 5000, 'widgets');

  -- 1. Not VAT registered, and the rest is still required.
  v_v := erp.validate_sales_invoice_issue(v_inv);
  return query select 'a company that is not VAT registered still needs its own legal details',
    (v_v ->> 'is_vat_registered')::boolean = false
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING"}]'::jsonb
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING"}]'::jsonb
      and not ((v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_VAT_NUMBER_MISSING"}]'::jsonb),
    left(v_v -> 'missing' #>> '{}', 90);

  -- 2. Registered with no number: the VAT refusal is reachable.
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
  values (r.tenant_id, r.entity_id, 'GB', 'VAT', '  ', current_date - 365);

  v_v := erp.validate_sales_invoice_issue(v_inv);
  return query select 'a VAT-registered company with no VAT number is refused by name',
    (v_v ->> 'is_vat_registered')::boolean
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_VAT_NUMBER_MISSING"}]'::jsonb
      and exists (select 1 from erp_ref.refusal f
                   where f.code = 'CLOVEERP_ISSUER_VAT_NUMBER_MISSING'
                     and coalesce(btrim(f.next_action), '') <> ''),
    'registration present, number blank';

  update erp.entity_tax_registration set registration_number = 'GB123456789'
   where tenant_id = r.tenant_id and entity_id = r.entity_id;
  update erp.document_line set net_minor = 10000, tax_code = 'S', tax_rate_pct = 20, tax_minor = 2000
   where tenant_id = r.tenant_id and document_id = v_inv;

  -- 3. Nothing on it is nothing to issue.
  v_empty := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
  v_v := erp.validate_sales_invoice_issue(v_empty);
  return query select 'an invoice with no lines is refused',
    not (v_v ->> 'can_issue')::boolean
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_NO_LINES"}]'::jsonb,
    'zero lines';

  -- 4. A complete invoice issues and freezes what it said.
  res := erp.issue_sales_invoice(v_inv);
  v_issue := (res ->> 'document_issue_id')::uuid;
  v_num := res ->> 'issued_number';
  select di.sequence_number, di.contract_snapshot into v_n1, v_c
    from erp.document_issue di where di.id = v_issue;
  return query select 'a complete invoice takes a number and freezes its whole contract',
    v_num is not null and v_c ?& array['header','company','customer','lines','tax_summary','totals','terminology','brand']
      and (v_c -> 'totals' ->> 'vat_total_sterling_minor')::bigint = 2000,
    format('%s, VAT 20.00', v_num);

  -- 5. The prefix is permanent.
  begin
    update erp.document_sequence set prefix = 'ZZZ'
     where tenant_id = r.tenant_id and document_kind = 'sales_invoice';
    v_ok := false; v_msg := 'the prefix changed after a number had been taken';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 58); end;
  return query select 'the numbering prefix cannot change once a number has been taken', v_ok, v_msg;

  -- 6 and 7. Amendment before sending: original void, new number, never reused.
  perform erp.complete_document_issue(v_issue, 'tenant/' || r.tenant_id || '/' || v_num || '.pdf',
                                      repeat('a', 64));
  res := erp.amend_sales_invoice(v_issue, 'Wrong address');
  v_issue2 := (res ->> 'document_issue_id')::uuid;
  v_num2 := res ->> 'issued_number';
  select di.sequence_number into v_n2 from erp.document_issue di where di.id = v_issue2;

  return query select 'amending before sending voids the original and issues a new number',
    (select di.status from erp.document_issue di where di.id = v_issue) = 'void'
      and (select di.replaces_issue_id from erp.document_issue di where di.id = v_issue2) = v_issue
      and v_num2 <> v_num,
    format('%s replaced by %s', v_num, v_num2);

  return query select 'a spent number is never handed out again',
    v_n2 = v_n1 + 1
      and (select count(*) from erp.document_issue di
            where di.tenant_id = r.tenant_id and di.sequence_number = v_n1) = 1,
    format('%s then %s', v_n1, v_n2);

  -- 8. After sending, amendment is refused and points somewhere.
  perform erp.complete_document_issue(v_issue2, 'tenant/' || r.tenant_id || '/' || v_num2 || '.pdf',
                                      repeat('b', 64));
  perform erp.mark_document_issue_sent(v_issue2);
  begin
    perform erp.amend_sales_invoice(v_issue2, 'Too late');
    v_ok := false; v_msg := 'a sent invoice was amended';
  exception when others then
    v_ok := (sqlerrm like '%CLOVEERP_INVOICE_ALREADY_SENT%'); v_msg := left(sqlerrm, 58);
  end;
  return query select 'amending after sending is refused and sends you to a credit note',
    v_ok and exists (select 1 from erp_ref.refusal f
                      where f.code = 'CLOVEERP_INVOICE_ALREADY_SENT'
                        and f.next_action ilike '%credit%'),
    v_msg;

  -- 9. Reprint returns the file, and nothing else happens.
  select count(*) into v_before from erp.document_issue where tenant_id = r.tenant_id;
  res := erp.reprint_document_issue(v_issue2, 'Customer asked again');
  return query select 'reprinting returns the stored file and takes no number',
    res ->> 'content_checksum' = repeat('b', 64)
      and (res ->> 'rendered_again')::boolean = false
      and (select count(*) from erp.document_issue where tenant_id = r.tenant_id) = v_before
      and (select s.next_number from erp.document_sequence s
            where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice') = v_n2 + 1,
    res ->> 'issued_number';

  -- 10. The frozen contract outlives the records it was taken from.
  update erp.party set name = 'Renamed After Issue', legal_name = 'Renamed Legal Ltd'
   where tenant_id = r.tenant_id and id = v_cust;
  update erp.document_line set net_minor = 999999
   where tenant_id = r.tenant_id and document_id = v_inv;
  select di.contract_snapshot into v_c from erp.document_issue di where di.id = v_issue2;
  return query select 'the frozen contract still says what was issued after the records change',
    v_c -> 'customer' ->> 'legal_name' = 'Customer Legal Ltd'
      and (v_c -> 'totals' ->> 'net_minor')::bigint = 10000,
    'customer renamed and the line rewritten; the issue is unmoved';

  -- 11. Wording and logo provenance. Terminology is configuration, so the
  --     organisation is put back into build for the moment it is written.
  select e.id into v_env from erp.environment e where e.tenant_id = r.tenant_id and e.is_self;
  update erp.environment set is_live = false where id = v_env;
  insert into erp.resource_override (tenant_id, key, locale, value, status)
  values (r.tenant_id, 'document.invoice_reference', 'en', 'Tax invoice', 'active'),
         (r.tenant_id, 'brand.logo.url', 'en', 'https://example.test/logo.png', 'active');
  update erp.environment set is_live = true where id = v_env;

  v_c := erp.sales_invoice_contract(v_inv);
  return query select 'the contract carries the organisation''s own wording and its logo',
    v_c -> 'terminology' ->> 'document.invoice_reference' = 'Tax invoice'
      and v_c -> 'brand' ->> 'logo_url' = 'https://example.test/logo.png'
      and v_c -> 'brand' ->> 'logo_source' = 'resource_override',
    'reworded label and logo provenance both resolved';

  -- 12. Another organisation sees none of it.
  select * into r2 from erp.provision_tenant('zzdocissue2','Other Organisation','a@zzdocissue2.test','Other Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
  perform erp.claim_invitation(r2.admin_token);
  return query select 'another organisation cannot see this organisation''s issues',
    public.erp_document_issues(null, 100) = '[]'::jsonb
      and not exists (select 1 from erp.document_issue di where di.id = v_issue2),
    'read as the administrator of a different organisation';

  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r2.tenant_id);
  delete from erp.tenant where id = r2.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

comment on function erp_test.document_issue_suite is
  'Issues a real sales invoice and tries to break it: refusals for a VAT and a '
  'non-VAT issuer, an empty invoice, a prefix that cannot move, a number that '
  'cannot come back, amendment before and after sending, reprint that renders '
  'nothing, a contract that outlives its records, the organisation''s own '
  'wording, and another organisation that sees none of it.';

create or replace function erp_test.assert_document_issue_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_total integer; v_failed integer; v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.document_issue_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_DOCUMENT_ISSUE_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;
  if v_total <> c_expected then
    raise exception 'ERPWARE_DOCUMENT_ISSUE_SUITE_INCOMPLETE: expected % cases, ran %',
      c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('document issue: %s/%s cases passed', v_total, v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The structural check, without the regular expressions
-- ---------------------------------------------------------------------------

create or replace function erp.assert_document_issue_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_bad text; v_code text;
begin
  -- every new table registered, under row security
  select string_agg(t, ', ') into v_bad from unnest(
    array['document_sequence', 'document_issue', 'document_reprint']) t
   where not exists (
     select 1 from erp_meta.table_policy p
      where p.schema_name = 'erp' and p.table_name = t)
      or not exists (
     select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'erp' and c.relname = t and c.relrowsecurity);
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_TABLE_UNGOVERNED: %', v_bad using errcode = 'P0001';
  end if;

  -- nothing crosses an organisation
  if exists (select 1 from erp.document_issue di join erp.document d on d.id = di.source_document_id
              where d.tenant_id <> di.tenant_id)
  or exists (select 1 from erp.document_issue di join erp.document_issue rr on rr.id = di.replaces_issue_id
              where rr.tenant_id <> di.tenant_id)
  or exists (select 1 from erp.document_reprint rp join erp.document_issue di on di.id = rp.document_issue_id
              where di.tenant_id <> rp.tenant_id) then
    raise exception 'ERPWARE_DOCUMENT_TENANT_LEAK: an issue, replacement or reprint crosses organisations'
      using errcode = 'P0001';
  end if;

  -- one active version per template, and no two active versions of one
  -- document type in the same organisation
  if not exists (select 1 from pg_class where relname = 'output_template_version_one_active') then
    raise exception 'ERPWARE_DOCUMENT_TEMPLATE_UNBOUNDED: a template may hold more than one active version'
      using errcode = 'P0001';
  end if;
  select string_agg(format('%s in %s', base_type_code, tenant_id), ', ') into v_bad from (
    select t.tenant_id, t.base_type_code
      from erp.output_template_version v
      join erp.output_template t on t.tenant_id = v.tenant_id and t.id = v.output_template_id
     where v.status::text = 'active'
       and t.base_type_code is not null
     group by 1, 2 having count(*) > 1) s;
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_TEMPLATE_AMBIGUOUS: two active versions for one document type: %', v_bad
      using errcode = 'P0001';
  end if;

  -- a number is taken once and never reused
  if not exists (
    select 1 from pg_constraint
     where conname = 'document_issue_number_once' and conrelid = 'erp.document_issue'::regclass) then
    raise exception 'ERPWARE_DOCUMENT_NUMBER_REUSABLE: nothing stops a number being issued twice'
      using errcode = 'P0001';
  end if;
  select string_agg(format('%s %s', document_kind, sequence_number), ', ') into v_bad from (
    select tenant_id, document_kind, sequence_number from erp.document_issue
     group by 1, 2, 3 having count(*) > 1) s;
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_NUMBER_REUSED: %', v_bad using errcode = 'P0001';
  end if;

  -- the prefix cannot change once used, and an issued row cannot be rewritten
  if not exists (
    select 1 from pg_trigger where tgrelid = 'erp.document_sequence'::regclass
      and tgname = 't_document_sequence_identity' and not tgisinternal) then
    raise exception 'ERPWARE_DOCUMENT_SEQUENCE_UNPROTECTED: the numbering register can be rewritten'
      using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from pg_trigger where tgrelid = 'erp.document_issue'::regclass
      and tgname = 't_document_issue_immutable' and not tgisinternal) then
    raise exception 'ERPWARE_DOCUMENT_ISSUE_UNPROTECTED: an issued row can be rewritten'
      using errcode = 'P0001';
  end if;

  -- every issued row keeps a complete frozen contract
  if exists (
    select 1 from erp.document_issue
     where contract_snapshot is null
        or not (contract_snapshot ?& array['header', 'company', 'customer', 'lines', 'tax_summary', 'totals'])
        or contract_snapshot -> 'totals' ->> 'vat_total_sterling_minor' is null) then
    raise exception 'ERPWARE_DOCUMENT_CONTRACT_INCOMPLETE: an issued row cannot explain itself'
      using errcode = 'P0001';
  end if;

  -- a replacement only ever stands beside a voided original, under its own number
  if exists (
    select 1 from erp.document_issue di
     where di.replaces_issue_id is not null
       and (select rr.status from erp.document_issue rr where rr.id = di.replaces_issue_id) <> 'void') then
    raise exception 'ERPWARE_DOCUMENT_REPLACEMENT_UNVOIDED: a replacement exists while the original still stands'
      using errcode = 'P0001';
  end if;

  -- the gates exist and the roles that raise invoices hold them
  foreach v_code in array array['document.issue', 'document.reprint', 'document.template_manage'] loop
    if not exists (select 1 from erp_ref.permission where code = v_code) then
      raise exception 'ERPWARE_DOCUMENT_PERMISSION_MISSING: %', v_code using errcode = 'P0001';
    end if;
  end loop;
  if not ('document.issue' = any (erp.standard_role_permissions('sales')))
     or not ('document.reprint' = any (erp.standard_role_permissions('finance')))
     or not ('document.template_manage' = any (erp.standard_role_permissions('master_data'))) then
    raise exception 'ERPWARE_DOCUMENT_ROLE_UNSEEDED: the standard roles do not carry the document permissions'
      using errcode = 'P0001';
  end if;

  -- every legal refusal is registered with somewhere to go
  foreach v_code in array array['CLOVEERP_ISSUER_VAT_NUMBER_MISSING',
                                'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING',
                                'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING',
                                'CLOVEERP_INVOICE_TAX_POINT_MISSING',
                                'CLOVEERP_INVOICE_LINE_TAX_MISSING',
                                'CLOVEERP_INVOICE_NO_LINES',
                                'CLOVEERP_CUSTOMER_ADDRESS_MISSING',
                                'CLOVEERP_INVOICE_ALREADY_SENT'] loop
    if not exists (
      select 1 from erp_ref.refusal r
       where r.code = v_code and coalesce(btrim(r.next_action), '') <> '') then
      raise exception 'ERPWARE_DOCUMENT_REFUSAL_UNNAMED: % has no destination', v_code
        using errcode = 'P0001';
    end if;
  end loop;

  -- Behaviour is not read out of the source text any more. It is executed:
  -- erp_test.document_issue_suite() issues, voids, amends before and after
  -- sending, reprints, and reads across an organisation boundary, and
  -- erp_test.assert_document_issue_suite() is in the CI catalogue by existing.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp_test' and p.proname = 'document_issue_suite')
  or not exists (
    select 1 from erp.ci_check_catalogue() c
     where c.qualified_name = 'erp_test.assert_document_issue_suite') then
    raise exception 'ERPWARE_DOCUMENT_BEHAVIOUR_UNPROVEN: nothing executes the issue behaviour'
      using errcode = 'P0001';
  end if;

  return 'document issue: numbers permanent, issues frozen and gated, templates unambiguous, behaviour proven by erp_test.document_issue_suite()';
end $$;

comment on function erp.assert_document_issue_sound is
  'The structure and the data: registered and isolated tables, one active '
  'version per document type, numbers taken once, every issued row carrying a '
  'complete frozen contract, replacements standing only beside voided '
  'originals, the permissions and the refusals in place. What the routines '
  'actually do is proven by executing them, in erp_test.document_issue_suite().';

-- ---------------------------------------------------------------------------
-- 7. Registered, so the product can run it and the build must
-- ---------------------------------------------------------------------------

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, blurb, runs_in_ci, seq) values
  ('document_issue', 'Issued documents keep their numbers', 'assertion', 'platform',
   'erp', 'assert_document_issue_sound', '',
   'An issued document is a legal statement: its number is permanent, its contents are frozen against it, a replacement never takes the number it replaces, and reprinting hands back the file that was issued rather than a fresh rendering of today''s data.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      schema_name = excluded.schema_name, blurb = excluded.blurb;

-- Two checks that arrived without a register entry, so nothing in the product
-- could run them and erp.assert_diagnostics_registered() refused.
insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, blurb, runs_in_ci, seq) values
  ('api_exposure', 'The public API cannot exceed its grants', 'assertion', 'platform',
   'erp', 'assert_api_exposure_sound', '',
   'An API key can only do what the service principal behind it may do, in the one organisation it belongs to, and its secret is never readable after it is shown once.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check)),
  ('journals_balance', 'Every posted journal balances', 'assertion', 'platform',
   'erp', 'assert_posted_journals_balance', '',
   'A posted journal whose debits and credits disagree is a broken set of books, so the build refuses one.',
   true, (select coalesce(max(seq), 0) + 2 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      schema_name = excluded.schema_name, blurb = excluded.blurb;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_document_issue_sound();
