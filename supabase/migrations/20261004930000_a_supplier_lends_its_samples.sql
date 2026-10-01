set lock_timeout = '30s';

-- =============================================================================
-- 20261004930000  A supplier lends its samples
-- -----------------------------------------------------------------------------
-- The fourth procure-to-pay gap the owner named on 1 October 2026, on top of a
-- purchase order reaching its supplier (20261004920000). A retailer buying
-- from a brand is sent samples ahead of a season: to photograph, to show at a
-- buying appointment, to lend to the press, to check the fit. They are the
-- brand's until somebody decides otherwise, and most go back.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Nothing received them. A sample was either booked in as stock at a price
-- nobody charged, putting goods on the books that were not ours, or kept off
-- the system, so nobody could say which samples were where, which were due
-- back, or what became of them. 'Sample' existed only as a reason for giving
-- our own stock away.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
-- Built on stock having an owner (20260906060000) and changing hands where it
-- stands (20260906143000): stock the supplier owns is held and counted, not
-- valued, and posts nothing.
--
--   * erp_receive_samples(p_supplier, p_site, p_lines, p_due_back, p_purpose,
--     p_their_reference, p_note): a goods receipt, posted, whose goods the
--     supplier owns and which carries no price (owner, 1 October 2026: received
--     directly, no order). Its purpose (photo shoot, buying appointment, press
--     loan, fit or quality check) and the date it is due back are kept on it.
--     A received line may carry no price only on such a receipt: the rule that
--     refuses a line at nothing (erp.add_document_line()) is there because
--     goods would go on the books at nothing, and these go on nobody's books.
--   * erp_samples(p_include_settled): every sample line, what of it is still
--     held, where, for what, due back when, and whether it is overdue.
--   * erp_settle_samples(p_line, p_outcome, p_quantity, p_price_minor,
--     p_reason): what becomes of a sample, line by line, some or all of it:
--       - return: the goods leave the supplier's position for the supplier,
--         a return movement that values nothing, as nothing was ours;
--       - keep: the supplier gives it to us. Ownership passes where it
--         stands at nothing (owner: our stock at zero cost), so it can be sold
--         at a sample sale or written off, and nothing posts;
--       - buy: we pay for it. Ownership passes at the agreed price, posting
--         inventory against goods received not invoiced, as consigned stock
--         consumed does (consignment_consumption), and the supplier's bill
--         settles that.
--     A sample lost or damaged in our hands is kept, if the supplier waives
--     it, or bought, if they charge for it, with the reason.
--   * The organisation's samples are checked daily (job
--     procurement.sample_overdue, installed with its first samples): the
--     person who received samples now overdue is told in the product, once
--     per receipt.
--   * Refusals, registered, and three events: sample.received,
--     sample.returned and sample.kept (buying raises the movement's own
--     stock.ownership_transferred, as consigned stock does).
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No sample order (owner): samples are received as they arrive.
--   * No onward loans: a sample sent to a photographer or a publication is a
--     move to another location or custodian, a follow-up.
--   * Buying a sample posts what consumed consignment posts, and the
--     supplier's bill meets it where a consignor's bill does. Matching a bill
--     to consumed consignment is a gap of its own, flagged separately.
--
-- Proved by erp_test.supplier_samples_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_SAMPLE_PURPOSE_UNKNOWN',
  'Receiving samples for a purpose the product does not know.',
  'A sample is lent for a reason, and the reason says who has it and when it goes back: a shoot, a buying appointment, a press loan or a fit check.',
  'Choose shoot, buying, press or fit.');

select erp.register_refusal('CLOVEERP_SAMPLES_HAVE_NO_LINES',
  'Receiving samples with no product, no quantity, or a quantity of nothing.',
  'A sample receipt records goods that arrived; one with nothing on it records nothing.',
  'Name each product and how many arrived, one line each.');

select erp.register_refusal('CLOVEERP_SAMPLE_NOT_HELD',
  'Settling a sample that is not one, or more of it than is still held.',
  'A sample goes back, is kept or is bought once; deciding again about what has already gone would move stock that is not there.',
  'Settle no more than the samples list shows as still held for that line.');

select erp.register_refusal('CLOVEERP_SAMPLE_OUTCOME_UNKNOWN',
  'Settling a sample with an outcome other than return, keep or buy.',
  'A sample goes back to the supplier, becomes ours free, or becomes ours at a price; the ledger differs for each.',
  'Choose return, keep or buy.');

