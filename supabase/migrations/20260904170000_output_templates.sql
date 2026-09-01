-- =============================================================================
-- §9.3 — the output template surface
--
-- The decision left open said the schema has three template tables and none of
-- them renders a delivery note or a pallet label, and that what is missing is
-- "a table, a change-set kind, and a renderer". All three are here, with one
-- boundary stated plainly: the renderer resolves, it does not draw.
--
-- erp.render_output_template() returns a JSON document — every label already
-- translated through the resource and branding layer in the caller's locale,
-- every value already read off the document, the organisation's own branding
-- attached. Turning that into a PDF or a ZPL label stream is the client's job,
-- because a page is pixels and pixels are not configuration. What IS
-- configuration — which fields appear, in what order, under which words, on
-- which document types — is a promotable row like everything else.
--
-- §9.3's "neutral layouts, tenant-brandable through the resource and branding
-- layer" is the whole design brief, and it is met by construction rather than
-- by discipline: a template block names a RESOURCE KEY, never a piece of text,
-- so a template cannot contain a word an organisation is unable to change.
-- erp.assert_output_templates_sound() refuses one that tries.
--
-- Two registers make that checkable. erp_ref.output_block_kind says what a
-- renderer handles, and erp_ref.output_field says which values a block may
-- bind and where each comes from — so a mistyped field is a build failure
-- rather than a blank line on a delivery note somebody posts to a customer.
-- =============================================================================

create table if not exists erp_ref.output_block_kind (
  code        text primary key,
  name        text not null,
  description text not null,
  -- Whether the block repeats per line. A renderer needs to know before it
  -- starts, and a template that puts a line field in a once-only block is a
  -- template that renders the first line and silently loses the rest.
  repeats     boolean not null default false,
  seq         integer not null default 100
);

comment on table erp_ref.output_block_kind is
  'The block kinds a renderer handles. A template using anything else would '
  'render as a gap, so erp.assert_output_templates_sound() refuses it.';

insert into erp_ref.output_block_kind (code, name, description, repeats, seq) values
  ('logo',          'Logo',          'The organisation''s mark, from the branding layer.', false, 10),
  ('title',         'Title',         'The document''s name and its reference.', false, 20),
  ('issuer',        'Issuer',        'Who is sending it: the company, its address and registration.', false, 30),
  ('counterparty',  'Counterparty',  'Who it is for, from the address snapshot the document carries.', false, 40),
  ('summary',       'Summary',       'Dates, references and terms, as label-and-value pairs.', false, 50),
  ('lines',         'Lines',         'The line table. Repeats per document line.', true,  60),
  ('totals',        'Totals',        'Net, tax and gross, as label-and-value pairs.', false, 70),
  ('note',          'Note',          'Free text the document carries.', false, 80),
  ('barcode',       'Barcode',       'A one-dimensional code, for a label.', false, 90),
  ('qr',            'QR',            'A two-dimensional code, for a label.', false, 100),
  ('signature',     'Signature',     'A space for a name, a signature and a date.', false, 110),
  ('footer',        'Footer',        'Small print, from the resource layer.', false, 120)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  repeats = excluded.repeats, seq = excluded.seq;

create table if not exists erp_ref.output_field (
  code        text primary key,
  source      text not null check (source in ('document', 'line', 'entity', 'party', 'branding', 'computed')),
  -- The label an organisation renames it by. A field with no resource key
  -- would print a word nobody can change, which §9.3 forbids.
  label_key   text not null,
  description text not null,
  is_line     boolean not null default false,
  seq         integer not null default 100
);

comment on table erp_ref.output_field is
  'Every value a template block may bind, where it comes from, and the '
  'resource key its label is renamed by. A template naming anything else '
  'fails erp.assert_output_templates_sound() rather than printing a blank.';

insert into erp_ref.output_field (code, source, label_key, description, is_line, seq) values
  ('document_number',   'document', 'output.field.document_number',   'The reference the sequence issued.', false, 10),
  ('document_date',     'document', 'output.field.document_date',     'The date on the document.', false, 20),
  ('required_date',     'document', 'output.field.required_date',     'When it is needed by.', false, 30),
  ('due_date',          'document', 'output.field.due_date',          'When payment falls due.', false, 40),
  ('our_reference',     'document', 'output.field.our_reference',     'Our reference.', false, 50),
  ('their_reference',   'document', 'output.field.their_reference',   'The counterparty''s reference.', false, 60),
  ('currency',          'document', 'output.field.currency',          'The currency the amounts are in.', false, 70),
  ('notes',             'document', 'output.field.notes',             'Whatever was written on the document.', false, 80),
  ('party_name',        'party',    'output.field.party_name',        'Who the document is for.', false, 90),
  ('party_address',     'party',    'output.field.party_address',     'The address as it stood when the document was raised.', false, 100),
  ('entity_name',       'entity',   'output.field.entity_name',       'The company issuing it.', false, 110),
  ('entity_country',    'entity',   'output.field.entity_country',    'Where that company is registered.', false, 120),
  ('brand_name',        'branding', 'output.field.brand_name',        'The name the organisation trades under.', false, 130),
  ('line_no',           'line',     'output.field.line_no',           'Line number.', true, 200),
  ('item_code',         'line',     'output.field.item_code',         'The item''s code.', true, 210),
  ('description',       'line',     'output.field.description',       'What the line is for.', true, 220),
  ('quantity',          'line',     'output.field.quantity',          'How many.', true, 230),
  ('uom',               'line',     'output.field.uom',               'The unit it is counted in.', true, 240),
  ('unit_price',        'line',     'output.field.unit_price',        'Price per unit.', true, 250),
  ('net_amount',        'line',     'output.field.net_amount',        'Line net.', true, 260),
  ('tax_amount',        'line',     'output.field.tax_amount',        'Line tax.', true, 270),
  ('batch',             'line',     'output.field.batch',             'The batch, where the line names one.', true, 280),
  ('location',          'line',     'output.field.location',          'Where the stock is or goes.', true, 290),
  ('quantity_fulfilled','line',     'output.field.quantity_fulfilled','How much has already moved.', true, 300),
  ('total_net',         'computed', 'output.field.total_net',         'The sum of the line nets.', false, 400),
  ('total_tax',         'computed', 'output.field.total_tax',         'The sum of the line taxes.', false, 410),
  ('total_gross',       'computed', 'output.field.total_gross',       'Net plus tax.', false, 420),
  ('line_count',        'computed', 'output.field.line_count',        'How many lines there are.', false, 430)
on conflict (code) do update set
  source = excluded.source, label_key = excluded.label_key,
  description = excluded.description, is_line = excluded.is_line, seq = excluded.seq;

select erp_meta.register_table('erp_ref', 'output_block_kind', 'product_content',
  'The block kinds an output renderer handles.');
select erp_meta.register_table('erp_ref', 'output_field', 'product_content',
  'The values an output template block may bind.');

-- -----------------------------------------------------------------------------
-- The table
-- -----------------------------------------------------------------------------

create table if not exists erp.output_template (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  code          text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  -- The name is a resource key, not a name. §9.3's whole brief is that a
  -- layout is brandable through the resource layer, and a column holding
  -- 'Delivery note' would be a word no organisation could rename.
  name_key      text not null,
  kind          text not null check (kind in ('document', 'label')),
  -- Which document this renders. A neutral base type, so a template is written
  -- once and applies to whatever an organisation called its own document type.
  -- Null for a label that belongs to stock rather than to a document.
  base_type_code text references erp_ref.document_type(code),
  -- A4, A5, or a label size. Free text because a label printer's stock is not
  -- something this product should have opinions about.
  page          text not null default 'A4',
  blocks        jsonb not null default '[]',
  status        erp.record_status not null default 'active',
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint output_template_document_has_type
    check (kind <> 'document' or base_type_code is not null)
);

comment on table erp.output_template is
  '§9.3''s document and label layouts. A block names a resource key and a '
  'field code, never a piece of text and never a column — so the layout is '
  'configuration, the words are the organisation''s, and '
  'erp.assert_output_templates_sound() can check both.';

create index if not exists output_template_by_type
  on erp.output_template (tenant_id, base_type_code) where status = 'active';

select erp_meta.register_table('erp', 'output_template', 'tenant_scoped',
  '§9.3''s document and label layouts.');

-- -----------------------------------------------------------------------------
-- The writer the promoter uses
-- -----------------------------------------------------------------------------

create or replace function erp.upsert_output_template(
  p_code           text,
  p_name_key       text,
  p_kind           text,
  p_base_type_code text default null,
  p_page           text default 'A4',
  p_blocks         jsonb default '[]')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  b        jsonb;
  f        text;
begin
  -- Refuse here rather than at print time. A template that names a block kind
  -- nothing renders, or a field nothing resolves, produces a gap on a document
  -- somebody has already put in an envelope.
  for b in select * from jsonb_array_elements(coalesce(p_blocks, '[]'::jsonb))
  loop
    if not exists (select 1 from erp_ref.output_block_kind k
                    where k.code = (b ->> 'kind')) then
      raise exception
        'ERPWARE_UNKNOWN_BLOCK_KIND: template % names block kind %, which no '
        'renderer handles', p_code, b ->> 'kind'
        using errcode = '23503';
    end if;
    for f in select jsonb_array_elements_text(coalesce(b -> 'fields', '[]'::jsonb))
    loop
      if not exists (select 1 from erp_ref.output_field o where o.code = f) then
        raise exception
          'ERPWARE_UNKNOWN_OUTPUT_FIELD: template % binds field %, which is not '
          'in erp_ref.output_field', p_code, f
          using errcode = '23503';
      end if;
    end loop;
  end loop;

  insert into erp.output_template
    (tenant_id, code, name_key, kind, base_type_code, page, blocks)
  values (v_tenant, p_code, p_name_key, p_kind, p_base_type_code,
          coalesce(p_page, 'A4'), coalesce(p_blocks, '[]'::jsonb))
  on conflict (tenant_id, code) do update set
    name_key = excluded.name_key, kind = excluded.kind,
    base_type_code = excluded.base_type_code, page = excluded.page,
    blocks = excluded.blocks, status = 'active', updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.upsert_output_template is
  'The promoter''s writer for erp.output_template. Refuses a block kind no '
  'renderer handles and a field nothing resolves, because the alternative is '
  'discovering it on a delivery note that has already been posted.';

-- -----------------------------------------------------------------------------
-- The renderer, which resolves rather than draws
-- -----------------------------------------------------------------------------

create or replace function erp.render_output_template(
  p_code        text,
  p_document_id uuid default null,
  p_locale      text default 'en')
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  t          erp.output_template%rowtype;
  d          erp.document%rowtype;
  v_res      jsonb;
  v_blocks   jsonb := '[]'::jsonb;
  b          jsonb;
  v_fields   jsonb;
  v_lines    jsonb;
  v_totals   jsonb;
  f          text;
begin
  select * into t from erp.output_template
   where tenant_id = v_tenant and code = p_code and status = 'active';
  if not found then
    raise exception 'ERPWARE_UNKNOWN_OUTPUT_TEMPLATE: %', p_code using errcode = '23503';
  end if;

  if t.kind = 'document' then
    if p_document_id is null then
      raise exception
        'ERPWARE_DOCUMENT_REQUIRED: template % renders a document and none was '
        'given', p_code using errcode = '23514';
    end if;
    select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
    if not found then
      raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
    end if;
  end if;

  -- Every label the template names, already in the caller's locale and already
  -- through this organisation's overrides. This is the whole of §9.3's
  -- "tenant-brandable through the resource and branding layer": the renderer
  -- never sees a word the organisation could not have changed.
  v_res := public.erp_resources(p_locale);

  -- The totals, once, whether or not a block asks for them. Cheap, and it
  -- keeps the block loop from having to know how to add up.
  select jsonb_build_object(
           'total_net',   coalesce(sum(l.net_minor), 0),
           'total_tax',   coalesce(sum(l.tax_minor), 0),
           'total_gross', coalesce(sum(l.net_minor), 0) + coalesce(sum(l.tax_minor), 0),
           'line_count',  count(*))
    into v_totals
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id
     and not l.is_cancelled;

  for b in select * from jsonb_array_elements(t.blocks)
  loop
    v_fields := '[]'::jsonb;
    v_lines  := null;

    if (b ->> 'kind') = 'lines' and p_document_id is not null then
      -- One object per line, carrying only the fields the block asked for.
      select coalesce(jsonb_agg(row_obj order by line_no), '[]'::jsonb)
        into v_lines
        from (
          select l.line_no,
                 (select jsonb_object_agg(fld.code, case fld.code
                    when 'line_no'            then to_jsonb(l.line_no)
                    when 'item_code'          then to_jsonb(i.code)
                    when 'description'        then to_jsonb(l.description)
                    when 'quantity'           then to_jsonb(l.quantity)
                    when 'uom'                then to_jsonb(u.code)
                    when 'unit_price'         then to_jsonb(l.unit_price_minor)
                    when 'net_amount'         then to_jsonb(l.net_minor)
                    when 'tax_amount'         then to_jsonb(l.tax_minor)
                    when 'batch'              then to_jsonb(bt.batch_number)
                    when 'location'           then to_jsonb(loc.code)
                    when 'quantity_fulfilled' then to_jsonb(l.quantity_fulfilled)
                    else 'null'::jsonb end)
                    from jsonb_array_elements_text(coalesce(b -> 'fields', '[]'::jsonb)) as x(code)
                    join erp_ref.output_field fld on fld.code = x.code
                   where fld.is_line) as row_obj
            from erp.document_line l
            left join erp.item i     on i.id = l.item_id
            left join erp.uom u      on u.id = l.uom_id
            left join erp.batch bt   on bt.id = l.batch_id
            left join erp.location loc on loc.id = l.location_id
           where l.tenant_id = v_tenant and l.document_id = p_document_id
             and not l.is_cancelled
        ) s;
    else
      -- A once-only block: label and value, both resolved.
      for f in select jsonb_array_elements_text(coalesce(b -> 'fields', '[]'::jsonb))
      loop
        v_fields := v_fields || jsonb_build_array(jsonb_build_object(
          'field', f,
          'label', coalesce(
            v_res -> (select o.label_key from erp_ref.output_field o where o.code = f),
            to_jsonb(f)),
          'value', case f
            when 'document_number' then to_jsonb(d.document_number)
            when 'document_date'   then to_jsonb(d.document_date)
            when 'required_date'   then to_jsonb(d.required_date)
            when 'due_date'        then to_jsonb(d.due_date)
            when 'our_reference'   then to_jsonb(d.our_reference)
            when 'their_reference' then to_jsonb(d.their_reference)
            when 'currency'        then to_jsonb(d.currency)
            when 'notes'           then to_jsonb(d.notes)
            when 'party_name'      then (select to_jsonb(pt.name) from erp.party pt
                                          where pt.id = d.party_id)
            when 'party_address'   then coalesce(d.address_snapshot, 'null'::jsonb)
            when 'entity_name'     then (select to_jsonb(e.name) from erp.entity e
                                          where e.id = d.entity_id)
            when 'entity_country'  then (select to_jsonb(e.country_code) from erp.entity e
                                          where e.id = d.entity_id)
            when 'brand_name'      then (select to_jsonb(tn.name) from erp.tenant tn
                                          where tn.id = v_tenant)
            when 'total_net'       then v_totals -> 'total_net'
            when 'total_tax'       then v_totals -> 'total_tax'
            when 'total_gross'     then v_totals -> 'total_gross'
            when 'line_count'      then v_totals -> 'line_count'
            else 'null'::jsonb end));
      end loop;
    end if;

    v_blocks := v_blocks || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'kind',  b ->> 'kind',
      'label', case when b ? 'label_key'
                    then coalesce(v_res -> (b ->> 'label_key'), to_jsonb(b ->> 'label_key'))
                    end,
      'fields', case when v_lines is null then v_fields end,
      'rows',   v_lines,
      -- What each column is called, once, rather than repeated on every row.
      'columns', case when v_lines is not null then (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'field', x.code,
                 'label', coalesce(v_res -> fld.label_key, to_jsonb(x.code)))), '[]'::jsonb)
          from jsonb_array_elements_text(coalesce(b -> 'fields', '[]'::jsonb)) as x(code)
          join erp_ref.output_field fld on fld.code = x.code
         where fld.is_line) end)));
  end loop;

  return jsonb_build_object(
    'template', t.code,
    'title', coalesce(v_res -> t.name_key, to_jsonb(t.name_key)),
    'kind', t.kind,
    'page', t.page,
    'locale', p_locale,
    'document_id', p_document_id,
    'blocks', v_blocks);
