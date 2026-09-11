set lock_timeout = '30s';

-- ---------------------------------------------------------------------------
-- 1. The document permission area
-- ---------------------------------------------------------------------------

insert into erp_ref.module (code, name_key, sort_order)
values ('document', 'module.document', 95)
on conflict (code) do nothing;

insert into erp_ref.permission (code, module_code, action, name_key, data_class_aware, is_mutating) values
  ('document.template_manage', 'document', 'template_manage', 'permission.document.template_manage', false, true),
  ('document.issue',           'document', 'issue',           'permission.document.issue',           false, true),
  ('document.reprint',         'document', 'reprint',         'permission.document.reprint',         false, false)
on conflict (code) do nothing;

-- Granted through the roles that already own the work, composably: a role that
-- raises sales invoices may issue and reprint them; a role that configures the
-- organisation may manage the templates. Nothing else is widened.
insert into erp.role_permission (tenant_id, role_id, permission_code)
select rp.tenant_id, rp.role_id, c.code
  from erp.role_permission rp
  cross join (values ('document.issue'), ('document.reprint')) as c(code)
 where rp.permission_code = 'sales.invoice'
   and not exists (
     select 1 from erp.role_permission x
      where x.role_id = rp.role_id and x.permission_code = c.code);

insert into erp.role_permission (tenant_id, role_id, permission_code)
select rp.tenant_id, rp.role_id, 'document.template_manage'
  from erp.role_permission rp
 where rp.permission_code = 'administration.configure'
   and not exists (
     select 1 from erp.role_permission x
      where x.role_id = rp.role_id and x.permission_code = 'document.template_manage');

-- ---------------------------------------------------------------------------
-- 2. The numbering register
-- ---------------------------------------------------------------------------

create table if not exists erp.document_sequence (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant (id) on delete cascade,
  document_kind text not null,
  prefix        text not null,
  next_number   bigint not null default 1,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint document_sequence_kind_shape check (document_kind ~ '^[a-z][a-z0-9_]*$'),
  constraint document_sequence_prefix_shape check (prefix ~ '^[A-Z0-9][A-Z0-9-]{0,11}$'),
  constraint document_sequence_number_positive check (next_number >= 1),
  constraint document_sequence_one_per_kind unique (tenant_id, document_kind),
  constraint document_sequence_tenant_id_key unique (tenant_id, id)
);

comment on table erp.document_sequence is
  'One counter per organisation per document type. The prefix is permanent once '
  'a number has been taken from it, and the number only ever moves forward: a '
  'failed or cancelled issue keeps its number rather than handing it back.';

create or replace function erp.document_sequence_identity_is_fixed()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'CLOVEERP_SEQUENCE_IMMUTABLE: a numbering register is never deleted'
      using errcode = '42501';
  end if;
  if new.tenant_id <> old.tenant_id or new.document_kind <> old.document_kind then
    raise exception 'CLOVEERP_SEQUENCE_IMMUTABLE: a numbering register cannot change organisation or document type'
      using errcode = '42501';
  end if;
  if new.prefix <> old.prefix and old.next_number > 1 then
    raise exception 'CLOVEERP_SEQUENCE_PREFIX_FIXED: numbers have already been issued under prefix %, so it cannot change', old.prefix
      using errcode = '42501';
  end if;
  if new.next_number < old.next_number then
    raise exception 'CLOVEERP_SEQUENCE_MONOTONIC: a document number is never reused'
      using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists t_document_sequence_identity on erp.document_sequence;
create trigger t_document_sequence_identity
  before update or delete on erp.document_sequence
  for each row execute function erp.document_sequence_identity_is_fixed();

-- ---------------------------------------------------------------------------
-- 3. The issue register
-- ---------------------------------------------------------------------------