select erp.register_refusal('CLOVEERP_SAMPLE_PRICE_REQUIRED',
  'Buying a sample without a price.',
  'Buying a sample is a purchase the supplier will invoice; a purchase at nothing is a sample kept free, and the ledger must say which.',
  'Name the price agreed with the supplier, in minor units, or keep it free instead.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.sample.received', 'en', 'Samples received', 'procurement',
   'Event raised when a supplier''s samples arrive, owned by the supplier.'),
  ('event.sample.received', 'de', 'Muster erhalten', 'procurement',
   'Ereignis, wenn Muster eines Lieferanten eintreffen, die dem Lieferanten gehören.'),
  ('event.sample.returned', 'en', 'Samples returned', 'procurement',
   'Event raised when samples go back to the supplier who lent them.'),
  ('event.sample.returned', 'de', 'Muster zurückgesandt', 'procurement',
   'Ereignis, wenn Muster an den Lieferanten zurückgehen, der sie geliehen hat.'),
  ('event.sample.kept', 'en', 'Samples kept', 'procurement',
   'Event raised when a supplier''s samples become the organisation''s, free of charge or at a price.'),
  ('event.sample.kept', 'de', 'Muster behalten', 'procurement',
   'Ereignis, wenn Muster eines Lieferanten in das Eigentum der Organisation übergehen, kostenlos oder zu einem Preis.'),
  ('job_handler.sample_overdue.name', 'en', 'Samples due back', 'procurement',
   'The daily check of samples due back to their suppliers.'),
  ('job_handler.sample_overdue.name', 'de', 'Fällige Musterrückgaben', 'procurement',
   'Die tägliche Prüfung der an Lieferanten zurückzugebenden Muster.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('sample.received', 1, 'document', 'procurement', 'event.sample.received',
   'A supplier''s samples arrived, owned by the supplier.',
   '{"type":"object","required":["reference","lines"],
     "properties":{"reference":{"type":"string"},"lines":{"type":"integer"},"purpose":{"type":"string"},
                   "due_back":{"type":["string","null"]},"supplier_id":{"type":"string"}}}'::jsonb, true),
  ('sample.returned', 1, 'document', 'procurement', 'event.sample.returned',
   'Samples went back to the supplier who lent them.',
   '{"type":"object","required":["reference","quantity"],
     "properties":{"reference":{"type":"string"},"quantity":{"type":"number"},"line_id":{"type":"string"},
                   "reason":{"type":["string","null"]}}}'::jsonb, true),
  ('sample.kept', 1, 'document', 'procurement', 'event.sample.kept',
   'A supplier''s samples became the organisation''s, free or at a price.',
   '{"type":"object","required":["reference","quantity","price_minor"],
     "properties":{"reference":{"type":"string"},"quantity":{"type":"number"},"line_id":{"type":"string"},
                   "price_minor":{"type":"integer"},"outcome":{"type":"string"},"reason":{"type":["string","null"]}}}'::jsonb, true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code in ('sample.received', 'sample.returned', 'sample.kept')
         and et.is_current and et.version = 1 and et.aggregate_type = 'document'
         and et.name_key = 'event.' || et.code) <> 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a sample event is declared already, and not as 20261004930000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. A sample receipt carries no price
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.is_sample_receipt(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A goods receipt of a supplier's samples (20261004930000): the supplier
  -- owns its goods and it says it is samples.
  select exists (
    select 1 from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and dt.base_type_code = 'receipt'
       and d.attributes ->> 'kind' = 'samples'
       and d.stock_owner_party_id is not null
       and d.stock_owner_party_id = d.party_id)
$$;

revoke all on function erp.is_sample_receipt(uuid) from public, anon;

comment on function erp.is_sample_receipt(uuid) is
  'Whether a goods receipt is of a supplier''s samples: owned by the supplier and marked samples (20261004930000).';

-- Edited, not rewritten: one anchor over erp.add_document_line() (md5
-- 02cfe58a…). A received line at nothing is refused because goods would go
-- on the books at nothing; a sample's goods go on nobody's.

do $line$
declare
  v_sig  constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if coalesce(v_valued, false) and v_price = 0 then$o$;
  v_new  constant text := $n$  -- A supplier's samples are theirs and valued by nobody, so they carry
  -- no price (20261004930000).
  if coalesce(v_valued, false) and v_price = 0 and not erp.is_sample_receipt(p_document_id) then$n$;
begin
  if strpos(v_src, '20261004930000') > 0 then
    raise notice '% already lets a sample receipt carry no price; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '02cfe58a045eabea1dd20a5e1ebfc6e8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004930000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$line$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. Receiving samples
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.receive_samples(p_supplier uuid, p_site uuid, p_lines jsonb,
                                               p_due_back date default null, p_purpose text default 'shoot',
                                               p_their_reference text default null, p_note text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_entity  uuid;
  v_purpose text := lower(btrim(coalesce(p_purpose, 'shoot')));
  v_grn     uuid;
  l         jsonb;
  v_item    uuid;
  v_qty     numeric;
  v_line    uuid;
  v_n       integer := 0;
begin
  -- A supplier's samples, arrived (20261004930000): one goods receipt, the
  -- supplier its owner, no price on any line, posted, so the goods are held
  -- and counted here and valued by nobody.
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site;
  if v_entity is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', coalesce(p_site::text, 'nothing')
      using errcode = '23503', hint = 'erp_sites() lists the sites.';
  end if;
  perform erp.authorise('procurement.receive', v_entity, p_site, null, 'party', p_supplier);

  if v_purpose not in ('shoot', 'buying', 'press', 'fit') then
    raise exception 'CLOVEERP_SAMPLE_PURPOSE_UNKNOWN: samples are lent for a shoot, a buying appointment, a press loan or a fit check, not %',
      coalesce(p_purpose, 'nothing')
      using errcode = '22023', hint = 'Choose shoot, buying, press or fit.';
  end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'CLOVEERP_SAMPLES_HAVE_NO_LINES: no product was named'
      using errcode = '23514', hint = 'Name each product and how many arrived, one line each.';
  end if;

  v_grn := erp.open_document('goods_receipt', p_supplier, v_entity, p_site,
                             nullif(btrim(coalesce(p_their_reference, '')), ''), null, null);
  update erp.document d
     set stock_owner_party_id = p_supplier,
         attributes = coalesce(d.attributes, '{}'::jsonb) || jsonb_build_object(
           'kind', 'samples', 'purpose', v_purpose, 'due_back', p_due_back,
           'note', nullif(btrim(coalesce(p_note, '')), '')),
         notes = coalesce(d.notes, 'Samples lent by the supplier'),
         updated_at = now()
   where d.tenant_id = v_tenant and d.id = v_grn;

  for l in select value from jsonb_array_elements(p_lines) loop
    v_item := nullif(l ->> 'item_id', '')::uuid;
    v_qty := nullif(l ->> 'quantity', '')::numeric;
    if v_item is null or v_qty is null or v_qty <= 0 then
      raise exception 'CLOVEERP_SAMPLES_HAVE_NO_LINES: line % names no product or no quantity', v_n + 1
        using errcode = '23514', hint = 'Name each product and how many arrived, one line each.';
    end if;
    v_line := erp.add_document_line(v_grn, v_item, v_qty, 0, nullif(btrim(coalesce(l ->> 'description', '')), ''));
    if nullif(l ->> 'batch_id', '') is not null then
      update erp.document_line x set batch_id = (l ->> 'batch_id')::uuid, updated_at = now()
       where x.tenant_id = v_tenant and x.id = v_line;
    end if;
    v_n := v_n + 1;
  end loop;

  perform erp.transition_document(v_grn, 'post', 'samples lent by the supplier');

  perform erp.append_event('sample.received', 'document', v_grn,
    jsonb_build_object('reference', (select d.document_number from erp.document d where d.id = v_grn),
                       'lines', v_n, 'purpose', v_purpose, 'due_back', p_due_back, 'supplier_id', p_supplier),
    v_entity, p_site);

  -- The daily check of what is due back, installed with the organisation's
  -- first samples; a job somebody switched off stays off.
  if not exists (select 1 from erp.job j
                  where j.tenant_id = v_tenant and j.handler_code = 'procurement.sample_overdue') then
    perform erp.upsert_job('sample_overdue', 'Samples due back', 'procurement.sample_overdue',
                           'daily', null, time '07:00', null, null, 'UTC', '{}'::jsonb, 120, null, true);
  end if;

  return jsonb_build_object(
    'document_id', v_grn,
    'document_number', (select d.document_number from erp.document d where d.id = v_grn),
    'lines', v_n,
    'state', erp.object_current_state('document', v_grn));
end;
$$;

revoke all on function erp.receive_samples(uuid, uuid, jsonb, date, text, text, text) from public, anon;

comment on function erp.receive_samples(uuid, uuid, jsonb, date, text, text, text) is
  'Receives a supplier''s samples: a posted goods receipt the supplier owns, at no price, with its '
  'purpose and the date it is due back (20261004930000). Authorises procurement.receive at the site.';

create or replace function public.erp_receive_samples(p_supplier uuid, p_site uuid, p_lines jsonb,
                                                      p_due_back date default null, p_purpose text default 'shoot',
                                                      p_their_reference text default null, p_note text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.receive_samples(p_supplier, p_site, p_lines, p_due_back, p_purpose, p_their_reference, p_note) $$;

revoke all on function public.erp_receive_samples(uuid, uuid, jsonb, date, text, text, text) from public, anon;
grant execute on function public.erp_receive_samples(uuid, uuid, jsonb, date, text, text, text) to authenticated, service_role;

comment on function public.erp_receive_samples(uuid, uuid, jsonb, date, text, text, text) is
  'Receives a supplier''s samples, owned by the supplier and valued by nobody (20261004930000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_receive_samples', 'erp.receive_samples',
   'Receives a supplier''s samples: opens and posts a goods receipt the supplier owns, at no price, and installs the daily samples-due check; authorises procurement.receive at the site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_receive_samples']);

-- ═════════════════════════════════════════════════════════════════════════════
-- D. What is held, and what becomes of it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.sample_line_held(p_line uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- What of a sample line is still the supplier's and here (20261004930000):
  -- what arrived, less what went back and what became ours, as the movements
  -- naming the line say.
  select greatest(0, l.quantity - coalesce((
           select sum(m.quantity)
             from erp.stock_movement m
            where m.tenant_id = l.tenant_id and m.document_line_id = l.id
              and m.movement_type in ('return_to_supplier', 'ownership_transfer')
              and not m.is_reversal), 0))
    from erp.document_line l
   where l.tenant_id = erp.current_tenant_id() and l.id = p_line
     and not l.is_cancelled
     and erp.is_sample_receipt(l.document_id)
$$;

revoke all on function erp.sample_line_held(uuid) from public, anon;

comment on function erp.sample_line_held(uuid) is
  'What of a line of a supplier''s samples is still held, neither returned nor taken into ownership (20261004930000).';

create or replace function erp.samples(p_include_settled boolean default false)
returns table(line_id uuid, receipt_id uuid, receipt_number text, received_on date, supplier_id uuid,
              supplier text, item_id uuid, item_code text, description text, received numeric, held numeric,
              purpose text, due_back date, overdue boolean, their_reference text, location_code text,
              site_id uuid, currency char(3), may_settle boolean)
language sql
stable
set search_path = ''
as $$
  -- Every line of a supplier's samples (20261004930000), those still held
  -- first and the most overdue first among them: what arrived, what is still
  -- here, where, for what, due back when, and whether the reader may decide
  -- what becomes of it (procurement.order at the site).
  select l.id, d.id, d.document_number, d.document_date, d.party_id, p.name, l.item_id, i.code,
         coalesce(l.description, i.name), l.quantity, erp.sample_line_held(l.id),
         d.attributes ->> 'purpose', (d.attributes ->> 'due_back')::date,
         erp.sample_line_held(l.id) > 0 and (d.attributes ->> 'due_back')::date < current_date,
         d.their_reference,
         (select loc.code from erp.stock_movement m join erp.location loc on loc.id = m.to_location_id
           where m.tenant_id = l.tenant_id and m.document_line_id = l.id and m.to_location_id is not null
           order by m.id limit 1),
         d.site_id, d.currency,
         erp.sample_line_held(l.id) > 0 and erp.has_permission('procurement.order', d.entity_id, d.site_id)
    from erp.document d
    join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
    left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
   where d.tenant_id = erp.current_tenant_id()
     and erp.is_sample_receipt(d.id)
     and erp.object_current_state('document', d.id) = 'posted'
     and (coalesce(p_include_settled, false) or erp.sample_line_held(l.id) > 0)
   order by (erp.sample_line_held(l.id) > 0) desc, (d.attributes ->> 'due_back')::date nulls last,
            d.document_number, l.line_no
$$;

revoke all on function erp.samples(boolean) from public, anon;

comment on function erp.samples(boolean) is
  'The lines of suppliers'' samples, what is still held, where, for what, due back when, overdue or not, '
  'and whether the reader may settle them (20261004930000).';

create or replace function public.erp_samples(p_include_settled boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from erp.samples(p_include_settled) s
$$;

revoke all on function public.erp_samples(boolean) from public, anon;
grant execute on function public.erp_samples(boolean) to authenticated, service_role;

comment on function public.erp_samples(boolean) is
  'Suppliers'' samples: what is held, where, for what and due back when (20261004930000).';

create or replace function erp.settle_samples(p_line uuid, p_outcome text, p_quantity numeric default null,
                                              p_price_minor bigint default null, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  l         erp.document_line%rowtype;
  d         erp.document%rowtype;
  v_outcome text := lower(btrim(coalesce(p_outcome, '')));
  v_held    numeric;
  v_qty     numeric;
  v_company uuid;
  v_loc     uuid;
  v_status  erp.stock_status;
  v_unit    bigint;
  v_id      bigint;
  v_price   bigint;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  -- What becomes of some or all of a sample line (20261004930000): it goes
  -- back to the supplier, it is kept free, or it is bought. Each is one
  -- movement naming the line, so what is still held is read from them.
  select x.* into l from erp.document_line x where x.tenant_id = v_tenant and x.id = p_line for update;
  select x.* into d from erp.document x where x.tenant_id = v_tenant and x.id = l.document_id;
  if l.id is null or not erp.is_sample_receipt(d.id) or erp.object_current_state('document', d.id) <> 'posted' then
    raise exception 'CLOVEERP_SAMPLE_NOT_HELD: % is not a line of a supplier''s samples', coalesce(p_line::text, 'nothing')
      using errcode = '23503', hint = 'Settle no more than the samples list shows as still held for that line.';
  end if;

  -- Deciding what becomes of a supplier's goods is a buying decision.
  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null, 'document', d.id);

  if v_outcome not in ('return', 'keep', 'buy') then
    raise exception 'CLOVEERP_SAMPLE_OUTCOME_UNKNOWN: a sample is returned, kept or bought, not %', coalesce(p_outcome, 'nothing')
      using errcode = '22023', hint = 'Choose return, keep or buy.';
  end if;

  v_held := erp.sample_line_held(l.id);
  v_qty := coalesce(p_quantity, v_held);
  if v_qty <= 0 or v_qty > v_held then
    raise exception 'CLOVEERP_SAMPLE_NOT_HELD: % of % is still held, and % was to be settled', v_held,
      coalesce((select i.code from erp.item i where i.id = l.item_id), 'the sample'), v_qty
      using errcode = '23514', hint = 'Settle no more than the samples list shows as still held for that line.';
  end if;

  if v_outcome = 'buy' and coalesce(p_price_minor, 0) <= 0 then
    raise exception 'CLOVEERP_SAMPLE_PRICE_REQUIRED: buying % at nothing is keeping it free',
      coalesce((select i.code from erp.item i where i.id = l.item_id), 'the sample')
      using errcode = '23514',
            hint = 'Name the price agreed with the supplier, in minor units, or keep it free instead.';
  end if;

  -- Where the samples are: where the receipt put them, still the supplier's.
  v_company := erp.entity_party_for_site(d.site_id);
  select m.to_location_id, m.to_status into v_loc, v_status
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.document_line_id = l.id and m.to_location_id is not null
   order by m.id limit 1;

  if v_outcome = 'return' then
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, quantity, uom_id, reason_code,
      owner_party_id, custody_party_id, document_id, document_line_id)
    values (v_tenant, d.entity_id, d.site_id, 'return_to_supplier', l.item_id, l.batch_id,
            v_loc, coalesce(v_status, 'available'), v_qty, l.uom_id, left(coalesce(v_reason, 'sample returned'), 64),
            d.party_id, v_company, d.id, l.id)
    returning id into v_id;
    perform erp.append_event('sample.returned', 'document', d.id,
      jsonb_build_object('reference', d.document_number, 'quantity', v_qty, 'line_id', l.id, 'reason', v_reason),
      d.entity_id, d.site_id);
  else
    -- Ownership passes where the samples stand: at nothing if kept, at the
    -- agreed price if bought, which posts inventory against goods received
    -- not invoiced as consigned stock consumed does.
    v_price := case when v_outcome = 'buy' then p_price_minor else 0 end;
    v_unit := erp.receive_cost(l.item_id, d.site_id, v_qty, v_price, d.currency, l.batch_id, null);
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency, reason_code,
      owner_party_id, custody_party_id, to_owner_party_id, document_id, document_line_id)
    values (v_tenant, d.entity_id, d.site_id, 'ownership_transfer', l.item_id, l.batch_id,
            v_loc, coalesce(v_status, 'available'), v_loc, coalesce(v_status, 'available'),
            v_qty, l.uom_id, v_unit, d.currency,
            left(coalesce(v_reason, case when v_outcome = 'buy' then 'sample bought' else 'sample kept free' end), 64),
            d.party_id, v_company, v_company, d.id, l.id)
    returning id into v_id;
    perform erp.post_movement_finance(v_id);
    perform erp.append_event('sample.kept', 'document', d.id,
      jsonb_build_object('reference', d.document_number, 'quantity', v_qty, 'line_id', l.id,
                         'price_minor', v_price, 'outcome', v_outcome, 'reason', v_reason),
      d.entity_id, d.site_id);
  end if;

  return jsonb_build_object(
    'line_id', l.id,
    'receipt_number', d.document_number,
    'outcome', v_outcome,
    'quantity', v_qty,
    'price_minor', case when v_outcome = 'buy' then p_price_minor else 0 end,
    'currency', d.currency,
    'held', erp.sample_line_held(l.id),
    'movement_id', v_id);
end;
$$;

revoke all on function erp.settle_samples(uuid, text, numeric, bigint, text) from public, anon;

comment on function erp.settle_samples(uuid, text, numeric, bigint, text) is
  'Settles some or all of a line of a supplier''s samples: returned to the supplier, kept free at no '
  'cost, or bought at an agreed price posting inventory against goods received not invoiced '
  '(20261004930000). Authorises procurement.order at the site.';

create or replace function public.erp_settle_samples(p_line uuid, p_outcome text, p_quantity numeric default null,
                                                     p_price_minor bigint default null, p_reason text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.settle_samples(p_line, p_outcome, p_quantity, p_price_minor, p_reason) $$;

revoke all on function public.erp_settle_samples(uuid, text, numeric, bigint, text) from public, anon;
grant execute on function public.erp_settle_samples(uuid, text, numeric, bigint, text) to authenticated, service_role;

comment on function public.erp_settle_samples(uuid, text, numeric, bigint, text) is
  'Returns, keeps or buys a supplier''s samples (20261004930000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_settle_samples', 'erp.settle_samples',
   'Settles a supplier''s samples: a return movement, or an ownership transfer at nothing or at an agreed price that posts inventory against goods received not invoiced; authorises procurement.order at the site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_settle_samples']);

