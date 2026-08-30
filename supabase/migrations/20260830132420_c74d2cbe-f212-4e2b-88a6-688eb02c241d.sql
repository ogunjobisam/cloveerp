-- =============================================================================
-- Addendum B, phase 3: classification and code composition
--
-- Identity stays the surrogate key. The composed code is a derived label: it
-- is proposed from a versioned template, shown before commit, and recorded
-- with the template version that produced it. When an attribute later moves
-- away from the code, the platform says so rather than re-coding the item
-- behind the reader's back.
-- =============================================================================

create table erp.classification_axis (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  code          text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
  name          text not null,
  name_key      text,
  -- Null means the axis applies to every item class.
  item_classes  text[],
  is_mandatory  boolean not null default false,
  seq           integer not null default 100,
  valid_from    date not null default current_date,
  valid_to      date,
  status        erp.record_status not null default 'active',
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, code),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.classification_axis (tenant_id, status);

comment on table erp.classification_axis is
  'Addendum B 6: one dimension of product meaning - form, grade, pack size. '
  'Tenant-defined; no code path knows any particular axis.';

create table erp.classification_value (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  axis_id       uuid not null references erp.classification_axis(id) on delete cascade,
  code          text not null check (code ~ '^[A-Z0-9][A-Z0-9_.-]*$'),
  name          text not null,
  name_key      text,
  -- What the code template uses. Shorter than the code, and fixed once used.
  abbreviation  text not null check (abbreviation ~ '^[A-Z0-9]+$'),
  parent_value_id uuid references erp.classification_value(id) on delete restrict,
  valid_from    date not null default current_date,
  valid_to      date,
  status        erp.record_status not null default 'active',
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, axis_id, code),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.classification_value (tenant_id, axis_id, status);

create table erp.item_classification (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  item_id      uuid not null references erp.item(id) on delete cascade,
  axis_id      uuid not null references erp.classification_axis(id) on delete restrict,
  value_id     uuid not null references erp.classification_value(id) on delete restrict,
  valid_from   date not null default current_date,
  valid_to     date,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  check (valid_to is null or valid_to > valid_from)
);

create unique index item_classification_one_in_force
  on erp.item_classification (tenant_id, item_id, axis_id)
  where status = 'active' and valid_to is null;

create index on erp.item_classification (tenant_id, item_id);

-- -----------------------------------------------------------------------------
-- Code templates
--
-- segments is an ordered array. Each element is one of:
--   {"kind":"axis","axis_code":"FORM","length":3,"pad":"X","required":true}
--   {"kind":"literal","text":"-"}
--   {"kind":"sequence","length":4,"pad":"0"}
--   {"kind":"check"}                       -- modulo-36 check character
-- -----------------------------------------------------------------------------

create table erp.code_template (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  code          text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
  name          text not null,
  name_key      text,
  entity_id     uuid,
  item_classes  text[],
  version       integer not null default 1,
  segments      jsonb not null default '[]'::jsonb,
  casing        text not null default 'upper' check (casing in ('upper', 'lower', 'none')),
  next_value    bigint not null default 1,
  valid_from    date not null default current_date,
  valid_to      date,
  status        erp.record_status not null default 'active',
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, code, version),
  check (jsonb_typeof(segments) = 'array'),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.code_template (tenant_id, status);

-- The code an item carries, and the template version that produced it. Append
-- only: a re-code is a new row, and the old one stays as evidence.
create table erp.item_code_assignment (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  item_id           uuid not null references erp.item(id) on delete cascade,
  composed_code     text not null,
  template_id       uuid references erp.code_template(id) on delete set null,
  template_code     text,
  template_version  integer,
  classification    jsonb not null default '{}'::jsonb,
  assigned_at       timestamptz not null default now(),
  assigned_by       uuid,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id)
);

create index on erp.item_code_assignment (tenant_id, item_id, assigned_at desc);

select erp_meta.register_table('erp', 'classification_axis', 'tenant_scoped');
select erp_meta.register_table('erp', 'classification_value', 'tenant_scoped');
select erp_meta.register_table('erp', 'item_classification', 'tenant_scoped');
select erp_meta.register_table('erp', 'code_template', 'tenant_scoped');
select erp_meta.register_table('erp', 'item_code_assignment', 'tenant_scoped_append_only');

