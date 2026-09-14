-- A product carries its description, and a line takes it.
--
-- The owner, on 14 September, from the New goods receipt form: every line has
-- a product, a quantity, a unit price and a description somebody types, and
-- for BUT-05 they type "Unsalted Butter" every time. "There should be
-- description assigned to a product, so we don't have to type a description
-- for a product. Description is assigned during product creation."
--
-- erp.item had a name and no description. (0022 made erp.item_description, a
-- localised text per product and locale, and nothing has ever read or written
-- it. It is left as it is; this is the one description the owner asked for.)
--
-- What this does, in order:
--
--   1. erp.item.description: plain text, optional, at most 1000 characters.
--      One trigger tidies it for every writer, the form, a change request, a
--      mass change and an import alike: trimmed, a blank one kept as none, and
--      one past a thousand characters refused by name. A check constraint
--      holds the same rule underneath it. It is not personal data, and its
--      name matches nothing the personal-data sweep looks for.
--   2. It is a maintained field, so a change request, a mass change and an
--      import can set or change it where they set or change the name.
--   3. public.erp_create_item takes p_description, last, so every call that
--      exists keeps working. public.erp_items returns it, so a form that picks
--      a product can show it.
--   4. A line saved without a description takes the product's. One function,
--      erp.line_description(), answers it: a description typed on the line
--      stands as typed; a blank or missing one becomes the product's; a
--      product with none leaves the line as it is today. It is asked where a
--      line is written:
--        * erp.add_document_line, which every other route calls: the New
--          document form (erp.create_document_full), a single added line, a
--          quotation converted into an order, a requisition converted into a
--          purchase order, a call-off, a drop-ship or intercompany order, a
--          quote revised or renewed;
--        * erp.firm_planned_order, which wrote its line with no description
--          at all;
--        * erp.add_quote_line, the platform's quotes, which never asked
--          anybody and wrote the product's name; it now writes the product's
--          description where there is one, and the name where there is not.
--      Receipts and invoices raised against an order copy the order line's
--      description, so they carry what the order line took.
--
-- Not changed: a line already written keeps what it has; nothing is filled in
-- afterwards. A product created from a classification template does not take
-- a description at creation (its form is not this change); it can be given
-- one afterwards like any other product.
--
-- Proof: erp_test.product_description_suite() (12).

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The column, tidied for every writer
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.item add column if not exists description text;

alter table erp.item
  add constraint item_description_is_plain_text
  check (description is null
         or (btrim(description, E' \t\r\n') <> '' and length(description) <= 1000));

comment on column erp.item.description is
  'What the product is, in the words orders, receipts and invoices carry. '
  'Optional and plain; at most 1000 characters, trimmed, never blank. A '
  'document line saved without a description takes this one '
  '(erp.line_description).';

create or replace function erp.tidy_item_description()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.description := nullif(btrim(new.description, E' \t\r\n'), '');

  if length(new.description) > 1000 then
    raise exception 'CLOVEERP_PRODUCT_DESCRIPTION_TOO_LONG: a product description is at most 1000 characters, and this one is %', length(new.description)
      using errcode = '23514',
            hint = 'Shorten the description to 1000 characters or fewer. It is the text a line carries onto orders, receipts and invoices, not a specification.';
  end if;

  return new;
end;
$$;

comment on function erp.tidy_item_description() is
  'Trims a product''s description, keeps a blank one as none, and refuses one '
  'past 1000 characters by name, for every writer of erp.item.';

drop trigger if exists t_item_description_tidy on erp.item;
create trigger t_item_description_tidy
  before insert or update of description on erp.item
  for each row execute function erp.tidy_item_description();

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A maintained field
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.maintainable_field (object_type, table_name, column_name, data_kind, rationale)
values ('item', 'item', 'description', 'text',
        'The words a line carries onto orders, receipts and invoices. Written with a catalogue import and corrected after it, alongside the name.')
on conflict (object_type, column_name) do update set
  table_name = excluded.table_name,
  data_kind  = excluded.data_kind,
  rationale  = excluded.rationale;

do $maintained$
begin
  if not exists (select 1 from erp_ref.maintainable_field m
                  where m.object_type = 'item' and m.column_name = 'description'
                    and m.table_name = 'item' and m.data_kind = 'text') then
    raise exception 'CLOVEERP_REGISTER_NOT_WRITTEN: erp_ref.maintainable_field does not list item.description after the insert';
  end if;