end;
$$;

comment on function erp.render_output_template is
  'Resolves a §9.3 layout against a document: every label already in the '
  'caller''s locale and through this organisation''s overrides, every value '
  'already read. It deliberately stops there — turning this into a PDF or a '
  'label stream is the client''s job, because a page is pixels and pixels are '
  'not configuration.';

-- -----------------------------------------------------------------------------
-- The change-set kind, and the manifest that carries it between environments
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    -- Spec 5.7: "declarative posting rules from operational events". Declarative
    -- means configuration, and configuration in this product is promoted rather
    -- than edited — otherwise the rule that decides which account a receipt
    -- lands in would be the one thing in finance nobody had to get approved.
    --
    -- Rules are versioned in place: a new version supersedes the last rather
    -- than replacing it, because a journal line records the rule version that
    -- produced it and that reference must stay resolvable for ever.
    when 'posting_rule' then
      if i.operation = 'remove' then
        update erp.posting_rule pr set status = 'withdrawn', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';
      else
        select coalesce(max(pr.version), 0) + 1 into v_vnum
          from erp.posting_rule pr
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');

        -- Supersede the version in force, and only move its end date if it
        -- actually started earlier.
        --
        -- This is the defect 0019 found in every other activation path,
        -- arriving here through a door that did not exist when 0019 was
        -- written. Setting effective_to = v_from on a version that started on
        -- the same day produces an empty window, which posting_rule_range
        -- refuses. Invisible in normal use, because changes are made on later
        -- days than the versions they replace — and immediate the moment two
        -- change sets touch the same rule in one sitting, which is exactly
        -- what installing finance and then inventory does.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = case when pr.effective_from < v_from then v_from
                                   else pr.effective_to end,
               updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';

        insert into erp.posting_rule (
          tenant_id, code, name, entity_id, ledger_id, event_type, condition,
          posting_lines, version, status, effective_from, legislation_pack_code)
        values (
          v_tenant, p ->> 'code', p ->> 'name', v_entity,
          (select l.id from erp.ledger l
            where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')
              and (v_entity is null or l.entity_id = v_entity)
            order by l.code limit 1),
          p ->> 'event_type',
          coalesce(p -> 'condition', 'true'::jsonb),
          coalesce(p -> 'posting_lines', '[]'::jsonb),
          v_vnum, 'active', v_from, p ->> 'legislation_pack');

        -- A rule that does not balance would raise a journal that cannot post,
        -- and it would do so at month end rather than here. Refusing at
        -- promotion is the whole point of promoting it.
        perform erp.assert_posting_rule_balances(p ->> 'code', v_vnum);
      end if;

    -- Spec 5.1: what a good record looks like is a tenant's opinion, and an
    -- opinion that decides whether a record is fit to trade on belongs in the
    -- same promotion pipeline as everything else. Replaced rather than
    -- versioned: nothing records "the quality rule version that scored this",
    -- so a superseded version would be a row nobody could ever read.
    when 'data_quality_rule' then
      if i.operation = 'remove' then
        update erp.data_quality_rule q set status = 'inactive', updated_at = now()
         where q.tenant_id = v_tenant
           and q.object_type = (p ->> 'object_type')
           and q.code = (p ->> 'code');
      else
        insert into erp.data_quality_rule (
          tenant_id, object_type, code, name, kind, condition, weight,
          severity, message, entity_id, status)
        values (v_tenant, p ->> 'object_type', p ->> 'code', p ->> 'name',
                coalesce(p ->> 'kind', 'completeness'),
                coalesce(p -> 'condition', 'true'::jsonb),
                coalesce((p ->> 'weight')::integer, 1),
                coalesce(p ->> 'severity', 'warning'),
                coalesce(p ->> 'message', p ->> 'name'),
                v_entity, 'active')
        on conflict (tenant_id, object_type, code) do update
          set name = excluded.name, kind = excluded.kind,
              condition = excluded.condition, weight = excluded.weight,
              severity = excluded.severity, message = excluded.message,
              status = 'active', updated_at = now();
      end if;

    -- Which fields cannot change without somebody agreeing. Promoted for the
    -- same reason the approval chains themselves are: a control that its own
    -- subject can switch off is not a control.
    when 'field_approval_rule' then
      if i.operation = 'remove' then
        update erp.field_approval_rule f set status = 'inactive', updated_at = now()
         where f.tenant_id = v_tenant
           and f.object_type = (p ->> 'object_type')
           and f.field_name = (p ->> 'field_name');
      else
        if not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = (p ->> 'object_type')
                          and m.column_name = (p ->> 'field_name')) then
          raise exception
            'ERPWARE_PROMOTION_UNGOVERNABLE_FIELD: %.% is not a maintainable field',
            p ->> 'object_type', p ->> 'field_name'
            using errcode = '23503',
                  hint = 'A rule guarding a field nothing can change is a control '
                         'that will never fire.';
        end if;

        insert into erp.field_approval_rule (
          tenant_id, object_type, field_name, condition, approval_chain_code,
          sensitivity, reason_required, status)
        values (v_tenant, p ->> 'object_type', p ->> 'field_name',
                coalesce(p -> 'condition', 'true'::jsonb),
                p ->> 'approval_chain',
                coalesce((p ->> 'sensitivity')::integer, 100),
                coalesce((p ->> 'reason_required')::boolean, false),
                'active')
        on conflict (tenant_id, object_type, field_name) do update
          set condition = excluded.condition,
              approval_chain_code = excluded.approval_chain_code,
              sensitivity = excluded.sensitivity,
              reason_required = excluded.reason_required,
              status = 'active', updated_at = now();
      end if;

    -- Which stock is valued how. Promoted rather than written, because
    -- switching an item from FIFO to average changes what every future issue
    -- costs and therefore what the accounts say.
    when 'costing_policy' then
      if i.operation = 'remove' then
        update erp.costing_policy c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.costing_policy (
          tenant_id, code, name, method, item_class, entity_id, site_id,
          variance_account_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                (p ->> 'method')::erp.costing_method,
                p ->> 'item_class', v_entity, v_site,
                p ->> 'variance_account', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, method = excluded.method,
              item_class = excluded.item_class,
              variance_account_code = excluded.variance_account_code,
              status = 'active', updated_at = now();
      end if;

    -- What gets counted, how often, and how wrong a count may be before
    -- somebody has to look at it. A tolerance a warehouse can set for itself
    -- is not a tolerance.
    when 'count_programme' then
      if i.operation = 'remove' then
        update erp.count_programme c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.count_programme (
          tenant_id, code, name, site_id, kind, selector,
          tolerance_absolute, tolerance_pct, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_site,
                (p ->> 'kind')::erp.count_programme_kind,
                coalesce(p -> 'selector', 'true'::jsonb),
                coalesce((p ->> 'tolerance_absolute')::numeric, 0),
                coalesce((p ->> 'tolerance_pct')::numeric, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, kind = excluded.kind,
              selector = excluded.selector,
              tolerance_absolute = excluded.tolerance_absolute,
              tolerance_pct = excluded.tolerance_pct,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much more than was ordered may arrive, and what to do with it.
    when 'receipt_tolerance' then
      if i.operation = 'remove' then
        update erp.receipt_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.receipt_tolerance (
          tenant_id, code, name, item_class, over_pct, under_pct, over_action, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'over_pct')::numeric, 0),
                coalesce((p ->> 'under_pct')::numeric, 100),
                coalesce(p ->> 'over_action', 'accept'), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              over_pct = excluded.over_pct, under_pct = excluded.under_pct,
              over_action = excluded.over_action,
              status = 'active', updated_at = now();
      end if;

    -- How far an invoice may differ from the receipt before somebody looks.
    -- The most contested numbers in a finance function, and therefore exactly
    -- the ones that should be promoted rather than typed.
    when 'match_tolerance' then
      if i.operation = 'remove' then
        update erp.match_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.match_tolerance (
          tenant_id, code, name, item_class, quantity_pct, price_pct,
          price_absolute_minor, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'quantity_pct')::numeric, 0),
                coalesce((p ->> 'price_pct')::numeric, 0),
                coalesce((p ->> 'price_absolute_minor')::bigint, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              quantity_pct = excluded.quantity_pct, price_pct = excluded.price_pct,
              price_absolute_minor = excluded.price_absolute_minor,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What may be spent, and what happens when it would be exceeded.
    when 'budget' then
      if i.operation = 'remove' then
        update erp.budget b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.code = (p ->> 'code');
      else
        insert into erp.budget (
          tenant_id, entity_id, code, name, fiscal_year, selector, amount_minor,
          currency, on_exceed, approval_chain_code, status)
        select v_tenant,
               coalesce(v_entity, (select e.id from erp.entity e
                                    where e.tenant_id = v_tenant and e.status = 'active'
                                    order by e.code limit 1)),
               p ->> 'code', p ->> 'name',
               coalesce((p ->> 'fiscal_year')::integer,
                        extract(year from v_from)::integer),
               coalesce(p -> 'selector', 'true'::jsonb),
               (p ->> 'amount_minor')::bigint,
               coalesce(p ->> 'currency',
                        (select e.base_currency from erp.entity e
                          where e.tenant_id = v_tenant limit 1)),
               coalesce(p ->> 'on_exceed', 'block'),
               p ->> 'approval_chain', 'active'
        on conflict (tenant_id, code, fiscal_year) do update
          set name = excluded.name, selector = excluded.selector,
              amount_minor = excluded.amount_minor,
              on_exceed = excluded.on_exceed,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much risk of running out is acceptable, how far ahead the plan is
    -- fixed, and how orders are sized. Every one of those is a number a
    -- business argues about for a fortnight and then nobody revisits, which is
    -- precisely what promotion is for.
    when 'planning_policy' then
      if i.operation = 'remove' then
        update erp.planning_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.planning_policy (
          tenant_id, code, name, reorder_method, safety_stock_basis,
          service_level_pct, lot_sizing, fixed_lot_size, rounding_multiple,
          demand_time_fence_days, planning_time_fence_days, sourcing_rules, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'reorder_method')::erp.reorder_method, 'reorder_point'),
                coalesce(p ->> 'safety_stock_basis', 'statistical'),
                coalesce((p ->> 'service_level_pct')::numeric, 95),
                coalesce(p ->> 'lot_sizing', 'lot_for_lot'),
                (p ->> 'fixed_lot_size')::numeric,
                (p ->> 'rounding_multiple')::numeric,
                coalesce((p ->> 'demand_time_fence_days')::integer, 0),
                coalesce((p ->> 'planning_time_fence_days')::integer, 0),
                coalesce(p -> 'sourcing_rules', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, reorder_method = excluded.reorder_method,
              safety_stock_basis = excluded.safety_stock_basis,
              service_level_pct = excluded.service_level_pct,
              lot_sizing = excluded.lot_sizing,
              fixed_lot_size = excluded.fixed_lot_size,
              rounding_multiple = excluded.rounding_multiple,
              demand_time_fence_days = excluded.demand_time_fence_days,
              planning_time_fence_days = excluded.planning_time_fence_days,
              sourcing_rules = excluded.sourcing_rules,
              status = 'active', updated_at = now();
      end if;

    -- The margin floor, and whether anybody may go under it. Promoted because
    -- it is the number a sales force will ask to have moved.
    when 'pricing_policy' then
      if i.operation = 'remove' then
        update erp.pricing_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.pricing_policy (
          tenant_id, code, name, entity_id, min_margin_pct, allow_below_cost,
          approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_entity,
                coalesce((p ->> 'min_margin_pct')::numeric, 0),
                coalesce((p ->> 'allow_below_cost')::boolean, false),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name,
              min_margin_pct = excluded.min_margin_pct,
              allow_below_cost = excluded.allow_below_cost,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What is inspected and how much of it. Promoted because a sampling rule
    -- is exactly the sort of thing that gets loosened quietly under delivery
    -- pressure and should have to be argued for.
    when 'inspection_plan' then
      if i.operation = 'remove' then
        update erp.inspection_plan ip set status = 'inactive', updated_at = now()
         where ip.tenant_id = v_tenant and ip.code = (p ->> 'code');
      else
        insert into erp.inspection_plan (
          tenant_id, code, name, item_class, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce(p ->> 'trigger_point', 'receipt'),
                coalesce(p -> 'sampling_rule', '{}'::jsonb),
                coalesce(p -> 'characteristics', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              trigger_point = excluded.trigger_point,
              sampling_rule = excluded.sampling_rule,
              characteristics = excluded.characteristics,
              status = 'active', updated_at = now();
      end if;

    -- Which carriers may be used and what they charge. A tariff that anybody
    -- can edit is one where the cheapest carrier is whoever last touched it.
    when 'carrier' then
      if i.operation = 'remove' then
        update erp.carrier c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.carrier (tenant_id, code, name, services, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'services', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
      end if;

    -- What has to be true before a period closes. Promoted, because a close
    -- checklist that the people being checked can shorten is not a control.
    when 'close_task' then
      if i.operation = 'remove' then
        update erp.close_task_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = (p ->> 'code');
      else
        insert into erp.close_task_template (
          tenant_id, code, name, seq, depends_on, blocking_check,
          owner_role_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'seq')::integer, 100),
                coalesce((select array_agg(d #>> '{}')
                            from jsonb_array_elements(coalesce(p -> 'depends_on',
                                                               '[]'::jsonb)) d),
                         '{}'::text[]),
                p ->> 'blocking_check', p ->> 'owner_role', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, seq = excluded.seq,
              depends_on = excluded.depends_on,
              blocking_check = excluded.blocking_check,
              owner_role_code = excluded.owner_role_code,
              status = 'active', updated_at = now();
      end if;

    -- When a customer is chased and when they stop being sold to. The second
    -- is a commercial decision that finance owns and sales will ask to move,
    -- which is exactly what promotion is for.
    when 'dunning_policy' then
      if i.operation = 'remove' then
        update erp.dunning_policy dp set status = 'inactive', updated_at = now()
         where dp.tenant_id = v_tenant and dp.code = (p ->> 'code');
      else
        insert into erp.dunning_policy (tenant_id, code, name, levels, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'levels', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, levels = excluded.levels,
              status = 'active', updated_at = now();
      end if;


    -- ── Addendum B configuration surfaces ───────────────────────────────────
    --
    -- Each resolves the codes a change set carries to this environment's own
    -- ids, then calls the erp.* mechanism extracted in 20260901120000. None of
    -- them authorises: promotion authorised once, at the change set, which is
    -- what lets a promote-only principal promote somebody else's work.

    when 'department' then
      if i.operation = 'remove' then
        update erp.department d set status = 'inactive', updated_at = now()
         where d.tenant_id = v_tenant and d.code = upper(p ->> 'code');
      else
        perform erp.upsert_department(
          p ->> 'code', p ->> 'name',
          (select u.id from erp.app_user u
            where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'manager_email')),
          (select d2.id from erp.department d2
            where d2.tenant_id = v_tenant and d2.code = upper(p ->> 'parent')),
          p ->> 'default_cost_centre', v_entity, v_from);
      end if;

    when 'approval_band' then
      declare
        v_dept uuid;
      begin
        select d.id into v_dept from erp.department d
         where d.tenant_id = v_tenant and d.code = upper(p ->> 'department');
        if v_dept is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_DEPARTMENT: this environment has no department %',
            p ->> 'department' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.approval_band ab set status = 'inactive', updated_at = now()
           where ab.tenant_id = v_tenant and ab.department_id = v_dept
             and ab.object_type = (p ->> 'object_type')
             and ab.seq = (p ->> 'seq')::integer;
        else
          perform erp.upsert_approval_band(
            v_dept, p ->> 'object_type', (p ->> 'seq')::integer,
            (p ->> 'upper_bound_minor')::bigint,
            coalesce((p ->> 'lower_bound_minor')::bigint, 0),
            (select u.id from erp.app_user u
              where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'approver_email')),
            p ->> 'approver_role',
            coalesce((p ->> 'use_line_manager')::boolean, false),
            coalesce(p ->> 'currency', 'GBP'),
            coalesce((p ->> 'is_parallel')::boolean, false),
            coalesce((p ->> 'rerun_lower_bands')::boolean, true),
            (p ->> 'escalate_after_hours')::integer,
            coalesce(p ->> 'vacancy', 'hold_and_raise'),
            (p ->> 'tolerance_pct')::numeric);
        end if;
      end;

    when 'posting_class' then
      if i.operation = 'remove' then
        update erp.posting_class pc set status = 'inactive', updated_at = now()
         where pc.tenant_id = v_tenant
           and pc.kind = (p ->> 'kind')::erp.posting_class_kind
           and pc.code = (p ->> 'code');
      else
        perform erp.upsert_posting_class(
          p ->> 'kind', p ->> 'code', p ->> 'name', p ->> 'description', v_from);
      end if;

    -- The one that decides which ledger account a posting hits. §5 refuses a
    -- default-to-suspense, so an unresolved account is an exception rather
    -- than a quiet landing place — which is exactly why this belongs behind
    -- promotion rather than a direct write on a live organisation.
    when 'account_determination' then
      declare
        v_account uuid;
      begin
        select a.id into v_account from erp.account a
         where a.tenant_id = v_tenant and a.code = (p ->> 'account');
        if v_account is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_ACCOUNT: this environment has no account %',
            p ->> 'account' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.account_determination ad set status = 'inactive', updated_at = now()
           where ad.tenant_id = v_tenant
             and ad.transaction_type = (p ->> 'transaction_type')
             and ad.account_id = v_account;
        else
          perform erp.upsert_account_determination(
            p ->> 'transaction_type', v_account,
            (select pc.id from erp.posting_class pc
              where pc.tenant_id = v_tenant and pc.kind = 'item'
                and pc.code = (p ->> 'item_class')),
            (select pc.id from erp.posting_class pc
              where pc.tenant_id = v_tenant and pc.kind = 'party'
                and pc.code = (p ->> 'party_class')),
            v_site, v_entity,
            (select l.id from erp.ledger l
              where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')),
            p ->> 'reason_code', p ->> 'legislation_pack',
            p -> 'dimensions', p ->> 'note', v_from);
        end if;
      end;

    when 'classification_axis' then
      if i.operation = 'remove' then
        update erp.classification_axis ca set status = 'inactive', updated_at = now()
         where ca.tenant_id = v_tenant and ca.code = upper(p ->> 'code');
      else
        perform erp.upsert_classification_axis(
          p ->> 'code', p ->> 'name',
          coalesce((p ->> 'is_mandatory')::boolean, false),
          p ->> 'item_classes',
          coalesce((p ->> 'seq')::integer, 100),
          p ->> 'name_key');
      end if;

    when 'classification_value' then
      declare
        v_axis uuid;
      begin
        select ca.id into v_axis from erp.classification_axis ca
         where ca.tenant_id = v_tenant and ca.code = upper(p ->> 'axis');
        if v_axis is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_AXIS: this environment has no classification axis %',
            p ->> 'axis' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.classification_value cv set status = 'inactive', updated_at = now()
           where cv.tenant_id = v_tenant and cv.axis_id = v_axis
             and cv.code = upper(p ->> 'code');
        else
          perform erp.upsert_classification_value(
            v_axis, p ->> 'code', p ->> 'name', p ->> 'abbreviation',
            (select cv2.id from erp.classification_value cv2
              where cv2.tenant_id = v_tenant and cv2.axis_id = v_axis
                and cv2.code = upper(p ->> 'parent')),
            p ->> 'name_key');
        end if;
      end;

    when 'code_template' then
      if i.operation = 'remove' then
        update erp.code_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = upper(p ->> 'code');
      else
        perform erp.upsert_code_template(
          p ->> 'code', p ->> 'name',
          coalesce(p -> 'segments', '[]'::jsonb),
          p ->> 'item_classes',
          coalesce(p ->> 'casing', 'upper'),
          v_entity);
      end if;

    when 'release_area' then
      declare
        v_ra_site uuid;
      begin
        v_ra_site := coalesce(v_site,
          (select s2.id from erp.site s2
            where s2.tenant_id = v_tenant and s2.status = 'active'
            order by s2.code limit 1));
        if v_ra_site is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SITE: a release area needs a site and this '
            'environment has none' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.release_area ra set status = 'inactive', updated_at = now()
           where ra.tenant_id = v_tenant and ra.site_id = v_ra_site
             and ra.code = upper(p ->> 'code');
        else
          perform erp.upsert_release_area(
            v_ra_site, p ->> 'code', p ->> 'name',
            (select l.id from erp.location l
              where l.tenant_id = v_tenant and l.site_id = v_ra_site
                and l.code = (p ->> 'location')),
            coalesce(p ->> 'replenishment_mode', 'pull'),
            p ->> 'channel', p ->> 'order_type', p ->> 'item_classes',
            (p ->> 'min_quantity')::numeric,
            (p ->> 'max_quantity')::numeric,
            coalesce((p ->> 'ageing_hours')::integer, 72),
            coalesce((p ->> 'gate_printing')::boolean, true));
        end if;
      end;

    -- approver_assignment carries a named approver rather than a band, and
    -- both subject and approver are people. Promoting a rule that names a
    -- person only works where that person exists in the target, so the
    -- subject and approver are carried by email and resolved here.
    when 'approver_assignment' then
      declare
        v_subject  uuid;
        v_approver uuid;
      begin
        select u.id into v_approver from erp.app_user u
         where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'approver_email');
        if v_approver is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_APPROVER: this environment has no principal %',
            p ->> 'approver_email' using errcode = '23503';
        end if;

        v_subject := case (p ->> 'subject_kind')
          when 'department' then (select d.id from erp.department d
                                   where d.tenant_id = v_tenant
                                     and d.code = upper(p ->> 'subject'))
          else (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'subject'))
        end;
        if v_subject is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SUBJECT: this environment has no % %',
            p ->> 'subject_kind', p ->> 'subject' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.approver_assignment aa set status = 'inactive', updated_at = now()
           where aa.tenant_id = v_tenant and aa.subject_id = v_subject
             and aa.object_type = (p ->> 'object_type')
             and aa.approver_user_id = v_approver;
        else
          perform erp.assign_named_approver(
            p ->> 'subject_kind', v_subject, p ->> 'object_type', v_approver,
            coalesce(p ->> 'mode', 'prepends'),
            (p ->> 'lower_bound_minor')::bigint,
            (p ->> 'upper_bound_minor')::bigint,
            p ->> 'reason', v_from, (p ->> 'valid_to')::date);
        end if;
      end;

    -- ── Starter Content Packs: eleven kinds a pack installs ─────────────────

    -- §2.1: "switched through a change set like any other configuration".
    when 'capability' then
      if i.operation = 'remove' then
        perform erp.set_capability(p ->> 'code', false,
          coalesce(p ->> 'reason', 'Removed by change set'), v_from);
      else
        perform erp.set_capability(p ->> 'code',
          coalesce((p ->> 'enabled')::boolean, true),
          coalesce(p ->> 'reason', 'Promoted by change set'), v_from);
      end if;

    when 'uom' then
      if i.operation = 'remove' then
        update erp.uom u set status = 'inactive', updated_at = now()
         where u.tenant_id = v_tenant and u.code = upper(p ->> 'code');
      else
        perform erp.upsert_uom(
          p ->> 'code', p ->> 'name',
          coalesce(p ->> 'uom_class', 'quantity')::erp.uom_class,
          coalesce((p ->> 'decimals')::smallint, 0::smallint),
          coalesce((p ->> 'is_base')::boolean, false));
        if p ? 'converts_to' then
          perform erp.upsert_uom_conversion(
            p ->> 'code', p ->> 'converts_to', (p ->> 'factor')::numeric,
            p ->> 'item');
        end if;
      end if;

    when 'reason_code' then
      if i.operation = 'remove' then
        perform erp.set_reason_code_status(p ->> 'category', p ->> 'code', false);
      else
        perform erp.upsert_reason_code(
          p ->> 'category', p ->> 'code', p ->> 'name',
          coalesce((p ->> 'requires_note')::boolean, false),
          coalesce((p ->> 'requires_approval')::boolean, false),
          coalesce((p ->> 'seq')::integer, 100));
      end if;

    when 'calendar' then
      if i.operation = 'remove' then
        update erp.calendar c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = upper(p ->> 'code');
      else
        perform erp.upsert_calendar(
          p ->> 'code', p ->> 'name', coalesce(p ->> 'timezone', 'UTC'),
          coalesce((select array_agg(x::boolean order by ord)
                      from jsonb_array_elements_text(p -> 'working_days')
                             with ordinality y(x, ord)),
                   '{t,t,t,t,t,f,f}'::boolean[]));
        -- Exceptions travel with the calendar rather than as their own kind: a
        -- public holiday without the calendar it falls in is not a thing.
        if p ? 'exceptions' then
          for r in select value from jsonb_array_elements(p -> 'exceptions') loop
            perform erp.upsert_calendar_exception(
              p ->> 'code', (r.value ->> 'date')::date,
              coalesce((r.value ->> 'is_working')::boolean, false),
              r.value ->> 'description');
          end loop;
        end if;
      end if;

    when 'sod_rule' then
      if i.operation = 'remove' then
        update erp.sod_rule sr set status = 'inactive', updated_at = now()
         where sr.tenant_id = v_tenant and sr.code = upper(p ->> 'code');
      else
        perform erp.upsert_sod_rule(
          p ->> 'code', p ->> 'name',
          string_to_array(p ->> 'permissions_a', ','),
          string_to_array(p ->> 'permissions_b', ','),
          coalesce(p ->> 'severity', 'material')::erp.sod_severity,
          p ->> 'description', p ->> 'mitigation');
      end if;

    when 'numbering_rule' then
      if i.operation = 'remove' then
        update erp.numbering_rule nr set status = 'inactive', updated_at = now()
         where nr.tenant_id = v_tenant and nr.code = (p ->> 'code');
      else
        perform erp.upsert_numbering_rule(
          p ->> 'code', p ->> 'prefix', p ->> 'entity', p ->> 'site',
          p ->> 'suffix',
          coalesce((p ->> 'pad_to')::smallint, 6::smallint),
          coalesce(p ->> 'reset_period', 'yearly')::erp.number_reset,
          coalesce((p ->> 'next_value')::bigint, 1));
      end if;

    when 'document_type' then
      -- The other half of the spine. A document type is configuration by every
      -- test the product applies to the word: it names a lifecycle, a chain, a
      -- sequence, a movement type and a posting rule, and changing any of them
      -- changes what happens when somebody presses a button. It was outside
      -- promotion only because the sequence it needs was.
      if i.operation = 'remove' then
        update erp.document_type dt set status = 'inactive', updated_at = now()
         where dt.tenant_id = v_tenant and dt.code = (p ->> 'code');
      else
        perform erp.upsert_document_type(
          p ->> 'code', p ->> 'base_type', p ->> 'name',
          p ->> 'numbering_rule', p ->> 'entity', p ->> 'site',
          p ->> 'state_machine', p ->> 'approval_chain',
          p ->> 'stock_movement_type', p ->> 'posting_rule',
          p ->> 'create_permission');
      end if;

    -- §9.3's layouts. The last of the three template surfaces to become
    -- promotable, and the only one that renders a document rather than a
    -- message.
    when 'output_template' then
      if i.operation = 'remove' then
        update erp.output_template ot set status = 'inactive', updated_at = now()
         where ot.tenant_id = v_tenant and ot.code = (p ->> 'code');
      else
        perform erp.upsert_output_template(
          p ->> 'code', p ->> 'name_key', p ->> 'kind',
          nullif(p ->> 'base_type', ''),
          coalesce(nullif(p ->> 'page', ''), 'A4'),
          coalesce(p -> 'blocks', '[]'::jsonb));
      end if;

    when 'notification_template' then
      if i.operation = 'remove' then
        delete from erp.notification_template nt
         where nt.tenant_id = v_tenant and nt.code = (p ->> 'code');
      else
        perform erp.upsert_notification_template(
          p ->> 'code',
          coalesce(p ->> 'channel_kind', 'in_app')::erp.notification_channel_kind,
          p ->> 'body_key', p ->> 'subject_key');
      end if;

    when 'kpi' then
      if i.operation = 'remove' then
        delete from erp.kpi k where k.tenant_id = v_tenant and k.code = (p ->> 'code');
      else
        perform erp.upsert_kpi(
          p ->> 'code', p ->> 'name', p ->> 'unit',
          coalesce((p ->> 'higher_is_better')::boolean, true),
          p ->> 'description', p ->> 'module_code',
          coalesce((p ->> 'currency_scoped')::boolean, false),
          p ->> 'name_key');
      end if;

    when 'report' then
      if i.operation = 'remove' then
        update erp.report rp set status = 'inactive', updated_at = now()
         where rp.tenant_id = v_tenant and rp.code = (p ->> 'code');
      else
        perform erp.upsert_report(
          p ->> 'code', p ->> 'name', p ->> 'description', p ->> 'module_code',
          coalesce(string_to_array(nullif(p ->> 'kpi_codes', ''), ','), '{}'),
          coalesce(string_to_array(nullif(p ->> 'audience_role_codes', ''), ','), '{}'),
          p ->> 'name_key');
      end if;

    when 'account' then
      if i.operation = 'remove' then
        update erp.account a set status = 'inactive', updated_at = now()
         where a.tenant_id = v_tenant and a.entity_id = v_entity
           and a.code = (p ->> 'code');
      else
        -- A tenant-neutral pack cannot know an organisation's company codes,
        -- so an item that names none lands on the primary company — the same
        -- fallback the budget and release_area branches already use for the
        -- same reason. Refusing instead would make the account kind
        -- unreachable from a pack, which is the one place it is most wanted.
        perform erp.upsert_account(
          coalesce(nullif(p ->> 'entity', ''),
                   (select e.code from erp.entity e
                     where e.tenant_id = v_tenant and e.status = 'active'
                     order by e.code limit 1)),
          p ->> 'code', p ->> 'name',
          (p ->> 'account_type')::erp.account_type,
          nullif(p ->> 'control_kind', '')::erp.control_account_kind,
          p ->> 'group_code',
          coalesce((p ->> 'is_postable')::boolean, true),
          coalesce(string_to_array(nullif(p ->> 'requires_dimensions', ''), ','), '{}'),
          nullif(p ->> 'currency', '')::character(3),
          nullif(p ->> 'parent', ''),
          coalesce((p ->> 'reconciliation_required')::boolean, false),
          coalesce((p ->> 'close_blocking')::boolean, false));
      end if;

    -- §9.1's scheduled jobs. erp.upsert_job() exists and erp.run_due_jobs()
    -- runs them; what was missing was a way for a pack to carry one.
    when 'job' then
      if i.operation = 'remove' then
        update erp.job j set is_enabled = false, updated_at = now()
         where j.tenant_id = v_tenant and j.code = (p ->> 'code');
      else
        perform erp.upsert_job(
          p ->> 'code', p ->> 'name', p ->> 'handler_code',
          coalesce(p ->> 'schedule_kind', 'interval'),
          (p ->> 'interval_seconds')::integer,
          (p ->> 'at_time')::time,
          p ->> 'days_of_week',
          (p ->> 'day_of_month')::integer,
          coalesce(p ->> 'timezone', 'UTC'),
          coalesce(p -> 'parameters', '{}'::jsonb),
          (p ->> 'timeout_seconds')::integer,
          (p ->> 'max_silence_seconds')::integer,
          -- §9.1: "Shipped disabled, enabled per tenant." A pack that switched
          -- on eleven jobs on an organisation's first day would be a pack that
          -- starts doing work nobody asked for.
          coalesce((p ->> 'is_enabled')::boolean, false));
      end if;

    when 'location' then
      declare
        v_loc_site uuid;
      begin
        v_loc_site := coalesce(v_site,
          (select s2.id from erp.site s2
            where s2.tenant_id = v_tenant and s2.status = 'active'
            order by s2.code limit 1));
        if v_loc_site is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SITE: a location needs a site and this environment has none'
            using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.location l set status = 'inactive', updated_at = now()
           where l.tenant_id = v_tenant and l.site_id = v_loc_site
             and l.code = upper(p ->> 'code');
        else
          perform erp.upsert_location(
            (select s3.code from erp.site s3 where s3.id = v_loc_site),
            p ->> 'code', p ->> 'name', p ->> 'location_type',
            nullif(p ->> 'parent', ''), nullif(p ->> 'count_class', ''),
            (p ->> 'is_pickable')::boolean,
            case when p ? 'storage_conditions' then p -> 'storage_conditions' end);
        end if;
      end;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier, close_task, dunning_policy, department, approval_band, approver_assignment, posting_class, account_determination, classification_axis, classification_value, code_template, release_area, capability, uom, reason_code, calendar, sod_rule, numbering_rule, notification_template, kpi, report, account, location, job';
  end case;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configuration_manifest(p_kinds text[] DEFAULT NULL::text[])
 RETURNS TABLE(object_kind text, object_key text, content jsonb, content_hash text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with t as (select erp.require_tenant_id() as tenant_id),
  entries as (
    select 'config'::text as object_kind,
           co.config_type_code || '|' || coalesce(co.code, '') || '|' ||
             coalesce(e.code, '-') || '|' || coalesce(s.code, '-') as object_key,
           jsonb_build_object(
             'config_type', co.config_type_code,
             'code', co.code,
             'entity', e.code,
             'site', s.code,
             'value', cv.value,
             'effective_from', cv.effective_from,
             'effective_to', cv.effective_to,
             'version', cv.version) as content
      from t
      join erp.config_object co on co.tenant_id = t.tenant_id and co.status = 'active'
      join erp.config_version cv
        on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id
       and cv.status = 'active'
       -- In force today, not merely once in force.
       and daterange(cv.effective_from, cv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = co.entity_id
      left join erp.site s   on s.id = co.site_id

    union all

    select 'rule_set',
           rs.decision_point_code || '|' || rs.code,
           jsonb_build_object(
             'decision_point', rs.decision_point_code,
             'code', rs.code,
             'name', rs.name,
             'entity', e.code,
             'site', s.code,
             'version', rsv.version,
             'effective_from', rsv.effective_from,
             'effective_to', rsv.effective_to,
             'rules', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'seq', r.seq, 'code', r.code, 'name', r.name,
                        'condition', r.condition, 'outcome', r.outcome,
                        'stop_on_match', r.stop_on_match, 'is_active', r.is_active)
                      order by r.seq)
                 from erp.rule r
                where r.tenant_id = rsv.tenant_id
                  and r.rule_set_version_id = rsv.id), '[]'::jsonb))
      from t
      join erp.rule_set rs on rs.tenant_id = t.tenant_id and rs.status = 'active'
      join erp.rule_set_version rsv
        on rsv.tenant_id = rs.tenant_id and rsv.rule_set_id = rs.id
       and rsv.status = 'active'
       and daterange(rsv.effective_from, rsv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = rs.entity_id
      left join erp.site s   on s.id = rs.site_id

    union all

    select 'state_machine',
           sm.code,
           jsonb_build_object(
             'code', sm.code,
             'object_type', sm.object_type,
             'name', sm.name,
             'entity', e.code,
             'site', s.code,
             'version', smv.version,
             'effective_from', smv.effective_from,
             'states', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'code', st.code, 'name', st.name,
                        'is_initial', st.is_initial, 'is_terminal', st.is_terminal,
                        'is_committed', st.is_committed, 'sort_order', st.sort_order,
                        'on_enter', st.on_enter, 'on_exit', st.on_exit)
                      order by st.code)
                 from erp.state st
                where st.tenant_id = smv.tenant_id
                  and st.state_machine_version_id = smv.id), '[]'::jsonb),
             'transitions', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'code', tr.code, 'name', tr.name,
                        'from', fs.code, 'to', ts.code,
                        'guard', tr.guard, 'effects', tr.effects,
                        'required_permission', tr.required_permission,
                        'is_automatic', tr.is_automatic, 'sort_order', tr.sort_order)
                      order by tr.code)
                 from erp.transition tr
                 join erp.state fs on fs.id = tr.from_state_id
                 join erp.state ts on ts.id = tr.to_state_id
                where tr.tenant_id = smv.tenant_id
                  and tr.state_machine_version_id = smv.id), '[]'::jsonb))
      from t
      join erp.state_machine sm on sm.tenant_id = t.tenant_id and sm.status = 'active'
      join erp.state_machine_version smv
        on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id
       and smv.status = 'active'
       and daterange(smv.effective_from, smv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = sm.entity_id
      left join erp.site s   on s.id = sm.site_id

    union all

    select 'approval_chain',
           ac.code,
           jsonb_build_object(
             'code', ac.code,
             'object_type', ac.object_type,
             'name', ac.name,
             'applies_when', ac.applies_when,
             'priority', ac.priority,
             'entity', e.code,
             'site', s.code,
             'version', acv.version,
             'effective_from', acv.effective_from,
             'material_fields', to_jsonb(acv.material_fields),
             'value_field', acv.value_field,
             'tolerance_pct', acv.tolerance_pct,
             'tolerance_absolute', acv.tolerance_absolute,
             'steps', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'seq', st.seq, 'code', st.code, 'name', st.name,
                        'approver_kind', st.approver_kind,
                        'role', r.code, 'user', u.email,
                        'min_approvals', st.min_approvals,
                        'condition', st.condition,
                        'escalate_after', st.escalate_after,
                        'allow_delegation', st.allow_delegation)
                      order by st.seq, st.code)
                 from erp.approval_step st
                 left join erp.role r on r.id = st.role_id
                 left join erp.app_user u on u.id = st.app_user_id
                where st.tenant_id = acv.tenant_id
                  and st.approval_chain_version_id = acv.id), '[]'::jsonb))
      from t
      join erp.approval_chain ac on ac.tenant_id = t.tenant_id and ac.status = 'active'
      join erp.approval_chain_version acv
        on acv.tenant_id = ac.tenant_id and acv.approval_chain_id = ac.id
       and acv.status = 'active'
       and daterange(acv.effective_from, acv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = ac.entity_id
      left join erp.site s   on s.id = ac.site_id

    union all

    select 'terminology',
           ro.key || '|' || ro.locale || '|' || coalesce(e.code, '-'),
           jsonb_build_object('key', ro.key, 'locale', ro.locale,
                              'value', ro.value, 'entity', e.code)
      from t
      join erp.resource_override ro on ro.tenant_id = t.tenant_id and ro.status = 'active'
      left join erp.entity e on e.id = ro.entity_id

    union all

    select 'legislation_binding',
           e.code || '|' || b.pack_code,
           jsonb_build_object('entity', e.code, 'pack', b.pack_code,
                              'pack_version', b.pack_version,
                              'effective_from', b.effective_from,
                              'effective_to', b.effective_to)
      from t
      join erp.entity_legislation_binding b on b.tenant_id = t.tenant_id and b.status = 'active'
       and daterange(b.effective_from, b.effective_to, '[)') @> current_date
      join erp.entity e on e.id = b.entity_id

    union all

    select 'event_subscription',
           es.consumer_code || '|' || es.event_pattern,
           jsonb_build_object('consumer', es.consumer_code, 'pattern', es.event_pattern,
                              'module', es.module_code, 'max_attempts', es.max_attempts)
      from t
      join erp.event_subscription es on es.tenant_id = t.tenant_id and es.status = 'active'

    union all

    select 'role',
           r.code,
           jsonb_build_object('code', r.code, 'name', r.name, 'name_key', r.name_key,
                              'from_template', r.from_template,
                              'permissions', coalesce((
                                select jsonb_agg(jsonb_build_object(
                                         'permission', rp.permission_code,
                                         'data_classes', to_jsonb(rp.data_classes))
                                       order by rp.permission_code)
                                  from erp.role_permission rp
                                 where rp.tenant_id = r.tenant_id and rp.role_id = r.id), '[]'::jsonb))
      from t
      join erp.role r on r.tenant_id = t.tenant_id and r.status = 'active'

    -- ── Addendum B configuration surfaces ───────────────────────────────────
    --
    -- Nine surfaces the manifest never described, which is why they could be
    -- authored into a change set but never captured out of one. Every block
    -- emits the same keys the matching erp.apply_change_set_item branch reads,
    -- and names nothing by id: a manifest that carried local ids would promote
    -- into one environment and nowhere else.

    union all

    select 'department',
           d.code,
           jsonb_build_object(
             'code', d.code,
             'name', d.name,
             'entity', e.code,
             'manager_email', mu.email,
             'parent', pd.code,
             'default_cost_centre', d.default_cost_centre,
             'effective_from', d.valid_from)
      from t
      join erp.department d on d.tenant_id = t.tenant_id and d.status = 'active'
       and daterange(d.valid_from, d.valid_to, '[)') @> current_date
      left join erp.entity e      on e.id = d.entity_id
      left join erp.app_user mu   on mu.id = d.manager_user_id
      left join erp.department pd on pd.id = d.parent_department_id

    union all

    select 'approval_band',
           d.code || '|' || ab.object_type || '|' || ab.seq,
           jsonb_build_object(
             'department', d.code,
             'object_type', ab.object_type,
             'seq', ab.seq,
             'lower_bound_minor', ab.lower_bound_minor,
             'upper_bound_minor', ab.upper_bound_minor,
             'currency', btrim(ab.currency),
             'is_parallel', ab.is_parallel,
             'rerun_lower_bands', ab.rerun_lower_bands,
             'escalate_after_hours',
               (extract(epoch from ab.escalate_after) / 3600)::integer,
             'vacancy', ab.vacancy::text,
             'tolerance_pct', ab.tolerance_pct,
             'effective_from', ab.valid_from,
             -- The band stores a resolution ladder; the door that built it took
             -- three arguments. Emit the arguments, not the ladder, so a
             -- captured band promotes through the same door it came from.
             'approver_email', (
               select u.email
                 from jsonb_array_elements(ab.resolution) r
                 join erp.app_user u
                   on u.tenant_id = ab.tenant_id
                  and u.id = (r.value ->> 'user_id')::uuid
                where r.value ->> 'kind' = 'user' limit 1),
             'approver_role', (
               select r.value ->> 'role_code'
                 from jsonb_array_elements(ab.resolution) r
                where r.value ->> 'kind' = 'role_in_department' limit 1),
             'use_line_manager', exists (
               select 1 from jsonb_array_elements(ab.resolution) r
                where r.value ->> 'kind' = 'line_manager'))
      from t
      join erp.approval_band ab on ab.tenant_id = t.tenant_id and ab.status = 'active'
       and daterange(ab.valid_from, ab.valid_to, '[)') @> current_date
      join erp.department d on d.id = ab.department_id

    union all

    select 'approver_assignment',
           aa.subject_kind::text || '|' ||
             coalesce(sd.code, sr.code, su.email, '?') || '|' ||
             aa.object_type || '|' || au.email,
           jsonb_build_object(
             'subject_kind', aa.subject_kind::text,
             'subject', coalesce(sd.code, sr.code, su.email),
             'object_type', aa.object_type,
             'approver_email', au.email,
             'mode', aa.mode::text,
             'lower_bound_minor', aa.lower_bound_minor,
             'upper_bound_minor', aa.upper_bound_minor,
             'reason', aa.reason,
             'effective_from', aa.valid_from,
             'valid_to', aa.valid_to)
      from t
      join erp.approver_assignment aa
        on aa.tenant_id = t.tenant_id and aa.status = 'active'
       and daterange(aa.valid_from, aa.valid_to, '[)') @> current_date
      join erp.app_user au on au.id = aa.approver_user_id
      left join erp.department sd
        on aa.subject_kind = 'department' and sd.id = aa.subject_id
      left join erp.role sr
        on aa.subject_kind = 'role' and sr.id = aa.subject_id
      left join erp.app_user su
        on aa.subject_kind = 'principal' and su.id = aa.subject_id

    union all

    select 'posting_class',
           pc.kind::text || '|' || pc.code,
           jsonb_build_object(
             'kind', pc.kind::text,
             'code', pc.code,
             'name', pc.name,
             'description', pc.description,
             'effective_from', pc.valid_from)
      from t
      join erp.posting_class pc on pc.tenant_id = t.tenant_id and pc.status = 'active'
       and daterange(pc.valid_from, pc.valid_to, '[)') @> current_date

    union all

    -- §5 refuses a default-to-suspense, so an account determination rule that
    -- promotes into the wrong account is a wrong posting rather than a missing
    -- one. Every reference here is a code.
    select 'account_determination',
           ad.transaction_type || '|' || coalesce(ic.code, '-') || '|' ||
             coalesce(pcl.code, '-') || '|' || coalesce(s.code, '-') || '|' ||
             coalesce(e.code, '-') || '|' || coalesce(l.code, '-') || '|' ||
             coalesce(ad.legislation_pack_code, '-') || '|' ||
             coalesce(ad.reason_code, '-'),
           jsonb_build_object(
             'transaction_type', ad.transaction_type,
             'account', a.code,
             'item_class', ic.code,
             'party_class', pcl.code,
             'site', s.code,
             'entity', e.code,
             'ledger', l.code,
             'reason_code', ad.reason_code,
             'legislation_pack', ad.legislation_pack_code,
             'dimensions', ad.dimensions,
             'note', ad.note,
             'effective_from', ad.valid_from)
      from t
      join erp.account_determination ad
        on ad.tenant_id = t.tenant_id and ad.status = 'active'
       and daterange(ad.valid_from, ad.valid_to, '[)') @> current_date
      join erp.account a on a.id = ad.account_id
      left join erp.posting_class ic  on ic.id = ad.item_class_id
      left join erp.posting_class pcl on pcl.id = ad.party_class_id
      left join erp.site s   on s.id = ad.site_id
      left join erp.entity e on e.id = ad.entity_id
      left join erp.ledger l on l.id = ad.ledger_id

    union all

    select 'classification_axis',
           ca.code,
           jsonb_build_object(
             'code', ca.code,
             'name', ca.name,
             'name_key', ca.name_key,
             'is_mandatory', ca.is_mandatory,
             'seq', ca.seq,
             'item_classes', array_to_string(ca.item_classes, ','))
      from t
      join erp.classification_axis ca
        on ca.tenant_id = t.tenant_id and ca.status = 'active'
       and daterange(ca.valid_from, ca.valid_to, '[)') @> current_date

    union all

    select 'classification_value',
           ca.code || '|' || cv.code,
           jsonb_build_object(
             'axis', ca.code,
             'code', cv.code,
             'name', cv.name,
             'name_key', cv.name_key,
             'abbreviation', cv.abbreviation,
             'parent', pv.code)
      from t
      join erp.classification_value cv
        on cv.tenant_id = t.tenant_id and cv.status = 'active'
       and daterange(cv.valid_from, cv.valid_to, '[)') @> current_date
      join erp.classification_axis ca on ca.id = cv.axis_id
      left join erp.classification_value pv on pv.id = cv.parent_value_id

    union all

    -- Only the newest version of a template. Superseded versions are kept
    -- because assigned codes still point at them, and promoting a superseded
    -- version would hand the target a template the source has moved past.
    select 'code_template',
           ct.code,
           jsonb_build_object(
             'code', ct.code,
             'name', ct.name,
             'entity', e.code,
             'segments', ct.segments,
             'casing', ct.casing,
             'item_classes', array_to_string(ct.item_classes, ','))
      from t
      join erp.code_template ct on ct.tenant_id = t.tenant_id and ct.status = 'active'
       and daterange(ct.valid_from, ct.valid_to, '[)') @> current_date
       and ct.version = (select max(c2.version) from erp.code_template c2
                          where c2.tenant_id = ct.tenant_id and c2.code = ct.code)
      left join erp.entity e on e.id = ct.entity_id

    union all

    select 'release_area',
           s.code || '|' || ra.code,
           jsonb_build_object(
             'site', s.code,
             'code', ra.code,
             'name', ra.name,
             'location', lo.code,
             'replenishment_mode', ra.replenishment_mode,
             'channel', ra.channel_code,
             'order_type', ra.order_type_code,
             'item_classes', array_to_string(ra.item_classes, ','),
             'min_quantity', ra.min_quantity,
             'max_quantity', ra.max_quantity,
             'ageing_hours', ra.ageing_hours,
             'gate_printing', ra.gate_printing)
      from t
      join erp.release_area ra on ra.tenant_id = t.tenant_id and ra.status = 'active'
       and daterange(ra.valid_from, ra.valid_to, '[)') @> current_date
      join erp.site s on s.id = ra.site_id
      left join erp.location lo on lo.id = ra.location_id

    union all

    -- ── Starter Content Packs: capture for the eight surfaces the register
    --    now claims. Promotion without capture is one-way — a change set can
    --    be authored into an organisation but never lifted back out of one.

    select 'capability',
           tc.capability_code,
           jsonb_build_object(
             'code', tc.capability_code,
             'enabled', tc.is_enabled,
             'reason', tc.reason,
             'effective_from', tc.valid_from)
      from t
      join erp.tenant_capability tc on tc.tenant_id = t.tenant_id
       and daterange(tc.valid_from, tc.valid_to, '[)') @> current_date

    union all

    select 'reason_code',
           rc.category_code || '|' || rc.code,
           jsonb_build_object(
             'category', rc.category_code,
             'code', rc.code,
             'name', rc.name,
             'requires_note', rc.requires_note,
             'requires_approval', rc.requires_approval,
             'seq', rc.seq)
      from t
      join erp.reason_code rc on rc.tenant_id = t.tenant_id and rc.status = 'active'

    union all

    select 'calendar',
           c.code,
           jsonb_build_object(
             'code', c.code,
             'name', c.name,
             'timezone', c.timezone,
             'working_days', to_jsonb(c.working_days),
             'exceptions', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'date', ce.exception_date,
                        'is_working', ce.is_working,
                        'description', ce.description_key)
                      order by ce.exception_date)
                 from erp.calendar_exception ce
                where ce.tenant_id = c.tenant_id and ce.calendar_id = c.id),
               '[]'::jsonb))
      from t
      join erp.calendar c on c.tenant_id = t.tenant_id and c.status = 'active'

    union all

    select 'sod_rule',
           sr.code,
           jsonb_build_object(
             'code', sr.code,
             'name', sr.name,
             'description', sr.description,
             'permissions_a', array_to_string(sr.permissions_a, ','),
             'permissions_b', array_to_string(sr.permissions_b, ','),
             'severity', sr.severity,
             'mitigation', sr.mitigation_guidance)
      from t
      join erp.sod_rule sr on sr.tenant_id = t.tenant_id and sr.status = 'active'

    union all

    select 'numbering_rule',
           nr.code,
           jsonb_build_object(
             'code', nr.code,
             'entity', e.code,
             'site', s.code,
             'prefix', nr.prefix,
             'suffix', nr.suffix,
             'pad_to', nr.pad_to,
             'reset_period', nr.reset_period)
      from t
      join erp.numbering_rule nr on nr.tenant_id = t.tenant_id and nr.status = 'active'
      left join erp.entity e on e.id = nr.entity_id
      left join erp.site s on s.id = nr.site_id
    -- next_value is deliberately not captured. A manifest is a statement of
    -- configuration, and how far a sequence has counted is state: carrying it
    -- across would rewind or fast-forward the target's own numbering.

    union all

    select 'document_type',
           dt.code,
           jsonb_build_object(
             'code', dt.code,
             'base_type', dt.base_type_code,
             'name', dt.name,
             'entity', e.code,
             'site', s.code,
             'numbering_rule', nr.code,
             'state_machine', dt.state_machine_code,
             'approval_chain', dt.approval_chain_code,
             'stock_movement_type', dt.stock_movement_type,
             'posting_rule', dt.posting_rule_code,
             'create_permission', dt.create_permission)
      from t
      join erp.document_type dt on dt.tenant_id = t.tenant_id and dt.status = 'active'
      -- Inner, deliberately: a document type with no sequence cannot issue a
      -- reference, so it is not configuration another environment could adopt.
      -- erp.assert_no_dead_configuration() is where that shows up as a finding.
      join erp.numbering_rule nr on nr.id = dt.numbering_rule_id
      left join erp.entity e on e.id = dt.entity_id
      left join erp.site s on s.id = dt.site_id

    union all

    select 'output_template',
           ot.code,
           jsonb_build_object(
             'code', ot.code,
             'name_key', ot.name_key,
             'kind', ot.kind,
             'base_type', ot.base_type_code,
             'page', ot.page,
             'blocks', ot.blocks)
      from t
      join erp.output_template ot on ot.tenant_id = t.tenant_id and ot.status = 'active'

    union all

    select 'notification_template',
           nt.code,
           jsonb_build_object(
             'code', nt.code,
             'channel_kind', nt.channel_kind,
             'subject_key', nt.subject_key,
             'body_key', nt.body_key)
      from t
      join erp.notification_template nt on nt.tenant_id = t.tenant_id

    union all

    select 'kpi',
           k.code,
           jsonb_build_object(
             'code', k.code,
             'name', k.name,
             'name_key', k.name_key,
             'description', k.description,
             'module_code', k.module_code,
             'unit', k.unit,
             'currency_scoped', k.currency_scoped,
             'higher_is_better', k.higher_is_better)
      from t
      join erp.kpi k on k.tenant_id = t.tenant_id

    union all

    select 'report',
           rp.code,
           jsonb_build_object(
             'code', rp.code,
             'name', rp.name,
             'name_key', rp.name_key,
             'description', rp.description,
             'module_code', rp.module_code,
             'kpi_codes', array_to_string(rp.kpi_codes, ','),
             'audience_role_codes', array_to_string(rp.audience_role_codes, ','))
      from t
      join erp.report rp on rp.tenant_id = t.tenant_id and rp.status = 'active'

  )
  select en.object_kind, en.object_key, en.content, md5(en.content::text)
    from entries en
   where p_kinds is null or en.object_kind = any (p_kinds)
   order by 1, 2
