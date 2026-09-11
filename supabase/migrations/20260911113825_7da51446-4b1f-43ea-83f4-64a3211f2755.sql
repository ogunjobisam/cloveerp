create or replace function erp_test.document_issue_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; r2 record;
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  cs1 uuid; cs2 uuid; v_second uuid; v_tok text; res jsonb;
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

  -- The books first: sales documents reach a ledger, and the installer says so.
  cs1 := erp.configure_finance(extract(year from current_date)::integer, 'GBP', r.entity_id);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs1); perform erp.promote_change_set(cs1);

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  cs2 := erp.configure_sales(15);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
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

  v_v := erp.validate_sales_invoice_issue(v_inv);
  return query select 'a company that is not VAT registered still needs its own legal details',
    (v_v ->> 'is_vat_registered')::boolean = false
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING"}]'::jsonb
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING"}]'::jsonb
      and not ((v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_VAT_NUMBER_MISSING"}]'::jsonb),
    left(v_v -> 'missing' #>> '{}', 90);

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

  v_empty := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
  v_v := erp.validate_sales_invoice_issue(v_empty);
  return query select 'an invoice with no lines is refused',
    not (v_v ->> 'can_issue')::boolean
      and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_NO_LINES"}]'::jsonb,
    'zero lines';

  res := erp.issue_sales_invoice(v_inv);
  v_issue := (res ->> 'document_issue_id')::uuid;
  v_num := res ->> 'issued_number';
  select di.sequence_number, di.contract_snapshot into v_n1, v_c
    from erp.document_issue di where di.id = v_issue;
  return query select 'a complete invoice takes a number and freezes its whole contract',
    v_num is not null and v_c ?& array['header','company','customer','lines','tax_summary','totals','terminology','brand']
      and (v_c -> 'totals' ->> 'vat_total_sterling_minor')::bigint = 2000,
    format('%s, VAT 20.00', v_num);

  begin
    update erp.document_sequence set prefix = 'ZZZ'
     where tenant_id = r.tenant_id and document_kind = 'sales_invoice';
    v_ok := false; v_msg := 'the prefix changed after a number had been taken';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 58); end;
  return query select 'the numbering prefix cannot change once a number has been taken', v_ok, v_msg;

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

  select count(*) into v_before from erp.document_issue where tenant_id = r.tenant_id;
  res := erp.reprint_document_issue(v_issue2, 'Customer asked again');
  return query select 'reprinting returns the stored file and takes no number',
    res ->> 'content_checksum' = repeat('b', 64)
      and (res ->> 'rendered_again')::boolean = false
      and (select count(*) from erp.document_issue where tenant_id = r.tenant_id) = v_before
      and (select s.next_number from erp.document_sequence s
            where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice') = v_n2 + 1,
    res ->> 'issued_number';

  update erp.party set name = 'Renamed After Issue', legal_name = 'Renamed Legal Ltd'
   where tenant_id = r.tenant_id and id = v_cust;
  update erp.document_line set net_minor = 999999
   where tenant_id = r.tenant_id and document_id = v_inv;
  select di.contract_snapshot into v_c from erp.document_issue di where di.id = v_issue2;
  return query select 'the frozen contract still says what was issued after the records change',
    v_c -> 'customer' ->> 'legal_name' = 'Customer Legal Ltd'
      and (v_c -> 'totals' ->> 'net_minor')::bigint = 10000,
    'customer renamed and the line rewritten; the issue is unmoved';

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

select erp.assert_document_issue_sound();