end
$maintained$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The door that creates a product, and the read that lists them
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20260911002634's body, with p_description added last and written with the
-- row. Dropped first: CREATE OR REPLACE with a longer argument list would
-- overload the name, and a call relying on defaults would then match both.

drop function if exists public.erp_create_item(text, text, text, boolean, text, text);

create or replace function public.erp_create_item(
  p_code text,
  p_name text,
  p_item_class text default null,
  p_is_batch_controlled boolean default false,
  p_item_group text default null,
  p_lifecycle text default null,
  p_description text default null
) returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid;
  v_uom uuid;
  v_id uuid;
  v_lifecycle erp.item_lifecycle;
begin
  perform erp.authorise('master_data.write', null, null, null, 'item', null);
  v_tenant := erp.current_tenant_id();

  if p_code is null or btrim(p_code) = '' then
    raise exception 'CLOVEERP_VALIDATION: an item code is required' using errcode = '23514';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'CLOVEERP_VALIDATION: an item name is required' using errcode = '23514';
  end if;

  v_lifecycle := coalesce(nullif(btrim(coalesce(p_lifecycle, '')), ''), 'active')::erp.item_lifecycle;

  v_uom := erp.ensure_base_uom(v_tenant, erp.current_principal_id());

  -- The description goes in as given: erp.tidy_item_description() trims it,
  -- keeps a blank one as none and refuses one past 1000 characters, for this
  -- door and every other writer alike.
  insert into erp.item (tenant_id, code, name, description, item_class, item_group, stock_uom_id,
                        is_batch_controlled, lifecycle, status, created_by)
  values (v_tenant, btrim(p_code), btrim(p_name),
          p_description,
          nullif(btrim(coalesce(p_item_class, '')), ''),
          nullif(btrim(coalesce(p_item_group, '')), ''),
          v_uom,
          coalesce(p_is_batch_controlled, false),
          v_lifecycle, 'active'::erp.record_status,
          erp.current_principal_id())
  returning id into v_id;

  return jsonb_build_object('item_id', v_id);
end $$;

comment on function public.erp_create_item(text, text, text, boolean, text, text, text) is
  'Creates a product with class, category, lifecycle and description. Blank lifecycle starts active; '
  'a blank description is none.';