$function$;

insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale)
values ('erp', 'output_template', 'output_template',
        'What appears on a delivery note and in what order is configuration by '
        'every test this product applies: it changes what a customer sees '
        'without a line of code changing. §9.3 asks for neutral layouts, and a '
        'layout an organisation can edit directly on a live system is one '
        'nobody approved.')
on conflict (schema_name, table_name) do update set
  object_kind = excluded.object_kind, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- §9.3's sixteen, as base pack items
--
-- Twelve documents and four labels, each a list of blocks and the fields those
-- blocks bind. Neutral: not one of them names an organisation, a site, a
-- product or a word — every piece of text on the page comes from a resource
-- key, which is what makes §9.3's "tenant-brandable" true rather than
-- aspirational.
-- -----------------------------------------------------------------------------

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'base', 'output_template', t.code,
       jsonb_strip_nulls(jsonb_build_object(
         'code', t.code,
         'name_key', 'output.template.' || t.code,
         'kind', t.kind,
         'base_type', t.base_type,
         'page', t.page,
         'blocks', t.blocks)),
       t.why, 900 + t.seq
  from (values
    -- ── Documents ────────────────────────────────────────────────────────
    ('purchase_order', 'document', 'purchase_order', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name','entity_country')),
       jsonb_build_object('kind','counterparty','label_key','output.block.supplier','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','required_date','our_reference','their_reference','currency')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','unit_price','net_amount')),
       jsonb_build_object('kind','totals','fields',jsonb_build_array('total_net','total_tax','total_gross')),
       jsonb_build_object('kind','note','fields',jsonb_build_array('notes')),
       jsonb_build_object('kind','footer','label_key','output.footer.purchase_order')),
     'Starter Content Packs §9.3, first of sixteen.', 10),
    ('order_acknowledgement', 'document', 'sales_order', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','counterparty','label_key','output.block.customer','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','required_date','their_reference','currency')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','unit_price','net_amount')),
       jsonb_build_object('kind','totals','fields',jsonb_build_array('total_net','total_tax','total_gross')),
       jsonb_build_object('kind','footer','label_key','output.footer.acknowledgement')),
     'Starter Content Packs §9.3.', 20),
    ('goods_receipt_note', 'document', 'receipt', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','counterparty','label_key','output.block.supplier','fields',jsonb_build_array('party_name')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','their_reference')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','batch','location')),
       jsonb_build_object('kind','signature','label_key','output.block.received_by')),
     'Starter Content Packs §9.3.', 30),
    ('picking_ticket', 'document', 'sales_order', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','required_date')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','location','batch')),
       jsonb_build_object('kind','signature','label_key','output.block.picked_by')),
     'Starter Content Packs §9.3.', 40),
    ('packing_note', 'document', 'delivery', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','counterparty','label_key','output.block.deliver_to','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','batch')),
       jsonb_build_object('kind','signature','label_key','output.block.packed_by')),
     'Starter Content Packs §9.3.', 50),
    ('delivery_note', 'document', 'delivery', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name','entity_country')),
       jsonb_build_object('kind','counterparty','label_key','output.block.deliver_to','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','their_reference')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','batch')),
       jsonb_build_object('kind','signature','label_key','output.block.received_by'),
       jsonb_build_object('kind','footer','label_key','output.footer.delivery_note')),
     'Starter Content Packs §9.3. No prices: a delivery note is what arrived, not what it cost.', 60),
    ('commercial_invoice', 'document', 'invoice_reference', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name','entity_country')),
       jsonb_build_object('kind','counterparty','label_key','output.block.invoice_to','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','due_date','their_reference','currency')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','unit_price','net_amount','tax_amount')),
       jsonb_build_object('kind','totals','fields',jsonb_build_array('total_net','total_tax','total_gross')),
       jsonb_build_object('kind','footer','label_key','output.footer.invoice')),
     'Starter Content Packs §9.3.', 70),
    ('credit_note', 'document', 'credit_reference', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','counterparty','label_key','output.block.invoice_to','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','their_reference','currency')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','unit_price','net_amount','tax_amount')),
       jsonb_build_object('kind','totals','fields',jsonb_build_array('total_net','total_tax','total_gross')),
       jsonb_build_object('kind','footer','label_key','output.footer.credit_note')),
     'Starter Content Packs §9.3.', 80),
    ('pro_forma', 'document', 'quotation', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','counterparty','label_key','output.block.customer','fields',jsonb_build_array('party_name','party_address')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','currency')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','unit_price','net_amount')),
       jsonb_build_object('kind','totals','fields',jsonb_build_array('total_net','total_tax','total_gross')),
       jsonb_build_object('kind','footer','label_key','output.footer.pro_forma')),
     'Starter Content Packs §9.3.', 90),
    ('transfer_note', 'document', 'transfer_order', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','required_date')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','batch','location')),
       jsonb_build_object('kind','signature','label_key','output.block.despatched_by')),
     'Starter Content Packs §9.3.', 100),
    ('works_order_pack', 'document', 'works_order', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','required_date')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','quantity_fulfilled')),
       jsonb_build_object('kind','note','fields',jsonb_build_array('notes')),
       jsonb_build_object('kind','signature','label_key','output.block.completed_by')),
     'Starter Content Packs §9.3.', 110),
    ('certificate_of_analysis', 'document', 'receipt', 'A4',
     jsonb_build_array(
       jsonb_build_object('kind','logo'),
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('line_no','item_code','description','quantity','uom','batch')),
       jsonb_build_object('kind','signature','label_key','output.block.authorised_by'),
       jsonb_build_object('kind','footer','label_key','output.footer.certificate')),
     'Starter Content Packs §9.3. The twelfth and last document.', 120),
    -- ── Labels ───────────────────────────────────────────────────────────
    ('pallet_label', 'label', null, '100x150mm',
     jsonb_build_array(
       jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','barcode','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('item_code','description','quantity','uom','batch'))),
     'Starter Content Packs §9.3, first of four labels.', 130),
    ('carton_label', 'label', null, '100x100mm',
     jsonb_build_array(
       jsonb_build_object('kind','barcode','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('item_code','description','quantity','uom'))),
     'Starter Content Packs §9.3.', 140),
    ('bin_label', 'label', null, '50x25mm',
     jsonb_build_array(
       jsonb_build_object('kind','barcode','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('item_code','location'))),
     'Starter Content Packs §9.3.', 150),
    ('returns_label', 'label', null, '100x150mm',
     jsonb_build_array(
       jsonb_build_object('kind','qr','fields',jsonb_build_array('document_number')),
       jsonb_build_object('kind','counterparty','label_key','output.block.return_to','fields',jsonb_build_array('entity_name')),
       jsonb_build_object('kind','lines','fields',jsonb_build_array('item_code','description','quantity','uom'))),
     'Starter Content Packs §9.3, the sixteenth.', 160)
  ) as t(code, kind, base_type, page, blocks, why, seq)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- -----------------------------------------------------------------------------
-- Every word on every page
--
-- Sixteen template names, twenty-eight field labels, eight block headings and
-- six footers, all in the base locale so an organisation renames rather than
-- creates. This is the half of §9.3 that makes "tenant-brandable" mean
-- something: there is no other place the text could come from.
-- -----------------------------------------------------------------------------

insert into erp_ref.resource (key, locale, value, description)
select 'output.template.' || t.code, 'en', t.name,
       'Starter Content Packs §9.3 output template name.'
  from (values
    ('purchase_order',          'Purchase order'),
    ('order_acknowledgement',   'Order acknowledgement'),
    ('goods_receipt_note',      'Goods receipt note'),
    ('picking_ticket',          'Picking ticket'),
    ('packing_note',            'Packing note'),
    ('delivery_note',           'Delivery note'),
    ('commercial_invoice',      'Commercial invoice'),
    ('credit_note',             'Credit note'),
    ('pro_forma',               'Pro-forma'),
    ('transfer_note',           'Transfer note'),
    ('works_order_pack',        'Works order pack'),
    ('certificate_of_analysis', 'Certificate of analysis'),
    ('pallet_label',            'Pallet label'),
    ('carton_label',            'Carton label'),
    ('bin_label',               'Bin label'),
    ('returns_label',           'Returns label')
  ) as t(code, name)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- The field labels, from the register rather than typed again.
insert into erp_ref.resource (key, locale, value, description)
select f.label_key, 'en', f.name,
       'Starter Content Packs §9.3 output field label.'
  from (values
    ('output.field.document_number',    'Reference'),
    ('output.field.document_date',      'Date'),
    ('output.field.required_date',      'Required by'),
    ('output.field.due_date',           'Due'),
    ('output.field.our_reference',      'Our reference'),
    ('output.field.their_reference',    'Your reference'),
    ('output.field.currency',           'Currency'),
    ('output.field.notes',              'Notes'),
    ('output.field.party_name',         'Name'),
    ('output.field.party_address',      'Address'),
    ('output.field.entity_name',        'Company'),
    ('output.field.entity_country',     'Country'),
    ('output.field.brand_name',         'Trading name'),
    ('output.field.line_no',            'Line'),
    ('output.field.item_code',          'Item'),
    ('output.field.description',        'Description'),
    ('output.field.quantity',           'Quantity'),
    ('output.field.uom',                'Unit'),
    ('output.field.unit_price',         'Unit price'),
    ('output.field.net_amount',         'Net'),
    ('output.field.tax_amount',         'Tax'),
    ('output.field.batch',              'Batch'),
    ('output.field.location',           'Location'),
    ('output.field.quantity_fulfilled', 'Completed'),
    ('output.field.total_net',          'Total net'),
    ('output.field.total_tax',          'Total tax'),
    ('output.field.total_gross',        'Total'),
    ('output.field.line_count',         'Lines')
  ) as f(label_key, name)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select b.key, 'en', b.name,
       'Starter Content Packs §9.3 output block heading.'
  from (values
    ('output.block.supplier',       'Supplier'),
    ('output.block.customer',       'Customer'),
    ('output.block.deliver_to',     'Deliver to'),
    ('output.block.invoice_to',     'Invoice to'),
    ('output.block.return_to',      'Return to'),
    ('output.block.received_by',    'Received by'),
    ('output.block.picked_by',      'Picked by'),
    ('output.block.packed_by',      'Packed by'),
    ('output.block.despatched_by',  'Despatched by'),
    ('output.block.completed_by',   'Completed by'),
    ('output.block.authorised_by',  'Authorised by'),
    ('output.footer.purchase_order','This order is placed on the terms agreed between the parties.'),
    ('output.footer.acknowledgement','This acknowledges the order and does not vary its terms.'),
    ('output.footer.delivery_note', 'Please check the goods on arrival and report any shortage.'),
    ('output.footer.invoice',       'Payment is due on the date shown.'),
    ('output.footer.credit_note',   'This credit note relates to the reference shown.'),
    ('output.footer.pro_forma',     'This is a pro-forma and is not a demand for payment.'),
    ('output.footer.certificate',   'This certificate relates to the batches shown.')
  ) as b(key, name)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- -----------------------------------------------------------------------------
-- The assertion
-- -----------------------------------------------------------------------------

create or replace function erp.assert_output_templates_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_detail text := '';
  r record;
begin
  -- 1. Sixteen, because §9.3 lists sixteen. A template that quietly leaves the
  --    pack is one an organisation stops being given and nothing says so.
  if (select count(*) from erp_ref.pack_item
       where object_kind = 'output_template') <> 16 then
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  the pack carries %s output templates and §9.3 lists 16\n',
      (select count(*) from erp_ref.pack_item where object_kind = 'output_template'));
  end if;

  -- 2. Every block kind is one a renderer handles. The writer refuses this at
  --    promotion; this catches a pack item that would be refused, before
  --    anybody tries to install it.
  for r in
    select pi.object_key, b ->> 'kind' as kind
      from erp_ref.pack_item pi,
           lateral jsonb_array_elements(pi.payload -> 'blocks') b
     where pi.object_kind = 'output_template'
       and not exists (select 1 from erp_ref.output_block_kind k
                        where k.code = b ->> 'kind')
     order by 1, 2
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  %s names block kind %s, which no renderer handles\n', r.object_key, r.kind);
  end loop;

  -- 3. Every field is one erp.render_output_template() resolves.
  for r in
    select pi.object_key, x.code
      from erp_ref.pack_item pi,
           lateral jsonb_array_elements(pi.payload -> 'blocks') b,
           lateral jsonb_array_elements_text(coalesce(b -> 'fields', '[]'::jsonb)) as x(code)
     where pi.object_kind = 'output_template'
       and not exists (select 1 from erp_ref.output_field o where o.code = x.code)
     order by 1, 2
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  %s binds field %s, which is not in erp_ref.output_field\n',
      r.object_key, r.code);
  end loop;

  -- 4. A line field in a block that does not repeat renders the first line and
  --    silently loses the rest, which is the worst way for a delivery note to
  --    be wrong.
  for r in
    -- Explicit joins throughout, and the lateral expansion isolated in a
    -- subquery: a comma-joined lateral is not in scope for an explicit JOIN
    -- beside it, which is a plpgsql trap this codebase has now hit twice.
    select bound.object_key, bound.kind, bound.code
      from (
        select pi.object_key, b ->> 'kind' as kind, x.code
          from erp_ref.pack_item pi
          cross join lateral jsonb_array_elements(pi.payload -> 'blocks') b
          cross join lateral jsonb_array_elements_text(
                       coalesce(b -> 'fields', '[]'::jsonb)) as x(code)
         where pi.object_kind = 'output_template'
      ) bound
      join erp_ref.output_field o on o.code = bound.code
      join erp_ref.output_block_kind k on k.code = bound.kind
     where o.is_line and not k.repeats
     order by 1, 2, 3
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  %s puts line field %s in %s, which does not repeat — it would render '
       'the first line and lose the rest\n', r.object_key, r.code, r.kind);
  end loop;

  -- 5. Every word on the page has a row it can be renamed by. This is §9.3's
  --    "tenant-brandable through the resource and branding layer", checked
  --    rather than asserted: a template name, a block heading or a field label
  --    with no resource row is a word no organisation can change.
  for r in
    select key from (
      select pi.payload ->> 'name_key' as key from erp_ref.pack_item pi
       where pi.object_kind = 'output_template'
      union
      select b ->> 'label_key' from erp_ref.pack_item pi,
             lateral jsonb_array_elements(pi.payload -> 'blocks') b
       where pi.object_kind = 'output_template' and b ? 'label_key'
      union
      select o.label_key from erp_ref.output_field o
    ) k
     where key is not null
       and not exists (select 1 from erp_ref.resource rr
                        where rr.key = k.key and rr.locale = 'en')
     order by 1
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  %s has no en resource row, so no organisation could rename it\n', r.key);
  end loop;

  -- 6. And a document template names a document this product knows. A label
  --    names none, on purpose: a pallet belongs to stock, not to a document.
  for r in
    select pi.object_key, pi.payload ->> 'base_type' as bt
      from erp_ref.pack_item pi
     where pi.object_kind = 'output_template'
       and pi.payload ->> 'kind' = 'document'
       and not exists (select 1 from erp_ref.document_type dt
                        where dt.code = pi.payload ->> 'base_type')
     order by 1
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  %s renders base type %s, which is not in the neutral catalogue\n',
      r.object_key, coalesce(r.bt, '(none)'));
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_OUTPUT_TEMPLATES_UNSOUND: % finding(s)\n%',
      v_count, v_detail using errcode = '23514';
  end if;

  return format('output templates: %s (%s documents, %s labels), %s block kinds, %s fields',
    (select count(*) from erp_ref.pack_item where object_kind = 'output_template'),
    (select count(*) from erp_ref.pack_item
      where object_kind = 'output_template' and payload ->> 'kind' = 'document'),
    (select count(*) from erp_ref.pack_item
      where object_kind = 'output_template' and payload ->> 'kind' = 'label'),
    (select count(*) from erp_ref.output_block_kind),
    (select count(*) from erp_ref.output_field));
