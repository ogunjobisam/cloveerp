set lock_timeout = '30s';

create or replace function erp.document_archive_object(
  p_tenant_id uuid, p_storage_path text)
returns table(metadata jsonb, user_metadata jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  select o.metadata, o.user_metadata
    from storage.objects o
   where o.bucket_id = 'document-output'
     and o.name = p_storage_path
     and o.name like (p_tenant_id::text || '/%')
$$;

revoke all on function erp.document_archive_object(uuid, text) from public, anon, authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'document_archive_object',
  'A real authenticated caller cannot read the private archive through storage RLS. This narrow helper returns metadata for one exact path only after its invoker has derived and supplied the current tenant; it is executable only by owner-held ERP code.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

create or replace function erp.complete_document_issue(
  p_document_issue_id uuid, p_storage_path text, p_content_checksum text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_obj record;
  v_hash text;
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);
  if p_storage_path is null or p_storage_path not like (v_tenant::text || '/%') then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_FOREIGN: % is not under this organisation''s folder', coalesce(p_storage_path, '(none)') using errcode = '42501';
  end if;
  select a.metadata, a.user_metadata into v_obj from erp.document_archive_object(v_tenant, p_storage_path) a;
  if not found then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_MISSING: no file in the archive at %', p_storage_path using errcode = 'P0002';
  end if;
  if coalesce(v_obj.metadata ->> 'mimetype', '') <> 'application/pdf'
     or coalesce((v_obj.metadata ->> 'size')::bigint, 0) <= 0 then
    raise exception 'CLOVEERP_DOCUMENT_OBJECT_NOT_PDF: the archived file is not a PDF with contents' using errcode = '23514';
  end if;
  v_hash := lower(coalesce(v_obj.user_metadata ->> 'sha256', v_obj.metadata ->> 'sha256', ''));
  if v_hash = '' or v_hash <> lower(coalesce(p_content_checksum, '')) then
    raise exception 'CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH: the stored file does not hash to the checksum being filed' using errcode = '23514';
  end if;
  update erp.document_issue
     set storage_path = p_storage_path, content_checksum = v_hash,
         status = 'issued', completed_at = now()
   where tenant_id = v_tenant and id = p_document_issue_id and status = 'reserved';
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no reserved issue of that number to complete' using errcode = 'P0002';
  end if;
  return jsonb_build_object('document_issue_id', p_document_issue_id, 'status', 'issued', 'content_checksum', v_hash);
end $$;

comment on function erp.complete_document_issue is
  'Files a rendered document against its reserved number after authorisation. A private SECURITY DEFINER helper reads metadata for that one tenant-prefixed path through storage RLS; browser roles retain no archive policy.';

create or replace function erp.fail_document_issue(p_document_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'CLOVEERP_VALIDATION: say why the reserved number could not be completed' using errcode = '23514';
  end if;
  update erp.document_issue
     set status = 'void', voided_at = now(), void_reason = btrim(p_reason)
   where tenant_id = v_tenant and id = p_document_issue_id and status = 'reserved';
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no reserved issue of that number to fail' using errcode = 'P0002';
  end if;
  return jsonb_build_object('document_issue_id', p_document_issue_id, 'status', 'void', 'number_remains_spent', true);
end $$;

create or replace function public.erp_fail_document_issue(p_document_issue_id uuid, p_reason text)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.fail_document_issue(p_document_issue_id, p_reason) $$;
revoke all on function public.erp_fail_document_issue(uuid, text) from public, anon;
grant execute on function public.erp_fail_document_issue(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_fail_document_issue', 'erp.fail_document_issue',
  'Marks a reserved issue void, with its failure reason, when rendering or archive completion fails. Gated on document.issue.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

create or replace function erp.purge_expired_document_previews()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_paths text[];
begin
  with gone as (
    delete from erp.document_preview p
     where p.tenant_id = v_tenant and p.expires_at < now()
     returning p.storage_path
  )
  select coalesce(array_agg(g.storage_path order by g.storage_path), '{}') into v_paths from gone g;
  return jsonb_build_object('expired', cardinality(v_paths), 'storage_paths', to_jsonb(v_paths));
end $$;

comment on function erp.purge_expired_document_previews is
  'Deletes every expired preview row for the current organisation and returns all object paths. The scheduled dispatch removes those private objects even when nobody returns to the document screen.';

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
  if not exists (select 1 from storage.buckets b where b.id = 'document-output'
                  and b.file_size_limit = 20971520
                  and b.allowed_mime_types = array['application/pdf']::text[]) then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_FORMAT: document-output must be PDF-only with a 20 MiB file limit';
  end if;
  if exists (select 1 from pg_policies p where p.schemaname = 'storage' and p.tablename = 'objects'
              and (p.qual ilike '%document-output%' or coalesce(p.with_check, '') ilike '%document-output%')
              and (p.roles::text[] && array['anon', 'authenticated'])) then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_REACHABLE: a browser role can reach the document archive directly';
  end if;
  select string_agg(di.issued_number, ', ') into v_bad from erp.document_issue di
   where di.status in ('issued', 'sent')
     and (di.storage_path is null or di.storage_path not like (di.tenant_id::text || '/%'));
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_STRAY: % stored outside its own organisation''s folder', v_bad;
  end if;
  if not exists (select 1 from erp_meta.table_policy p where p.schema_name = 'erp' and p.table_name = 'document_preview')
     or not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'erp' and c.relname = 'document_preview' and c.relrowsecurity) then
    raise exception 'ERPWARE_DOCUMENT_PREVIEW_UNGOVERNED: the preview register is unregistered or unprotected';
  end if;
  if exists (select 1 from information_schema.columns c where c.table_schema = 'erp'
              and c.table_name = 'document_preview' and c.column_name in ('issued_number', 'sequence_number')) then
    raise exception 'ERPWARE_DOCUMENT_PREVIEW_NUMBERED: a preview must not be able to hold a document number';
  end if;
  select string_agg(c, ', ') into v_bad from unnest(array[
    'CLOVEERP_DOCUMENT_OBJECT_MISSING', 'CLOVEERP_DOCUMENT_OBJECT_FOREIGN',
    'CLOVEERP_DOCUMENT_OBJECT_NOT_PDF', 'CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH']) c
   where not exists (select 1 from erp_ref.refusal f where f.code = c and coalesce(btrim(f.next_action), '') <> '');
  if v_bad is not null then
    raise exception 'ERPWARE_DOCUMENT_REFUSAL_UNREGISTERED: % has nowhere to send the reader', v_bad;
  end if;
  return 'document archive: private, PDF-only, size-limited, organisation-foldered, previews expiring, refusals registered';
end $$;

create or replace function erp_test.document_archive_authenticated_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; r2 record;
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  v_owner text := current_user; v_uom uuid; v_site uuid; v_cust uuid; v_item uuid; v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_inv4 uuid;
  v_issue uuid; v_issue2 uuid; v_issue3 uuid; v_issue4 uuid; v_num text; v_path text; v_path2 text;
  v_result jsonb; v_ok boolean; v_msg text; v_next bigint; v_preview1 uuid; v_preview2 uuid; v_cs uuid; v_approver uuid; v_token text;
begin
  begin
    select * into r from erp.provision_tenant('zzdocauth','Document Auth Suite','a@zzdocauth.test','Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    v_result := public.erp_invite_principal('approver@zzdocauth.test','Suite Approver');
    v_approver := (v_result ->> 'app_user_id')::uuid; v_token := v_result ->> 'token';
    perform erp.grant_role(v_approver, 'administrator', null, null, 'suite approval');
    v_cs := erp.configure_finance(extract(year from current_date)::integer, 'GBP', r.entity_id);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cs := erp.configure_sales(15);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
    insert into erp.party (tenant_id, code, name, legal_name, status)
    values (r.tenant_id,'CUST','Customer','Customer Ltd','active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id,v_cust,'customer','{}','active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;
    update erp.entity set registration_number = '07123456' where tenant_id = r.tenant_id and id = r.entity_id;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines, locality, postcode, country_code, is_default, valid_from)
    select r.tenant_id,e.party_id,'registered','Registered office',array['1 Ledger Way'],'Leeds','LS1 1AA','GB',true,current_date
      from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines, locality, postcode, country_code, is_default, valid_from)
    values (r.tenant_id,v_cust,'billing','Invoice to',array['2 Buyer Street'],'York','YO1 1AA','GB',true,current_date);
    v_inv := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv, v_item, 1, 10000, 'widget');
    update erp.document set tax_point = current_date where tenant_id = r.tenant_id and id = v_inv;
    update erp.document_line set net_minor = 10000, tax_code = 'Z', tax_rate_pct = 0, tax_minor = 0 where tenant_id = r.tenant_id and document_id = v_inv;

    execute 'set local role authenticated';
    v_result := public.erp_issue_sales_invoice(v_inv, null);
    v_issue := (v_result ->> 'document_issue_id')::uuid; v_num := v_result ->> 'issued_number';
    v_path := r.tenant_id::text || '/' || v_num || '.pdf';
    execute format('set local role %I', v_owner);
    insert into storage.objects (bucket_id, name, metadata, user_metadata)
    values ('document-output', v_path, '{"mimetype":"application/pdf","size":20480}', jsonb_build_object('sha256', repeat('a',64)));
    execute 'set local role authenticated';
    v_result := public.erp_complete_document_issue(v_issue, v_path, repeat('a',64));
    v_ok := v_result ->> 'status' = 'issued';
    execute format('set local role %I', v_owner);
    return query select 'authenticated caller completes an issue through the private archive boundary', v_ok, v_path;

    v_inv2 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv2, v_item, 1, 10000, 'widget');
    update erp.document set tax_point = current_date where tenant_id = r.tenant_id and id = v_inv2;
    update erp.document_line set net_minor = 10000, tax_code = 'Z', tax_rate_pct = 0, tax_minor = 0 where tenant_id = r.tenant_id and document_id = v_inv2;
    execute 'set local role authenticated';
    v_result := public.erp_issue_sales_invoice(v_inv2, null);
    v_issue2 := (v_result ->> 'document_issue_id')::uuid;
    begin
      perform public.erp_complete_document_issue(v_issue2, r.tenant_id::text || '/missing.pdf', repeat('b',64));
      v_ok := false; v_msg := 'missing object accepted';
    exception when others then v_ok := sqlerrm like '%CLOVEERP_DOCUMENT_OBJECT_MISSING%'; v_msg := left(sqlerrm,80); end;
    perform public.erp_fail_document_issue(v_issue2, 'archive completion failed in fixture');
    select s.next_number into v_next from erp.document_sequence s where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice';
    v_ok := v_ok and exists (select 1 from erp.document_issue di where di.id = v_issue2 and di.status = 'void'
                              and di.void_reason = 'archive completion failed in fixture')
                 and v_next > (select di.sequence_number from erp.document_issue di where di.id = v_issue2);
    execute format('set local role %I', v_owner);
    return query select 'authenticated failed completion leaves an explained void and never reuses its number', v_ok, v_msg;

    v_inv3 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv3, v_item, 1, 10000, 'widget');
    update erp.document set tax_point = current_date where tenant_id = r.tenant_id and id = v_inv3;
    update erp.document_line set net_minor = 10000, tax_code = 'Z', tax_rate_pct = 0, tax_minor = 0 where tenant_id = r.tenant_id and document_id = v_inv3;
    execute 'set local role authenticated';
    v_result := public.erp_issue_sales_invoice(v_inv3, null);
    v_issue3 := (v_result ->> 'document_issue_id')::uuid;
    v_path2 := r.tenant_id::text || '/' || (v_result ->> 'issued_number') || '.pdf';
    execute format('set local role %I', v_owner);
    insert into storage.objects (bucket_id, name, metadata, user_metadata)
    values ('document-output', v_path2, '{"mimetype":"application/pdf","size":20480}', jsonb_build_object('sha256', repeat('c',64)));
    execute 'set local role authenticated';
    begin
      perform public.erp_complete_document_issue(v_issue3, v_path2, repeat('d',64));
      v_ok := false; v_msg := 'bad checksum accepted';
    exception when others then v_ok := sqlerrm like '%CLOVEERP_DOCUMENT_CHECKSUM_MISMATCH%'; v_msg := left(sqlerrm,80); end;
    perform public.erp_fail_document_issue(v_issue3, 'checksum mismatch in fixture');
    execute format('set local role %I', v_owner);
    return query select 'authenticated caller cannot file a checksum unlike the stored bytes', v_ok, v_msg;

    v_inv4 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv4, v_item, 1, 10000, 'widget');
    update erp.document set tax_point = current_date where tenant_id = r.tenant_id and id = v_inv4;
    update erp.document_line set net_minor = 10000, tax_code = 'Z', tax_rate_pct = 0, tax_minor = 0 where tenant_id = r.tenant_id and document_id = v_inv4;
    execute 'set local role authenticated';
    v_result := public.erp_issue_sales_invoice(v_inv4, null);
    v_issue4 := (v_result ->> 'document_issue_id')::uuid;
    begin
      perform public.erp_complete_document_issue(v_issue4, gen_random_uuid()::text || '/foreign.pdf', repeat('e',64));
      v_ok := false; v_msg := 'foreign path accepted';
    exception when others then v_ok := sqlerrm like '%CLOVEERP_DOCUMENT_OBJECT_FOREIGN%'; v_msg := left(sqlerrm,80); end;
    perform public.erp_fail_document_issue(v_issue4, 'foreign path in fixture');
    execute format('set local role %I', v_owner);
    return query select 'authenticated caller cannot file another organisation path', v_ok, v_msg;

    execute 'set local role authenticated';
    v_result := public.erp_reprint_document_issue(v_issue, 'fixture reprint');
    v_ok := v_result ->> 'storage_path' = v_path and v_result ->> 'content_checksum' = repeat('a',64)
      and (v_result ->> 'rendered_again')::boolean = false;
    execute format('set local role %I', v_owner);
    return query select 'authenticated reprint returns the exact stored path and hash without rendering', v_ok, v_result::text;

    insert into erp.document_preview (tenant_id, document_kind, source_document_id, storage_path, expires_at)
    values (r.tenant_id,'sales_invoice',v_inv,r.tenant_id::text || '/previews/one.pdf',now()-interval '1 minute') returning id into v_preview1;
    insert into erp.document_preview (tenant_id, document_kind, source_document_id, storage_path, expires_at)
    values (r.tenant_id,'sales_invoice',v_inv,r.tenant_id::text || '/previews/two.pdf',now()-interval '1 minute') returning id into v_preview2;
    execute 'set local role authenticated';
    v_result := public.erp_purge_expired_document_previews();
    v_ok := (v_result ->> 'expired')::integer = 2 and jsonb_array_length(v_result -> 'storage_paths') = 2;
    execute format('set local role %I', v_owner);
    return query select 'authenticated sweep returns every expired preview path', v_ok, v_result::text;

    select * into r2 from erp.provision_tenant('zzdocauth2','Other Organisation','b@zzdocauth.test','Other Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, true);
    perform erp.claim_invitation(r2.admin_token);
    execute 'set local role authenticated';
    select count(*) = 0 into v_ok from storage.objects o where o.bucket_id = 'document-output' and o.name = v_path;
    execute format('set local role %I', v_owner);
    return query select 'authenticated second tenant cannot read the first tenant archive object', v_ok, v_path;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;
end $$;

create or replace function erp_test.assert_document_archive_authenticated_suite()
returns text language plpgsql set search_path = '' as $$
declare v_total integer; v_failed integer; v_detail text;
begin
  select count(*), count(*) filter (where not s.passed),
         string_agg(format('  %s — %s',s.case_name,s.detail),E'\n') filter (where not s.passed)
    into v_total,v_failed,v_detail from erp_test.document_archive_authenticated_suite() s;
  if v_failed > 0 then raise exception E'ERPWARE_DOCUMENT_ARCHIVE_AUTH_SUITE_FAILED: %/% failed\n%',v_failed,v_total,v_detail; end if;
  if v_total <> 7 then raise exception 'ERPWARE_DOCUMENT_ARCHIVE_AUTH_SUITE_INCOMPLETE: expected 7 cases, ran %',v_total; end if;
  return format('document archive authenticated: %s/%s cases passed',v_total,v_total);
end $$;

insert into erp_meta.diagnostic_check
  (code,title,kind,scope,schema_name,function_name,arguments,blurb,runs_in_ci,seq)
values ('document_archive_authenticated','Real callers can complete documents without seeing the private archive',
        'assertion','platform','erp_test','assert_document_archive_authenticated_suite','',
        'Runs completion, failed-completion voiding, bad checksum and path refusals, exact-byte reprint, multi-preview cleanup and cross-organisation archive isolation as authenticated.',
        true,(select coalesce(max(seq),0)+1 from erp_meta.diagnostic_check))
on conflict (code) do update set title=excluded.title,schema_name=excluded.schema_name,
 function_name=excluded.function_name,blurb=excluded.blurb,runs_in_ci=excluded.runs_in_ci;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

do $tighten$
declare v_def text;
begin
  v_def := pg_get_functiondef('erp_test.document_issue_suite()'::regprocedure);
  if position('exception when others then v_ok := true; v_msg := left(sqlerrm, 58); end;' in v_def) > 0 then
    v_def := replace(v_def,
      'exception when others then v_ok := true; v_msg := left(sqlerrm, 58); end;',
      'exception when others then v_ok := (sqlerrm like ''%CLOVEERP_ISSUE_IMMUTABLE%''); v_msg := left(sqlerrm, 58); end;');
    execute v_def;
  end if;
end
$tighten$;

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_document_issue_sound();
select erp.assert_document_archive_sound();
select erp_test.assert_document_issue_suite();
select erp_test.assert_document_archive_authenticated_suite();