revoke all on function public.erp_create_item(text, text, text, boolean, text, text, text) from public, anon;
grant execute on function public.erp_create_item(text, text, text, boolean, text, text, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_item', 'erp.authorise',
   'Creates a product under master_data.write, with class, category, lifecycle and description.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- 20260829360000's read, returning the description beside the name.
create or replace function public.erp_items(
  p_search text default null,
  p_limit  integer default 200
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'item_id', i.id, 'code', i.code, 'name', i.name,
      'description', i.description,
      'item_class', i.item_class, 'item_group', i.item_group,
      'lifecycle', i.lifecycle, 'status', i.status,
      'stock_uom_id', i.stock_uom_id,
      'stock_uom_code', u.code,
      'is_batch_controlled', i.is_batch_controlled,
      'is_serial_controlled', i.is_serial_controlled,
      'has_expiry', i.has_expiry) as x
      from erp.item i
      left join erp.uom u on u.tenant_id = i.tenant_id and u.id = i.stock_uom_id
     where i.tenant_id = erp.current_tenant_id()
       and i.status <> 'archived'
       and (p_search is null or i.code ilike '%' || p_search || '%'
                             or i.name ilike '%' || p_search || '%')
     order by i.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A line nobody described takes its product's description
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.line_description(p_item_id uuid, p_given text)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_description text;
begin
  -- Somebody described the line: it stands, exactly as they typed it.
  if p_item_id is null or btrim(coalesce(p_given, ''), E' \t\r\n') <> '' then
    return p_given;
  end if;

  select i.description into v_description
    from erp.item i
   where i.tenant_id = erp.require_tenant_id()
     and i.id = p_item_id;

  -- A product with no description leaves the line as it was given.
  return coalesce(v_description, p_given);
end;
$$;

comment on function erp.line_description(uuid, text) is
  'The description a document line is written with: the one given when it has '
  'words in it, otherwise the product''s, otherwise what was given.';

-- erp.add_document_line, which every route that adds a line calls.
do $add_line$
declare
  v_sig    constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def    text := pg_get_functiondef('erp.add_document_line(uuid,uuid,numeric,bigint,text,date)'::regprocedure);
  v_needle constant text :=
       E'  insert into erp.document_line (\n'
    || E'    tenant_id, document_id, line_no, item_id, description, quantity,\n'
    || E'    unit_price_minor, net_minor, currency, required_date)\n'
    || E'  values (\n'
    || E'    v_tenant, p_document_id, v_line, p_item_id, p_description, p_quantity,\n';
  v_new    constant text :=
       E'  -- A line nobody described takes its product''s description, so nobody\n'
    || E'  -- types "Unsalted Butter" for BUT-05 again. A typed one stands.\n'
    || E'  insert into erp.document_line (\n'
    || E'    tenant_id, document_id, line_no, item_id, description, quantity,\n'
    || E'    unit_price_minor, net_minor, currency, required_date)\n'
    || E'  values (\n'
    || E'    v_tenant, p_document_id, v_line, p_item_id, erp.line_description(p_item_id, p_description), p_quantity,\n';
begin
  if position('erp.line_description(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks erp.line_description()', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not write its line exactly once the way the 20260906130000 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  if position('erp.line_description(p_item_id, p_description)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without erp.line_description()', v_sig;
  end if;
end
$add_line$;

-- erp.firm_planned_order, which wrote a purchase line with no description.
do $firm$
declare
  v_sig    constant text := 'erp.firm_planned_order(uuid,text)';
  v_def    text := pg_get_functiondef('erp.firm_planned_order(uuid,text)'::regprocedure);
  v_needle constant text :=
       E'  insert into erp.document_line (\n'
    || E'    tenant_id, document_id, line_no, item_id, quantity, uom_id, required_date)\n'
    || E'  values (v_tenant, v_doc, 1, po.item_id, po.quantity, po.uom_id, po.required_by);\n';
  v_new    constant text :=
       E'  -- Nobody describes a firmed line, so it takes its product''s description.\n'
    || E'  insert into erp.document_line (\n'
    || E'    tenant_id, document_id, line_no, item_id, description, quantity, uom_id, required_date)\n'
    || E'  values (v_tenant, v_doc, 1, po.item_id, erp.line_description(po.item_id, null),\n'
    || E'          po.quantity, po.uom_id, po.required_by);\n';
begin
  if position('erp.line_description(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks erp.line_description()', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not write its line exactly once the way the 20260906133000 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  if position('erp.line_description(po.item_id, null)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without erp.line_description()', v_sig;
  end if;
end
$firm$;

-- erp.add_quote_line, which described every quote line with the product's name.
do $quote_line$
declare
  v_sig    constant text := 'erp.add_quote_line(uuid,text,numeric,numeric)';
  v_def    text := pg_get_functiondef('erp.add_quote_line(uuid,text,numeric,numeric)'::regprocedure);
  v_needle constant text := '(select i.name from erp.item i where i.id = v_item));';
  v_new    constant text := '(select coalesce(i.description, i.name) from erp.item i where i.id = v_item));';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not describe its line with the product''s name exactly once, so it is not the 20260904600000 body', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  if position(v_new in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the product''s description', v_sig;
  end if;
end
$quote_line$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The words on the form
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Every string the product form now hands the dialog, which renders it through
-- ui(). supabase/ci/screen_strings.sh harvests the forms and refuses any
-- string with no row keyed erp_ref.ui_key(text). "Description" has one already;
-- restating it changes nothing.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). The product form''s description field, added when a product began carrying the description its lines take.'
  from (values
    ('Description'),
    ('What the product is, in the words that should appear on orders, receipts and invoices. Lines take it when nobody types one.')
) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- An organisation with finance and sales installed the way a person installs
-- them (a change set, approved by somebody other than its author), products
-- made through the door, a quotation made through the New document form's
-- function and converted into an order. Everything happens inside a block that
-- ends by raising, so nothing it made outlives it; the cases are answered
-- afterwards from what it saw.

create or replace function erp_test.product_description_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_code          text := 'zz-pdesc-' || substr(md5(gen_random_uuid()::text), 1, 8);
  r               record;
  a_admin         uuid := gen_random_uuid();
  a_second        uuid := gen_random_uuid();
  u_second        uuid;
  v_token         text;
  v_cs            uuid;
  v_site          uuid;
  v_cust          uuid;
  v_butter        uuid;
  v_sugar         uuid;
  v_blank         uuid;
  v_long          uuid;
  v_result        jsonb;
  v_quo           uuid;
  v_order         uuid;
  v_batch         uuid;
  v_state         text;
  v_butter_desc   text;
  v_blank_null    boolean;
  v_long_len      integer;
  v_too_long      text;
  v_listed_butter text;
  v_listed_sugar  jsonb;
  v_quote_lines   text[];
  v_sugar_null    boolean;
  v_order_lines   text[];
  v_maintained    text;
  v_import_errors integer;
  v_import_row    text;
begin
  begin
    select * into r from erp.provision_tenant(
      v_code, 'Product Description Suite', 'admin@' || v_code || '.test', 'Description Admin');

    perform set_config('request.jwt.claims',
                       json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);
    perform erp.claim_invitation(r.admin_token);

    -- A second administrator, so a module's change set has somebody other
    -- than its author to approve it.
    v_result := public.erp_invite_principal('second@' || v_code || '.test', 'Description Second');
    u_second := (v_result ->> 'app_user_id')::uuid;
    v_token  := v_result ->> 'token';
    perform erp.grant_role(u_second, 'administrator', null, null, 'the suite needs a second approver');

    v_cs := erp.configure_finance(extract(year from current_date)::integer, 'GBP', r.entity_id);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', a_second, 'role', 'authenticated')::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);
    v_cs := erp.configure_sales(15);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', a_second, 'role', 'authenticated')::text, true);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);

    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active')
    returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', '{}', 'active');

    -- ── Products, through the door the form calls ───────────────────────────
    v_butter := (public.erp_create_item(p_code => 'BUT-05', p_name => 'Butter',
                                        p_description => E'  Unsalted Butter \n') ->> 'item_id')::uuid;
    v_sugar  := (public.erp_create_item(p_code => 'SUG-01', p_name => 'Sugar') ->> 'item_id')::uuid;
    v_blank  := (public.erp_create_item(p_code => 'BLANK-01', p_name => 'Blank',
                                        p_description => E'   \t ') ->> 'item_id')::uuid;
    v_long   := (public.erp_create_item(p_code => 'LONG-01', p_name => 'Long',
                                        p_description => ' ' || repeat('x', 1000) || ' ') ->> 'item_id')::uuid;
    begin
      perform public.erp_create_item(p_code => 'LONG-02', p_name => 'Longer',
                                     p_description => repeat('x', 1001));
      v_too_long := 'accepted';
    exception when others then
      v_too_long := left(sqlerrm, 120);
    end;

    select i.description into v_butter_desc from erp.item i where i.id = v_butter;
    select i.description is null into v_blank_null from erp.item i where i.id = v_blank;
    select length(i.description) into v_long_len from erp.item i where i.id = v_long;

    select x.el ->> 'description' into v_listed_butter
      from jsonb_array_elements(public.erp_items(null, 500)) as x(el) where x.el ->> 'code' = 'BUT-05';
    select x.el into v_listed_sugar
      from jsonb_array_elements(public.erp_items(null, 500)) as x(el) where x.el ->> 'code' = 'SUG-01';

    -- ── A quotation, through the New document form's function ───────────────
    v_result := erp.create_document_full(
      'quotation', v_cust, v_site, null, null, null,
      jsonb_build_array(
        jsonb_build_object('item_id', v_butter, 'quantity', 2, 'unit_price_minor', 250),
        jsonb_build_object('item_id', v_butter, 'quantity', 1, 'unit_price_minor', 250,
                           'description', 'Butter for the bakery'),
        jsonb_build_object('item_id', v_butter, 'quantity', 1, 'unit_price_minor', 250,
                           'description', '   '),
        jsonb_build_object('item_id', v_sugar, 'quantity', 5, 'unit_price_minor', 90)));
    v_quo := (v_result ->> 'document_id')::uuid;

    -- A line added on its own, through the door, with and without words.
    perform public.erp_add_document_line(v_quo, v_butter, 3, 250);
    perform public.erp_add_document_line(v_quo, v_butter, 1, 250, 'Salted butter, as asked');

    select array_agg(coalesce(l.description, '(none)') order by l.line_no) into v_quote_lines
      from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = v_quo;
    select bool_and(l.description is null) into v_sugar_null
      from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = v_quo and l.item_id = v_sugar;

    -- ── The order made from it ───────────────────────────────────────────────
    perform erp.transition_document(v_quo, 'send');
    v_result := erp.convert_document(v_quo);
    v_order := (v_result ->> 'document_id')::uuid;
    select array_agg(coalesce(l.description, '(none)') order by l.line_no) into v_order_lines
      from erp.document_line l where l.tenant_id = r.tenant_id and l.document_id = v_order;

    -- ── Afterwards: the maintained fields, and an import ─────────────────────
    perform erp.write_master_fields('item', v_sugar,
                                    jsonb_build_object('description', E'  Caster sugar\n'));
    select i.description into v_maintained from erp.item i where i.id = v_sugar;

    v_batch := erp.stage_import('item',
      jsonb_build_array(jsonb_build_object('code', 'SUG-01', 'description', 'Caster sugar, 1 kg')),
      v_code || '-import');
    v_import_errors := erp.validate_import(v_batch);
    select ir.action || ' ' || ir.findings::text into v_import_row
      from erp.import_row ir where ir.tenant_id = r.tenant_id and ir.import_batch_id = v_batch;

    raise exception 'ZZ_PRODUCT_DESCRIPTION_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_PRODUCT_DESCRIPTION_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
  end;

  case_name := 'a product created with a description keeps it, trimmed';
  passed := v_state is null and v_butter_desc = 'Unsalted Butter';
  detail := coalesce(v_state, format('stored %L', v_butter_desc));
  return next;

  case_name := 'a blank description is kept as none';
  passed := v_state is null and v_blank_null is true;
  detail := coalesce(v_state, format('stored as none: %s', coalesce(v_blank_null::text, 'unknown')));
  return next;

  case_name := 'a description holds 1000 characters after trimming, and one longer is refused by name';
  passed := v_state is null and v_long_len = 1000
        and v_too_long like 'CLOVEERP_PRODUCT_DESCRIPTION_TOO_LONG%';
  detail := coalesce(v_state, format('%s characters kept; 1001 answered %s',
                                     coalesce(v_long_len::text, 'none'), coalesce(v_too_long, 'nothing')));
  return next;

  case_name := 'the product list returns each product''s description';
  passed := v_state is null and v_listed_butter = 'Unsalted Butter'
        and v_listed_sugar ? 'description' and v_listed_sugar -> 'description' = 'null'::jsonb;
  detail := coalesce(v_state, format('BUT-05 %L, SUG-01 %s', v_listed_butter,
                                     coalesce(v_listed_sugar -> 'description', '"(no key)"'::jsonb)::text));
  return next;

  case_name := 'a line saved with no description takes the product''s';
  passed := v_state is null and v_quote_lines[1] = 'Unsalted Butter';
  detail := coalesce(v_state, array_to_string(v_quote_lines, ' | '));
  return next;

  case_name := 'a description typed on the line wins';
  passed := v_state is null and v_quote_lines[2] = 'Butter for the bakery';
  detail := coalesce(v_state, array_to_string(v_quote_lines, ' | '));
  return next;

  case_name := 'a blank description on the line takes the product''s';
  passed := v_state is null and v_quote_lines[3] = 'Unsalted Butter';
  detail := coalesce(v_state, array_to_string(v_quote_lines, ' | '));
  return next;

  case_name := 'a product with no description leaves the line without one';
  passed := v_state is null and v_sugar_null is true and v_quote_lines[4] = '(none)';
  detail := coalesce(v_state, array_to_string(v_quote_lines, ' | '));
  return next;

  case_name := 'a line added on its own takes the product''s description, and a typed one wins';
  passed := v_state is null and v_quote_lines[5] = 'Unsalted Butter'
        and v_quote_lines[6] = 'Salted butter, as asked';
  detail := coalesce(v_state, array_to_string(v_quote_lines, ' | '));
  return next;

  case_name := 'the order made from the quotation keeps every line''s description';
  passed := v_state is null and cardinality(v_order_lines) = 6 and v_order_lines = v_quote_lines;
  detail := coalesce(v_state, array_to_string(v_order_lines, ' | '));
  return next;

  case_name := 'a product''s description is changed afterwards through the maintained fields, trimmed';
  passed := v_state is null and v_maintained = 'Caster sugar';
  detail := coalesce(v_state, format('stored %L', v_maintained));
  return next;

  case_name := 'an import may carry a product''s description';
  passed := v_state is null and v_import_errors = 0 and v_import_row = 'update []';
  detail := coalesce(v_state, format('%s error(s); row %s', coalesce(v_import_errors::text, 'no'),
                                     coalesce(v_import_row, 'not staged')));
  return next;
end;
$$;

revoke all on function erp_test.product_description_suite() from public, anon, authenticated;

create or replace function erp_test.assert_product_description_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  create temp table if not exists _product_description on commit drop as
    select * from erp_test.product_description_suite();
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from _product_description s;
  drop table _product_description;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PRODUCT_DESCRIPTION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_PRODUCT_DESCRIPTION_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('product description: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.assert_product_description_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

select erp_test.assert_product_description_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