end;
$$;

comment on function erp.assert_output_templates_sound is
  '§9.3''s sixteen are all there, every block kind is one a renderer handles, '
  'every field one the renderer resolves, no line field sits in a block that '
  'does not repeat, every word has a resource row, and every document template '
  'names a document this product knows.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('output_templates', 'Output templates sound', 'assertion', 'platform',
        'assert_output_templates_sound', '', null, '',
        '§9.3''s sixteen document and label layouts: all present, every field '
        'and block kind resolvable, and every word on the page renameable.',
        true, 33)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind,
  scope = excluded.scope, runs_in_ci = excluded.runs_in_ci;

-- -----------------------------------------------------------------------------
-- The doors
-- -----------------------------------------------------------------------------

create or replace function public.erp_output_templates()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', ot.code, 'name_key', ot.name_key, 'kind', ot.kind,
           'base_type', ot.base_type_code, 'page', ot.page,
           'blocks', jsonb_array_length(ot.blocks)) order by ot.kind, ot.code), '[]'::jsonb)
    from erp.output_template ot
   where ot.tenant_id = erp.current_tenant_id() and ot.status = 'active';
$$;

create or replace function public.erp_render_output_template(
  p_code text, p_document_id uuid default null, p_locale text default 'en')
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'output_template', null);
  return erp.render_output_template(p_code, p_document_id, p_locale);