create table if not exists erp.document_issue (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant (id) on delete cascade,
  document_kind       text not null,
  source_document_id  uuid not null,
  output_template_id  uuid,
  template_version_id uuid,
  template_version    integer,
  sequence_prefix     text not null,
  sequence_number     bigint not null,
  issued_number       text not null,
  status              text not null default 'reserved',
  storage_path        text,
  content_checksum    text,
  issued_by           uuid,
  issued_at           timestamptz not null default now(),
  completed_at        timestamptz,
  sent_at             timestamptz,
  voided_at           timestamptz,
  void_reason         text,
  replaces_issue_id   uuid,
  contract_snapshot   jsonb not null,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint document_issue_status_known
    check (status in ('reserved', 'issued', 'sent', 'void')),
  constraint document_issue_checksum_shape
    check (content_checksum is null or content_checksum ~ '^[0-9a-f]{64}$'),
  constraint document_issue_issued_has_artefact
    check (status not in ('issued', 'sent')
           or (storage_path is not null and content_checksum is not null)),
  constraint document_issue_void_has_reason
    check (status <> 'void' or coalesce(btrim(void_reason), '') <> ''),
  constraint document_issue_snapshot_sections
    check (contract_snapshot ?& array['header', 'company', 'customer', 'lines', 'tax_summary', 'totals']),
  constraint document_issue_number_once unique (tenant_id, document_kind, sequence_number),
  constraint document_issue_tenant_id_key unique (tenant_id, id),
  constraint document_issue_source_fk
    foreign key (tenant_id, source_document_id) references erp.document (tenant_id, id) on delete restrict,
  constraint document_issue_replaces_fk
    foreign key (tenant_id, replaces_issue_id) references erp.document_issue (tenant_id, id) on delete restrict
);

comment on table erp.document_issue is
  'What was actually issued. The number, the template version, the stored file '
  'and its checksum, and the whole resolved document frozen as contract_snapshot '
  'at the moment of issue, so a later edit or a partner merge cannot change the '
  'explanation of what the customer was given.';

create index if not exists document_issue_source_idx
  on erp.document_issue (tenant_id, source_document_id);

create or replace function erp.document_issue_is_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'CLOVEERP_ISSUE_IMMUTABLE: an issued document is never deleted; it is voided and replaced'
      using errcode = '42501';
  end if;

  if new.tenant_id        <> old.tenant_id
  or new.document_kind    <> old.document_kind
  or new.source_document_id <> old.source_document_id
  or new.sequence_prefix  <> old.sequence_prefix
  or new.sequence_number  <> old.sequence_number
  or new.issued_number    <> old.issued_number
  or new.contract_snapshot::text <> old.contract_snapshot::text
  or coalesce(new.template_version_id, '00000000-0000-0000-0000-000000000000'::uuid)
     <> coalesce(old.template_version_id, '00000000-0000-0000-0000-000000000000'::uuid)
  or coalesce(new.replaces_issue_id, '00000000-0000-0000-0000-000000000000'::uuid)
     <> coalesce(old.replaces_issue_id, '00000000-0000-0000-0000-000000000000'::uuid) then
    raise exception 'CLOVEERP_ISSUE_IMMUTABLE: the identity of an issue cannot be altered after the number was taken'
      using errcode = '42501';
  end if;

  if old.status in ('issued', 'sent')
     and (coalesce(new.storage_path, '') <> coalesce(old.storage_path, '')
          or coalesce(new.content_checksum, '') <> coalesce(old.content_checksum, '')) then
    raise exception 'CLOVEERP_ISSUE_IMMUTABLE: the issued file and its checksum cannot change'
      using errcode = '42501';
  end if;

  if new.status <> old.status and not (
       (old.status = 'reserved' and new.status in ('issued', 'void'))
    or (old.status = 'issued'   and new.status in ('sent', 'void'))) then
    raise exception 'CLOVEERP_ISSUE_STATE: an issue cannot move from % to %', old.status, new.status
      using errcode = '42501';
  end if;

  return new;
end $$;

drop trigger if exists t_document_issue_immutable on erp.document_issue;
create trigger t_document_issue_immutable
  before update or delete on erp.document_issue
  for each row execute function erp.document_issue_is_immutable();

create table if not exists erp.document_reprint (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant (id) on delete cascade,
  document_issue_id uuid not null,
  reason            text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  constraint document_reprint_issue_fk
    foreign key (tenant_id, document_issue_id)
      references erp.document_issue (tenant_id, id) on delete cascade
);

comment on table erp.document_reprint is
  'Every reprint of an issued document, so handing the same file out again is '
  'evidence rather than a silent read.';