do $$
declare t text;
begin
  foreach t in array array['classification_axis', 'classification_value',
                           'item_classification', 'code_template',
                           'item_code_assignment'] loop
    execute format(
      'create trigger t_%1$s_attribution before insert or update on erp.%1$s '
      'for each row execute function erp.touch_attribution()', t);
    execute format(
      'create trigger t_%1$s_freeze before update on erp.%1$s '
      'for each row execute function erp.freeze_tenant_id()', t);
  end loop;
end;
$$;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, is_current)
values
  ('item.classified', 1, 'item', 'master_data', 'event.item.classified',
   'An item was placed on a classification axis.', true),
  ('item.code_assigned', 1, 'item', 'master_data', 'event.item.code_assigned',
   'A composed code was derived from a template and recorded against an item.', true),
  ('item.code_diverged', 1, 'item', 'master_data', 'event.item.code_diverged',
   'An item classification no longer agrees with the code the item carries.', true)
on conflict (code, version) do nothing;

-- -----------------------------------------------------------------------------
-- Composition
-- -----------------------------------------------------------------------------

create or replace function erp.check_character(p_body text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_alphabet constant text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  v_sum int := 0;
  v_pos int;
  i int;
begin
  for i in 1 .. length(p_body) loop
    v_pos := position(substr(upper(p_body), i, 1) in v_alphabet) - 1;
    if v_pos >= 0 then
      v_sum := v_sum + v_pos * (i + 1);
    end if;
  end loop;
  return substr(v_alphabet, (v_sum % 36) + 1, 1);
end;
$$;

/**
 * Compose a code from a template and a set of axis codes.
 *
 * p_classification is {"AXIS_CODE": "VALUE_CODE"}. Sequence segments consume a
 * number only when p_consume is true, so a preview never burns one.
 */
create or replace function erp.compose_code(
  p_template_id    uuid,
  p_classification jsonb,
  p_consume        boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  t          erp.code_template%rowtype;
  seg        jsonb;
  v_out      text := '';
  v_piece    text;
  v_axis     text;
  v_value    text;
  v_abbrev   text;
  v_seq      bigint;
  v_missing  text[] := '{}';
begin
  select * into t from erp.code_template
   where tenant_id = v_tenant and id = p_template_id
     for update;

  if not found then
    raise exception 'ERPWARE_CODE_TEMPLATE_NOT_FOUND: %', p_template_id
      using errcode = '23503';
  end if;

  for seg in select * from jsonb_array_elements(t.segments) loop
    v_piece := null;

    case coalesce(seg->>'kind', 'literal')
      when 'literal' then
        v_piece := coalesce(seg->>'text', '');

      when 'axis' then
        v_axis  := seg->>'axis_code';
        v_value := coalesce(p_classification, '{}'::jsonb) ->> v_axis;

        if v_value is null then
          if coalesce((seg->>'required')::boolean, true) then
            v_missing := v_missing || v_axis;
          end if;
          v_piece := repeat(coalesce(seg->>'pad', 'X'),
                            coalesce((seg->>'length')::int, 1));
        else
          select cv.abbreviation into v_abbrev
            from erp.classification_value cv
            join erp.classification_axis ca on ca.id = cv.axis_id
           where cv.tenant_id = v_tenant
             and ca.tenant_id = v_tenant
             and ca.code = v_axis
             and cv.code = v_value
             and cv.status = 'active';

          if v_abbrev is null then
            v_missing := v_missing || v_axis;
            v_piece := repeat(coalesce(seg->>'pad', 'X'),
                              coalesce((seg->>'length')::int, 1));
          else
            v_piece := v_abbrev;
          end if;
        end if;

      when 'sequence' then
        if p_consume then
          v_seq := t.next_value;
          update erp.code_template set next_value = t.next_value + 1, updated_at = now()
           where id = t.id;
        else
          v_seq := t.next_value;
        end if;
        v_piece := lpad(v_seq::text, coalesce((seg->>'length')::int, 4),
                        coalesce(seg->>'pad', '0'));

      when 'check' then
        v_piece := erp.check_character(v_out);

      else
        v_piece := coalesce(seg->>'text', '');
    end case;

    -- Fixed-length segments are padded or truncated so the shape of a code
    -- never depends on how long somebody's abbreviation happened to be.
    if (seg->>'length') is not null and coalesce(seg->>'kind','literal') <> 'literal' then
      v_piece := rpad(left(v_piece, (seg->>'length')::int), (seg->>'length')::int,
                      coalesce(seg->>'pad', 'X'));
    end if;

    v_out := v_out || coalesce(v_piece, '');
  end loop;

  v_out := case t.casing when 'upper' then upper(v_out)
                         when 'lower' then lower(v_out)
                         else v_out end;

  return jsonb_build_object(
    'code', v_out,
    'template_id', t.id,
    'template_code', t.code,
    'template_version', t.version,
    'missing_axes', to_jsonb(v_missing),
    'complete', cardinality(v_missing) = 0);
end;
$$;

-- -----------------------------------------------------------------------------
-- Axes and vocabularies
-- -----------------------------------------------------------------------------

create or replace function public.erp_classification_axes()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(x order by x->>'seq', x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'axis_id', a.id, 'code', a.code, 'name', a.name, 'name_key', a.name_key,
      'item_classes', coalesce(to_jsonb(a.item_classes), 'null'::jsonb),
      'is_mandatory', a.is_mandatory, 'seq', a.seq,
      'value_count', (select count(*) from erp.classification_value v
                       where v.tenant_id = a.tenant_id and v.axis_id = a.id
                         and v.status = 'active'),
      'valid_from', a.valid_from, 'valid_to', a.valid_to, 'status', a.status) as x
      from erp.classification_axis a
     where a.tenant_id = erp.current_tenant_id()) q;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_classification_axis(
  p_code         text,
  p_name         text,
  p_is_mandatory boolean default false,
  p_item_classes text default null,
  p_seq          integer default 100,
  p_name_key     text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_classes text[];
begin
  perform erp.authorise('master_data.write');

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select a.id into v_id from erp.classification_axis a
   where a.tenant_id = v_tenant and a.code = upper(p_code);

  if v_id is null then
    insert into erp.classification_axis (
      tenant_id, code, name, name_key, item_classes, is_mandatory, seq)
    values (v_tenant, upper(p_code), p_name, p_name_key, v_classes,
            coalesce(p_is_mandatory, false), coalesce(p_seq, 100))
    returning id into v_id;
  else
    update erp.classification_axis
       set name = p_name, name_key = coalesce(p_name_key, name_key),
           item_classes = v_classes,
           is_mandatory = coalesce(p_is_mandatory, is_mandatory),
           seq = coalesce(p_seq, seq), updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('axis_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_classification_values(p_axis_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(x order by x->>'axis_code', x->>'code'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'value_id', v.id, 'axis_id', v.axis_id, 'axis_code', a.code,
      'code', v.code, 'name', v.name, 'abbreviation', v.abbreviation,
      'parent_code', pv.code,
      'valid_from', v.valid_from, 'valid_to', v.valid_to, 'status', v.status) as x
      from erp.classification_value v
      join erp.classification_axis a on a.id = v.axis_id and a.tenant_id = v.tenant_id
      left join erp.classification_value pv
        on pv.id = v.parent_value_id and pv.tenant_id = v.tenant_id
     where v.tenant_id = erp.current_tenant_id()
       and (p_axis_id is null or v.axis_id = p_axis_id)) q;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_classification_value(
  p_axis_id      uuid,
  p_code         text,
  p_name         text,
  p_abbreviation text,
  p_parent_value_id uuid default null,
  p_name_key     text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_used   boolean;
begin
  perform erp.authorise('master_data.write');

  select v.id into v_id from erp.classification_value v
   where v.tenant_id = v_tenant and v.axis_id = p_axis_id and v.code = upper(p_code);

  if v_id is null then
    insert into erp.classification_value (
      tenant_id, axis_id, code, name, name_key, abbreviation, parent_value_id)
    values (v_tenant, p_axis_id, upper(p_code), p_name, p_name_key,
            upper(p_abbreviation), p_parent_value_id)
    returning id into v_id;
  else
    -- An abbreviation that has already produced a code cannot move: the codes
    -- it produced would stop meaning what they say.
    select exists (select 1 from erp.item_classification ic
                    where ic.tenant_id = v_tenant and ic.value_id = v_id)
      into v_used;

    if v_used and upper(p_abbreviation) is distinct from
         (select abbreviation from erp.classification_value where id = v_id) then
      raise exception
        'ERPWARE_ABBREVIATION_IN_USE: items already carry codes built from this abbreviation'
        using errcode = '23514';
    end if;

    update erp.classification_value
       set name = p_name, name_key = coalesce(p_name_key, name_key),
           abbreviation = upper(p_abbreviation),
           parent_value_id = p_parent_value_id, updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('value_id', v_id, 'code', upper(p_code));
end;
$$;

-- -----------------------------------------------------------------------------
-- Classifying an item
-- -----------------------------------------------------------------------------

create or replace function public.erp_classify_item(
  p_item_id    uuid,
  p_axis_id    uuid,
  p_value_id   uuid,
  p_valid_from date default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from   date := coalesce(p_valid_from, current_date);
  v_id     uuid;
begin
  perform erp.authorise('master_data.write');

  if not exists (select 1 from erp.classification_value v
                  where v.tenant_id = v_tenant and v.id = p_value_id
                    and v.axis_id = p_axis_id) then
    raise exception 'ERPWARE_VALUE_NOT_ON_AXIS: that value belongs to a different axis'
      using errcode = '23514';
  end if;

  update erp.item_classification
     set valid_to = v_from, status = 'retired', updated_at = now()
   where tenant_id = v_tenant and item_id = p_item_id and axis_id = p_axis_id
     and status = 'active' and valid_to is null;

  insert into erp.item_classification (
    tenant_id, item_id, axis_id, value_id, valid_from)
  values (v_tenant, p_item_id, p_axis_id, p_value_id, v_from)
  returning id into v_id;

  perform erp.append_event('item.classified', 'item', p_item_id,
    jsonb_build_object('axis_id', p_axis_id, 'value_id', p_value_id,
                       'valid_from', v_from));

  return jsonb_build_object('classification_id', v_id);
end;
$$;

create or replace function public.erp_item_classification(p_item_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(x order by x->>'axis_code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'classification_id', ic.id, 'axis_id', ic.axis_id, 'axis_code', a.code,
      'axis_name', a.name, 'value_id', ic.value_id, 'value_code', v.code,
      'value_name', v.name, 'abbreviation', v.abbreviation,
      'valid_from', ic.valid_from, 'valid_to', ic.valid_to, 'status', ic.status) as x
      from erp.item_classification ic
      join erp.classification_axis a on a.id = ic.axis_id and a.tenant_id = ic.tenant_id
      join erp.classification_value v on v.id = ic.value_id and v.tenant_id = ic.tenant_id
     where ic.tenant_id = erp.current_tenant_id()
       and ic.item_id = p_item_id
       and ic.status = 'active') q;
  return v_out;
end;
$$;

/** Items missing an axis their class makes mandatory. */
create or replace function public.erp_classification_gaps(p_limit integer default 200)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(x order by x->>'item_code', x->>'axis_code'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'item_id', i.id, 'item_code', i.code, 'item_name', i.name,
      'item_class', i.item_class,
      'axis_id', a.id, 'axis_code', a.code, 'axis_name', a.name) as x
      from erp.item i
      join erp.classification_axis a
        on a.tenant_id = i.tenant_id
       and a.status = 'active'
       and a.is_mandatory
       and (a.item_classes is null or i.item_class = any(a.item_classes))
     where i.tenant_id = erp.current_tenant_id()
       and i.status = 'active'
       and not exists (
         select 1 from erp.item_classification ic
          where ic.tenant_id = i.tenant_id and ic.item_id = i.id
            and ic.axis_id = a.id and ic.status = 'active' and ic.valid_to is null)
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)) q;
  return v_out;
end;
$$;

-- -----------------------------------------------------------------------------
-- Templates
-- -----------------------------------------------------------------------------

create or replace function public.erp_code_templates()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(x order by x->>'code', x->>'version'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'template_id', t.id, 'code', t.code, 'name', t.name, 'version', t.version,
      'item_classes', coalesce(to_jsonb(t.item_classes), 'null'::jsonb),
      'segments', t.segments, 'casing', t.casing, 'next_value', t.next_value,
      'valid_from', t.valid_from, 'valid_to', t.valid_to, 'status', t.status) as x
      from erp.code_template t
     where t.tenant_id = erp.current_tenant_id()) q;
  return v_out;