end;
$$;

do $$
begin
  execute 'revoke all on function public.erp_output_templates() from public, anon';
  execute 'grant execute on function public.erp_output_templates() to authenticated';
  execute 'revoke all on function public.erp_render_output_template(text, uuid, text) from public, anon';
  execute 'grant execute on function public.erp_render_output_template(text, uuid, text) to authenticated';
end $$;

select erp.assert_output_templates_sound();
select erp.assert_resource_coverage('en');
select erp.assert_public_api_safe();

-- -----------------------------------------------------------------------------
-- The branding door, which has never worked
--
-- §9.3's layouts are brandable "through the resource and branding layer", and
-- the suite below exercises that by renaming a column heading on a delivery
-- note. It could not: public.erp_set_resource_override() names an ON CONFLICT
-- target of (tenant_id, key, locale, entity_id) and the unique index is on
-- (tenant_id, key, locale, COALESCE(entity_id, …)) — an expression, which an
-- ON CONFLICT target has to match exactly. Every first override an
-- organisation ever set raised "no unique or exclusion constraint matching the
-- ON CONFLICT specification", and since this is the only door that creates
-- one, no organisation has ever had an override at all.
--
-- Dumped and patched at that one clause.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.erp_set_resource_override(p_key text, p_value text, p_locale text DEFAULT 'en'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_tenant uuid; v_id uuid;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.current_tenant_id();

  if not exists (select 1 from erp_ref.resource r
                  where r.key = p_key and r.locale = coalesce(p_locale, 'en')) then
    raise exception 'ERPWARE_VALIDATION: no such resource key in this locale';
  end if;

  if p_value is null or btrim(p_value) = '' then
    delete from erp.resource_override o
     where o.tenant_id = v_tenant and o.key = p_key and o.locale = coalesce(p_locale, 'en');
    return jsonb_build_object('key', p_key, 'override', null);
  end if;

  insert into erp.resource_override (tenant_id, key, locale, value, note, status, created_by)
  values (v_tenant, p_key, coalesce(p_locale, 'en'), p_value, p_note,
          'active'::erp.record_status, erp.current_principal_id())
  -- The unique index is on COALESCE(entity_id, …), not on entity_id, and an
  -- ON CONFLICT target has to name the index's expression exactly. It named
  -- the bare column, so this door raised "no unique or exclusion constraint
  -- matching the ON CONFLICT specification" on every first override an
  -- organisation ever tried to set — which is every override, because there
  -- was no other way to create one. The branding panel's only write has never
  -- worked. Found by erp_test.output_template_suite() renaming a column
  -- heading on a delivery note, which is exactly the thing §9.3 promises.
  on conflict (tenant_id, key, locale,
               coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
    do update
    set value = excluded.value, note = excluded.note,
        status = 'active'::erp.record_status,
        updated_at = now(), updated_by = erp.current_principal_id()
  returning id into v_id;

  return jsonb_build_object('key', p_key, 'override_id', v_id);
end;
$function$;

-- -----------------------------------------------------------------------------
-- The suite
--
-- The assertion checks the templates are well formed. This checks the renderer
-- actually resolves one against a real document — and, decisively, that
-- renaming a word through the resource layer changes what comes out, because
-- that is §9.3's entire claim about brandability and the easiest thing in this
-- design to have got wrong.
-- -----------------------------------------------------------------------------

create or replace function erp_test.output_template_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();
  v_t uuid; v_e uuid; v_site uuid; v_party uuid; v_item uuid; v_uom uuid;
  v_doc uuid; res jsonb; v_cs uuid; v_ok boolean; v_msg text; n integer;
  v_lines jsonb; v_title text;
begin
  insert into auth.users (id, email) values (a1, 'out@zzout.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.onboard_tenant('Output', 'zzout');
  v_t := erp.require_tenant_id();
  select e.id into v_e from erp.entity e where e.tenant_id = v_t limit 1;

  perform erp.configure_finance();
  perform erp.configure_procurement();
  perform erp.configure_sales();

  -- ── The pack carries them ───────────────────────────────────────────────

  res := erp.apply_content_pack('base');
  v_cs := (res ->> 'change_set_id')::uuid;

  select count(*) into n from erp.change_set_item i
   where i.change_set_id = v_cs and i.object_kind = 'output_template';
  return query select 'the base pack plans §9.3''s sixteen layouts',
    n = 16, format('%s output templates in the change set', n);

  -- §11.4: promotion refuses while a required decision remains, and it refuses
  -- for the whole change set rather than for the kinds being promoted — which
  -- is right, because a half-answered pack is not a pack. The approval
  -- thresholds are not this suite's subject, so they are answered and moved
  -- past; the layouts are what it is here to test, and
  -- erp.promote_change_set() takes the kinds to promote as its second
  -- argument.
  for n in select 1 from erp.pack_decisions('base') where not answered loop null; end loop;
  declare d record; i integer := 0;
  begin
    for d in select * from erp.pack_decisions('base') where not answered loop
      i := i + 1;
      perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
        jsonb_build_object('upper_bound_minor', i * 500000));
    end loop;
  end;

  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs, array['output_template']);

  return query select 'and promoting them lands twelve documents and four labels',
    (select count(*) from erp.output_template ot
      where ot.tenant_id = v_t and ot.kind = 'document') = 12
    and (select count(*) from erp.output_template ot
          where ot.tenant_id = v_t and ot.kind = 'label') = 4,
    format('%s documents, %s labels',
      (select count(*) from erp.output_template ot where ot.tenant_id = v_t and ot.kind = 'document'),
      (select count(*) from erp.output_template ot where ot.tenant_id = v_t and ot.kind = 'label'));

  -- ── A document to render ────────────────────────────────────────────────

  insert into erp.site (tenant_id, entity_id, code, name, site_type)
  values (v_t, v_e, 'MAIN', 'Main', 'warehouse') returning id into v_site;
  insert into erp.party (tenant_id, code, name)
  values (v_t, 'CUST1', 'A customer') returning id into v_party;
  select u.id into v_uom from erp.uom u where u.tenant_id = v_t and u.code = 'EA';
  if v_uom is null then
    insert into erp.uom (tenant_id, code, name, uom_class)
    values (v_t, 'EA', 'Each', 'quantity') returning id into v_uom;
  end if;
  insert into erp.item (tenant_id, code, name, stock_uom_id)
  values (v_t, 'WIDGET', 'A widget', v_uom) returning id into v_item;

  -- (type, party, entity, site) — the party comes first.
  v_doc := erp.open_document('delivery', v_party, v_e, v_site);
  insert into erp.document_line
    (tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
     unit_price_minor, net_minor, tax_minor, currency)
  values (v_t, v_doc, 1, v_item, 'A widget', 3, v_uom, 1000, 3000, 600, 'GBP'),
         (v_t, v_doc, 2, v_item, 'Another widget', 2, v_uom, 1000, 2000, 400, 'GBP');

  res := erp.render_output_template('delivery_note', v_doc, 'en');

  return query select 'the renderer resolves a delivery note',
    res ->> 'template' = 'delivery_note' and res ->> 'kind' = 'document',
    format('%s blocks', jsonb_array_length(res -> 'blocks'));

  return query select 'its title is the resolved word, not the resource key',
    res ->> 'title' = 'Delivery note',
    coalesce(res ->> 'title', '(none)');

  select b into v_lines from jsonb_array_elements(res -> 'blocks') b
   where b ->> 'kind' = 'lines';

  return query select 'the line block carries a row per line, with its columns named',
    jsonb_array_length(v_lines -> 'rows') = 2
      and jsonb_array_length(v_lines -> 'columns') > 0,
    format('%s rows, %s columns',
      jsonb_array_length(v_lines -> 'rows'), jsonb_array_length(v_lines -> 'columns'));

  return query select 'and the values come off the document, not out of the template',
    (v_lines -> 'rows' -> 0 ->> 'description') = 'A widget'
      and (v_lines -> 'rows' -> 1 ->> 'quantity')::numeric = 2,
    coalesce(v_lines -> 'rows' -> 0 ->> 'description', '(none)');

  return query select 'a delivery note carries no prices',
    not (v_lines -> 'columns') @> '[{"field":"unit_price"}]'::jsonb,
    'what arrived, not what it cost — the layout says so and nothing in code does';

  -- ── §9.3's actual claim ─────────────────────────────────────────────────

  -- (key, value, locale) — the value comes second.
  perform public.erp_set_resource_override('output.field.quantity', 'Qty shipped', 'en');
  res := erp.render_output_template('delivery_note', v_doc, 'en');
  select b into v_lines from jsonb_array_elements(res -> 'blocks') b
   where b ->> 'kind' = 'lines';

  return query select 'renaming a word through the resource layer changes the page',
    (v_lines -> 'columns') @> '[{"field":"quantity","label":"Qty shipped"}]'::jsonb,
    '§9.3 asks for layouts "tenant-brandable through the resource and branding '
    'layer", and this is the whole of that claim, tested';

  -- ── The refusals ────────────────────────────────────────────────────────

  begin
    perform erp.render_output_template('delivery_note', null, 'en');
    v_ok := false; v_msg := 'a document template rendered with no document';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DOCUMENT_REQUIRED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a document layout with no document is refused', v_ok, v_msg;

  begin
    perform erp.upsert_output_template('bad', 'output.template.bad', 'label',
      null, 'A4', '[{"kind":"hologram"}]'::jsonb);
    v_ok := false; v_msg := 'a template named a block kind nothing renders';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_BLOCK_KIND%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a block kind no renderer handles is refused at write time',
    v_ok, v_msg;

  begin
    perform erp.upsert_output_template('bad2', 'output.template.bad2', 'label',
      null, 'A4', '[{"kind":"lines","fields":["nonexistent"]}]'::jsonb);
    v_ok := false; v_msg := 'a template bound a field nothing resolves';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_OUTPUT_FIELD%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and so is a field nothing resolves', v_ok, v_msg;

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  delete from auth.users where id = a1;

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp.output_template ot where ot.tenant_id = v_t),
    'layouts cascade with the tenant, as every tenant-scoped table does';