-- ═════════════════════════════════════════════════════════════════════════════
-- E. Due back
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.notify_overdue_samples()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_n      integer := 0;
begin
  -- The daily check (20261004930000): each receipt of samples with some
  -- still held past its due-back date tells the person who received it, in
  -- the product, once.
  for r in
    select d.id, d.document_number, d.created_by, d.attributes ->> 'due_back' as due_back,
           (select p.name from erp.party p where p.tenant_id = d.tenant_id and p.id = d.party_id) as supplier,
           (select sum(erp.sample_line_held(l.id)) from erp.document_line l
             where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled) as held
      from erp.document d
     where d.tenant_id = v_tenant
       and erp.is_sample_receipt(d.id)
       and (d.attributes ->> 'due_back')::date < current_date
       and coalesce((d.attributes ->> 'overdue_notified')::boolean, false) = false
       and d.created_by is not null
  loop
    continue when coalesce(r.held, 0) <= 0;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (v_tenant, 'medium', r.created_by, 'in_app',
            format('Samples on %s were due back to %s on %s', r.document_number, coalesce(r.supplier, 'the supplier'), r.due_back),
            format('%s of them are still here. Return, keep or buy them from Samples on the Procurement screen.', r.held),
            'delivered', now(), now());
    update erp.document x
       set attributes = x.attributes || jsonb_build_object('overdue_notified', true), updated_at = now()
     where x.tenant_id = v_tenant and x.id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function erp.notify_overdue_samples() from public, anon;