end;
$$;

/**
 * Write a template. Editing a template that has already produced codes raises
 * a new version rather than rewriting the one those codes came from.
 */
create or replace function public.erp_upsert_code_template(
  p_code         text,
  p_name         text,
  p_segments     jsonb,
  p_item_classes text default null,
  p_casing       text default 'upper',
  p_entity_id    uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_classes text[];
  v_latest  erp.code_template%rowtype;
  v_used    boolean := false;
  v_id      uuid;
  v_version integer := 1;
begin
  perform erp.authorise('master_data.write');

  if jsonb_typeof(coalesce(p_segments, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_segments) = 0 then
    raise exception 'ERPWARE_TEMPLATE_EMPTY: a template needs at least one segment'
      using errcode = '23514';
  end if;

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select * into v_latest from erp.code_template t
   where t.tenant_id = v_tenant and t.code = upper(p_code)
   order by t.version desc limit 1;

  if v_latest.id is not null then
    select exists (select 1 from erp.item_code_assignment a
                    where a.tenant_id = v_tenant and a.template_id = v_latest.id)
      into v_used;
  end if;

  if v_latest.id is null then
    insert into erp.code_template (
      tenant_id, code, name, segments, item_classes, casing, entity_id, version)
    values (v_tenant, upper(p_code), p_name, p_segments, v_classes,
            coalesce(p_casing, 'upper'), p_entity_id, 1)
    returning id into v_id;
  elsif v_used then
    update erp.code_template set valid_to = current_date, status = 'retired',
                                 updated_at = now()
     where id = v_latest.id;
    v_version := v_latest.version + 1;
    insert into erp.code_template (
      tenant_id, code, name, segments, item_classes, casing, entity_id, version,
      next_value)
    values (v_tenant, upper(p_code), p_name, p_segments, v_classes,
            coalesce(p_casing, 'upper'), p_entity_id, v_version, v_latest.next_value)
    returning id into v_id;
  else
    update erp.code_template
       set name = p_name, segments = p_segments, item_classes = v_classes,
           casing = coalesce(p_casing, casing), entity_id = p_entity_id,
           updated_at = now()
     where id = v_latest.id
    returning id, version into v_id, v_version;
  end if;

  return jsonb_build_object('template_id', v_id, 'code', upper(p_code),
                            'version', v_version);
end;
$$;

/** What the code would be. Consumes nothing. */
create or replace function public.erp_preview_item_code(
  p_template_id    uuid,
  p_classification jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  v_out := erp.compose_code(p_template_id, coalesce(p_classification, '{}'::jsonb), false);
  return v_out || jsonb_build_object(
    'already_used', exists (
      select 1 from erp.item i
       where i.tenant_id = erp.current_tenant_id() and i.code = v_out->>'code'));
end;
$$;

/**
 * Create an item the guided way: classification first, then the composed code.
 *
 * p_classification is {"AXIS_CODE":"VALUE_CODE"}. Mandatory axes for the class
 * must all be present, because a code with a placeholder in it is a code
 * somebody will have to correct later.
 */
create or replace function public.erp_create_classified_item(
  p_name                text,
  p_item_class          text,
  p_template_id         uuid,
  p_classification      jsonb default '{}'::jsonb,
  p_is_batch_controlled boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_composed jsonb;
  v_code     text;
  v_item     uuid;
  v_missing  text[];
  r          record;
begin
  perform erp.authorise('master_data.write');

  select array_agg(a.code) into v_missing
    from erp.classification_axis a
   where a.tenant_id = v_tenant and a.status = 'active' and a.is_mandatory
     and (a.item_classes is null or p_item_class = any(a.item_classes))
     and coalesce(p_classification, '{}'::jsonb) ->> a.code is null;

  if v_missing is not null then
    raise exception
      'ERPWARE_CLASSIFICATION_INCOMPLETE: these axes are required for this class: %',
      array_to_string(v_missing, ', ')
      using errcode = '23514';
  end if;

  v_composed := erp.compose_code(p_template_id, coalesce(p_classification, '{}'::jsonb), true);
  v_code := v_composed->>'code';

  if not coalesce((v_composed->>'complete')::boolean, false) then
    raise exception 'ERPWARE_CODE_INCOMPLETE: the template needs %',
      v_composed->>'missing_axes' using errcode = '23514';
  end if;

  if exists (select 1 from erp.item i where i.tenant_id = v_tenant and i.code = v_code) then
    raise exception 'ERPWARE_CODE_TAKEN: % is already an item code', v_code
      using errcode = '23505';
  end if;

  insert into erp.item (tenant_id, code, name, item_class, is_batch_controlled)
  values (v_tenant, v_code, p_name, p_item_class, coalesce(p_is_batch_controlled, false))
  returning id into v_item;

  for r in
    select a.id as axis_id, v.id as value_id
      from jsonb_each_text(coalesce(p_classification, '{}'::jsonb)) as kv(axis_code, value_code)
      join erp.classification_axis a
        on a.tenant_id = v_tenant and a.code = kv.axis_code
      join erp.classification_value v
        on v.tenant_id = v_tenant and v.axis_id = a.id and v.code = kv.value_code
  loop
    insert into erp.item_classification (tenant_id, item_id, axis_id, value_id)
    values (v_tenant, v_item, r.axis_id, r.value_id);
  end loop;

  insert into erp.item_code_assignment (
    tenant_id, item_id, composed_code, template_id, template_code, template_version,
    classification, assigned_by)
  values (v_tenant, v_item, v_code, p_template_id, v_composed->>'template_code',
          (v_composed->>'template_version')::int, coalesce(p_classification, '{}'::jsonb),
          erp.current_app_user_id());

  perform erp.append_event('item.code_assigned', 'item', v_item, v_composed);

  return jsonb_build_object('item_id', v_item, 'code', v_code,
                            'template_version', v_composed->>'template_version');
end;
$$;

/**
 * Items whose classification has moved away from the code they carry.
 *
 * The platform reports; it does not re-code. Renaming an item that other
 * people, systems and printed labels already refer to is a decision, not a
 * side effect.
 */
create or replace function public.erp_code_divergences(p_limit integer default 200)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');

  select coalesce(jsonb_agg(x order by x->>'item_code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'item_id', i.id, 'item_code', i.code, 'item_name', i.name,
      'template_code', a.template_code, 'template_version', a.template_version,
      'coded_as', a.classification, 'classified_as', cur.classification,
      'assigned_at', a.assigned_at) as x
      from erp.item i
      join lateral (
        select * from erp.item_code_assignment ia
         where ia.tenant_id = i.tenant_id and ia.item_id = i.id
         order by ia.assigned_at desc limit 1) a on true
      join lateral (
        select coalesce(jsonb_object_agg(ax.code, cv.code), '{}'::jsonb) as classification
          from erp.item_classification ic
          join erp.classification_axis ax on ax.id = ic.axis_id and ax.tenant_id = ic.tenant_id
          join erp.classification_value cv on cv.id = ic.value_id and cv.tenant_id = ic.tenant_id
         where ic.tenant_id = i.tenant_id and ic.item_id = i.id
           and ic.status = 'active' and ic.valid_to is null) cur on true
     where i.tenant_id = erp.current_tenant_id()
       and i.status = 'active'
       and cur.classification is distinct from a.classification
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)) q;

  return v_out;
end;
$$;

create or replace function public.erp_item_code_assignments(p_limit integer default 200)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(x order by x->>'assigned_at' desc), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'assignment_id', a.id, 'item_id', a.item_id, 'item_name', i.name,
      'composed_code', a.composed_code, 'template_code', a.template_code,
      'template_version', a.template_version, 'classification', a.classification,
      'assigned_at', a.assigned_at, 'assigned_by', u.display_name) as x
      from erp.item_code_assignment a
      left join erp.item i on i.id = a.item_id and i.tenant_id = a.tenant_id
      left join erp.app_user u on u.id = a.assigned_by and u.tenant_id = a.tenant_id
     where a.tenant_id = erp.current_tenant_id()
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)) q;
  return v_out;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_classification_axes()',
    'public.erp_upsert_classification_axis(text,text,boolean,text,integer,text)',
    'public.erp_classification_values(uuid)',
    'public.erp_upsert_classification_value(uuid,text,text,text,uuid,text)',
    'public.erp_classify_item(uuid,uuid,uuid,date)',
    'public.erp_item_classification(uuid)',
    'public.erp_classification_gaps(integer)',
    'public.erp_code_templates()',
    'public.erp_upsert_code_template(text,text,jsonb,text,text,uuid)',
    'public.erp_preview_item_code(uuid,jsonb)',
    'public.erp_create_classified_item(text,text,uuid,jsonb,boolean)',
    'public.erp_code_divergences(integer)',
    'public.erp_item_code_assignments(integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

select erp.apply_row_security();