end $$;

create or replace function erp_test.assert_output_template_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Two on the pack, five on the render, one on renaming, three refusals,
  -- and the cleanup.
  c_expected constant integer := 12;
begin
  create temporary table if not exists zz_output_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_output_result;
  insert into zz_output_result select * from erp_test.output_template_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_pass, v_total, v_detail from zz_output_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_SUITE_SHRANK: %/% cases ran, % expected',
      v_pass, v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_OUTPUT_TEMPLATE_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('output templates: %s/%s', v_pass, v_total);
end $$;

-- -----------------------------------------------------------------------------
-- §13's clause 5 recounts, again
--
-- The acceptance suite asserts a literal base-pack item count so a pack that
-- grows by accident fails the build. Sixteen output templates is a deliberate
-- growth, so the constant moves. Dumped and patched at that one number.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp_test.starter_pack_acceptance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();   -- the author
  a2 uuid := gen_random_uuid();   -- the approver, because B6 refuses self-approval
  r         record;
  c         record;
  res       jsonb;
  v_cs      uuid;
  v_tok     text;
  v_second  uuid;
  d         record;
  i         integer := 0;
  n         integer;
  v_ok      boolean; v_msg text;
  v_ready   integer;
begin
  select * into r from erp.provision_tenant(
    'zz13', 'Acceptance', 'admin@zz13.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zz13.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- The modules. Installing one is not "further configuration" in §13's sense
  -- — it is what gives the product a procurement flow to configure at all —
  -- and the pack presupposes them: a requisition lifecycle comes from
  -- erp.configure_procurement(), not from erp_ref.pack_item.
  perform erp.configure_finance();
  perform erp.configure_procurement(1000000);
  perform erp.configure_sales();
  perform erp.configure_inventory();
  perform erp.configure_quality();
  perform erp.configure_logistics();
  perform erp.configure_period_close();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── §2.1's route ────────────────────────────────────────────────────────

  res := erp.apply_preset('standard');
  return query select 'a live organisation switches capabilities through a change set',
    (res ->> 'route') = 'change_set' and (res ->> 'change_set_id') is not null,
    'erp.provision_tenant() marks the self environment live immediately, so '
    'the promotable-surface guard bites from the first day — and before this '
    'there was no promotion route to take instead, which left every '
    'organisation able to read the capability catalogue and none able to '
    'change it';

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) into n from erp.tenant_capability tc
   where tc.tenant_id = r.tenant_id and tc.is_enabled and tc.valid_to is null;
  return query select 'and promoting it switches on what the preset selects',
    n = 9, format('%s capabilities on after the Standard preset', n);

  -- ── §11, applied ────────────────────────────────────────────────────────

  res := erp.apply_content_pack('base');
  v_cs := (res ->> 'change_set_id')::uuid;
  return query select 'the base pack plans only what the capabilities allow',
    -- 342. It was 322 when §13's clause 5 was written, 326 after
    -- 20260904100000 added §9.1's four remaining scheduled jobs, and 342 now
    -- that 20260904170000 has added §9.3's sixteen output templates. The
    -- number is hardcoded on purpose — it is what makes a pack that grows by
    -- accident fail the build — so each deliberate growth updates it and says
    -- what moved it.
    (res ->> 'items')::integer = 342
      and jsonb_array_length(res -> 'advisories') = 6,
    format('%s of %s items, %s advisories naming the capabilities that held the rest back',
           res ->> 'items',
           (select count(*) from erp_ref.pack_item where pack_code = 'base'),
           jsonb_array_length(res -> 'advisories'));

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a pack promoted with twelve decisions unanswered';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_DECISIONS_OUTSTANDING%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'promotion refuses while a required decision remains', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  for d in select * from erp.pack_decisions('base') where not answered loop
    i := i + 1;
    perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
      jsonb_build_object('upper_bound_minor', i * 500000));
  end loop;
  return query select 'and §3.4''s twelve approval bands are all of them',
    i = 12, format('%s decisions, every one an approval threshold', i);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'the answer lands, not the pack''s placeholder',
    (select ab.upper_bound_minor from erp.approval_band ab
      join erp.department dp on dp.id = ab.department_id
     where ab.tenant_id = r.tenant_id and dp.code = 'PROC'
       and ab.object_type = 'requisition' and ab.seq = 1) is not null,
    'a band whose threshold is still null is a chain that approves everything';

  -- ── §13's seven clauses ─────────────────────────────────────────────────

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'four of §13''s seven clauses hold after Standard and the base pack',
    v_ready = 4,
    format('%s of 7 ready with nothing configured by hand', v_ready);

  return query select 'clauses 1, 2, 4 and 7 are the four',
    (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
      where clause in (1, 2, 4, 7)),
    'requisition to invoice; determination with no suspense fallback; count '
    'and variance; period close';

  -- The two clauses §13 describes after "having chosen the Standard preset"
  -- and §2.3 puts in Full. Settled as: §13 means Full. The report says which
  -- preset each clause needs, derived from erp_ref.preset_capability, so
  -- neither document had to be rewritten and neither is quoted at the reader.
  return query select 'clause 3 needs Full, and says so rather than reading as a fault',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 3) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      = 'Container identity is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 3), 'nothing missing');

  return query select 'clause 6 needs Full for the same reason, and nothing else',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 6) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 6)
      = 'Recall management is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 6), 'nothing missing');

  -- The invariant the whole change is for: nothing a preset can switch on is
  -- ever reported as something the pack failed to provide. §13's last sentence
  -- logs a pack gap against the product, and a preset nobody chose is not one.
  return query select 'no clause blames the pack for a capability a preset carries',
    not exists (
      select 1 from erp.pack_acceptance_report(r.tenant_id) ar
       where ar.missing is not null
         and ar.missing like '%is off%'
         and ar.missing not like '%preset)%'),
    'before this, two clauses answered a reader with a paragraph about §2.3 '
    'disagreeing with §13';

  return query select 'clause 5''s gap is a site''s, not the pack''s',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 5)
      = 'no marshalling area configured for any site; ',
    'a marshalling area belongs to a site, and a site is an organisation''s own '
    '— §11 lists none in a pack for the same reason';

  -- ── The Full preset closes both, which is what names the cause ──────────

  res := erp.apply_preset('full');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 're-applying the base pack plans exactly what was held back',
    (res ->> 'items')::integer = 13,
    format('%s items — §11.7''s "a tenant that skipped manufacturing at '
           'onboarding can add it later, and the change set contains only what '
           'is missing"', res ->> 'items');

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'the Full preset closes clauses 3 and 6 and nothing else changes',
    v_ready = 6
      and (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
            where clause in (3, 6)),
    format('%s of 7 ready; only clause 5 remains, and it wants a site', v_ready);

  return query select 'and a third application plans nothing at all',
    (select count(*) from erp.plan_content_pack('base')) = 0,
    'additive, per §11.7';

  -- ── §10, over the base ──────────────────────────────────────────────────

  begin
    perform erp.apply_content_pack('outsourced_logistics');
    v_ok := false; v_msg := 'a profile pack applied with its capability off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_CONFLICT%'
        and sqlerrm like '%third_party_custody%';
    v_msg := left(sqlerrm, 58);
  end;
  return query select 'a profile pack whose capability is off is refused by name',
    v_ok, v_msg;

  res := erp.apply_content_pack('manufacturing');
  return query select 'and one whose capability is on applies over the base',
    (res ->> 'items')::integer = 13, format('%s items', res ->> 'items');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select '§10''s five works order types all land',
    (select count(*) from erp.classification_value cv
       join erp.classification_axis ca on ca.id = cv.axis_id
      where cv.tenant_id = r.tenant_id and ca.code = 'WORKS_ORDER_TYPE'
        and cv.status = 'active') = 5,
    'production, assembly, kitting, rework, repack';

  return query select '§11.6: the organisation records which packs it holds, and at which version',
    (select count(*) from erp.tenant_pack tp
      where tp.tenant_id = r.tenant_id and tp.status = 'applied') = 3
    and (select bool_and(tp.version = '1.0.0') from erp.tenant_pack tp
          where tp.tenant_id = r.tenant_id and tp.status = 'applied'),
    'base twice and manufacturing once, each with its version';

  -- ── §12, checkable rather than trusted ──────────────────────────────────

  return query select 'every pack value states where it came from',
    not exists (select 1 from erp_ref.pack_item where length(provenance) <= 20)
    and not exists (select 1 from erp_ref.content_pack where length(provenance) <= 30),
    '§12: "every value carries a provenance note naming the standard or '
    'practice it derives from, so the review is checkable rather than trusted"';

  -- Cleanup, so the next suite starts from the schema rather than from this.
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'a suite that leaves an organisation makes the next one measure this one';
end;
$function$;

