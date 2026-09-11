-- ===========================================================================
-- Two corrections to the issue ledger, then the private archive it writes to.
--
-- 1. CLOVEERP_INVOICE_TAX_POINT_MISSING was unreachable. The contract derives
--    a tax point with coalesce(tax_point, posting_date, document_date), so the
--    header value is never null and the refusal could never fire. The contract
--    already records whether the value came from the invoice itself; the
--    validation now reads that flag, so the refusal means what it says: a VAT
--    invoice states its own tax point rather than borrowing another date.
--
-- 2. erp_test.document_issue_suite() purged its fixtures at the end, so any
--    mid-suite failure left zzdocissue behind and every later run collided.
--    It now follows the CLOVEERP_SUITE_UNDO pattern: the work is undone by the
--    exception that ends it, whichever way the run goes.
--
-- Then PR 2's database half: completing an issue no longer trusts the caller's
-- path and checksum. It looks the object up in the private archive and refuses
-- a file that is not there, is not under this organisation's own prefix, is
-- not a PDF, or whose recorded hash disagrees with the one being filed.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. A tax point the invoice states itself
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

  if coalesce(btrim(v_c -> 'company' ->> 'company_registration_number'), '') = '' then
    v_bad := v_bad || jsonb_build_object('field', 'Company registration number',
      'refusal', 'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING');
  end if;
  if v_c -> 'company' -> 'registered_office' is null
     or v_c -> 'company' -> 'registered_office' = 'null'::jsonb then
    v_bad := v_bad || jsonb_build_object('field', 'Registered office',
      'refusal', 'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING');
  end if;

  -- The invoice's own tax point, not a date borrowed from somewhere else. The
  -- contract still carries a resolved value for the renderer; what is refused
  -- here is issuing without having decided the tax point.
  if not coalesce((v_c -> 'header' ->> 'tax_point_is_explicit')::boolean, false) then
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

-- ---------------------------------------------------------------------------
-- 2. Completing an issue proves the file is really in the archive
-- ---------------------------------------------------------------------------

insert into erp_ref.refusal (code, refused, why, next_action) values
  ('CLOVEERP_DOCUMENT_OBJECT_MISSING',
   'Recording an issued document whose file is not in the archive',
   'The number was reserved but no file was found in the document archive at the path given, so there is nothing to reprint later.',
   'Try issuing again. If it keeps failing, the rendering step is not completing.'),
  ('CLOVEERP_DOCUMENT_OBJECT_FOREIGN',
   'Recording a file stored outside this organisation''s own folder',
   'Every issued file lives under its own organisation''s folder in the archive. A path outside it would let one organisation point at another''s document.',
   'Issue the document again from this organisation.'),
  ('CLOVEERP_DOCUMENT_OBJECT_NOT_PDF',
   'Recording an issued document that is not a PDF',
   'The archive holds issued documents as PDFs only, so that a reprint returns the same readable file years later.',
   'Try issuing again.'),
  ('CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH',
   'Recording a checksum that does not match the stored file',
   'The checksum filed against the number must be the checksum of the bytes actually stored, otherwise a reprint cannot be proved to be the original.',
   'Issue the document again so the file and its checksum are written together.')
on conflict (code) do update
  set refused = excluded.refused, why = excluded.why, next_action = excluded.next_action;

create or replace function erp.complete_document_issue(
  p_document_issue_id uuid, p_storage_path text, p_content_checksum text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_obj    record;
  v_hash   text;
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);

  -- The caller no longer says what was stored; the archive does. A path or a
  -- checksum invented by a caller is refused before it can reach the ledger.
  if p_storage_path is null or p_storage_path not like (v_tenant::text || '/%') then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_FOREIGN: % is not under this organisation''s folder', coalesce(p_storage_path, '(none)')
      using errcode = '42501';
  end if;

  select o.metadata, o.user_metadata into v_obj
    from storage.objects o
   where o.bucket_id = 'document-output' and o.name = p_storage_path;
  if not found then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_MISSING: no file in the archive at %', p_storage_path
      using errcode = 'P0002';
  end if;

  if coalesce(v_obj.metadata ->> 'mimetype', '') <> 'application/pdf'
     or coalesce((v_obj.metadata ->> 'size')::bigint, 0) <= 0 then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_NOT_PDF: the archived file is not a PDF with contents'
      using errcode = '23514';
  end if;

  v_hash := lower(coalesce(v_obj.user_metadata ->> 'sha256', v_obj.metadata ->> 'sha256', ''));
  if v_hash = '' or v_hash <> lower(coalesce(p_content_checksum, '')) then
    raise exception 'CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH: the stored file does not hash to the checksum being filed'
      using errcode = '23514';
  end if;

  update erp.document_issue
     set storage_path = p_storage_path,
         content_checksum = v_hash,
         status = 'issued',
         completed_at = now()
   where tenant_id = v_tenant and id = p_document_issue_id and status = 'reserved';
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no reserved issue of that number to complete'
      using errcode = 'P0002';
  end if;

  return jsonb_build_object('document_issue_id', p_document_issue_id,
                            'status', 'issued', 'content_checksum', v_hash);
