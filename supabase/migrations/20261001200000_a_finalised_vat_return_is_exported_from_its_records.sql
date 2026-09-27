set lock_timeout = '30s';

-- =============================================================================
-- 20261001200000  A finalised VAT return is exported from its records
-- -----------------------------------------------------------------------------
-- PR14 M3 (docs/spec/simplification-review.md §7 VAT, node V2), on top of the
-- finalised return of 20261001100000.
--
-- ── WHAT WAS THERE ───────────────────────────────────────────────────────────
--
-- A finalised VAT return held its nine boxes, the journals it took and a
-- digest of them in its attributes, and nothing gave them to anybody in a
-- form bridging software reads. The only way out was to copy the figures off
-- a screen, which is not a digital link (VAT Notice 700/22 §4).
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp.vat_return_export(return, format) and public.erp_vat_return_export,
--     under finance.close_period in the return's company (D13), for a
--     finalised return only. It re-derives the return's entries from the
--     ledger and the determinations, the journals it names on the days it was
--     made over, and refuses when they are not what it was finalised from:
--     a journal it named is no longer an entry there, the digest of the
--     entries differs, one of them would now block a return (its side cannot
--     be told, it is not in the company's currency, or its determinations and
--     the ledger disagree), or the boxes the entries give are not the frozen
--     ones. The figures exported are the ones the records give, which is the
--     digital link.
--   * Three forms, each a byte-stable body with LF line endings, '.' decimals
--     and no locale:
--       - csv: a header block (the return, the VRN without GB, the period,
--         the due date, when and by whom it was finalised, the entries and
--         their digest, the export's format version), then the nine boxes,
--         one row each: boxes 1 to 4 in pounds and pence, box 5 never
--         negative with payable or repayable beside it (D10), 6 to 9 in whole
--         pounds;
--       - json: the MTD VAT return body's field names (periodKey, vatDueSales,
--         vatDueAcquisitions, totalVatDue, vatReclaimedCurrPeriod, netVatDue,
--         totalValueSalesExVAT, totalValuePurchasesExVAT,
--         totalValueGoodsSuppliedExVAT, totalAcquisitionsExVAT, finalised),
--         periodKey null because it is HMRC's and only its obligations API
--         gives it, finalised true, and vrn, periodStart and periodEnd beside
--         them;
--       - entries_csv: the return's digital records, one row per entry, with
--         its journal, document, VAT date, side, net, tax and whether it was
--         carried forward.
--   * Each export appends vat_return.exported on the return: the format, the
--     sha256 of the body, its length, the entries' digest and who exported
--     it. The body is returned, not stored. No filed state is added (D14):
--     the export is the last thing the product does, and a filing reference
--     goes in the return's notes.
--   * Registers: two refusals and a third for a format it does not make, the
--     event and its words, the write allowance, api-only until the VAT
--     returns screen (M4), and the help action.
--
-- ── CALLS MADE HERE, FOR THE PR DESCRIPTION ──────────────────────────────────
--
--   * The door answers jsonb, not bare text: the body with its filename, media
--     type and sha256, so the M4 screen downloads it as it is and the event's
--     digest can be checked against what was handed over.
--   * The export re-derives the journals the return names, over the days it
--     was made from (its first day to its period end), not the inclusion rule
--     read afresh. Read afresh, a return's own journals are taken by it and so
--     excluded, and an entry posted late into its quarter would be counted in;
--     that entry is the next return's, and a late posting is not a change to
--     the records this one was made from.
--   * Blocking findings on the return's own entries refuse as changed records:
--     finalise refused them, so one there now was made after it. The digest
--     covers the ledger's tax and the net but not the determinations' tax,
--     which is where the plan's tampered determination would otherwise pass.
--   * The CSV names the export's format version rather than the build: the
--     release register is the platform's, and a body that changed with every
--     deploy would not be the same body twice.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * HMRC submission and the periodKey (spec §5, §11).
--   * The screen, the download button and the help topic's words (M4): the
--     topic for /finance/vat does not exist yet. Bridging tools differ in the
--     cells they map; the CSV and the MTD JSON are the two common inputs, and
--     no one tool is claimed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NOT_A_FINALISED_VAT_RETURN',
  'Exporting something that is not a finalised VAT return of this organisation.',
  'An export is the figures of a return that is final. A period not yet finalised has no return to export, and anything else is not a return.',
  'Finalise the period from VAT returns first, then export its return from there.');

select erp.register_refusal('CLOVEERP_VAT_RETURN_RECORDS_CHANGED',
  'Exporting a VAT return whose records are no longer what it was finalised from.',
  'An export is generated from the records it re-reads, which is the digital link HMRC asks for. When a journal or determination the return took has changed since it was finalised, its figures are not the records'' figures, and exporting them would break the link.',
  'Find out what changed the entries the refusal names, and put the records back as they were; a correction that is right belongs on a new posting, which the next return takes.');