select erp_test.assert_starter_pack_acceptance();

-- ── The decision this closes, and the one the work opened ────────────────────

update erp_meta.policy_decision set
  title = '§9.3''s sixteen output templates ship, with a surface that resolves '
          'them and a boundary at the page',
  decision =
    'Built. erp.output_template is a promotable, tenant-scoped surface with a '
    'change-set kind, a manifest block and a guard; the base pack carries '
    '§9.3''s sixteen layouts — twelve documents and four labels; and '
    'erp.render_output_template() resolves one against a document. The '
    'boundary is stated rather than fudged: the renderer resolves, it does not '
    'draw. Turning a resolved layout into a PDF or a label stream is the '
    'client''s job, because a page is pixels and pixels are not '
    'configuration.',
  rationale =
    'The record said what was missing was "a table, a change-set kind, and a '
    'renderer", and called it a subsystem rather than pack content. It is '
    'both, and the pack content is the smaller half. What makes it tractable '
    'is that §9.3''s own words settle the hard question: "neutral layouts, '
    'tenant-brandable through the resource and branding layer" means a block '
    'names a RESOURCE KEY and never a piece of text, so a template cannot '
    'contain a word an organisation is unable to change — and that is '
    'checkable rather than a matter of discipline. Two registers make the rest '
    'checkable too: erp_ref.output_block_kind says what a renderer handles and '
    'erp_ref.output_field says which values a block may bind, so a mistyped '
    'field is a build failure rather than a blank line on a delivery note '
    'somebody has already posted.',
  evidence =
    'erp.assert_output_templates_sound() has six checks, each falsified by '
    'breaking it: sixteen present, every block kind renderable, every field '
    'resolvable, no line field in a block that does not repeat, every word '
    'with an en resource row, and every document template naming a document '
    'this product knows. erp_test.output_template_suite() promotes the sixteen '
    'into an organisation, renders a real delivery note off a real document, '
    'and renames a column heading through the resource layer to prove the page '
    'changes — which is §9.3''s whole claim.',
  status = 'accepted', decided_at = now()
 where code = 'no_output_template_surface';

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence, decided_by)
values
  ('resource_override_door_was_broken',
   'The only door that creates a terminology override could never create one',
   'Terminology §1, Starter Content Packs §9.3',
   'Fixed, and recorded because the interesting part is not the fix. '
   'public.erp_set_resource_override() named an ON CONFLICT target of '
   '(tenant_id, key, locale, entity_id) while the unique index is on '
   '(tenant_id, key, locale, COALESCE(entity_id, …)) — an expression, which an '
   'ON CONFLICT target must match exactly. The clause now matches the index.',
   'Every first override an organisation tried to set raised "no unique or '
   'exclusion constraint matching the ON CONFLICT specification", and this is '
   'the only door that creates one, so no organisation has ever successfully '
   'renamed anything. The terminology layer has a register, an alignment '
   'assertion, a screen-string gate and 234 renameable strings — and the write '
   'at the end of all of it did not work. Nothing caught it because nothing '
   'had ever called it: erp.assert_public_api_safe() checks a door is gated, '
   'not that it functions, and no suite set an override. That gap is the '
   'finding worth keeping. It is recorded as accepted rather than closed '
   'silently so the next person asking "what else is reachable but untested?" '
   'has somewhere to start.',
   'accepted',
   'erp_test.output_template_suite() renames output.field.quantity to "Qty '
   'shipped" and asserts the rendered delivery note carries the new heading — '
   'the first time anything in this product has written a resource override.',
   null)
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, status = excluded.status,
  evidence = excluded.evidence;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_output_templates_sound();
select erp.assert_configuration_promotable();
select erp.assert_diagnostics_registered();
select erp.assert_resource_coverage('en');
select erp.assert_public_api_safe();
select erp_test.assert_output_template_suite();