end $$;

comment on function erp.complete_document_issue is
  'Files a rendered document against its reserved number, only after finding '
  'the file in the private archive under this organisation''s own folder and '
  'confirming the checksum recorded on the stored object is the one being '
  'filed. The caller cannot name a path or a checksum of its own choosing.';

-- ---------------------------------------------------------------------------
-- 3. Previews: no number, and they expire
-- ---------------------------------------------------------------------------

create table if not exists erp.document_preview (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant (id) on delete cascade,
  document_kind       text not null,
  source_document_id  uuid not null,
  template_version_id uuid,
  storage_path        text not null,
  content_checksum    text,
  expires_at          timestamptz not null,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint document_preview_checksum_shape
    check (content_checksum is null or content_checksum ~ '^[0-9a-f]{64}$'),
  constraint document_preview_path_once unique (tenant_id, storage_path),
  constraint document_preview_tenant_id_key unique (tenant_id, id)
);

comment on table erp.document_preview is
  'A watermarked preview of a draft template against a real record. It takes '
  'no document number, it is not evidence of anything, and it is deleted when '
  'it expires whether or not anybody returns to the screen.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'document_preview', 'tenant_scoped',
   'Short-lived watermarked previews, expired and deleted rather than kept.')
on conflict (schema_name, table_name) do update
  set table_class = excluded.table_class, note = excluded.note;

create or replace function erp.record_document_preview(
  p_document_id uuid, p_template_version_id uuid, p_storage_path text,
  p_content_checksum text default null, p_minutes integer default 15)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_exp    timestamptz := now() + make_interval(mins => greatest(1, least(60, coalesce(p_minutes, 15))));
begin
  -- Both permissions: previewing a template is a template action, and it shows
  -- a real invoice, which is a sales action.
  perform erp.authorise('document.template_manage', null, null, null, 'document', p_document_id);
  perform erp.authorise('sales.invoice', null, null, null, 'document', p_document_id);

  if p_storage_path is null or p_storage_path not like (v_tenant::text || '/%') then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_FOREIGN: % is not under this organisation''s folder', coalesce(p_storage_path, '(none)')
      using errcode = '42501';
  end if;

  insert into erp.document_preview (tenant_id, document_kind, source_document_id,
                                    template_version_id, storage_path, content_checksum, expires_at)
  values (v_tenant, 'sales_invoice', p_document_id, p_template_version_id,
          p_storage_path, lower(nullif(p_content_checksum, '')), v_exp)
  on conflict (tenant_id, storage_path) do update set expires_at = excluded.expires_at
  returning id into v_id;

  return jsonb_build_object('document_preview_id', v_id, 'expires_at', v_exp,
                            'issued_number', null);
end $$;

create or replace function erp.purge_expired_document_previews()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_paths text[];
begin
  delete from erp.document_preview p
   where p.tenant_id = v_tenant and p.expires_at < now()
  returning p.storage_path into v_paths;

  select coalesce(array_agg(x), '{}') into v_paths from unnest(coalesce(v_paths, '{}')) x;
  return jsonb_build_object('expired', coalesce(array_length(v_paths, 1), 0),
                            'storage_paths', to_jsonb(coalesce(v_paths, '{}')));
end $$;

create or replace function public.erp_record_document_preview(
  p_document_id uuid, p_template_version_id uuid default null,
  p_storage_path text default null, p_content_checksum text default null,
  p_minutes integer default 15)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.record_document_preview(p_document_id, p_template_version_id,
                                     p_storage_path, p_content_checksum, p_minutes) $$;

