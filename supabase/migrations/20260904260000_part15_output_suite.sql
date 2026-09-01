-- =============================================================================
-- Part 15 — the adversarial suite
--
-- erp.assert_output_integrity() passes on an empty schema. These are the
-- sentences worth attacking:
--
--   §15.3 "a label that will not scan cannot be promoted" — so the suite tries
--         to promote one, twice: once with no decode check at all and once with
--         a check that did not pass.
--   §15.2 "a reprinted document is marked as a copy, and the reissue is
--         recorded" — so the suite reissues one and reads back both halves,
--         and tries to record a copy that names nothing.
--   §15.5 "Sending to a suppressed address is refused" — so the suite sends to
--         one, and checks the refusal names why rather than dropping it.
--   §15.1 "its template version recorded so a document can always be reproduced
--         exactly as issued" — so the suite supersedes the version and confirms
--         the earlier render still names the one that made it.
-- =============================================================================

create or replace function erp_test.output_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ad uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzout-a';
  v_site uuid; v_doc uuid; v_label uuid; v_v1 uuid; v_v2 uuid; v_lv uuid;
  v_printer uuid; v_ok boolean; v_msg text; res jsonb;
  v_req uuid; v_render uuid; v_copy uuid;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Output A', 'admin-a@zzout.test', 'Output A Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ad, 'admin-a@zzout.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- Templates are guarded configuration, so the fixture is built inside a
  -- bootstrap window, as configuration authoring should be. It closes before
  -- anything is produced.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  select id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.status = 'active' limit 1;

  if v_site is null then
    -- erp.provision_tenant() creates a company but no site, and a site belongs
    -- to a company: §15.4 registers printers per site, so the suite needs one.
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    select v_tenant, e.id, 'MAIN', 'Main site', 'warehouse', 'active'
      from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active'
     order by e.code limit 1
    returning id into v_site;
  end if;

  insert into erp.output_template (tenant_id, code, name_key, kind, base_type_code)
  values (v_tenant, 'delivery_note', 'output.delivery_note', 'document', 'delivery')
  returning id into v_doc;

  insert into erp.output_template (tenant_id, code, name_key, kind)
  values (v_tenant, 'pallet_label', 'output.pallet_label', 'label')
  returning id into v_label;

  -- ── §15.1 a template with no version has nothing to render ────────────────

  begin
    perform erp.assert_output_integrity();
    v_ok := false; v_msg := 'a template with no version was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_OUTPUT_UNSOUND%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a template with no version fails the assertion', v_ok, v_msg;

  insert into erp.output_template_version
    (tenant_id, output_template_id, version, rendering_engine, blocks,
     required_permission, status, effective_from)
  values (v_tenant, v_doc, 1, 'pdf', '[{"kind":"title"},{"kind":"lines"}]'::jsonb,
          'reporting.export', 'active', current_date - 1)
  returning id into v_v1;

  -- ── §15.3 a label that will not scan cannot be promoted ───────────────────

  begin
    insert into erp.output_template_version
      (tenant_id, output_template_id, version, rendering_engine, label_language,
       blocks, status, effective_from)
    values (v_tenant, v_label, 1, 'zpl', 'zpl',
            '[{"kind":"barcode"}]'::jsonb, 'active', current_date);
    v_ok := false; v_msg := 'an active label with no decode check was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'an ACTIVE label with no decode check is refused', v_ok, v_msg;

  begin
    insert into erp.output_template_version
      (tenant_id, output_template_id, version, rendering_engine, label_language,
       blocks, test_render, decode_check_passed, decoded_value,
       status, effective_from)
    values (v_tenant, v_label, 2, 'zpl', 'zpl', '[{"kind":"barcode"}]'::jsonb,
            '^XA^BY2^BC^FD0012345678901231^FS^XZ', false, null,
            'active', current_date);
    v_ok := false; v_msg := 'a decode check that did not pass was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'and so is one whose decode check did not pass', v_ok, v_msg;

  insert into erp.output_template_version
    (tenant_id, output_template_id, version, rendering_engine, label_language,
     blocks, test_render, decode_check_passed, decoded_value,
     status, effective_from)
  values (v_tenant, v_label, 3, 'zpl', 'zpl', '[{"kind":"barcode"}]'::jsonb,
          '^XA^BY2^BC^FD0012345678901231^FS^XZ', true, '0012345678901231',
          'active', current_date)
  returning id into v_lv;

  return query select 'while one that scans is promoted',
    v_lv is not null, 'test render, decode check passed, value read back';

  -- A draft label needs no decode check: §15.3 gates promotion, not authoring.
  begin
    insert into erp.output_template_version
      (tenant_id, output_template_id, version, rendering_engine, label_language,
       blocks, status, effective_from)
    values (v_tenant, v_label, 4, 'zpl', 'zpl', '[{"kind":"barcode"}]'::jsonb,
            'draft', current_date);
    v_ok := true; v_msg := 'draft accepted without a decode check';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'but a DRAFT label may be authored without one', v_ok, v_msg;

  insert into erp.printer
    (tenant_id, site_id, code, name, printer_type, language, dots_per_inch,
     queue_address, status)
  values (v_tenant, v_site, 'pallet1', 'Pallet printer', 'label', 'zpl', 203,
          'tcp://printer.local:9100', 'active')
  returning id into v_printer;

  -- §15.4: resolution is a printer property, so a label printer must state one.
  begin
    insert into erp.printer
      (tenant_id, site_id, code, name, printer_type, language, queue_address)
    values (v_tenant, v_site, 'bad1', 'No resolution', 'label', 'zpl',
            'tcp://x:9100');
    v_ok := false; v_msg := 'a label printer with no resolution was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'a label printer must state its resolution', v_ok, v_msg;

  perform erp_test.close_bootstrap_window(v_tenant);

  -- ── §15.1 request, render, and the version that produced it ───────────────

  res := erp.request_output('delivery_note', 'document', null, 'download');
  v_req := (res ->> 'request_id')::uuid;

  return query select 'a request captures the version in force',
    (res ->> 'version')::integer = 1, format('version %s', res ->> 'version');

  res := erp.record_render(v_req, 'pdf', 'sha256:aaa', 2048,
                           '{"total":100}'::jsonb, 'DN-000001');
  v_render := (res ->> 'render_id')::uuid;

  return query select 'the render is archived against that version',
    (select rr.version from erp.output_render rr where rr.id = v_render) = 1
      and (select rr.checksum from erp.output_render rr where rr.id = v_render) = 'sha256:aaa',
    'bytes, format, checksum, template version, data snapshot, timestamp';

  return query select 'and is retrievable by its document reference',
    exists (select 1 from erp.output_render rr
             where rr.tenant_id = v_tenant and rr.document_reference = 'DN-000001'),
    '§15.1: archived and retrievable by its document reference';

  return query select 'an original is not a copy',
    (select not rr.is_copy and rr.reissue_of is null
       from erp.output_render rr where rr.id = v_render),
    'nothing is marked a copy until something reissues it';

  -- ── §15.2 reissue is distinguishable from original ────────────────────────

  res := erp.record_render(v_req, 'pdf', 'sha256:bbb', 2048,
                           '{"total":100}'::jsonb, 'DN-000001', v_render);
  v_copy := (res ->> 'render_id')::uuid;

  return query select 'a reissue is marked as a copy',
    (res ->> 'is_copy')::boolean,
    '§15.2: a reprinted document is marked as a copy';

  return query select 'and records what it reissues',
    (select rr.reissue_of from erp.output_render rr where rr.id = v_copy) = v_render,
    'the reissue is recorded, not merely flagged';

  begin
    insert into erp.output_render
      (tenant_id, output_request_id, template_version_id, version, format,
       checksum, is_copy, reissue_of)
    values (v_tenant, v_req, v_v1, 1, 'pdf', 'sha256:ccc', true, null);
    v_ok := false; v_msg := 'a copy naming nothing was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'a copy that names no original is refused', v_ok, v_msg;

  -- ── §15.5 sending to a suppressed address is refused ──────────────────────

  res := erp.attempt_delivery(v_render, 'ops@customer.test', 'email');
  return query select 'a delivery to a good address is queued',
    (res ->> 'status') = 'queued', res ->> 'status';

  insert into erp.email_suppression (tenant_id, address, reason, is_permanent)
  values (v_tenant, 'gone@customer.test', 'hard_bounce', false);

  begin
    perform erp.attempt_delivery(v_render, 'gone@customer.test', 'email');
    v_ok := false; v_msg := 'a suppressed address was sent to';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ADDRESS_SUPPRESSED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and one to a suppressed address is REFUSED, not dropped',
    v_ok, v_msg;

  begin
    perform erp.attempt_delivery(v_render, 'GONE@Customer.TEST', 'email');
    v_ok := false; v_msg := 'case changed the answer';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ADDRESS_SUPPRESSED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'regardless of the case it is typed in', v_ok, v_msg;

  -- §15.5: a complaint suppresses permanently, and may not say otherwise.
  begin
    insert into erp.email_suppression (tenant_id, address, reason, is_permanent)
    values (v_tenant, 'angry@customer.test', 'complaint', false);
    v_ok := false; v_msg := 'a non-permanent complaint was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'a complaint cannot be recorded as temporary', v_ok, v_msg;

  -- ── §15.1 the archive survives a new version ──────────────────────────────

  perform erp_test.reopen_bootstrap_window(v_tenant);
  update erp.output_template_version
     set effective_to = current_date, status = 'superseded' where id = v_v1;
  insert into erp.output_template_version
    (tenant_id, output_template_id, version, rendering_engine, blocks,
     required_permission, status, effective_from)
  values (v_tenant, v_doc, 2, 'pdf',
          '[{"kind":"title"},{"kind":"lines"},{"kind":"totals"}]'::jsonb,
          'reporting.export', 'active', current_date)
  returning id into v_v2;
  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.request_output('delivery_note', 'document', null, 'download');
  return query select 'a later request uses the version now in force',
    (res ->> 'version')::integer = 2, format('version %s', res ->> 'version');

  return query select 'while the archived document still names the version that issued it',
    (select rr.version from erp.output_render rr where rr.id = v_render) = 1,
    '§15.1: reproduced exactly as issued, not as it would be issued today';

  return query select 'and the whole subsystem asserts sound',
    erp.assert_output_integrity() is not null, 'no findings';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id = ad;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzout-%')
      and not exists (select 1 from auth.users u where u.id = ad),
    'renders and deliveries go with the organisation, being tenant-scoped';
end;
$$;

comment on function erp_test.output_suite is
  'Specification v1.2 Part 15, proven adversarially: a label that will not scan '
  'is refused promotion twice over, a reissue is marked and recorded, a '
  'suppressed address is refused rather than dropped, and an archived document '
  'still names the version that issued it after a newer one takes force.';

create or replace function erp_test.assert_output_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _output_result on commit drop as
    select * from erp_test.output_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _output_result;

  if v_total <> 21 then
    raise exception 'ERPWARE_OUTPUT_SUITE_SHRANK: % case(s), expected 21', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_OUTPUT_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('output: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_output_suite();