select erp.register_refusal('CLOVEERP_VAT_EXPORT_FORMAT_UNKNOWN',
  'Exporting a VAT return in a form the product does not make.',
  'A return is exported as the nine boxes in CSV, as the MTD return body in JSON, or as its entries in CSV, and nothing else.',
  'Ask for one of the three forms VAT returns offers: the nine boxes as a spreadsheet, the MTD return body, or the return''s entries as a spreadsheet.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The event and its words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.vat_return.exported', 'en', 'VAT return exported', 'finance',
   'Event raised each time a finalised VAT return is exported, with the format and the sha256 of what was exported (20261001200000).'),
  ('event.vat_return.exported', 'de', 'Umsatzsteuererklärung exportiert', 'finance',
   'Ereignis bei jedem Export einer abgeschlossenen Umsatzsteuererklärung, mit Format und SHA-256 des Exports.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('vat_return.exported', 1, 'document', 'finance', 'event.vat_return.exported',
        'A finalised VAT return was exported, from its records re-derived and found unchanged.',
        '{"type":"object","required":["format","sha256","bytes","entries_digest"],
          "properties":{"format":{"type":"string"},"sha256":{"type":"string"},
                        "bytes":{"type":"integer"},"entries_digest":{"type":"string"},
                        "exported_by":{"type":"string"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'vat_return.exported' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.vat_return.exported') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: vat_return.exported is declared already, and not as 20261001200000 declares it';
  end if;
end
$event$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The export
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.vat_return_export(p_document_id uuid, p_format text default 'csv')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  v_format  text := lower(btrim(coalesce(p_format, 'csv')));
  r         jsonb;
  v_start   date;
  v_end     date;
  v_first   date;
  v_named   integer;
  x         record;
  v_boxes   jsonb;
  v_vrn     text;
  v_by      text;
  v_body    text;
  v_name    text;
  v_media   text;
  v_sha     text;
  v_rows    jsonb;
begin
  -- The return, in this organisation. A draft, anything else, or another
  -- organisation's document is not a finalised return here.
  select doc.* into d
    from erp.document doc
    join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
   where doc.tenant_id = v_tenant and doc.id = p_document_id and dt.base_type_code = 'vat_return';
  if not found then
    raise exception 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN: % is not a VAT return in this organisation', p_document_id
      using errcode = '23503',
            hint = 'Finalise the period from VAT returns first, then export its return from there.';
  end if;

  -- Whoever closes the books exports what they finalised (D13), in the
  -- return's own company, before anything about the return is said.
  perform erp.authorise('finance.close_period', d.entity_id, null, null, 'document', p_document_id);

  r := d.attributes -> 'vat_return';
  if d.is_cancelled
     or erp.object_current_state('document', d.id) is distinct from 'finalised'
     or jsonb_typeof(r -> 'journal_ids') is distinct from 'array'
     or jsonb_typeof(r -> 'boxes') is distinct from 'object'
     or r ->> 'entries_digest' is null or r ->> 'first_day' is null then
    raise exception 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN: % is not finalised, and a return is exported once it is',
      coalesce(d.document_number, p_document_id::text)
      using errcode = '23514',
            hint = 'Finalise the period from VAT returns first, then export its return from there.';
  end if;

  if v_format not in ('csv', 'json', 'entries_csv') then
    raise exception 'CLOVEERP_VAT_EXPORT_FORMAT_UNKNOWN: % is not a form a VAT return is exported in', p_format
      using errcode = '22023',
            hint = 'Ask for one of the three forms VAT returns offers: the nine boxes as a spreadsheet, the MTD return body, or the return''s entries as a spreadsheet.';
  end if;

  v_start := (r ->> 'period_start')::date;
  v_end   := (r ->> 'period_end')::date;
  v_first := (r ->> 'first_day')::date;
  v_named := jsonb_array_length(r -> 'journal_ids');

  -- The digital link: the entries re-derived from the ledger and the
  -- determinations, the journals the return names over the days it was made
  -- from, and the boxes the same arithmetic as erp.vat_return_figures()
  -- gives. The digest is its recipe: each journal, its tax and its net, in
  -- journal order.
  select count(*) as entries,
         count(*) filter (where e.side not in ('sale', 'purchase')
                             or not e.in_base_currency
                             or e.determined_tax_minor <> e.tax_minor) as blocking,
         md5(coalesce(string_agg(e.journal_id::text || ':' || e.tax_minor || ':' || e.net_minor, ','
                                 order by e.journal_id::text), '')) as digest,
         coalesce(sum(e.tax_minor) filter (where e.side = 'sale'), 0)::bigint as box1,
         coalesce(sum(e.tax_minor) filter (where e.side = 'purchase'), 0)::bigint as box4,
         trunc(coalesce(sum(e.net_minor) filter (where e.side = 'sale'), 0) / 100.0)::bigint as box6,
         trunc(coalesce(sum(e.net_minor) filter (where e.side = 'purchase'), 0) / 100.0)::bigint as box7,
         coalesce(jsonb_agg(jsonb_build_object(
             'journal_id', e.journal_id,
             'journal_number', e.journal_number,
             'document_number', e.document_number,
             'type_code', e.type_code,
             'vat_date', e.vat_date,
             'side', e.side,
             'net', (e.net_minor::numeric / 100)::numeric(20, 2)::text,
             'tax', (e.tax_minor::numeric / 100)::numeric(20, 2)::text,
             'carried_forward', case when e.vat_date < v_start then 'true' else 'false' end)
           order by e.vat_date, e.journal_number, e.journal_id::text), '[]'::jsonb) as entry_rows
    into x
    from erp.vat_entries(d.entity_id, v_first, v_end) e
   where (r -> 'journal_ids') ? e.journal_id::text;

  v_boxes := jsonb_build_object(
    'box1_minor', x.box1, 'box2_minor', 0, 'box3_minor', x.box1 + 0, 'box4_minor', x.box4,
    'box5_minor', abs(x.box1 + 0 - x.box4),
    'box5_is', case when x.box1 + 0 >= x.box4 then 'payable' else 'repayable' end,
    'box6_pounds', x.box6, 'box7_pounds', x.box7, 'box8_pounds', 0, 'box9_pounds', 0);

  if x.entries <> v_named or x.digest is distinct from (r ->> 'entries_digest') or x.blocking > 0
     or v_boxes is distinct from (r -> 'boxes') then
    raise exception 'CLOVEERP_VAT_RETURN_RECORDS_CHANGED: % was finalised from % entr(y/ies) with digest %; its records now give % of them with digest %, % blocking, and the boxes %',
      d.document_number, v_named, r ->> 'entries_digest', x.entries, x.digest, x.blocking,
      case when v_boxes is distinct from (r -> 'boxes') then 'differ' else 'agree' end
      using errcode = '23514',
            hint = 'Find out what changed the entries the refusal names, and put the records back as they were; a correction that is right belongs on a new posting, which the next return takes.';
  end if;

  -- HMRC's VRN is the nine digits, without the country prefix.
  v_vrn := regexp_replace(upper(coalesce(r ->> 'vrn', '')), '^GB|[^0-9A-Z]', '', 'g');
  -- The one cell a person typed: a name a spreadsheet would read as a
  -- formula is written as text.
  select case when u.display_name ~ '^[=+@\t\r-]' then '''' || u.display_name else u.display_name end
    into v_by
    from erp.app_user u where u.tenant_id = v_tenant and u.id = (r ->> 'finalised_by')::uuid;

  if v_format = 'csv' then
    v_body :=
      erp.csv_of(jsonb_build_array(
          jsonb_build_object('field', 'return', 'value', d.document_number),
          jsonb_build_object('field', 'vrn', 'value', v_vrn),
          jsonb_build_object('field', 'period_start', 'value', v_start::text),
          jsonb_build_object('field', 'period_end', 'value', v_end::text),
          jsonb_build_object('field', 'due_on', 'value', r ->> 'due_on'),
          jsonb_build_object('field', 'finalised_at', 'value', r ->> 'computed_at'),
          jsonb_build_object('field', 'finalised_by', 'value', coalesce(v_by, '')),
          jsonb_build_object('field', 'entries', 'value', x.entries::text),
          jsonb_build_object('field', 'entries_digest', 'value', x.digest),
          jsonb_build_object('field', 'generated_by', 'value', 'Clove ERP VAT return export format 1')),
        array['field', 'value'])
      || E'\n\n'
      || erp.csv_of(jsonb_build_array(
          jsonb_build_object('box', '1', 'description', 'VAT due in the period on sales and other outputs',
                             'value', (x.box1::numeric / 100)::numeric(20, 2)::text),
          jsonb_build_object('box', '2', 'description', 'VAT due in the period on acquisitions of goods made in Northern Ireland from EU Member States',
                             'value', '0.00'),
          jsonb_build_object('box', '3', 'description', 'Total VAT due (the sum of boxes 1 and 2)',
                             'value', ((x.box1 + 0)::numeric / 100)::numeric(20, 2)::text),
          jsonb_build_object('box', '4', 'description', 'VAT reclaimed in the period on purchases and other inputs',
                             'value', (x.box4::numeric / 100)::numeric(20, 2)::text),
          jsonb_build_object('box', '5', 'description', 'Net VAT to pay to HMRC or reclaim (the difference between boxes 3 and 4)',
                             'value', ((v_boxes ->> 'box5_minor')::numeric / 100)::numeric(20, 2)::text,
                             'direction', v_boxes ->> 'box5_is'),
          jsonb_build_object('box', '6', 'description', 'Total value of sales and all other outputs excluding any VAT',
                             'value', x.box6::text),
          jsonb_build_object('box', '7', 'description', 'Total value of purchases and all other inputs excluding any VAT',
                             'value', x.box7::text),
          jsonb_build_object('box', '8', 'description', 'Total value of dispatches of goods and related costs (excluding VAT) from Northern Ireland to EU Member States',
                             'value', '0'),
          jsonb_build_object('box', '9', 'description', 'Total value of acquisitions of goods and related costs (excluding VAT) made in Northern Ireland from EU Member States',
                             'value', '0')),
        array['box', 'description', 'value', 'direction'])
      || E'\n';
    v_name  := format('%s_%s_%s.csv', d.document_number, v_start, v_end);
    v_media := 'text/csv';
  elsif v_format = 'json' then
    -- The MTD body (D10: netVatDue never negative; boxes 6 to 9 whole pounds).
    -- jsonb orders its keys, so the text is the same text every time.
    v_body := jsonb_build_object(
        'periodKey', null,
        'vatDueSales', (x.box1::numeric / 100)::numeric(15, 2),
        'vatDueAcquisitions', 0.00::numeric(15, 2),
        'totalVatDue', ((x.box1 + 0)::numeric / 100)::numeric(15, 2),
        'vatReclaimedCurrPeriod', (x.box4::numeric / 100)::numeric(15, 2),
        'netVatDue', ((v_boxes ->> 'box5_minor')::numeric / 100)::numeric(15, 2),
        'totalValueSalesExVAT', x.box6,
        'totalValuePurchasesExVAT', x.box7,
        'totalValueGoodsSuppliedExVAT', 0,
        'totalAcquisitionsExVAT', 0,
        'finalised', true,
        'vrn', v_vrn,
        'periodStart', v_start,
        'periodEnd', v_end)::text || E'\n';
    v_name  := format('%s_%s_%s.json', d.document_number, v_start, v_end);
    v_media := 'application/json';
  else
    v_rows := x.entry_rows;
    v_body := erp.csv_of(v_rows, array['journal_id', 'journal_number', 'document_number', 'type_code',
                                       'vat_date', 'side', 'net', 'tax', 'carried_forward'])
              || E'\n';
    v_name  := format('%s_%s_%s_entries.csv', d.document_number, v_start, v_end);
    v_media := 'text/csv';
  end if;

  v_sha := encode(sha256(convert_to(v_body, 'UTF8')), 'hex');

  perform erp.append_event(
    'vat_return.exported', 'document', d.id,
    jsonb_strip_nulls(jsonb_build_object('format', v_format, 'sha256', v_sha,
                       'bytes', octet_length(convert_to(v_body, 'UTF8')),
                       'entries_digest', x.digest,
                       'exported_by', erp.current_principal_id())),
    d.entity_id, null);

  -- Returned, not stored (D14).
  return jsonb_build_object(
    'document_id', d.id, 'document_number', d.document_number,
    'period_start', v_start, 'period_end', v_end,
    'format', v_format, 'filename', v_name, 'media_type', v_media,
    'sha256', v_sha, 'entries', x.entries, 'entries_digest', x.digest,
    'body', v_body);
end;
$$;

revoke all on function erp.vat_return_export(uuid, text) from public, anon;

comment on function erp.vat_return_export(uuid, text) is
  'Exports a finalised VAT return from its records (20261001200000): under finance.close_period in its '
  'company, the journals it names re-derived and refused as CLOVEERP_VAT_RETURN_RECORDS_CHANGED unless '
  'they give its digest and its boxes; as the nine boxes in CSV, the MTD return body in JSON, or its '
  'entries in CSV. Appends vat_return.exported with the sha256 of the body; stores nothing and sends '
  'nothing to HMRC. Bridging tools differ in the cells they map, and no one tool is claimed.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The door
--
-- Volatile: it appends an event, and erp.authorise() writes its access-log
-- row.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_vat_return_export(p_document_id uuid, p_format text default 'csv')
returns jsonb
language sql
set search_path = ''
as $$ select erp.vat_return_export(p_document_id, p_format) $$;

revoke all on function public.erp_vat_return_export(uuid, text) from public, anon;
grant execute on function public.erp_vat_return_export(uuid, text) to authenticated, service_role;

comment on function public.erp_vat_return_export(uuid, text) is
  'A finalised VAT return exported from its re-derived records as CSV, MTD JSON or its entries, under '
  'finance.close_period (20261001200000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_vat_return_export', 'erp.vat_return_export',
   'Exports a finalised VAT return after re-deriving its entries and refusing when they changed; authorises finance.close_period in the return''s company. Writes the vat_return.exported event and the access-log row erp.authorise() raises; the body is returned, not stored, and nothing is sent to HMRC.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- Until the VAT returns screen offers it (PR14 M4).
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_vat_return_export', 'pending_screen', '/finance/vat',
   'Exports a finalised VAT return as CSV, MTD JSON or its entries for bridging software. Belongs as Export on a finalised row of the VAT returns screen, PR14 M4.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

select erp_meta.add_help_actions('/finance', array['erp_vat_return_export']);

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The proof: erp_test.vat_export_suite
--
-- One organisation configured from now on, so it is on tax version 2, whose
-- company is registered for VAT from the first day of the quarter before
-- last: a return that is payable for that quarter and, after a late sale into
-- it and its sale reversed last quarter, a repayment return for that one. And
-- a second organisation, to ask for the first one's return.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.vat_export_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_ware   uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  rb       record;
  rb2      record;
  res      jsonb;
  v_csv    jsonb; v_json jsonb; v_ent jsonb; v_csv2 jsonb; v_json2 jsonb; v_ent2 jsonb; v_again jsonb;
  j        jsonb;
  bx       jsonb;
  v_lines  text[];
  v_entity uuid; v_ccy char(3); v_site uuid; v_item uuid; v_cust uuid;
  v_inv_a  uuid; v_inv_b uuid;
  v_ret1   uuid; v_ret2 uuid; v_draft uuid;
  v_num1   text; v_num_a text; v_vrn text;
  v_pq_from date := (date_trunc('quarter', current_date) - interval '3 months')::date;
  v_pq_to  date := date_trunc('quarter', current_date)::date - 1;
  v_ppq_from date := (date_trunc('quarter', current_date) - interval '6 months')::date;
  v_ppq_to date := (date_trunc('quarter', current_date) - interval '3 months')::date - 1;
  v_n integer; v_n2 integer; v_x numeric; v_y numeric;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text;
begin
  begin
    v_step := 'an organisation configured as the demonstration is, with a reader and a warehouse seat';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzvx-' || v_tag, 'VAT Export Suite',
      'admin@zzvx-' || v_tag || '.test', 'VAT Export Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    select * into rb2 from erp.provision_tenant(
      'zzvy-' || v_tag, 'VAT Export Suite Elsewhere',
      'admin@zzvy-' || v_tag || '.test', 'VAT Export Elsewhere Admin');
    update erp.environment set is_live = false where tenant_id = rb2.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzvx-' || v_tag || '.test'),
           (a2, 'admin@zzvy-' || v_tag || '.test'),
           (s_ware, 'ware@zzvx-' || v_tag || '.test'),
           (s_read, 'reader@zzvx-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    res := public.erp_invite_principal('ware@zzvx-' || v_tag || '.test', 'Wes Warehouse');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'warehouse', null, null, 'moves the stock');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ware)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zzvx-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, registered for VAT from the first day of the quarter before last';
    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZZVXCUST', 'VAT export suite customer', 'GB', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    update erp.entity_tax_registration g set valid_from = v_ppq_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%'
    returning g.registration_number into v_vrn;
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'the fixture''s company has % VAT registration(s), expected one', v_n;
    end if;

    v_step := 'a sale of five hundred pounds supplied in the quarter before last, and its return finalised';
    v_inv_a := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZVX-A', '{}'::jsonb);
    perform erp.add_document_line(v_inv_a, v_item, 1, 50000, 'supplied in the quarter before last');
    perform erp.set_invoice_tax_point(v_inv_a, v_ppq_to);
    perform erp.transition_document(v_inv_a, 'issue', 'vat export suite');
    select d.document_number into v_num_a from erp.document d where d.id = v_inv_a;
    res := public.erp_finalise_vat_return(v_entity, v_ppq_to);
    v_ret1 := (res ->> 'document_id')::uuid;
    v_num1 := res ->> 'document_number';
    select d.attributes #> '{vat_return,boxes}' into bx from erp.document d where d.id = v_ret1;

    -- ── 1. Declared and governed ────────────────────────────────────────────
    v_step := 'the registers';
    v_cases := v_cases + 1;
    case_name := 'the export is declared: its three refusals name a next action, its event is current, and its door is volatile, allowed, api-only pending the VAT returns screen, a help action on Finance, and closed to anon';
    passed := v_state is null
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_NOT_A_FINALISED_VAT_RETURN', 'CLOVEERP_VAT_RETURN_RECORDS_CHANGED',
                                 'CLOVEERP_VAT_EXPORT_FORMAT_UNKNOWN')
                  and coalesce(f.next_action, '') <> '') = 3
          and exists (select 1 from erp_ref.event_type et
                       where et.code = 'vat_return.exported' and et.is_current and et.aggregate_type = 'document')
          and (select p.provolatile from pg_catalog.pg_proc p
                where p.oid = 'public.erp_vat_return_export(uuid,text)'::regprocedure) = 'v'
          and (select p.provolatile from pg_catalog.pg_proc p
                where p.oid = 'erp.vat_return_export(uuid,text)'::regprocedure) = 'v'
          and exists (select 1 from erp_meta.public_write_allowance w
                       where w.function_name = 'erp_vat_return_export' and w.gate = 'erp.vat_return_export')
          and exists (select 1 from erp_meta.api_only_door a
                       where a.function_name = 'erp_vat_return_export' and a.caller = 'pending_screen'
                         and a.intended_screen_path = '/finance/vat')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance' and 'erp_vat_return_export' = any(h.actions))
          and has_function_privilege('authenticated', 'public.erp_vat_return_export(uuid,text)', 'execute')
          and not has_function_privilege('anon', 'public.erp_vat_return_export(uuid,text)', 'execute');
    detail := coalesce(v_state, 'registered');
    return next;

    -- ── 2. The nine boxes in CSV ────────────────────────────────────────────
    v_step := 'the payable return exported as CSV';
    v_csv := public.erp_vat_return_export(v_ret1, 'csv');
    v_lines := string_to_array(v_csv ->> 'body', E'\n');
    v_cases := v_cases + 1;
    case_name := 'the CSV names the return, the VRN without GB, the period and its due date, then nine rows of the frozen boxes: pounds and pence to box 4, box 5 with payable beside it, whole pounds from box 6, LF line endings';
    passed := v_state is null
          and v_csv ->> 'media_type' = 'text/csv'
          and v_csv ->> 'filename' = format('%s_%s_%s.csv', v_num1, v_ppq_from, v_ppq_to)
          and strpos(v_csv ->> 'body', E'\r') = 0
          and right(v_csv ->> 'body', 1) = E'\n'
          and v_lines[1] = 'field,value'
          and v_lines[2] = 'return,' || v_num1
          and v_lines[3] = 'vrn,' || regexp_replace(upper(v_vrn), '^GB|[^0-9A-Z]', '', 'g')
          and v_lines[3] !~ 'GB'
          and v_lines[4] = 'period_start,' || v_ppq_from
          and v_lines[5] = 'period_end,' || v_ppq_to
          and v_lines[6] = 'due_on,' || erp.vat_return_due_on(v_ppq_to)
          and v_lines[8] = 'finalised_by,VAT Export Admin'
          and v_lines[9] = 'entries,1'
          and v_lines[11] = 'generated_by,Clove ERP VAT return export format 1'
          and v_lines[12] = ''
          and v_lines[13] = 'box,description,value,direction'
          and v_lines[14] = '1,VAT due in the period on sales and other outputs,100.00,'
          and v_lines[15] like '2,%,0.00,'
          and v_lines[16] = '3,Total VAT due (the sum of boxes 1 and 2),100.00,'
          and v_lines[17] = '4,VAT reclaimed in the period on purchases and other inputs,0.00,'
          and v_lines[18] = '5,Net VAT to pay to HMRC or reclaim (the difference between boxes 3 and 4),100.00,payable'
          and v_lines[19] = '6,Total value of sales and all other outputs excluding any VAT,500,'
          and v_lines[20] = '7,Total value of purchases and all other inputs excluding any VAT,0,'
          and v_lines[21] like '8,%,0,'
          and v_lines[22] like '9,%,0,'
          and v_lines[23] = '' and array_length(v_lines, 1) = 23
          and (select count(*) from unnest(v_lines) l where l ~ '^[1-9],') = 9
          and (bx ->> 'box1_minor')::bigint = 10000 and (bx ->> 'box6_pounds')::bigint = 500;
    detail := coalesce(v_state, left(v_csv ->> 'body', 900));
    return next;

    -- ── 3. The MTD body in JSON ─────────────────────────────────────────────
    v_step := 'the payable return exported as JSON';
    v_json := public.erp_vat_return_export(v_ret1, 'json');
    j := (v_json ->> 'body')::jsonb;
    v_cases := v_cases + 1;
    case_name := 'the JSON parses and carries exactly the MTD field names with vrn and the period; its values are the frozen boxes, pence to two places and whole pounds as integers, netVatDue positive and equal to box 5, periodKey null and finalised true';
    passed := v_state is null
          and v_json ->> 'media_type' = 'application/json'
          and (select array_agg(k order by k) from jsonb_object_keys(j) k)
              = (select array_agg(k order by k) from unnest(array[
                  'periodKey', 'vatDueSales', 'vatDueAcquisitions', 'totalVatDue', 'vatReclaimedCurrPeriod',
                  'netVatDue', 'totalValueSalesExVAT', 'totalValuePurchasesExVAT',
                  'totalValueGoodsSuppliedExVAT', 'totalAcquisitionsExVAT', 'finalised',
                  'vrn', 'periodStart', 'periodEnd']) k)
          and jsonb_typeof(j -> 'periodKey') = 'null'
          and j -> 'finalised' = 'true'::jsonb
          and (j -> 'vatDueSales')::text = '100.00'
          and (j ->> 'vatDueSales')::numeric * 100 = (bx ->> 'box1_minor')::numeric
          and (j -> 'vatDueAcquisitions')::text = '0.00'
          and (j ->> 'totalVatDue')::numeric * 100 = (bx ->> 'box3_minor')::numeric
          and (j ->> 'vatReclaimedCurrPeriod')::numeric * 100 = (bx ->> 'box4_minor')::numeric
          and (j -> 'netVatDue')::text = '100.00'
          and (j ->> 'netVatDue')::numeric * 100 = (bx ->> 'box5_minor')::numeric
          and (j ->> 'netVatDue')::numeric > 0
          and (j -> 'totalValueSalesExVAT')::text = '500'
          and (j ->> 'totalValueSalesExVAT')::numeric = (bx ->> 'box6_pounds')::numeric
          and (j -> 'totalValuePurchasesExVAT')::text = (bx ->> 'box7_pounds')
          and (j -> 'totalValueGoodsSuppliedExVAT')::text = '0'
          and (j -> 'totalAcquisitionsExVAT')::text = '0'
          and j ->> 'vrn' = regexp_replace(upper(v_vrn), '^GB|[^0-9A-Z]', '', 'g')
          and j ->> 'periodStart' = v_ppq_from::text and j ->> 'periodEnd' = v_ppq_to::text;
    detail := coalesce(v_state, left(coalesce(v_json ->> 'body', 'nothing'), 600));
    return next;

    -- ── 4. The digital records ──────────────────────────────────────────────
    v_step := 'the payable return''s entries exported';
    v_ent := public.erp_vat_return_export(v_ret1, 'entries_csv');
    v_lines := string_to_array(v_ent ->> 'body', E'\n');
    v_cases := v_cases + 1;
    case_name := 'the entries CSV has one row per journal the return took, naming its journal and document, and its sale tax less its purchase tax is box 1 less box 4';
    passed := v_state is null
          and v_ent ->> 'filename' = format('%s_%s_%s_entries.csv', v_num1, v_ppq_from, v_ppq_to)
          and v_lines[1] = 'journal_id,journal_number,document_number,type_code,vat_date,side,net,tax,carried_forward'
          and array_length(v_lines, 1) = 3 and v_lines[3] = ''
          and (select count(*) from erp.document d, jsonb_array_elements_text(d.attributes #> '{vat_return,journal_ids}') ji
                where d.id = v_ret1 and v_lines[2] like ji || ',%') = 1
          and v_lines[2] like '%,' || v_num_a || ',sales_invoice,' || v_ppq_to || ',sale,500.00,100.00,false'
          and (v_ent ->> 'entries')::integer = 1;
    detail := coalesce(v_state, left(coalesce(v_ent ->> 'body', 'nothing'), 600));
    return next;

    -- ── 5. Each export is an event, and the body is the same body ───────────
    v_step := 'the CSV exported again';
    v_again := public.erp_vat_return_export(v_ret1, 'csv');
    v_cases := v_cases + 1;
    case_name := 'each export appends one vat_return.exported whose sha256 is the body''s, and the same return exported twice is the same bytes';
    passed := v_state is null
          and (select count(*) from erp.event e
                where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1
                  and e.event_type = 'vat_return.exported') = 4
          and (select array_agg(e.payload ->> 'sha256' order by e.payload ->> 'sha256') from erp.event e
                where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1
                  and e.event_type = 'vat_return.exported')
              = (select array_agg(s order by s) from unnest(array[
                  encode(sha256(convert_to(v_csv ->> 'body', 'UTF8')), 'hex'),
                  encode(sha256(convert_to(v_json ->> 'body', 'UTF8')), 'hex'),
                  encode(sha256(convert_to(v_ent ->> 'body', 'UTF8')), 'hex'),
                  encode(sha256(convert_to(v_again ->> 'body', 'UTF8')), 'hex')]) s)
          and v_csv ->> 'sha256' = encode(sha256(convert_to(v_csv ->> 'body', 'UTF8')), 'hex')
          and (select array_agg(distinct e.payload ->> 'format') from erp.event e
                where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1
                  and e.event_type = 'vat_return.exported') @> array['csv', 'json', 'entries_csv']
          and v_again ->> 'body' = v_csv ->> 'body' and v_again ->> 'sha256' = v_csv ->> 'sha256';
    detail := coalesce(v_state, format('%s events', (select count(*) from erp.event e
                where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1 and e.event_type = 'vat_return.exported')));
    return next;

    -- ── 6. A records change after finalise is refused ───────────────────────
    -- Each tamper in a block of its own that is undone.
    v_step := 'the sale''s determination tampered with under the finalised return';
    begin
      -- A penny: the boxes' whole pounds do not move, and the digest does.
      update erp.tax_determination set taxable_minor = taxable_minor + 1
       where tenant_id = rb.tenant_id and document_id = v_inv_a;
      begin
        perform public.erp_vat_return_export(v_ret1, 'json');
        v_err := 'exported';
      exception when others then v_err := left(sqlerrm, 300); end;
      raise exception 'CLOVEERP_TAMPER_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_TAMPER_ROLLED_BACK' then raise; end if;
    end;
    begin
      update erp.tax_determination set tax_minor = tax_minor + 1
       where id = (select td.id from erp.tax_determination td
                    where td.tenant_id = rb.tenant_id and td.document_id = v_inv_a order by td.id limit 1);
      begin
        perform public.erp_vat_return_export(v_ret1, 'csv');
        v_err2 := 'exported';
      exception when others then v_err2 := left(sqlerrm, 300); end;
      raise exception 'CLOVEERP_TAMPER_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_TAMPER_ROLLED_BACK' then raise; end if;
    end;
    begin
      update erp.document set tax_point = v_ppq_to + 1 where id = v_inv_a;
      begin
        perform public.erp_vat_return_export(v_ret1, 'entries_csv');
        v_err3 := 'exported';
      exception when others then v_err3 := left(sqlerrm, 300); end;
      raise exception 'CLOVEERP_TAMPER_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_TAMPER_ROLLED_BACK' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'after finalise, a changed net, a determination the ledger no longer agrees with, or an entry moved out of the return''s days refuses the export by name, and nothing is exported';
    passed := v_state is null
          and v_err like 'CLOVEERP_VAT_RETURN_RECORDS_CHANGED:%' || v_num1 || '%boxes agree'
          and v_err2 like 'CLOVEERP_VAT_RETURN_RECORDS_CHANGED:%1 blocking%'
          and v_err3 like 'CLOVEERP_VAT_RETURN_RECORDS_CHANGED:%give 0 of them%'
          and (select count(*) from erp.event e
                where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1
                  and e.event_type = 'vat_return.exported') = 4;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3));
    return next;

    -- ── 7. A repayment ──────────────────────────────────────────────────────
    v_step := 'a late sale into the finalised quarter, the first sale''s posting reversed last quarter, and last quarter finalised';
    v_inv_b := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZVX-B', '{}'::jsonb);
    perform erp.add_document_line(v_inv_b, v_item, 1, 20000, 'supplied in the finalised quarter, invoiced late');
    perform erp.set_invoice_tax_point(v_inv_b, v_ppq_to);
    perform erp.transition_document(v_inv_b, 'issue', 'vat export suite');
    perform erp.reverse_document_posting(v_inv_a, 'the whole supply was cancelled', v_pq_to);
    res := public.erp_finalise_vat_return(v_entity, v_pq_to);
    v_ret2 := (res ->> 'document_id')::uuid;
    v_csv2 := public.erp_vat_return_export(v_ret2, 'csv');
    v_json2 := public.erp_vat_return_export(v_ret2, 'json');
    j := (v_json2 ->> 'body')::jsonb;
    v_lines := string_to_array(v_csv2 ->> 'body', E'\n');
    v_cases := v_cases + 1;
    case_name := 'a return whose reversal outweighs its sales is a repayment: box 5 and netVatDue are sixty pounds, never negative, the CSV says repayable, and boxes 1, 3 and 6 carry their sign';
    passed := v_state is null
          and res #>> '{boxes,box5_is}' = 'repayable'
          and (res #>> '{boxes,box1_minor}')::bigint = -6000
          and (res #>> '{boxes,box5_minor}')::bigint = 6000
          and (j -> 'netVatDue')::text = '60.00'
          and (j ->> 'netVatDue')::numeric * 100 = (res #>> '{boxes,box5_minor}')::numeric
          and (j -> 'vatDueSales')::text = '-60.00'
          and (j -> 'totalVatDue')::text = '-60.00'
          and (j -> 'totalValueSalesExVAT')::text = '-300'
          and v_lines[14] = '1,VAT due in the period on sales and other outputs,-60.00,'
          and v_lines[18] = '5,Net VAT to pay to HMRC or reclaim (the difference between boxes 3 and 4),60.00,repayable'
          and v_lines[19] = '6,Total value of sales and all other outputs excluding any VAT,-300,';
    detail := coalesce(v_state, format('%s / %s', left(coalesce(res::text, 'nothing'), 300),
                                       left(coalesce(v_json2 ->> 'body', 'nothing'), 300)));
    return next;

    -- ── 8. What was carried forward, and a late entry is not a change ───────
    v_step := 'last quarter''s entries, and the first return exported again';
    v_ent2 := public.erp_vat_return_export(v_ret2, 'entries_csv');
    v_lines := string_to_array(v_ent2 ->> 'body', E'\n');
    select coalesce(sum(split_part(l, ',', 8)::numeric) filter (where split_part(l, ',', 6) = 'sale'), 0),
           coalesce(sum(split_part(l, ',', 8)::numeric) filter (where split_part(l, ',', 6) = 'purchase'), 0)
      into v_x, v_y
      from unnest(v_lines[2:]) l where l <> '';
    v_again := public.erp_vat_return_export(v_ret1, 'csv');
    v_cases := v_cases + 1;
    case_name := 'the second return''s entries are the late sale, carried forward, and the reversal, their tax box 1 less box 4; and the first return, whose sale was since reversed and whose quarter took a late sale after it, exports the same bytes as before';
    passed := v_state is null
          and array_length(v_lines, 1) = 4
          and (select count(*) from unnest(v_lines) l
                where l like '%,sales_invoice,' || v_ppq_to || ',sale,200.00,40.00,true') = 1
          and (select count(*) from unnest(v_lines) l
                where l like '%,' || v_pq_to || ',sale,-500.00,-100.00,false') = 1
          and (v_x - v_y) * 100 = (res #>> '{boxes,box1_minor}')::numeric - (res #>> '{boxes,box4_minor}')::numeric
          and v_again ->> 'sha256' = v_csv ->> 'sha256';
    detail := coalesce(v_state, format('%s; sale %s purchase %s; again %s vs %s', left(v_ent2 ->> 'body', 500), v_x, v_y,
                                       v_again ->> 'sha256', v_csv ->> 'sha256'));
    return next;

    -- ── 9. Nothing but a finalised return, in a form it is made in ──────────
    v_step := 'a draft return, an invoice, a document that is not there, and a form not made';
    begin
      v_draft := erp.open_document('vat_return', null, v_entity, null, 'by hand', null, v_ccy);
      begin
        perform public.erp_vat_return_export(v_draft, 'csv');
        v_err := 'exported';
      exception when others then v_err := left(sqlerrm, 200); end;
      -- Dressed as the finalised one: still a draft.
      update erp.document set attributes = (select d.attributes from erp.document d where d.id = v_ret1)
       where id = v_draft;
      begin
        perform public.erp_vat_return_export(v_draft, 'json');
        v_err2 := 'exported';
      exception when others then v_err2 := left(sqlerrm, 200); end;
      -- And, undone with the draft, a finaliser whose name a spreadsheet
      -- would run as a formula.
      update erp.app_user set display_name = '=1+1'
       where tenant_id = rb.tenant_id and id = (select (d.attributes #>> '{vat_return,finalised_by}')::uuid
                                                  from erp.document d where d.id = v_ret1);
      v_lines := string_to_array(public.erp_vat_return_export(v_ret1, 'csv') ->> 'body', E'\n');
      raise exception 'CLOVEERP_DRAFT_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_DRAFT_ROLLED_BACK' then raise; end if;
    end;
    begin
      perform public.erp_vat_return_export(v_inv_a, 'csv');
      v_err3 := 'exported';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    begin
      perform public.erp_vat_return_export(gen_random_uuid(), 'csv');
      v_err4 := 'exported';
    exception when others then v_err4 := left(sqlerrm, 200); end;
    begin
      perform public.erp_vat_return_export(v_ret1, 'xml');
      v_err5 := 'exported';
    exception when others then v_err5 := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a period not finalised has nothing to export: a draft return, even one dressed as finalised, an invoice and an unknown document are refused by name, and so is a form the product does not make; a name that reads as a formula is written as text';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN:%not finalised%'
          and v_err2 like 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN:%not finalised%'
          and v_err3 like 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN:%not a VAT return%'
          and v_err4 like 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN:%not a VAT return%'
          and v_err5 like 'CLOVEERP_VAT_EXPORT_FORMAT_UNKNOWN:%xml%'
          and v_lines[8] = 'finalised_by,''=1+1';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_lines[8]));
    return next;

    -- ── 10. Another organisation ────────────────────────────────────────────
    v_step := 'the first return asked for by another organisation''s administrator';
    select count(*) into v_n from erp.event e
     where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1 and e.event_type = 'vat_return.exported';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin
      perform public.erp_vat_return_export(v_ret1, 'csv');
      v_err := 'exported';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n2 from erp.event e
     where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1 and e.event_type = 'vat_return.exported';
    v_cases := v_cases + 1;
    case_name := 'another organisation''s administrator asking for the return is told there is no such return in their organisation';
    passed := v_state is null
          and v_err like 'CLOVEERP_NOT_A_FINALISED_VAT_RETURN:%not a VAT return in this organisation%'
          and v_n2 = v_n;
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 11. Who may export ──────────────────────────────────────────────────
    v_step := 'the return exported by a reader of the books and by a warehouse seat';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_vat_return_export(v_ret1, 'csv');
      v_err := 'exported';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      res := public.erp_vat_obligations(v_entity);
      v_err3 := 'read';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_ware)::text, true);
    begin
      perform public.erp_vat_return_export(v_ret1, 'json');
      v_err2 := 'exported';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'exporting asks finance.close_period: a reader of the books, who sees the return, and a warehouse seat are refused';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%'
          and v_err3 = 'read';
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

  -- ── 12. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code in ('zzvx-' || v_tag, 'zzvy-' || v_tag))
        and not exists (select 1 from auth.users u where u.id in (a1, a2, s_ware, s_read));
  detail := coalesce(v_state, 'both organisations rolled back with their invoices, returns and events');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_VAT_EXPORT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.vat_export_suite() from public, anon;

comment on function erp_test.vat_export_suite() is
  'The VAT return''s export (20261001200000): its registers, the nine boxes in CSV, the MTD JSON with '
  'the frozen boxes and netVatDue never negative, the entries with what was carried forward, an event '
  'per export with the body''s sha256, a changed record refused, a repayment, a late entry and a later '
  'reversal that change nothing, no draft and no unknown form, no other organisation, and finance.close_period.';

create or replace function erp_test.assert_vat_export_suite()
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
    from erp_test.vat_export_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VAT_EXPORT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A VAT return would be exported with figures its records do not give, or to somebody who may not. Read the case that failed.';
  end if;
  if v_total <> 12 then
    raise exception 'CLOVEERP_VAT_EXPORT_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('vat export: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_export_suite() from public, anon;

comment on function erp_test.assert_vat_export_suite() is
  'A finalised VAT return is exported from its re-derived records as CSV, MTD JSON or its entries, and '
  'refused when they changed, under finance.close_period (20261001200000).';

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
-- Every move every lifecycle declares still has something that fires it, a
-- type ships nothing dead, and every posting kind has a way back, in whatever
-- database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
select erp.assert_no_dead_configuration();
select erp.assert_every_posting_can_be_undone();