create or replace function public.erp_purge_expired_document_previews()
returns jsonb language sql volatile set search_path to '' as $$
  select erp.purge_expired_document_previews() $$;

revoke all on function public.erp_record_document_preview(uuid, uuid, text, text, integer) from public, anon;
revoke all on function public.erp_purge_expired_document_previews() from public, anon;
grant execute on function public.erp_record_document_preview(uuid, uuid, text, text, integer) to authenticated, service_role;
grant execute on function public.erp_purge_expired_document_previews() to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_record_document_preview', 'erp.record_document_preview',
   'Registers a watermarked preview with an expiry. Takes no number. Gated on document.template_manage and sales.invoice.'),
  ('erp_purge_expired_document_previews', 'erp.purge_expired_document_previews',
   'Deletes this organisation''s expired preview rows and returns their paths so the files go too.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ---------------------------------------------------------------------------
-- 4. The archive is private, and provably so
-- ---------------------------------------------------------------------------

create or replace function erp.assert_document_archive_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_bad text;
begin
  if not exists (select 1 from storage.buckets b where b.id = 'document-output') then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_MISSING: the private document archive does not exist';
  end if;
  if exists (select 1 from storage.buckets b where b.id = 'document-output' and b.public) then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_PUBLIC: issued documents are not a public content surface';
  end if;

  -- Nothing hands the archive to a browser. Reads happen through short-lived
  -- signed URLs minted server-side after a fresh permission check.
  if exists (
    select 1 from pg_policies p
     where p.schemaname = 'storage' and p.tablename = 'objects'
       and (p.qual ilike '%document-output%' or coalesce(p.with_check, '') ilike '%document-output%')
       and (p.roles::text[] && array['anon', 'authenticated'])) then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_REACHABLE: a browser role can reach the document archive directly';
  end if;

  -- Every issued file is under the folder of the organisation that issued it.
  select string_agg(di.issued_number, ', ') into v_bad
    from erp.document_issue di
   where di.status in ('issued', 'sent')
     and (di.storage_path is null or di.storage_path not like (di.tenant_id::text || '/%'));
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_STRAY: % stored outside its own organisation''s folder', v_bad;
  end if;

  -- The preview register is governed like everything else.
  if not exists (select 1 from erp_meta.table_policy p
                  where p.schema_name = 'erp' and p.table_name = 'document_preview')
     or not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'erp' and c.relname = 'document_preview' and c.relrowsecurity) then
    raise exception 'ERPWARE_DOCUMENT_PREVIEW_UNGOVERNED: the preview register is unregistered or unprotected';
  end if;

  -- A preview never carries a number.
  if exists (select 1 from information_schema.columns c
              where c.table_schema = 'erp' and c.table_name = 'document_preview'
                and c.column_name in ('issued_number', 'sequence_number')) then
    raise exception 'ERPWARE_DOCUMENT_PREVIEW_NUMBERED: a preview must not be able to hold a document number';
  end if;

  select string_agg(c, ', ') into v_bad from unnest(array[
    'CLOVEERP_DOCUMENT_OBJECT_MISSING', 'CLOVEERP_DOCUMENT_OBJECT_FOREIGN',
    'CLOVEERP_DOCUMENT_OBJECT_NOT_PDF', 'CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH']) c
   where not exists (select 1 from erp_ref.refusal f
                      where f.code = c and coalesce(btrim(f.next_action), '') <> '');
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_REFUSAL_UNREGISTERED: % has nowhere to send the reader', v_bad;
  end if;

  return 'document archive: private, organisation-foldered, previews expiring, refusals registered';
end $$;

