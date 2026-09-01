-- =============================================================================
-- Part 15 — the output subsystem: request, render, delivery
--
-- "One subsystem produces everything the platform emits: printed documents,
-- labels, emails, notifications and machine messages. Treating them separately
-- is how organisations end up with four template systems and no archive."
--
-- erp.output_template exists (§9.3's surface) and erp_ref.output_block_kind and
-- erp_ref.output_field describe what a template may contain. What §15.1 asks for
-- and was not there is the other three quarters of the common model —
-- output_request, output_render, output_delivery — and the property they exist
-- to hold:
--
--   "Every rendered output is archived and retrievable by its document
--   reference ... and its template version recorded so a document can always be
--   reproduced exactly as issued."
--
-- A template alone cannot hold that. Reproducing a document as issued needs the
-- version that produced it, the data it was given, and a checksum of what came
-- out — none of which existed. erp.output_template was not even versioned,
-- though §15.1 calls it "versioned, effective-dated" in its first line.
--
-- Two further sentences are load-bearing and are implemented as refusals rather
-- than as intentions:
--
--   §15.3 "Barcode verification is part of the definition of done: a template
--   ships with a test render and a decode check, so a label that will not scan
--   cannot be promoted."  →  a CHECK constraint. An active label version without
--   a passing decode check is not a warning; it is a row the database will not
--   hold.
--
--   §15.5 "Sending to a suppressed address is refused."  →  the delivery path
--   raises. Hard bounces suppress automatically and complaints suppress
--   permanently, so the list is the thing that must be consulted, not advice.
--
-- Versioning is the same shape as erp.kpi_version and erp.report_version: a
-- separate version table, effective-dated, one in force at a time. Third use of
-- one pattern rather than a third pattern.
-- =============================================================================

-- ── §15.1 the versioned template ────────────────────────────────────────────

create table if not exists erp.output_template_version (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references erp.tenant(id) on delete cascade,
  output_template_id    uuid not null,
  version               integer not null,
  rendering_engine      text not null default 'pdf',
  page                  jsonb not null default '{}',
  blocks                jsonb not null default '[]',
  required_permission   text not null default 'reporting.export',
  -- §15.3. Labels render to a printer command language at a fixed physical
  -- size; documents render to PDF for a person to read. The language is a
  -- property of the label, the resolution a property of the printer.
  label_language        text,
  test_render           text,
  decode_check_passed   boolean not null default false,
  decoded_value         text,
  status                text not null default 'draft',
  effective_from        date not null default current_date,
  effective_to          date,
  note                  text,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint output_template_version_positive check (version >= 1),
  constraint output_template_version_dates_ordered
    check (effective_to is null or effective_to > effective_from),
  constraint output_template_version_status_known
    check (status in ('draft','active','superseded')),
  constraint output_template_version_engine_known
    check (rendering_engine in ('pdf','zpl','epl','ipl','html','text')),
  constraint output_template_version_label_language_known
    check (label_language is null or label_language in ('zpl','epl','ipl')),
  -- §15.3, as a refusal rather than a warning: "a label that will not scan
  -- cannot be promoted". A label version may sit in draft without a decode
  -- check; it may not become active without one that passed and produced a
  -- value. Written against label_language rather than against the engine so a
  -- label is a label however it is rendered.
  constraint output_template_version_label_decodes
    check (label_language is null
           or status <> 'active'
           or (test_render is not null
               and decode_check_passed
               and coalesce(btrim(decoded_value), '') <> '')),
  constraint output_template_version_unique_per_template
    unique (tenant_id, output_template_id, version),
  constraint output_template_version_tenant_id_key unique (tenant_id, id),
  constraint output_template_version_template_fk
    foreign key (tenant_id, output_template_id)
      references erp.output_template (tenant_id, id) on delete cascade
);

comment on table erp.output_template_version is
  'Specification v1.2 §15.1: an output template is "versioned, effective-dated, '
  'bound to an output type and a rendering engine". The version is what makes '
  '§15.1''s archive claim possible — a document can be reproduced exactly as '
  'issued only if what produced it is still readable.';

comment on constraint output_template_version_label_decodes
  on erp.output_template_version is
  '§15.3: "a template ships with a test render and a decode check, so a label '
  'that will not scan cannot be promoted." A constraint rather than an '
  'assertion, because a label that cannot be scanned is not a finding to report '
  'later — it is a row that must not exist.';

-- ── §15.4 the printer ───────────────────────────────────────────────────────

create table if not exists erp.printer (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  site_id         uuid not null,
  code            text not null,
  name            text not null,
  printer_type    text not null default 'label',
  language        text,
  dots_per_inch   integer,
  physical_location text,
  default_stock   text,
  queue_address   text not null,
  status          text not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint printer_type_known check (printer_type in ('label','document')),
  constraint printer_language_known
    check (language is null or language in ('zpl','epl','ipl','pdf')),
  -- §15.3: "Label stock and resolution are properties of the printer, not the
  -- template: the same template renders at 203 and 300 dots per inch without a
  -- second template."
  constraint printer_label_has_language_and_dpi
    check (printer_type <> 'label' or (language is not null and dots_per_inch is not null)),
  constraint printer_status_known check (status in ('active','inactive')),
  constraint printer_unique_code unique (tenant_id, code),
  constraint printer_tenant_id_key unique (tenant_id, id),
  constraint printer_site_fk
    foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

comment on table erp.printer is
  'Specification v1.2 §15.4: "printer — registered per site, with type, '
  'language, resolution, physical location, default stock and queue address". '
  'Resolution lives here and not on the template, so one template renders at '
  '203 and 300 dots per inch.';

-- ── §15.1 request, render, delivery ─────────────────────────────────────────

create table if not exists erp.output_request (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  output_template_id  uuid not null,
  template_version_id uuid not null,
  object_type         text not null,
  object_id           uuid,
  destination_kind    text not null,
  printer_id          uuid,
  locale              text not null default 'en',
  copies              integer not null default 1,
  triggering_event    text,
  requested_by        uuid,
  requested_at        timestamptz not null default now(),
  constraint output_request_destination_known
    check (destination_kind in ('print','email','download','archive_only')),
  constraint output_request_copies_positive check (copies >= 1),
  -- A print with no printer is a request nobody can satisfy.
  constraint output_request_print_has_printer
    check (destination_kind <> 'print' or printer_id is not null),
  constraint output_request_tenant_id_key unique (tenant_id, id),
  constraint output_request_version_fk
    foreign key (tenant_id, template_version_id)
      references erp.output_template_version (tenant_id, id),
  constraint output_request_printer_fk
    foreign key (tenant_id, printer_id) references erp.printer (tenant_id, id)
);

comment on table erp.output_request is
  'Specification v1.2 §15.1: "an intent to produce something: template, data '
  'reference, destination, locale, copies, triggering event, requesting user".';

create table if not exists erp.output_render (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  output_request_id   uuid not null,
  template_version_id uuid not null,
  version             integer not null,
  format              text not null,
  checksum            text not null,
  byte_size           integer,
  data_snapshot       jsonb not null default '{}',
  document_reference  text,
  rendered_at         timestamptz not null default now(),
  -- §15.2: "Reissue is distinguishable from original: a reprinted document is
  -- marked as a copy, and the reissue is recorded."
  is_copy             boolean not null default false,
  reissue_of          uuid,
  constraint output_render_copy_names_its_original
    check ((is_copy and reissue_of is not null)
           or (not is_copy and reissue_of is null)),
  constraint output_render_not_its_own_reissue check (reissue_of is distinct from id),
  constraint output_render_tenant_id_key unique (tenant_id, id),
  constraint output_render_request_fk
    foreign key (tenant_id, output_request_id)
      references erp.output_request (tenant_id, id) on delete cascade,
  constraint output_render_version_fk
    foreign key (tenant_id, template_version_id)
      references erp.output_template_version (tenant_id, id),
  constraint output_render_reissue_fk
    foreign key (tenant_id, reissue_of) references erp.output_render (tenant_id, id)
);

create index if not exists output_render_by_reference
  on erp.output_render (tenant_id, document_reference);

comment on table erp.output_render is
  'Specification v1.2 §15.1: "the produced artefact: bytes, format, checksum, '
  'template version, data snapshot reference, timestamp." Append-only, because '
  'an archive that can be edited is not an archive.';

create table if not exists erp.output_delivery (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  output_render_id    uuid not null,
  destination         text not null,
  destination_kind    text not null,
  status              text not null default 'queued',
  attempts            integer not null default 0,
  confirmed_at        timestamptz,
  failure_reason      text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint output_delivery_status_known
    check (status in ('queued','sent','confirmed','failed')),
  constraint output_delivery_kind_known
    check (destination_kind in ('print','email','download','archive_only')),
  constraint output_delivery_failure_has_reason
    check (status <> 'failed' or failure_reason is not null),
  constraint output_delivery_render_fk
    foreign key (tenant_id, output_render_id)
      references erp.output_render (tenant_id, id) on delete cascade
);

comment on table erp.output_delivery is
  'Specification v1.2 §15.1: "the attempt to get it somewhere: destination, '
  'status, retries, confirmation or failure reason". §15.4 adds that printing '
  'is "a queued, retried operation with a monitored backlog, not a request that '
  'succeeds or vanishes", which is why attempts is on the row.';

-- ── §15.5 the suppression list ──────────────────────────────────────────────

create table if not exists erp.email_suppression (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  address         text not null,
  reason          text not null,
  is_permanent    boolean not null default false,
  suppressed_at   timestamptz not null default now(),
  note            text,
  constraint email_suppression_reason_known
    check (reason in ('hard_bounce','complaint','manual','unsubscribed')),
  -- §15.5: "hard bounces suppress automatically, complaints suppress
  -- permanently". A complaint that was not permanent would be a complaint the
  -- platform intended to ignore.
  constraint email_suppression_complaint_is_permanent
    check (reason <> 'complaint' or is_permanent),
  constraint email_suppression_unique unique (tenant_id, address)
);

comment on table erp.email_suppression is
  'Specification v1.2 §15.5: "hard bounces suppress automatically, complaints '
  'suppress permanently, and the suppression list is visible and auditable. '
  'Sending to a suppressed address is refused." Visible is why it is a tenant '
  'table rather than a provider setting nobody here can read.';

-- ── The path ────────────────────────────────────────────────────────────────

create or replace function erp.request_output(p_template_code text,
                                              p_object_type text,
                                              p_object_id uuid default null,
                                              p_destination_kind text default 'download',
                                              p_printer_code text default null,
                                              p_locale text default 'en',
                                              p_copies integer default 1,
                                              p_triggering_event text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_template erp.output_template%rowtype;
  v_ver      erp.output_template_version%rowtype;
  v_printer  uuid;
  v_request  uuid;
begin
  select * into v_template from erp.output_template t
   where t.tenant_id = v_tenant and t.code = p_template_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_OUTPUT_TEMPLATE: %', p_template_code
      using errcode = '23503';
  end if;

  select * into v_ver from erp.output_template_version tv
   where tv.tenant_id = v_tenant and tv.output_template_id = v_template.id
     and tv.status = 'active'
     and tv.effective_from <= current_date
     and (tv.effective_to is null or tv.effective_to > current_date)
   order by tv.version desc
   limit 1;

  if not found then
    raise exception
      'ERPWARE_OUTPUT_TEMPLATE_NOT_IN_FORCE: % has no version in force on %',
      p_template_code, current_date
      using errcode = '23503',
            hint = 'A template with no effective version has nothing to render.';
  end if;

  perform erp.authorise(v_ver.required_permission, null, null, null,
                        'output_template', v_template.id);

  if p_destination_kind = 'print' then
    select p.id into v_printer from erp.printer p
     where p.tenant_id = v_tenant and p.code = p_printer_code and p.status = 'active';
    if v_printer is null then
      raise exception 'ERPWARE_UNKNOWN_PRINTER: % is not an active printer here',
        coalesce(p_printer_code, '(none given)')
        using errcode = '23503';
    end if;
  end if;

  insert into erp.output_request
    (tenant_id, output_template_id, template_version_id, object_type, object_id,
     destination_kind, printer_id, locale, copies, triggering_event, requested_by)
  values (v_tenant, v_template.id, v_ver.id, p_object_type, p_object_id,
          p_destination_kind, v_printer, p_locale, p_copies, p_triggering_event,
          erp.current_principal_id())
  returning id into v_request;

  return jsonb_build_object('request_id', v_request, 'template', p_template_code,
                            'version', v_ver.version,
                            'destination_kind', p_destination_kind);
end;
$$;

comment on function erp.request_output is
  'Specification v1.2 §15.1. Resolves the template version in force, authorises '
  'on the permission that version names, and records the intent. The version is '
  'captured on the request so what happens later cannot drift from what was '
  'asked for.';

create or replace function erp.record_render(p_request_id uuid,
                                             p_format text,
                                             p_checksum text,
                                             p_byte_size integer default null,
                                             p_data_snapshot jsonb default '{}',
                                             p_document_reference text default null,
                                             p_reissue_of uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_req     erp.output_request%rowtype;
  v_ver     erp.output_template_version%rowtype;
  v_render  uuid;
  v_is_copy boolean := p_reissue_of is not null;
begin
  select * into v_req from erp.output_request r
   where r.tenant_id = v_tenant and r.id = p_request_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_OUTPUT_REQUEST' using errcode = '23503';
  end if;

  select * into v_ver from erp.output_template_version tv
   where tv.tenant_id = v_tenant and tv.id = v_req.template_version_id;

  insert into erp.output_render
    (tenant_id, output_request_id, template_version_id, version, format,
     checksum, byte_size, data_snapshot, document_reference, is_copy, reissue_of)
  values (v_tenant, p_request_id, v_req.template_version_id, v_ver.version,
          p_format, p_checksum, p_byte_size, p_data_snapshot,
          p_document_reference, v_is_copy, p_reissue_of)
  returning id into v_render;

  return jsonb_build_object('render_id', v_render, 'version', v_ver.version,
                            'is_copy', v_is_copy);
end;
$$;

comment on function erp.record_render is
  'Specification v1.2 §15.1 and §15.2. Records the artefact against the version '
  'that produced it, and marks a reissue as a copy naming what it reissues — '
  '"a reprinted document is marked as a copy, and the reissue is recorded".';

create or replace function erp.attempt_delivery(p_render_id uuid,
                                                p_destination text,
                                                p_destination_kind text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_delivery uuid;
  v_supp     erp.email_suppression%rowtype;
begin
  if not exists (select 1 from erp.output_render r
                  where r.tenant_id = v_tenant and r.id = p_render_id) then
    raise exception 'ERPWARE_UNKNOWN_OUTPUT_RENDER' using errcode = '23503';
  end if;

  -- §15.5: "Sending to a suppressed address is refused." Refused, not skipped:
  -- a send that quietly does nothing is how an organisation discovers months
  -- later that its invoices stopped arriving.
  if p_destination_kind = 'email' then
    select * into v_supp from erp.email_suppression s
     where s.tenant_id = v_tenant and lower(s.address) = lower(p_destination);
    if found then
      raise exception
        'ERPWARE_ADDRESS_SUPPRESSED: % is suppressed (%)', p_destination, v_supp.reason
        using errcode = '42501',
              detail = case when v_supp.is_permanent
                            then 'Permanently suppressed. A complaint cannot be undone by sending again.'
                            else 'Suppressed after a hard bounce. Correct the address rather than retrying this one.'
                       end;
    end if;
  end if;

  insert into erp.output_delivery
    (tenant_id, output_render_id, destination, destination_kind, status, attempts)
  values (v_tenant, p_render_id, p_destination, p_destination_kind, 'queued', 0)
  returning id into v_delivery;

  return jsonb_build_object('delivery_id', v_delivery, 'status', 'queued');
end;
$$;

comment on function erp.attempt_delivery is
  'Specification v1.2 §15.1 and §15.5. Queues a delivery, and refuses an email '
  'to a suppressed address rather than silently dropping it.';

-- ── The assertion ───────────────────────────────────────────────────────────

create or replace function erp.output_integrity_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'an output template has no version', t.code,
         'a template with no version has nothing to render'
    from erp.output_template t
   where not exists (select 1 from erp.output_template_version tv
                      where tv.tenant_id = t.tenant_id and tv.output_template_id = t.id)

  union all

  select 'an output template has more than one version in force', t.code,
         format('%s versions effective today', count(*)::text)
    from erp.output_template t
    join erp.output_template_version tv
      on tv.tenant_id = t.tenant_id and tv.output_template_id = t.id
   where tv.status = 'active'
     and tv.effective_from <= current_date
     and (tv.effective_to is null or tv.effective_to > current_date)
   group by t.code
  having count(*) > 1

  union all

  -- §15.3, checked as data as well as constrained. A version activated before
  -- the constraint existed would still be here, and a label that will not scan
  -- is worth finding however it got in.
  select 'an active label version has no passing decode check', tv.id::text,
         'a label that will not scan cannot be promoted'
    from erp.output_template_version tv
   where tv.label_language is not null
     and tv.status = 'active'
     and not (tv.test_render is not null and tv.decode_check_passed
              and coalesce(btrim(tv.decoded_value), '') <> '')

  union all

  -- §15.1's archive claim. A render whose version has gone cannot be reproduced
  -- as issued, and the archive would be claiming otherwise.
  select 'a render names a template version that no longer exists', r.id::text,
         'it can no longer be reproduced exactly as issued'
    from erp.output_render r
   where not exists (select 1 from erp.output_template_version tv
                      where tv.tenant_id = r.tenant_id and tv.id = r.template_version_id)

  union all

  -- §15.5. A delivery that went to a suppressed address means the refusal was
  -- bypassed, which is worth knowing even though the function refuses.
  select 'a delivery was made to a suppressed address', d.id::text, d.destination
    from erp.output_delivery d
    join erp.email_suppression s
      on s.tenant_id = d.tenant_id and lower(s.address) = lower(d.destination)
   where d.destination_kind = 'email'

  union all

  select 'a template version requires a permission that does not exist',
         tv.id::text, tv.required_permission
    from erp.output_template_version tv
   where not exists (select 1 from erp_ref.permission p
                      where p.code = tv.required_permission)

  union all

  -- §15.4: a label printer must speak a language some active label version
  -- renders, or nothing routed to it can print.
  select 'a label printer speaks a language no active label template renders',
         p.code, p.language
    from erp.printer p
   where p.printer_type = 'label' and p.status = 'active'
     and exists (select 1 from erp.output_template_version tv
                  where tv.tenant_id = p.tenant_id and tv.label_language is not null
                    and tv.status = 'active')
     and not exists (select 1 from erp.output_template_version tv
                      where tv.tenant_id = p.tenant_id
                        and tv.label_language = p.language
                        and tv.status = 'active')

  order by 1, 2
$$;

comment on function erp.output_integrity_report is
  'Specification v1.2 Part 15. Read by erp.assert_output_integrity().';

create or replace function erp.assert_output_integrity()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_versions integer; v_renders integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.output_integrity_report();

  if v_count > 0 then
    raise exception 'ERPWARE_OUTPUT_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§15.1 requires every rendered output to be reproducible '
                   'exactly as issued, and §15.3 that a label which will not '
                   'scan cannot be promoted.';
  end if;

  select count(*) into v_versions from erp.output_template_version;
  select count(*) into v_renders from erp.output_render;
  return format('output: %s template version(s), %s render(s) reproducible',
                v_versions, v_renders);
end;
$$;

comment on function erp.assert_output_integrity is
  'Fails where a template has no version or more than one in force, where an '
  'active label version has no passing decode check, where a render names a '
  'version that has gone, where a delivery reached a suppressed address, or '
  'where a version requires a permission that does not exist.';

-- ── Registration ────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp','output_template_version','tenant_scoped',
   'Part 15 §15.1. The versioned, effective-dated template, without which a document cannot be reproduced as issued.'),
  ('erp','printer','tenant_scoped',
   'Part 15 §15.4. Registered per site, carrying the resolution and stock the template deliberately does not.'),
  ('erp','output_request','tenant_scoped_append_only',
   'Part 15 §15.1. The intent to produce something. Append-only: a request that could be edited would not be the one that was answered.'),
  ('erp','output_render','tenant_scoped_append_only',
   'Part 15 §15.1. The archive. An archive that can be edited is not an archive.'),
  ('erp','output_delivery','tenant_scoped',
   'Part 15 §15.1. The attempt, which is retried and so must be updatable.'),
  ('erp','email_suppression','tenant_scoped',
   'Part 15 §15.5. Visible and auditable, which is why it lives here rather than in a provider setting nobody here can read.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('output_integrity', 'Output subsystem sound', 'assertion', 'platform',
   'erp', 'assert_output_integrity', '',
   'output_integrity_report', '',
   'Part 15''s common model: one template version in force at a time, every '
   'render still resolving to what produced it, no active label without a '
   'passing decode check, and no delivery to a suppressed address.',
   true, 56)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

insert into erp_ref.resource (key, locale, value, description) values
('output.reissued_copy', 'en', 'Copy',
 '§15.2: a reprinted document is marked as a copy, so an original and a reissue are never mistaken for one another.'),
('output.address_suppressed', 'en', 'This address cannot receive messages',
 '§15.5: sending to a suppressed address is refused rather than silently dropped.')
on conflict (key, locale) do update set value = excluded.value;

-- Part 15 §15.7 says templates, printers, routing rules, sender domains and
-- notification bindings are all configuration promoted through change sets, and
-- that preview before promotion is mandatory. This migration builds the model
-- and the refusals; it does not make the new tables promotable, for the same
-- reason and with the same consequence as erp.report_version.
insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('output_model_outside_promotion',
   'The output model is not yet promotable configuration',
   'v1.2 §15.7',
   'erp.output_template_version, erp.printer and erp.email_suppression are '
   'tenant-scoped, row-secured and audited, but are not on '
   'erp_meta.promotable_surface, so they cannot yet move between an '
   'organisation''s environments through a change set.',
   'Each needs a branch in erp.apply_change_set_item and an arm in '
   'erp.configuration_manifest, and §15.7 additionally requires a mandatory '
   'preview — "a rendered sample against representative data, and for labels a '
   'decode check" — which is a promotion-time gate rather than a table. The '
   'decode check itself is already enforced as a constraint, so the dangerous '
   'half is closed; what remains is the promotion path. Recorded open with '
   'report_version_outside_promotion, which needs the same work on the same '
   'function and should be done once rather than twice.',
   'open',
   'erp_meta.promotable_surface holds erp.output_template and not '
   'erp.output_template_version; erp.apply_change_set_item has no branch for a '
   'template version, a printer or a suppression.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_output_integrity();
select erp.assert_output_templates_sound();