select erp_meta.register_table('erp', 'document_sequence', 'tenant_scoped',
  'The permanent numbering register of one organisation, per document type.');
select erp_meta.register_table('erp', 'document_issue', 'tenant_scoped',
  'What was issued, under which number and template, frozen as it read at issue.');
select erp_meta.register_table('erp', 'document_reprint', 'tenant_scoped_append_only',
  'Every reprint of an issued document.');

-- One active template version per organisation per template.
create unique index if not exists output_template_version_one_active
  on erp.output_template_version (tenant_id, output_template_id)
  where status = 'active';

-- The tax point the contract needs, recorded rather than guessed.
alter table erp.document add column if not exists tax_point date;
comment on column erp.document.tax_point is
  'The date the tax became due. Where it is absent the posting date, then the '
  'document date, stands in; an issued VAT invoice must have one resolved.';

-- ---------------------------------------------------------------------------
-- 4. The sales invoice contract
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
  v_office   jsonb;
  v_billing  jsonb;
  v_lines    jsonb;
  v_tax      jsonb;
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

  select r.registration_number into v_vat
    from erp.entity_tax_registration r
   where r.tenant_id = v_tenant
     and r.entity_id = v_doc.entity_id
     and upper(r.registration_type) like 'VAT%'
     and r.valid_from <= coalesce(v_doc.tax_point, v_doc.posting_date, v_doc.document_date)
     and (r.valid_to is null or r.valid_to >= coalesce(v_doc.tax_point, v_doc.posting_date, v_doc.document_date))
   order by r.valid_from desc
   limit 1;

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

  return jsonb_build_object(
    'contract', 'sales_invoice',
    'contract_version', 1,
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
      'is_vat_registered', v_vat is not null,
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
    'totals', jsonb_build_object(
      'net_minor', v_net,
      'tax_minor', v_taxm,
      'gross_minor', v_net + v_taxm,
      'currency', v_doc.currency,
      'vat_total_sterling_minor',
        case when upper(coalesce(v_doc.currency, '')) = 'GBP' then v_taxm
             else round(v_taxm * v_rate) end,
      'sterling_basis',
        case when upper(coalesce(v_doc.currency, '')) = 'GBP' then 'invoiced in sterling'
             else 'converted at the invoice exchange rate' end));
end $$;

comment on function erp.sales_invoice_contract is
  'Everything a sales invoice must say, resolved from the records as they read '
  'now: header, issuing company, customer and address, lines, grouped tax and '
  'totals including VAT in sterling. Frozen onto the issue when one is taken.';

-- ---------------------------------------------------------------------------
-- 5. Issue-time refusals
-- ---------------------------------------------------------------------------

insert into erp_ref.refusal (code, refused, why, next_action) values
  ('CLOVEERP_ISSUER_VAT_NUMBER_MISSING',
   'This invoice cannot be issued without a VAT registration number.',
   'The issuing company is VAT registered, so its VAT number must appear on the invoice.',
   'Open Organisation and approval routing and record the VAT registration, then issue again.'),
  ('CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING',
   'This invoice cannot be issued without a company registration number.',
   'A VAT invoice must name the company that issued it.',
   'Open Organisation and approval routing and record the company registration number, then issue again.'),
  ('CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING',
   'This invoice cannot be issued without a registered office address.',
   'A VAT invoice must carry the registered office of the issuing company.',
   'Open Organisation and approval routing and add a registered address for the company, then issue again.'),
  ('CLOVEERP_INVOICE_TAX_POINT_MISSING',
   'This invoice has no tax point.',
   'A VAT invoice must say the date the tax became due.',
   'Open the invoice and set its tax point, then issue again.'),
  ('CLOVEERP_INVOICE_LINE_TAX_MISSING',
   'A line on this invoice has no net amount or no VAT rate.',
   'Every line of a VAT invoice must show what it came to and the rate applied.',
   'Open the invoice, complete the line amount and VAT rate, then issue again.'),
  ('CLOVEERP_CUSTOMER_ADDRESS_MISSING',
   'This invoice has no customer invoice address.',
   'A VAT invoice must be addressed to the customer.',
   'Open Business partners, add an invoice address for this customer, then issue again.'),
  ('CLOVEERP_INVOICE_ALREADY_SENT',
   'This invoice has already been sent, so it cannot be amended.',
   'Once a customer holds an invoice, correcting it by replacement would leave two documents with the same claim.',
   'Raise a credit note against it instead, then issue a new invoice.')