comment on function erp.assert_document_archive_sound is
  'Proves the issued-document archive is private, that no browser role can '
  'reach it, that every issued file sits under the folder of the organisation '
  'that issued it, and that previews are governed, numberless and expiring.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, blurb, runs_in_ci, seq) values
  ('document_archive', 'The issued-document archive is private', 'assertion', 'platform',
   'erp', 'assert_document_archive_sound', '',
   'An issued PDF is evidence. It is kept in a private archive under its own organisation''s folder, reachable only through a short-lived link minted after a fresh permission check, and previews of drafts expire instead of accumulating.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      schema_name = excluded.schema_name, blurb = excluded.blurb;

-- ---------------------------------------------------------------------------
-- 5. The suite: undone by the exception that ends it
-- ---------------------------------------------------------------------------

create or replace function erp_test.document_issue_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; r2 record;
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  cs1 uuid; cs2 uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_cust uuid; v_item uuid; v_inv uuid; v_empty uuid;
  v_issue uuid; v_issue2 uuid; v_num text; v_num2 text; v_n1 bigint; v_n2 bigint;
  v_env uuid; v_c jsonb; v_v jsonb; v_ok boolean; v_msg text; v_before integer; v_owner text;
  v_path text; v_path2 text; v_foreign text; v_prev jsonb;
begin
  begin
    select * into r from erp.provision_tenant('zzdocissue','Document Issue Suite','a@zzdocissue.test','Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zzdocissue.test','Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

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

    -- 1 ------------------------------------------------------------------
    v_v := erp.validate_sales_invoice_issue(v_inv);
    return query select 'a company that is not VAT registered still needs its own legal details',
      (v_v ->> 'is_vat_registered')::boolean = false
        and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING"}]'::jsonb
        and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING"}]'::jsonb
        and not ((v_v -> 'missing') @> '[{"refusal":"CLOVEERP_ISSUER_VAT_NUMBER_MISSING"}]'::jsonb),
      left(v_v -> 'missing' #>> '{}', 90);

    -- 2 ------------------------------------------------------------------
    return query select 'an invoice with no customer address to bill is refused by name',
      (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_CUSTOMER_ADDRESS_MISSING"}]'::jsonb
        and exists (select 1 from erp_ref.refusal f
                     where f.code = 'CLOVEERP_CUSTOMER_ADDRESS_MISSING'
                       and coalesce(btrim(f.next_action), '') <> ''),
      'no billing address on the customer';

    -- 3 ------------------------------------------------------------------
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

    -- 4 ------------------------------------------------------------------
    update erp.entity_tax_registration set registration_number = 'GB123456789'
     where tenant_id = r.tenant_id and entity_id = r.entity_id;
    update erp.document_line set net_minor = 10000, tax_code = null, tax_rate_pct = null, tax_minor = null
     where tenant_id = r.tenant_id and document_id = v_inv;

    v_v := erp.validate_sales_invoice_issue(v_inv);
    return query select 'a VAT invoice with a line carrying no VAT rate is refused by line',
      (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb,
      left(v_v -> 'missing' #>> '{}', 90);

    -- 5 ------------------------------------------------------------------
    update erp.document_line set tax_code = 'S', tax_rate_pct = 20, tax_minor = 2000
     where tenant_id = r.tenant_id and document_id = v_inv;
    v_empty := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    v_v := erp.validate_sales_invoice_issue(v_empty);
    return query select 'an invoice with no lines is refused',
      not (v_v ->> 'can_issue')::boolean
        and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_NO_LINES"}]'::jsonb,
      'zero lines';

    -- 6 ------------------------------------------------------------------
    v_v := erp.validate_sales_invoice_issue(v_inv);
    return query select 'an invoice must state its own tax point, not borrow another date',
      (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_TAX_POINT_MISSING"}]'::jsonb
        and not (v_v ->> 'can_issue')::boolean,
      'no tax point recorded on the invoice';

    -- 7 ------------------------------------------------------------------
    update erp.document set tax_point = current_date
     where tenant_id = r.tenant_id and id = v_inv;
    res := erp.issue_sales_invoice(v_inv);
    v_issue := (res ->> 'document_issue_id')::uuid;
    v_num := res ->> 'issued_number';
    select di.sequence_number, di.contract_snapshot into v_n1, v_c
      from erp.document_issue di where di.id = v_issue;
    return query select 'a complete invoice takes a number and freezes its whole contract',
      v_num is not null and v_c ?& array['header','company','customer','lines','tax_summary','totals','terminology','brand']
        and (v_c -> 'totals' ->> 'vat_total_sterling_minor')::bigint = 2000
        and (v_c -> 'header' ->> 'tax_point_is_explicit')::boolean,
      format('%s, VAT 20.00', v_num);

    -- 8 ------------------------------------------------------------------
    begin
      update erp.document_sequence set prefix = 'ZZZ'
       where tenant_id = r.tenant_id and document_kind = 'sales_invoice';
      v_ok := false; v_msg := 'the prefix changed after a number had been taken';
    exception when others then
      v_ok := (sqlerrm like '%CLOVEERP_SEQUENCE_PREFIX_FIXED%'); v_msg := left(sqlerrm, 58);
    end;
    return query select 'the numbering prefix cannot change once a number has been taken', v_ok, v_msg;

    -- 9 ------------------------------------------------------------------
    begin
      update erp.document_sequence set next_number = next_number - 1
       where tenant_id = r.tenant_id and document_kind = 'sales_invoice';
      v_ok := false; v_msg := 'the counter was wound back';
    exception when others then
      v_ok := (sqlerrm like '%CLOVEERP_SEQUENCE_MONOTONIC%'); v_msg := left(sqlerrm, 58);
    end;
    return query select 'the counter cannot be wound back to reuse a number', v_ok, v_msg;

    -- 10 -----------------------------------------------------------------
    begin
      delete from erp.document_issue where tenant_id = r.tenant_id and id = v_issue;
      v_ok := false; v_msg := 'an issue was deleted';
    exception when others then v_ok := true; v_msg := left(sqlerrm, 58); end;
    begin
      delete from erp.document_sequence where tenant_id = r.tenant_id and document_kind = 'sales_invoice';
      v_ok := v_ok and false; v_msg := 'the numbering register was deleted';
    exception when others then
      v_ok := v_ok and (sqlerrm like '%CLOVEERP_SEQUENCE_IMMUTABLE%'); v_msg := left(v_msg || ' / ' || sqlerrm, 58);
    end;
    return query select 'neither an issue nor its numbering register can be deleted', v_ok, v_msg;

    -- 11 -----------------------------------------------------------------
    v_path := r.tenant_id::text || '/' || v_num || '.pdf';
    begin
      perform erp.complete_document_issue(v_issue, v_path, repeat('a', 64));
      v_ok := false; v_msg := 'a number was filed against a file that is not there';
    exception when others then
      v_ok := (sqlerrm like '%CLOVEERP_DOCUMENT_OBJECT_MISSING%'); v_msg := left(sqlerrm, 58);
    end;
    return query select 'a number cannot be filed against a file that is not in the archive', v_ok, v_msg;

    -- 12 -----------------------------------------------------------------
    insert into storage.objects (bucket_id, name, metadata, user_metadata)
    values ('document-output', v_path,
            jsonb_build_object('mimetype', 'application/pdf', 'size', 20480),
            jsonb_build_object('sha256', repeat('a', 64)));
    begin
      perform erp.complete_document_issue(v_issue, v_path, repeat('c', 64));
      v_ok := false; v_msg := 'a checksum that does not match the file was accepted';
    exception when others then
      v_ok := (sqlerrm like '%CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH%'); v_msg := left(sqlerrm, 58);
    end;
    return query select 'a checksum that disagrees with the stored file is refused', v_ok, v_msg;

    -- 13 -----------------------------------------------------------------
    v_foreign := gen_random_uuid()::text || '/' || v_num || '.pdf';
    insert into storage.objects (bucket_id, name, metadata, user_metadata)
    values ('document-output', v_foreign,
            jsonb_build_object('mimetype', 'application/pdf', 'size', 20480),
            jsonb_build_object('sha256', repeat('a', 64)));
    begin
      perform erp.complete_document_issue(v_issue, v_foreign, repeat('a', 64));
      v_ok := false; v_msg := 'a file under another organisation''s folder was accepted';
    exception when others then
      v_ok := (sqlerrm like '%CLOVEERP_DOCUMENT_OBJECT_FOREIGN%'); v_msg := left(sqlerrm, 58);
    end;
    return query select 'a file under another organisation''s folder is refused', v_ok, v_msg;

    -- 14 -----------------------------------------------------------------
    res := erp.complete_document_issue(v_issue, v_path, repeat('a', 64));
    return query select 'the file is filed only when the archive and the checksum agree',
      res ->> 'content_checksum' = repeat('a', 64)
        and (select di.status from erp.document_issue di where di.id = v_issue) = 'issued',
      v_path;

    -- 15 -----------------------------------------------------------------
    v_prev := erp.record_document_preview(v_inv, null, r.tenant_id::text || '/preview.pdf', null, 15);
    return query select 'a preview takes no number and carries an expiry',
      v_prev ->> 'issued_number' is null
        and (v_prev ->> 'expires_at')::timestamptz > now()
        and (select s.next_number from erp.document_sequence s
              where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice') = v_n1 + 1,
      'preview registered, counter unmoved';

    -- 16 -----------------------------------------------------------------
    res := erp.amend_sales_invoice(v_issue, 'Wrong address');
    v_issue2 := (res ->> 'document_issue_id')::uuid;
    v_num2 := res ->> 'issued_number';
    select di.sequence_number into v_n2 from erp.document_issue di where di.id = v_issue2;
    return query select 'amending before sending voids the original and issues a new number',
      (select di.status from erp.document_issue di where di.id = v_issue) = 'void'
        and (select di.replaces_issue_id from erp.document_issue di where di.id = v_issue2) = v_issue
        and v_num2 <> v_num,
      format('%s replaced by %s', v_num, v_num2);

    -- 17 -----------------------------------------------------------------
    return query select 'a spent number is never handed out again',
      v_n2 = v_n1 + 1
        and (select count(*) from erp.document_issue di
              where di.tenant_id = r.tenant_id and di.sequence_number = v_n1) = 1,
      format('%s then %s', v_n1, v_n2);

    -- 18 -----------------------------------------------------------------
    v_path2 := r.tenant_id::text || '/' || v_num2 || '.pdf';
    insert into storage.objects (bucket_id, name, metadata, user_metadata)
    values ('document-output', v_path2,
            jsonb_build_object('mimetype', 'application/pdf', 'size', 20480),
            jsonb_build_object('sha256', repeat('b', 64)));
    perform erp.complete_document_issue(v_issue2, v_path2, repeat('b', 64));
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

    -- 19 -----------------------------------------------------------------
    select count(*) into v_before from erp.document_issue where tenant_id = r.tenant_id;
    res := erp.reprint_document_issue(v_issue2, 'Customer asked again');
    return query select 'reprinting returns the stored file and takes no number',
      res ->> 'content_checksum' = repeat('b', 64)
        and res ->> 'storage_path' = v_path2
        and (res ->> 'rendered_again')::boolean = false
        and (select count(*) from erp.document_issue where tenant_id = r.tenant_id) = v_before
        and (select s.next_number from erp.document_sequence s
              where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice') = v_n2 + 1,
      res ->> 'issued_number';

    -- 20 -----------------------------------------------------------------
    update erp.party set name = 'Renamed After Issue', legal_name = 'Renamed Legal Ltd'
     where tenant_id = r.tenant_id and id = v_cust;
    update erp.document_line set net_minor = 999999
     where tenant_id = r.tenant_id and document_id = v_inv;
    select di.contract_snapshot into v_c from erp.document_issue di where di.id = v_issue2;
    return query select 'the frozen contract still says what was issued after the records change',
      v_c -> 'customer' ->> 'legal_name' = 'Customer Legal Ltd'
        and (v_c -> 'totals' ->> 'net_minor')::bigint = 10000,
      'customer renamed and the line rewritten; the issue is unmoved';

    -- 21 -----------------------------------------------------------------
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

    -- 22 -----------------------------------------------------------------
    select * into r2 from erp.provision_tenant('zzdocissue2','Other Organisation','a@zzdocissue2.test','Other Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    v_owner := current_user;
    execute 'set local role authenticated';
    v_ok := public.erp_document_issues(null, 100) = '[]'::jsonb
        and not exists (select 1 from erp.document_issue di where di.id = v_issue2);
    execute format('set local role %I', v_owner);
    return query select 'another organisation cannot see this organisation''s issues',
      v_ok, 'read as the administrator of a different organisation';

    -- Everything above is undone by the raise below. Nothing this suite
    -- created outlives it, whichever way a case went.
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm not like '%CLOVEERP_SUITE_UNDO%' then raise; end if;
  end;
end;
$$;

create or replace function erp_test.assert_document_issue_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 22;
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
-- 6. Generators, then the proof
-- ---------------------------------------------------------------------------

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_document_issue_sound();
select erp.assert_document_archive_sound();
select erp_test.assert_document_issue_suite();