comment on function erp.notify_overdue_samples() is
  'The daily check of suppliers'' samples due back: tells whoever received samples now overdue, once '
  'per receipt (20261004930000). Run by the job procurement.sample_overdue.';

insert into erp_ref.job_handler (code, name_key, description, module_code, parameter_schema,
                                 default_timeout_seconds, forbids_overlap, is_current, sql_function,
                                 default_max_silence_seconds)
values ('procurement.sample_overdue', 'job_handler.sample_overdue.name',
        'Tells whoever received a supplier''s samples when they are past their due-back date and still held (20261004930000).',
        'procurement', '{"type":"object"}'::jsonb, 120, true, true, 'notify_overdue_samples', 172800)
on conflict (code) do update set name_key = excluded.name_key, description = excluded.description,
  sql_function = excluded.sql_function, is_current = true;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.supplier_samples_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid; v_sb uuid;
  v_rcv jsonb; v_rcv2 jsonb; v_grn uuid; v_line uuid; v_line2 uuid; v_list jsonb; v_row jsonb;
  v_out jsonb; v_val0 bigint; v_val1 bigint; v_grni0 bigint; v_grni1 bigint; v_n integer; v_tie text;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, with a buyer and somebody who only reads';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzsmp-' || v_tag, 'Supplier Samples Suite',
      'admin@zzsmp-' || v_tag || '.test', 'Samples Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzsmp-' || v_tag || '.test'),
           (s_buy, 'buyer@zzsmp-' || v_tag || '.test'),
           (s_read, 'reader@zzsmp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('buyer@zzsmp-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zzsmp-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, two products and two suppliers';
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZMMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZMEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZMDRESS', 'Sample Dress', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZMBAG', 'Sample Bag', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZMBRAND');
    v_sb := erp_test.cash_payment_supplier('ZMOTHER');
    select coalesce(sum(v.value_minor), 0) into v_val0 from erp.stock_valuation_report() v;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, the refusals, the events, the job and the screens';
    v_cases := v_cases + 1;
    case_name := 'both write doors are on the allow-list under their gates and on the Procurement screen''s help, the five refusals are registered with a next action, the three events are current and named in English and German, and the daily job''s handler is registered';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance a
                where (a.function_name, a.gate) in (('erp_receive_samples', 'erp.receive_samples'),
                                                    ('erp_settle_samples', 'erp.settle_samples'))) = 2
          and (select count(*) from erp_ref.help_topic h
                where h.screen_path = '/procurement'
                  and h.actions && array['erp_receive_samples', 'erp_settle_samples']) >= 1
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_SAMPLE_PURPOSE_UNKNOWN', 'CLOVEERP_SAMPLES_HAVE_NO_LINES',
                                 'CLOVEERP_SAMPLE_NOT_HELD', 'CLOVEERP_SAMPLE_OUTCOME_UNKNOWN',
                                 'CLOVEERP_SAMPLE_PRICE_REQUIRED')
                  and coalesce(f.next_action, '') <> '') = 5
          and (select count(*) from erp_ref.event_type et
                where et.code in ('sample.received', 'sample.returned', 'sample.kept') and et.is_current) = 3
          and (select count(*) from erp_ref.resource x
                where x.key in ('event.sample.received', 'event.sample.returned', 'event.sample.kept')
                  and x.locale in ('en', 'de')) = 6
          and exists (select 1 from erp_ref.job_handler j
                       where j.code = 'procurement.sample_overdue' and j.sql_function = 'notify_overdue_samples');
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Samples arrive ───────────────────────────────────────────────────
    v_step := 'goods-in receives three dresses and a bag for a shoot, due back last week';
    v_rcv := public.erp_receive_samples(v_sa, v_site,
               jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 3),
                                 jsonb_build_object('item_id', v_item2, 'quantity', 1, 'description', 'Bag, tan')),
               current_date - 7, 'shoot', 'BRAND-SS27-01', 'For the SS27 lookbook');
    v_grn := (v_rcv ->> 'document_id')::uuid;
    select l.id into v_line from erp.document_line l where l.document_id = v_grn and l.item_id = v_item;
    select l.id into v_line2 from erp.document_line l where l.document_id = v_grn and l.item_id = v_item2;
    select coalesce(sum(v.value_minor), 0) into v_val1 from erp.stock_valuation_report() v;
    v_list := public.erp_samples(false);
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'line_id' = v_line::text;
    v_cases := v_cases + 1;
    case_name := 'samples arrive on a posted goods receipt the supplier owns, at no price: the stock is held here as the supplier''s, nothing is journalled, the valuation does not move, the samples list shows each line held, for the shoot, overdue, and the daily check is installed';
    passed := v_state is null
          and v_rcv ->> 'state' = 'posted'
          and (v_rcv ->> 'lines')::integer = 2
          and (select d.stock_owner_party_id from erp.document d where d.id = v_grn) = v_sa
          and not exists (select 1 from erp.journal j where j.document_id = v_grn)
          and v_val1 = v_val0
          and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                where b.tenant_id = rb.tenant_id and b.item_id = v_item and b.owner_party_id = v_sa) = 3
          and v_row is not null
          and (v_row ->> 'held')::numeric = 3
          and v_row ->> 'purpose' = 'shoot'
          and (v_row ->> 'overdue')::boolean
          and v_row ->> 'their_reference' = 'BRAND-SS27-01'
          and exists (select 1 from erp.job j where j.tenant_id = rb.tenant_id
                         and j.handler_code = 'procurement.sample_overdue' and j.is_enabled)
          and exists (select 1 from erp.event e where e.tenant_id = rb.tenant_id
                         and e.event_type = 'sample.received' and e.aggregate_id = v_grn);
    detail := coalesce(v_state, left(format('rcv %s; row %s; value %s→%s', v_rcv, v_row, v_val0, v_val1), 600));
    return next;

    -- ── 3. What may not be received ─────────────────────────────────────────
    v_step := 'a purpose nobody knows, nothing on it, a quantity of nought, and a reader';
    begin
      perform public.erp_receive_samples(v_sa, v_site, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1)),
                                         null, 'party', null, null);
      v_err := 'received';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_receive_samples(v_sa, v_site, '[]'::jsonb, null, 'shoot', null, null);
      v_err2 := 'received';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_receive_samples(v_sa, v_site, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 0)),
                                         null, 'shoot', null, null);
      v_err3 := 'received';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_receive_samples(v_sa, v_site, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1)),
                                         null, 'shoot', null, null);
      v_err4 := 'received';
    exception when others then v_err4 := sqlerrm; end;
    v_list := public.erp_samples(false);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a purpose nobody knows, no lines, a quantity of nought and somebody who may only read are each refused by name; the reader sees the samples and may not settle them';
    passed := v_state is null
          and v_err like 'CLOVEERP_SAMPLE_PURPOSE_UNKNOWN:%'
          and v_err2 like 'CLOVEERP_SAMPLES_HAVE_NO_LINES:%'
          and v_err3 like 'CLOVEERP_SAMPLES_HAVE_NO_LINES:%'
          and v_err4 like 'CLOVEERP_PERMISSION_DENIED: procurement.receive%'
          and jsonb_array_length(v_list) = 2
          and not exists (select 1 from jsonb_array_elements(v_list) x where (x ->> 'may_settle')::boolean);
    detail := coalesce(v_state, left(format('%s | %s | %s | %s', v_err, v_err2, v_err3, v_err4), 700));
    return next;

    -- ── 4. A price on any other receipt is still required ───────────────────
    v_step := 'a goods receipt that is not samples, with a line at nothing';
    begin
      perform erp.add_document_line(erp.open_document('goods_receipt', v_sa, v_entity, v_site), v_item, 1, 0, 'not a sample');
      v_err := 'added';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a goods receipt that is not samples still refuses a line at nothing';
    passed := v_state is null and v_err like 'CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE:%';
    detail := coalesce(v_state, left(v_err, 300));
    return next;

    -- ── 5. One goes back ────────────────────────────────────────────────────
    v_step := 'one dress returned to the supplier';
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_out := public.erp_settle_samples(v_line, 'return', 1, null, 'shot and done');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'one dress goes back: the supplier''s position here falls by one, two are still held, nothing is journalled and the valuation does not move';
    passed := v_state is null
          and (v_out ->> 'held')::numeric = 2
          and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                where b.tenant_id = rb.tenant_id and b.item_id = v_item and b.owner_party_id = v_sa) = 2
          and not exists (select 1 from erp.journal j where j.tenant_id = rb.tenant_id
                           and j.source_code = 'stock.ownership_transferred')
          and (select coalesce(sum(v.value_minor), 0) from erp.stock_valuation_report() v) = v_val0
          and exists (select 1 from erp.event e where e.tenant_id = rb.tenant_id
                         and e.event_type = 'sample.returned' and e.aggregate_id = v_grn);
    detail := coalesce(v_state, left(v_out::text, 400));
    return next;

    -- ── 6. One is kept free ─────────────────────────────────────────────────
    v_step := 'one dress kept free of charge';
    v_out := public.erp_settle_samples(v_line, 'keep', 1, null, 'the brand gave it to us');
    v_cases := v_cases + 1;
    case_name := 'one dress kept free becomes ours where it stands at no cost: the supplier holds one, we own one, nothing is journalled and the valuation does not move';
    passed := v_state is null
          and (v_out ->> 'held')::numeric = 1
          and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                where b.tenant_id = rb.tenant_id and b.item_id = v_item and b.owner_party_id = v_sa) = 1
          and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                where b.tenant_id = rb.tenant_id and b.item_id = v_item
                  and b.owner_party_id = erp.entity_party_for_site(v_site)) = 1
          and not exists (select 1 from erp.journal j where j.tenant_id = rb.tenant_id
                           and j.source_code = 'stock.ownership_transferred')
          and (select coalesce(sum(v.value_minor), 0) from erp.stock_valuation_report() v) = v_val0;
    detail := coalesce(v_state, left(v_out::text, 400));
    return next;

    -- ── 7. One is bought ────────────────────────────────────────────────────
    v_step := 'the last dress bought at £90';
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_grni0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '2100';
    v_out := public.erp_settle_samples(v_line, 'buy', null, 9000, 'the buyer wants it for the archive');
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_grni1
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = '2100';
    -- Journals are numbered as their transaction commits; this one has not.
    set constraints all immediate;
    begin
      perform erp.assert_whole_database_reconciles();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'the last dress bought at £90 becomes ours at that price: nothing of the line is still held, inventory rises by £90 against goods received not invoiced, the valuation moves by £90 and the books reconcile';
    passed := v_state is null
          and (v_out ->> 'held')::numeric = 0
          and (v_out ->> 'quantity')::numeric = 1
          and v_grni1 - v_grni0 = 9000
          and (select coalesce(sum(v.value_minor), 0) from erp.stock_valuation_report() v) = v_val0 + 9000
          and v_tie = 'ties'
          and not exists (select 1 from jsonb_array_elements(public.erp_samples(false)) x
                           where x ->> 'line_id' = v_line::text)
          and exists (select 1 from jsonb_array_elements(public.erp_samples(true)) x
                       where x ->> 'line_id' = v_line::text and (x ->> 'held')::numeric = 0);
    detail := coalesce(v_state, left(format('%s; grni %s; %s', v_out, v_grni1 - v_grni0, v_tie), 500));
    return next;

    -- ── 8. What may not be settled ──────────────────────────────────────────
    v_step := 'more than is held, an outcome nobody knows, buying at nothing, a line that is not a sample, and a reader';
    begin
      perform public.erp_settle_samples(v_line, 'return', 1, null, null);
      v_err := 'settled';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_settle_samples(v_line2, 'lend', 1, null, null);
      v_err2 := 'settled';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_settle_samples(v_line2, 'buy', 1, 0, null);
      v_err3 := 'settled';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_settle_samples(gen_random_uuid(), 'return', 1, null, null);
      v_err4 := 'settled';
    exception when others then v_err4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_settle_samples(v_line2, 'return', 1, null, null);
      v_err5 := 'settled';
    exception when others then v_err5 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'settling more than is held, an outcome nobody knows, buying at nothing, a line that is not a sample, and somebody who may only read are each refused by name, and the bag is still held';
    passed := v_state is null
          and v_err like 'CLOVEERP_SAMPLE_NOT_HELD:%'
          and v_err2 like 'CLOVEERP_SAMPLE_OUTCOME_UNKNOWN:%'
          and v_err3 like 'CLOVEERP_SAMPLE_PRICE_REQUIRED:%'
          and v_err4 like 'CLOVEERP_SAMPLE_NOT_HELD:%'
          and v_err5 like 'CLOVEERP_PERMISSION_DENIED: procurement.order%'
          and erp.sample_line_held(v_line2) = 1;
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 800));
    return next;

    -- ── 9. Due back ─────────────────────────────────────────────────────────
    v_step := 'the daily check, twice';
    v_n := erp.notify_overdue_samples();
    v_cases := v_cases + 1;
    case_name := 'the daily check tells whoever received samples now overdue, in the product, naming the receipt and the supplier, and only once';
    passed := v_state is null
          and v_n = 1
          and erp.notify_overdue_samples() = 0
          and exists (select 1 from erp.notification n
                       join erp.app_user u on u.id = n.app_user_id and u.auth_user_id = a1
                      where n.tenant_id = rb.tenant_id and n.channel_kind = 'in_app'
                        and n.subject like '%' || (v_rcv ->> 'document_number') || '%'
                        and n.subject like '%Cash Payment ZMBRAND%');
    detail := coalesce(v_state, format('%s notified', v_n));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzsmp-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_buy, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzsmp rolled back with its samples and what became of them');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.supplier_samples_suite() from public, anon;