on conflict (code) do update set
  refused = excluded.refused, why = excluded.why, next_action = excluded.next_action;

create or replace function erp.validate_sales_invoice_issue(p_document_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_c    jsonb := erp.sales_invoice_contract(p_document_id);
  v_bad  jsonb := '[]'::jsonb;
  v_line jsonb;
begin
  if (v_c -> 'company' ->> 'is_vat_registered')::boolean then
    if coalesce(btrim(v_c -> 'company' ->> 'vat_registration_number'), '') = '' then
      v_bad := v_bad || jsonb_build_object('field', 'VAT registration number',
        'refusal', 'CLOVEERP_ISSUER_VAT_NUMBER_MISSING');
    end if;
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
    for v_line in select * from jsonb_array_elements(v_c -> 'lines') loop
      if v_line ->> 'net_minor' is null or v_line ->> 'tax_rate_pct' is null then
        v_bad := v_bad || jsonb_build_object(
          'field', format('Line %s net amount and VAT rate', v_line ->> 'line_no'),
          'refusal', 'CLOVEERP_INVOICE_LINE_TAX_MISSING');
      end if;
    end loop;
    if jsonb_array_length(v_c -> 'lines') = 0 then
      v_bad := v_bad || jsonb_build_object('field', 'Invoice lines',
        'refusal', 'CLOVEERP_INVOICE_LINE_TAX_MISSING');
    end if;
  end if;

  return jsonb_build_object(
    'document_id', p_document_id,
    'can_issue', jsonb_array_length(v_bad) = 0,
    'missing', v_bad);
end $$;

comment on function erp.validate_sales_invoice_issue is
  'What is still missing before a VAT invoice may be issued, named field by '
  'field with the refusal that explains where to fix it.';

-- ---------------------------------------------------------------------------
-- 6. Reserving a number, issuing, sending, amending, reprinting
-- ---------------------------------------------------------------------------

create or replace function erp.reserve_document_number(p_document_kind text, p_prefix text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_prefix text; v_number bigint;
begin
  insert into erp.document_sequence (tenant_id, document_kind, prefix)
  values (v_tenant, p_document_kind, coalesce(nullif(btrim(upper(p_prefix)), ''), 'INV'))
  on conflict (tenant_id, document_kind) do nothing;

  update erp.document_sequence s
     set next_number = s.next_number + 1
   where s.tenant_id = v_tenant and s.document_kind = p_document_kind
  returning s.prefix, s.next_number - 1 into v_prefix, v_number;

  if v_number is null then
    raise exception 'CLOVEERP_NOT_FOUND: no numbering register for %', p_document_kind
      using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'prefix', v_prefix,
    'number', v_number,
    'issued_number', v_prefix || '-' || lpad(v_number::text, 6, '0'));
end $$;

comment on function erp.reserve_document_number is
  'Takes the next number and moves the counter forward in the same statement. '
  'The number is spent whether or not the issue that took it succeeds.';

create or replace function erp.issue_sales_invoice(
  p_document_id uuid,
  p_template_version_id uuid default null,
  p_replaces_issue_id uuid default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_check    jsonb;
  v_first    jsonb;
  v_r        jsonb;
  v_id       uuid;
  v_contract jsonb;
  v_tpl      uuid;
  v_ver      integer;
begin
  perform erp.authorise('document.issue', null, null, null, 'document', p_document_id);

  v_check := erp.validate_sales_invoice_issue(p_document_id);
  if not (v_check ->> 'can_issue')::boolean then
    v_first := (v_check -> 'missing') -> 0;
    raise exception '%: % is missing on this invoice',
      v_first ->> 'refusal', v_first ->> 'field'
      using errcode = '23514';
  end if;

  if exists (
    select 1 from erp.document_issue di
     where di.tenant_id = v_tenant
       and di.source_document_id = p_document_id
       and di.status in ('reserved', 'issued', 'sent')) and p_replaces_issue_id is null then
    raise exception 'CLOVEERP_ALREADY_ISSUED: this invoice already carries an issued number'
      using errcode = '23505';
  end if;

  v_contract := erp.sales_invoice_contract(p_document_id);

  select v.output_template_id, v.version into v_tpl, v_ver
    from erp.output_template_version v
   where v.tenant_id = v_tenant and v.id = p_template_version_id;

  v_r := erp.reserve_document_number('sales_invoice');

  insert into erp.document_issue (
    tenant_id, document_kind, source_document_id, output_template_id,
    template_version_id, template_version, sequence_prefix, sequence_number,
    issued_number, status, issued_by, replaces_issue_id, contract_snapshot)
  values (
    v_tenant, 'sales_invoice', p_document_id, v_tpl,
    p_template_version_id, v_ver, v_r ->> 'prefix', (v_r ->> 'number')::bigint,
    v_r ->> 'issued_number', 'reserved', erp.current_principal_id(),
    p_replaces_issue_id, v_contract)
  returning id into v_id;

  return jsonb_build_object(
    'document_issue_id', v_id,
    'issued_number', v_r ->> 'issued_number',
    'status', 'reserved',
    'replaces_issue_id', p_replaces_issue_id);
end $$;

comment on function erp.issue_sales_invoice is
  'Reserves a permanent number for one invoice and freezes the whole resolved '
  'contract against it. Refuses first, so a number is not spent on an invoice '
  'that could never be issued.';

create or replace function erp.complete_document_issue(
  p_document_issue_id uuid, p_storage_path text, p_content_checksum text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);

  update erp.document_issue
     set storage_path = p_storage_path,
         content_checksum = lower(p_content_checksum),
         status = 'issued',
         completed_at = now()
   where tenant_id = v_tenant and id = p_document_issue_id and status = 'reserved';
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no reserved issue of that number to complete'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('document_issue_id', p_document_issue_id, 'status', 'issued');
end $$;

create or replace function erp.void_document_issue(p_document_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'CLOVEERP_VALIDATION: say why the issue is being voided' using errcode = '23514';
  end if;

  update erp.document_issue
     set status = 'void', voided_at = now(), void_reason = btrim(p_reason)
   where tenant_id = v_tenant and id = p_document_issue_id and status in ('reserved', 'issued');
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: nothing to void; the issue is already sent or void'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('document_issue_id', p_document_issue_id, 'status', 'void');
end $$;

comment on function erp.void_document_issue is
  'Cancels an issue. The number stays spent and the row stays readable; nothing '
  'is deleted and no number returns to the pool.';

create or replace function erp.mark_document_issue_sent(p_document_issue_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);
  update erp.document_issue set status = 'sent', sent_at = now()
   where tenant_id = v_tenant and id = p_document_issue_id and status = 'issued';
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: only a completed issue can be marked as sent'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('document_issue_id', p_document_issue_id, 'status', 'sent');
end $$;

create or replace function erp.amend_sales_invoice(p_document_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_row    erp.document_issue%rowtype;
  v_new    jsonb;
begin
  perform erp.authorise('document.issue', null, null, null, 'document_issue', p_document_issue_id);

  select * into v_row from erp.document_issue di
   where di.tenant_id = v_tenant and di.id = p_document_issue_id;
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no such issued document' using errcode = 'P0002';
  end if;

  if v_row.status = 'sent' then
    raise exception 'CLOVEERP_INVOICE_ALREADY_SENT: invoice % has been sent; raise a credit note instead',
      v_row.issued_number using errcode = '42501';
  end if;
  if v_row.status = 'void' then
    raise exception 'CLOVEERP_NOT_FOUND: that issue is already void' using errcode = 'P0002';
  end if;

  perform erp.void_document_issue(p_document_issue_id,
    coalesce(nullif(btrim(p_reason), ''), 'Amended before sending'));

  v_new := erp.issue_sales_invoice(v_row.source_document_id, v_row.template_version_id,
                                   p_document_issue_id);

  return jsonb_build_object(
    'replaced_issue_id', p_document_issue_id,
    'replaced_number', v_row.issued_number,
    'document_issue_id', v_new ->> 'document_issue_id',
    'issued_number', v_new ->> 'issued_number');
end $$;

comment on function erp.amend_sales_invoice is
  'Before sending: the original is voided, its number kept and never reused, and '
  'a newly numbered issue is created that names what it replaces. After sending: '
  'refused, with a credit note as the way forward.';

create or replace function erp.reprint_document_issue(p_document_issue_id uuid, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_row erp.document_issue%rowtype;
begin
  perform erp.authorise('document.reprint', null, null, null, 'document_issue', p_document_issue_id);

  select * into v_row from erp.document_issue di
   where di.tenant_id = v_tenant and di.id = p_document_issue_id;
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no such issued document' using errcode = 'P0002';
  end if;
  if v_row.status not in ('issued', 'sent') then
    raise exception 'CLOVEERP_NOT_FOUND: that number was never completed, so there is no file to reprint'
      using errcode = 'P0002';
  end if;

  insert into erp.document_reprint (tenant_id, document_issue_id, reason)
  values (v_tenant, p_document_issue_id, nullif(btrim(p_reason), ''));

  return jsonb_build_object(
    'document_issue_id', v_row.id,
    'issued_number', v_row.issued_number,
    'storage_path', v_row.storage_path,
    'content_checksum', v_row.content_checksum,
    'rendered_again', false);
end $$;

comment on function erp.reprint_document_issue is
  'Hands back the file that was issued, by path and checksum. It never renders '
  'from current data and never takes another number.';

-- ---------------------------------------------------------------------------
-- 7. Public doors
-- ---------------------------------------------------------------------------

create or replace function public.erp_sales_invoice_contract(p_document_id uuid)
returns jsonb language plpgsql stable set search_path to '' as $$
begin
  perform erp.authorise('sales.read', null, null, null, 'document', p_document_id);
  return erp.sales_invoice_contract(p_document_id);
end $$;

create or replace function public.erp_sales_invoice_issue_readiness(p_document_id uuid)
returns jsonb language plpgsql stable set search_path to '' as $$
begin
  perform erp.authorise('sales.read', null, null, null, 'document', p_document_id);
  return erp.validate_sales_invoice_issue(p_document_id);
end $$;

create or replace function public.erp_document_issues(
  p_document_id uuid default null, p_limit integer default 100)
returns jsonb language plpgsql stable set search_path to '' as $$
declare v_out jsonb;
begin
  perform erp.authorise('sales.read');
  select coalesce(jsonb_agg(x order by x ->> 'issued_at' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'document_issue_id', di.id,
      'document_kind', di.document_kind,
      'source_document_id', di.source_document_id,
      'source_document_number', d.document_number,
      'issued_number', di.issued_number,
      'status', di.status,
      'template_version', di.template_version,
      'storage_path', di.storage_path,
      'content_checksum', di.content_checksum,
      'issued_by', di.issued_by,
      'issued_at', di.issued_at,
      'sent_at', di.sent_at,
      'voided_at', di.voided_at,
      'void_reason', di.void_reason,
      'replaces_issue_id', di.replaces_issue_id,
      'replaces_number', (select r.issued_number from erp.document_issue r
                           where r.tenant_id = di.tenant_id and r.id = di.replaces_issue_id),
      'contract_snapshot', di.contract_snapshot) as x
      from erp.document_issue di
      join erp.document d on d.tenant_id = di.tenant_id and d.id = di.source_document_id
     where di.tenant_id = erp.current_tenant_id()
       and (p_document_id is null or di.source_document_id = p_document_id)
     order by di.issued_at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500))
  ) s;
  return v_out;
end $$;

create or replace function public.erp_issue_sales_invoice(
  p_document_id uuid, p_template_version_id uuid default null)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.issue_sales_invoice(p_document_id, p_template_version_id, null) $$;

create or replace function public.erp_complete_document_issue(
  p_document_issue_id uuid, p_storage_path text, p_content_checksum text)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.complete_document_issue(p_document_issue_id, p_storage_path, p_content_checksum) $$;

create or replace function public.erp_amend_sales_invoice(p_document_issue_id uuid, p_reason text)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.amend_sales_invoice(p_document_issue_id, p_reason) $$;

create or replace function public.erp_void_document_issue(p_document_issue_id uuid, p_reason text)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.void_document_issue(p_document_issue_id, p_reason) $$;

create or replace function public.erp_mark_document_issue_sent(p_document_issue_id uuid)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.mark_document_issue_sent(p_document_issue_id) $$;

create or replace function public.erp_reprint_document_issue(
  p_document_issue_id uuid, p_reason text default null)
returns jsonb language sql volatile set search_path to '' as $$
  select erp.reprint_document_issue(p_document_issue_id, p_reason) $$;

revoke all on function public.erp_sales_invoice_contract(uuid) from public, anon;
revoke all on function public.erp_sales_invoice_issue_readiness(uuid) from public, anon;
revoke all on function public.erp_document_issues(uuid, integer) from public, anon;
revoke all on function public.erp_issue_sales_invoice(uuid, uuid) from public, anon;
revoke all on function public.erp_complete_document_issue(uuid, text, text) from public, anon;
revoke all on function public.erp_amend_sales_invoice(uuid, text) from public, anon;
revoke all on function public.erp_void_document_issue(uuid, text) from public, anon;
revoke all on function public.erp_mark_document_issue_sent(uuid) from public, anon;
revoke all on function public.erp_reprint_document_issue(uuid, text) from public, anon;

grant execute on function public.erp_sales_invoice_contract(uuid) to authenticated, service_role;
grant execute on function public.erp_sales_invoice_issue_readiness(uuid) to authenticated, service_role;
grant execute on function public.erp_document_issues(uuid, integer) to authenticated, service_role;
grant execute on function public.erp_issue_sales_invoice(uuid, uuid) to authenticated, service_role;
grant execute on function public.erp_complete_document_issue(uuid, text, text) to authenticated, service_role;
grant execute on function public.erp_amend_sales_invoice(uuid, text) to authenticated, service_role;
grant execute on function public.erp_void_document_issue(uuid, text) to authenticated, service_role;
grant execute on function public.erp_mark_document_issue_sent(uuid) to authenticated, service_role;
grant execute on function public.erp_reprint_document_issue(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_issue_sales_invoice', 'erp.issue_sales_invoice',
   'Reserves a permanent invoice number and freezes the contract. Gated on document.issue.'),
  ('erp_complete_document_issue', 'erp.complete_document_issue',
   'Records the rendered file and its checksum against a reserved number. Gated on document.issue.'),
  ('erp_amend_sales_invoice', 'erp.amend_sales_invoice',
   'Voids an unsent issue and reissues under a new number. Gated on document.issue; refused after sending.'),
  ('erp_void_document_issue', 'erp.void_document_issue',
   'Cancels an issue without returning its number. Gated on document.issue.'),
  ('erp_mark_document_issue_sent', 'erp.mark_document_issue_sent',
   'Records that the customer holds the issued document. Gated on document.issue.'),
  ('erp_reprint_document_issue', 'erp.reprint_document_issue',
   'Returns the stored file and checksum of an existing issue. Gated on document.reprint.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ---------------------------------------------------------------------------
-- 8. The self-check
-- ---------------------------------------------------------------------------

create or replace function erp.assert_document_issue_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_bad text; v_def text; v_code text;
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
  or exists (select 1 from erp.document_issue di join erp.document_issue r on r.id = di.replaces_issue_id
              where r.tenant_id <> di.tenant_id)
  or exists (select 1 from erp.document_reprint rp join erp.document_issue di on di.id = rp.document_issue_id
              where di.tenant_id <> rp.tenant_id) then
    raise exception 'ERPWARE_DOCUMENT_TENANT_LEAK: an issue, replacement or reprint crosses organisations'
      using errcode = 'P0001';
  end if;

  -- one active template version per organisation and template
  if not exists (select 1 from pg_class where relname = 'output_template_version_one_active') then
    raise exception 'ERPWARE_DOCUMENT_TEMPLATE_UNBOUNDED: more than one active version is possible'
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

  -- the prefix cannot change once used, and the counter only moves forward
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

  -- the gates: issue, template management and reprint
  foreach v_code in array array['document.issue', 'document.reprint', 'document.template_manage'] loop
    if not exists (select 1 from erp_ref.permission where code = v_code) then
      raise exception 'ERPWARE_DOCUMENT_PERMISSION_MISSING: %', v_code using errcode = 'P0001';
    end if;
  end loop;

  foreach v_code in array array['issue_sales_invoice', 'complete_document_issue',
                                'amend_sales_invoice', 'void_document_issue',
                                'mark_document_issue_sent'] loop
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp' and p.proname = v_code;
    if v_def is null or v_def !~ 'document\.issue' then
      raise exception 'ERPWARE_DOCUMENT_ISSUE_UNGATED: erp.% does not require document.issue', v_code
        using errcode = 'P0001';
    end if;
  end loop;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'reprint_document_issue';
  if v_def is null or v_def !~ 'document\.reprint' then
    raise exception 'ERPWARE_DOCUMENT_REPRINT_UNGATED: reprint does not require document.reprint'
      using errcode = 'P0001';
  end if;
  if v_def ~ 'sales_invoice_contract\(' or v_def ~ 'reserve_document_number\(' then
    raise exception 'ERPWARE_DOCUMENT_REPRINT_RERENDERS: reprint must return the stored file, not a new one'
      using errcode = 'P0001';
  end if;

  -- every legal refusal is registered with somewhere to go
  foreach v_code in array array['CLOVEERP_ISSUER_VAT_NUMBER_MISSING',
                                'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING',
                                'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING',
                                'CLOVEERP_INVOICE_TAX_POINT_MISSING',
                                'CLOVEERP_INVOICE_LINE_TAX_MISSING',
                                'CLOVEERP_CUSTOMER_ADDRESS_MISSING',
                                'CLOVEERP_INVOICE_ALREADY_SENT'] loop
    if not exists (
      select 1 from erp_ref.refusal r
       where r.code = v_code and coalesce(btrim(r.next_action), '') <> '') then
      raise exception 'ERPWARE_DOCUMENT_REFUSAL_UNNAMED: % has no destination', v_code
        using errcode = 'P0001';
    end if;
  end loop;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'validate_sales_invoice_issue';
  foreach v_code in array array['CLOVEERP_ISSUER_VAT_NUMBER_MISSING',
                                'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING',
                                'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING',
                                'CLOVEERP_INVOICE_TAX_POINT_MISSING',
                                'CLOVEERP_INVOICE_LINE_TAX_MISSING',
                                'CLOVEERP_CUSTOMER_ADDRESS_MISSING'] loop
    if v_def !~ v_code then
      raise exception 'ERPWARE_DOCUMENT_VALIDATION_INCOMPLETE: % is never checked', v_code
        using errcode = 'P0001';
    end if;
  end loop;

  -- amendment: voids before send, refuses after send
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'amend_sales_invoice';
  if v_def !~ 'CLOVEERP_INVOICE_ALREADY_SENT' or v_def !~ 'void_document_issue' then
    raise exception 'ERPWARE_DOCUMENT_AMENDMENT_UNDEFINED: amendment neither voids before send nor refuses after'
      using errcode = 'P0001';
  end if;
  if exists (
    select 1 from erp.document_issue di
     where di.replaces_issue_id is not null
       and (select r.status from erp.document_issue r where r.id = di.replaces_issue_id) <> 'void') then
    raise exception 'ERPWARE_DOCUMENT_REPLACEMENT_UNVOIDED: a replacement exists while the original still stands'
      using errcode = 'P0001';
  end if;
  if exists (
    select 1 from erp.document_issue di
     where di.replaces_issue_id is not null
       and di.sequence_number = (select r.sequence_number from erp.document_issue r
                                  where r.id = di.replaces_issue_id)) then
    raise exception 'ERPWARE_DOCUMENT_NUMBER_REUSED: a replacement took the number it replaced'
      using errcode = 'P0001';
  end if;

  return 'document issue: numbers permanent, issues frozen and gated, amendment defined, reprint returns the stored file';
end $$;

comment on function erp.assert_document_issue_sound is
  'Proves the issue ledger keeps its promises: registered and isolated tables, '
  'one active template version, numbers taken once and never reused, every '
  'issued row carrying a complete frozen contract, issue and reprint behind '
  'their own permissions, every legal refusal registered with a destination, '
  'and amendment that voids before sending and refuses after.';

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
select erp.assert_document_issue_sound();