comment on function erp_test.supplier_samples_suite() is
  'A supplier lends its samples (20261004930000): received owned by the supplier at no price and valued '
  'by nobody, listed held and overdue, returned, kept free at no cost or bought at a price against '
  'goods received not invoiced with the books reconciling, refused by name where they may not be, and '
  'the buyer told once when they are due back.';

create or replace function erp_test.assert_supplier_samples_suite()
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
    from erp_test.supplier_samples_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A supplier''s sample would be valued as ours, or leave without a trace. Read the case that failed.';
  end if;
  if v_total <> 10 then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('supplier samples: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_supplier_samples_suite() from public, anon;

comment on function erp_test.assert_supplier_samples_suite() is
  'A supplier''s samples are held as theirs, and returned, kept or bought without leaving the books '
  'untied (20261004930000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Suppliers'' samples on the Procurement screen (20261004930000).'
  from (values
    ('Samples'),
    ('Samples suppliers lent: theirs until they go back, are kept or are bought.'),
    ('No samples are held. Samples a supplier lends land here until they go back, are kept or are bought.'),
    ('Receive samples'),
    ('Receive a supplier''s samples'),
    ('The samples stay the supplier''s: held and counted here, valued by nobody, until they go back, are kept or are bought.'),
    ('Purpose'),
    ('Photo shoot'),
    ('Buying appointment'),
    ('Press loan'),
    ('Fit or quality check'),
    ('Due back'),
    ('Their reference'),
    ('Their delivery note or sample request'),
    ('Products'),
    ('Settle'),
    ('Settle a sample'),
    ('Return it to the supplier, keep it free, or buy it at the agreed price.'),
    ('Return to the supplier'),
    ('Keep free of charge'),
    ('Buy'),
    ('Price each'),
    ('Required to buy. The price agreed with the supplier.'),
    ('Leave empty to settle everything still held.'),
    ('Held'),
    ('Overdue'),
    ('{quantity} of {item} from {supplier}')
  ) as v(text)
on conflict (key, locale) do nothing;

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
