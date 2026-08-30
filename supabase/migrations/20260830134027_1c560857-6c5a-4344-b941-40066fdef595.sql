-- Configuration interchange: download and upload for the six-surface configuration
-- objects, a demo preset, and a release-print readiness view.

create or replace function erp.config_object_columns(p_object_type text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_object_type
    when 'classification_axis'  then array['code','name','name_key','is_mandatory','item_classes','seq']
    when 'classification_value' then array['axis_code','code','name','name_key','abbreviation','parent_code']
    when 'code_template'        then array['code','name','entity_code','item_classes','casing','segments']
    when 'item_supplier'        then array['item_code','supplier_code','site_code','preference_rank','is_default','split_pct','is_approved_for_use','supplier_item_code','lead_time_days','min_order_quantity']
    when 'release_area'         then array['site_code','code','name','location_code','replenishment_mode','channel_code','order_type_code','item_classes','min_quantity','max_quantity','ageing_hours','gate_printing']
    else null
  end;
$$;

/** The column order a download uses and an upload expects, for one object. */
create or replace function public.erp_configuration_columns(p_object_type text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  select coalesce(jsonb_agg(jsonb_build_object(
           'object_type', t, 'columns', to_jsonb(erp.config_object_columns(t)))
         order by t), '[]'::jsonb)
    into v_out
    from unnest(array['classification_axis','classification_value','code_template',
                      'item_supplier','release_area']) t
   where p_object_type is null or t = p_object_type;
  return v_out;
end;
$$;

/** Everything the tenant has configured for one object, ready to be written out. */
create or replace function public.erp_export_configuration(p_object_type text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_out    jsonb;
begin
  perform erp.authorise('master_data.read');

  if erp.config_object_columns(p_object_type) is null then
    raise exception 'ERPWARE_UNKNOWN_CONFIG_OBJECT: % cannot be exported', p_object_type
      using errcode = '23503',
      hint = 'Ask erp_configuration_columns() for the objects that can.';
  end if;

  if p_object_type = 'classification_axis' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'code', a.code, 'name', a.name, 'name_key', a.name_key,
             'is_mandatory', a.is_mandatory,
             'item_classes', array_to_string(a.item_classes, ','),
             'seq', a.seq) order by a.seq, a.code), '[]'::jsonb)
      into v_out from erp.classification_axis a
     where a.tenant_id = v_tenant and a.status = 'active';

  elsif p_object_type = 'classification_value' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'axis_code', ax.code, 'code', v.code, 'name', v.name,
             'name_key', v.name_key, 'abbreviation', v.abbreviation,
             'parent_code', pv.code) order by ax.code, v.code), '[]'::jsonb)
      into v_out
      from erp.classification_value v
      join erp.classification_axis ax on ax.id = v.axis_id and ax.tenant_id = v.tenant_id
      left join erp.classification_value pv on pv.id = v.parent_value_id
     where v.tenant_id = v_tenant and v.status = 'active';

  elsif p_object_type = 'code_template' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'code', t.code, 'name', t.name, 'entity_code', e.code,
             'item_classes', array_to_string(t.item_classes, ','),
             'casing', t.casing, 'segments', t.segments::text)
           order by t.code), '[]'::jsonb)
      into v_out
      from erp.code_template t
      left join erp.entity e on e.id = t.entity_id
     where t.tenant_id = v_tenant and t.status = 'active';

  elsif p_object_type = 'item_supplier' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'item_code', i.code, 'supplier_code', p.code, 'site_code', s.code,
             'preference_rank', x.preference_rank, 'is_default', x.is_default,
             'split_pct', x.split_pct, 'is_approved_for_use', x.is_approved_for_use,
             'supplier_item_code', x.supplier_item_code,
             'lead_time_days', x.lead_time_days,
             'min_order_quantity', x.min_order_quantity)
           order by i.code, x.preference_rank), '[]'::jsonb)
      into v_out
      from erp.item_supplier x
      join erp.item i on i.id = x.item_id
      join erp.party p on p.id = x.party_id
      left join erp.site s on s.id = x.site_id
     where x.tenant_id = v_tenant and x.status = 'active';

  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'site_code', s.code, 'code', a.code, 'name', a.name,
             'location_code', l.code, 'replenishment_mode', a.replenishment_mode,
             'channel_code', a.channel_code, 'order_type_code', a.order_type_code,
             'item_classes', array_to_string(a.item_classes, ','),
             'min_quantity', a.min_quantity, 'max_quantity', a.max_quantity,
             'ageing_hours', a.ageing_hours, 'gate_printing', a.gate_printing)
           order by s.code, a.code), '[]'::jsonb)
      into v_out
      from erp.release_area a
      join erp.site s on s.id = a.site_id
      left join erp.location l on l.id = a.location_id
     where a.tenant_id = v_tenant and a.status = 'active';
  end if;

  return v_out;
end;
$$;

/**
 * Uploading configuration.
 *
 * A dry run resolves every reference and reports what would happen without
 * writing anything; a real run applies each row through the same function a
 * keyed entry would use, so nothing skips the rules. One bad row is reported
 * and the rest still load — the outcome is per row, and says so.
 */
create or replace function public.erp_import_configuration(
  p_object_type text,
  p_rows        jsonb,
  p_dry_run     boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_row    jsonb;
  v_res    jsonb := '[]'::jsonb;
  v_ok     int := 0;
  v_bad    int := 0;
  v_axis   uuid;
  v_parent uuid;
  v_item   uuid;
  v_party  uuid;
  v_site   uuid;
  v_loc    uuid;
  v_entity uuid;
  v_msg    text;
  v_label  text;
begin
  perform erp.authorise('master_data.import');

  if erp.config_object_columns(p_object_type) is null then
    raise exception 'ERPWARE_UNKNOWN_CONFIG_OBJECT: % cannot be imported', p_object_type
      using errcode = '23503';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'ERPWARE_EMPTY_IMPORT: an import of no rows' using errcode = '23514';
  end if;

  for r in select (e.ordinality)::int as n, e.value as row
             from jsonb_array_elements(p_rows) with ordinality e(value, ordinality)
  loop
    v_row := r.row;
    v_msg := null;
    v_label := coalesce(v_row ->> 'code', v_row ->> 'item_code', '(no code)');

    begin
      if p_object_type = 'classification_axis' then
        if coalesce(v_row ->> 'code', '') = '' then
          raise exception 'no code, so this row names no axis';
        end if;
        if not p_dry_run then
          perform public.erp_upsert_classification_axis(
            v_row ->> 'code', coalesce(v_row ->> 'name', v_row ->> 'code'),
            coalesce((v_row ->> 'is_mandatory')::boolean, false),
            nullif(v_row ->> 'item_classes', ''),
            coalesce((v_row ->> 'seq')::int, 100),
            nullif(v_row ->> 'name_key', ''));
        end if;

      elsif p_object_type = 'classification_value' then
        select a.id into v_axis from erp.classification_axis a
         where a.tenant_id = v_tenant and a.code = v_row ->> 'axis_code'
           and a.status = 'active';
        if v_axis is null then
          raise exception 'no axis with code %', coalesce(v_row ->> 'axis_code', '(blank)');
        end if;
        if coalesce(v_row ->> 'code', '') = '' then
          raise exception 'no code, so this row names no value';
        end if;
        v_parent := null;
        if coalesce(v_row ->> 'parent_code', '') <> '' then
          select v.id into v_parent from erp.classification_value v
           where v.tenant_id = v_tenant and v.axis_id = v_axis
             and v.code = v_row ->> 'parent_code';
          if v_parent is null then
            raise exception 'no parent value % on axis %',
              v_row ->> 'parent_code', v_row ->> 'axis_code';
          end if;
        end if;
        if not p_dry_run then
          perform public.erp_upsert_classification_value(
            v_axis, v_row ->> 'code', coalesce(v_row ->> 'name', v_row ->> 'code'),
            nullif(v_row ->> 'abbreviation', ''), v_parent,
            nullif(v_row ->> 'name_key', ''));
        end if;

      elsif p_object_type = 'code_template' then
        if coalesce(v_row ->> 'code', '') = '' then
          raise exception 'no code, so this row names no template';
        end if;
        if coalesce(v_row ->> 'segments', '') = '' then
          raise exception 'a template with no segments composes nothing';
        end if;
        v_entity := null;
        if coalesce(v_row ->> 'entity_code', '') <> '' then
          select e.id into v_entity from erp.entity e
           where e.tenant_id = v_tenant and e.code = v_row ->> 'entity_code';
          if v_entity is null then
            raise exception 'no entity with code %', v_row ->> 'entity_code';
          end if;
        end if;
        if not p_dry_run then
          perform public.erp_upsert_code_template(
            v_row ->> 'code', coalesce(v_row ->> 'name', v_row ->> 'code'),
            (v_row ->> 'segments')::jsonb,
            nullif(v_row ->> 'item_classes', ''),
            coalesce(nullif(v_row ->> 'casing', ''), 'upper'),
            v_entity);
        end if;

      elsif p_object_type = 'item_supplier' then
        select i.id into v_item from erp.item i
         where i.tenant_id = v_tenant and i.code = v_row ->> 'item_code';
        if v_item is null then
          raise exception 'no item with code %', coalesce(v_row ->> 'item_code', '(blank)');
        end if;
        select p.id into v_party from erp.party p
         where p.tenant_id = v_tenant and p.code = v_row ->> 'supplier_code';
        if v_party is null then
          raise exception 'no party with code %', coalesce(v_row ->> 'supplier_code', '(blank)');
        end if;
        v_site := null;
        if coalesce(v_row ->> 'site_code', '') <> '' then
          select s.id into v_site from erp.site s
           where s.tenant_id = v_tenant and s.code = v_row ->> 'site_code';
          if v_site is null then
            raise exception 'no site with code %', v_row ->> 'site_code';
          end if;
        end if;
        v_label := (v_row ->> 'item_code') || ' / ' || (v_row ->> 'supplier_code');
        if not p_dry_run then
          perform public.erp_set_item_supplier(
            v_item, v_party, v_site,
            coalesce((v_row ->> 'preference_rank')::int, 1),
            coalesce((v_row ->> 'is_default')::boolean, false),
            nullif(v_row ->> 'split_pct', '')::numeric,
            coalesce((v_row ->> 'is_approved_for_use')::boolean, true),
            nullif(v_row ->> 'supplier_item_code', ''),
            nullif(v_row ->> 'lead_time_days', '')::int,
            nullif(v_row ->> 'min_order_quantity', '')::numeric,
            'Uploaded configuration');
        end if;

      else
        select s.id into v_site from erp.site s
         where s.tenant_id = v_tenant and s.code = v_row ->> 'site_code';
        if v_site is null then
          raise exception 'no site with code %', coalesce(v_row ->> 'site_code', '(blank)');
        end if;
        if coalesce(v_row ->> 'code', '') = '' then
          raise exception 'no code, so this row names no release area';
        end if;
        v_loc := null;
        if coalesce(v_row ->> 'location_code', '') <> '' then
          select l.id into v_loc from erp.location l
           where l.tenant_id = v_tenant and l.site_id = v_site
             and l.code = v_row ->> 'location_code';
          if v_loc is null then
            raise exception 'no location % at site %',
              v_row ->> 'location_code', v_row ->> 'site_code';
          end if;
        end if;
        if not p_dry_run then
          perform public.erp_upsert_release_area(
            v_site, v_row ->> 'code', coalesce(v_row ->> 'name', v_row ->> 'code'),
            v_loc, coalesce(nullif(v_row ->> 'replenishment_mode', ''), 'pull'),
            nullif(v_row ->> 'channel_code', ''),
            nullif(v_row ->> 'order_type_code', ''),
            nullif(v_row ->> 'item_classes', ''),
            nullif(v_row ->> 'min_quantity', '')::numeric,
            nullif(v_row ->> 'max_quantity', '')::numeric,
            nullif(v_row ->> 'ageing_hours', '')::int,
            coalesce((v_row ->> 'gate_printing')::boolean, true));
        end if;
      end if;

      v_ok := v_ok + 1;
      v_res := v_res || jsonb_build_object(
        'row_no', r.n, 'code', v_label,
        'status', case when p_dry_run then 'would apply' else 'applied' end,
        'message', null);

    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_bad := v_bad + 1;
      v_res := v_res || jsonb_build_object(
        'row_no', r.n, 'code', v_label, 'status', 'rejected', 'message', v_msg);
    end;
  end loop;

  if not p_dry_run and v_ok > 0 then
    perform erp.append_event('configuration.import_applied', 'import_batch', null,
      jsonb_build_object('object_type', p_object_type, 'applied', v_ok, 'rejected', v_bad));
  end if;

  return jsonb_build_object(
    'object_type', p_object_type, 'dry_run', p_dry_run,
    'rows', jsonb_array_length(p_rows), 'accepted', v_ok, 'rejected', v_bad,
    'results', v_res);
end;
$$;

/**
 * A configuration preset: enough classification, sourcing and release-area
 * shape for a walkthrough to have something to walk through. Running it twice
 * changes nothing the second time, because every write is an upsert.
 */
create or replace function public.erp_seed_demo_configuration()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_axis_f uuid;
  v_axis_g uuid;
  v_site   uuid;
  v_loc    uuid;
  v_item   uuid;
  v_party  uuid;
  v_items  int := 0;
  v_areas  int := 0;
  v_sups   int := 0;
  r        record;
begin
  perform erp.authorise('administration.configure');

  -- Classification: a family axis with a small hierarchy, and a grade axis.
  perform public.erp_upsert_classification_axis(
    'FAMILY', 'Product family', true, null, 10, null);
  perform public.erp_upsert_classification_axis(
    'GRADE', 'Grade', false, null, 20, null);

  select a.id into v_axis_f from erp.classification_axis a
   where a.tenant_id = v_tenant and a.code = 'FAMILY' and a.status = 'active';
  select a.id into v_axis_g from erp.classification_axis a
   where a.tenant_id = v_tenant and a.code = 'GRADE' and a.status = 'active';

  perform public.erp_upsert_classification_value(v_axis_f, 'AMB', 'Ambient goods', 'AMB', null, null);
  perform public.erp_upsert_classification_value(v_axis_f, 'CHL', 'Chilled goods', 'CHL', null, null);
  perform public.erp_upsert_classification_value(v_axis_f, 'PKG', 'Packaging', 'PKG', null, null);
  perform public.erp_upsert_classification_value(v_axis_g, 'STD', 'Standard', 'STD', null, null);
  perform public.erp_upsert_classification_value(v_axis_g, 'PRM', 'Premium', 'PRM', null, null);

  -- A code template that composes from those axes.
  perform public.erp_upsert_code_template(
    'DEMO-ITEM', 'Demo item code',
    '[{"kind":"literal","value":"D"},
      {"kind":"axis","axis":"FAMILY","length":3},
      {"kind":"axis","axis":"GRADE","length":3},
      {"kind":"sequence","length":4}]'::jsonb,
    null, 'upper', null);

  -- Classify whatever items exist, so the gaps report has something to say.
  for r in select i.id, row_number() over (order by i.code) as n
             from erp.item i
            where i.tenant_id = v_tenant and i.status <> 'archived'
            limit 12
  loop
    begin
      perform public.erp_classify_item(r.id, v_axis_f,
        (select v.id from erp.classification_value v
          where v.tenant_id = v_tenant and v.axis_id = v_axis_f
            and v.code = (array['AMB','CHL','PKG'])[1 + (r.n % 3)]), null);
      perform public.erp_classify_item(r.id, v_axis_g,
        (select v.id from erp.classification_value v
          where v.tenant_id = v_tenant and v.axis_id = v_axis_g
            and v.code = (array['STD','PRM'])[1 + (r.n % 2)]), null);
      v_items := v_items + 1;
    exception when others then null;
    end;
  end loop;

  -- Default suppliers for purchased items, ranked, with lead times.
  for r in select i.id as item_id, p.id as party_id,
                  row_number() over (order by i.code, p.code) as n
             from erp.item i
             cross join lateral (
               select p2.id, p2.code from erp.party p2
                where p2.tenant_id = v_tenant and p2.status = 'active'
                order by p2.code limit 2) p
            where i.tenant_id = v_tenant and i.status = 'active'
            limit 10
  loop
    begin
      perform public.erp_set_item_supplier(
        r.item_id, r.party_id, null,
        case when r.n % 2 = 1 then 1 else 2 end,
        r.n % 2 = 1, null, true, null,
        7 * (1 + (r.n % 3)), 10, 'Demo configuration preset');
      v_sups := v_sups + 1;
    exception when others then null;
    end;
  end loop;

  -- One release area per site, on a pickable location where there is one.
  for r in select s.id as site_id, s.code from erp.site s
            where s.tenant_id = v_tenant and s.status = 'active'
            order by s.code limit 2
  loop
    select l.id into v_loc from erp.location l
     where l.tenant_id = v_tenant and l.site_id = r.site_id
       and coalesce(l.is_pickable, true) and not coalesce(l.is_blocked, false)
     order by l.code limit 1;

    begin
      perform public.erp_upsert_release_area(
        r.site_id, 'DEMO-REL', 'Demo release area', v_loc, 'pull',
        null, null, null, 0, 500, 24, true);
      v_areas := v_areas + 1;
    exception when others then null;
    end;
  end loop;

  perform erp.append_event('configuration.preset_applied', 'tenant', v_tenant,
    jsonb_build_object('items_classified', v_items, 'suppliers', v_sups,
                       'release_areas', v_areas));

  return jsonb_build_object('items_classified', v_items, 'supplier_defaults', v_sups,
                            'release_areas', v_areas, 'axes', 2, 'code_templates', 1);
end;
$$;

/** Why a wave will or will not print, line by line. */
create or replace function public.erp_wave_print_readiness(p_wave_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  w        erp.release_wave%rowtype;
  a        erp.release_area%rowtype;
  v_short  jsonb;
  v_tasks  jsonb;
  v_n      int;
begin
  perform erp.authorise('logistics.read');

  select * into w from erp.release_wave
   where tenant_id = v_tenant and id = p_wave_id;
  if not found then
    raise exception 'ERPWARE_WAVE_NOT_FOUND: %', p_wave_id using errcode = '23503';
  end if;

  select * into a from erp.release_area
   where tenant_id = v_tenant and id = w.release_area_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'item_code', i.code, 'item_name', i.name,
           'wanted', l.quantity, 'allocated', l.allocated_quantity,
           'short', l.shortfall_quantity,
           'cause', coalesce(l.shortfall_cause, 'unallocated'),
           'explanation', case coalesce(l.shortfall_cause, 'unallocated')
             when 'no_stock_at_site' then 'nothing available anywhere at this site'
             when 'awaiting_replenishment' then 'stock is at the site but not in the release area; a replenishment task is open'
             when 'not_in_release_area' then 'stock is not in the release area and nothing can be moved into it'
             else 'this line has not been allocated yet' end)
         order by i.code), '[]'::jsonb), count(*)
    into v_short, v_n
    from erp.release_wave_line l
    join erp.item i on i.id = l.item_id and i.tenant_id = l.tenant_id
   where l.tenant_id = v_tenant and l.wave_id = p_wave_id and l.status <> 'allocated';

  select coalesce(jsonb_agg(jsonb_build_object(
           'item_code', i.code, 'quantity', t.quantity, 'status', t.status)
         order by i.code), '[]'::jsonb)
    into v_tasks
    from erp.warehouse_task t
    join erp.item i on i.id = t.item_id and i.tenant_id = t.tenant_id
   where t.tenant_id = v_tenant and t.kind = 'replenishment'
     and t.note = 'Raised by wave ' || w.code and t.status <> 'cancelled';

  return jsonb_build_object(
    'wave_id', p_wave_id, 'wave_code', w.code, 'status', w.status,
    'gate_printing', coalesce(a.gate_printing, false),
    'short_lines', v_n,
    'can_print', (v_n = 0 or not coalesce(a.gate_printing, false))
                 and w.status <> 'cancelled',
    'lines', v_short,
    'replenishment_tasks', v_tasks);
end;
$$;

/** Allocation, with a cause that distinguishes the three ways a line falls short. */
create or replace function public.erp_allocate_release_wave(p_wave_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  w          erp.release_wave%rowtype;
  a          erp.release_area%rowtype;
  r          record;
  v_here     numeric;
  v_site_qty numeric;
  v_take     numeric;
  v_short    numeric;
  v_target   numeric;
  v_cause    text;
  v_tasks    int := 0;
  v_lines    int := 0;
  v_shorts   int := 0;
  v_from     uuid;
begin
  perform erp.authorise('logistics.plan');

  select * into w from erp.release_wave
   where tenant_id = v_tenant and id = p_wave_id for update;
  if not found then
    raise exception 'ERPWARE_WAVE_NOT_FOUND: %', p_wave_id using errcode = '23503';
  end if;
  if w.status not in ('open', 'allocated') then
    raise exception 'ERPWARE_WAVE_CLOSED: this wave is %', w.status using errcode = '23514';
  end if;

  select * into a from erp.release_area
   where tenant_id = v_tenant and id = w.release_area_id;

  for r in select * from erp.release_wave_line l
            where l.tenant_id = v_tenant and l.wave_id = p_wave_id
              and l.status in ('pending', 'short')
  loop
    v_lines := v_lines + 1;

    select coalesce(sum(b.quantity), 0) into v_here
      from erp.stock_balance b
     where b.tenant_id = v_tenant
       and b.item_id = r.item_id
       and b.stock_status = 'available'
       and (a.location_id is null or b.location_id = a.location_id)
       and b.site_id = a.site_id;

    select coalesce(sum(b.quantity), 0) into v_site_qty
      from erp.stock_balance b
     where b.tenant_id = v_tenant and b.site_id = a.site_id
       and b.item_id = r.item_id and b.stock_status = 'available';

    v_take  := least(v_here, r.quantity);
    v_short := r.quantity - v_take;
    v_from  := null;
    v_cause := null;

    if v_short > 0 then
      v_shorts := v_shorts + 1;

      v_target := case
        when a.replenishment_mode = 'push' and a.max_quantity is not null
          then greatest(v_short, a.max_quantity - v_here)
        else v_short
      end;

      select b.location_id into v_from
        from erp.stock_balance b
       where b.tenant_id = v_tenant and b.site_id = a.site_id
         and b.item_id = r.item_id and b.stock_status = 'available'
         and b.quantity > 0
         and (a.location_id is null or b.location_id is distinct from a.location_id)
       order by b.quantity desc limit 1;

      if v_from is not null and a.location_id is not null then
        insert into erp.warehouse_task (
          tenant_id, site_id, kind, item_id, from_location_id, to_location_id,
          stock_status, quantity, status, note)
        values (v_tenant, a.site_id, 'replenishment', r.item_id, v_from,
                a.location_id, 'available', v_target, 'open',
                'Raised by wave ' || w.code);
        v_tasks := v_tasks + 1;
        v_cause := 'awaiting_replenishment';

        perform erp.append_event('replenishment.task_raised', 'warehouse_task', r.id,
          jsonb_build_object('wave_id', p_wave_id, 'item_id', r.item_id,
                             'quantity', v_target, 'mode', a.replenishment_mode));
      elsif v_site_qty <= v_take then
        v_cause := 'no_stock_at_site';
      else
        v_cause := 'not_in_release_area';
      end if;
    end if;

    update erp.release_wave_line
       set allocated_quantity = v_take,
           shortfall_quantity = v_short,
           shortfall_cause = v_cause,
           status = case when v_short > 0 then 'short' else 'allocated' end,
           updated_at = now()
     where id = r.id;
  end loop;

  update erp.release_wave
     set status = case when v_shorts = 0 then 'allocated' else 'open' end,
         allocated_at = case when v_shorts = 0 then now() else allocated_at end,
         updated_at = now()
   where id = p_wave_id;

  perform erp.append_event('release.allocation_completed', 'release_wave', p_wave_id,
    jsonb_build_object('lines', v_lines, 'short_lines', v_shorts,
                       'replenishment_tasks', v_tasks));

  return jsonb_build_object('lines', v_lines, 'short_lines', v_shorts,
                            'replenishment_tasks', v_tasks,
                            'allocated', v_shorts = 0);
end;
$$;

/** Printing, refusing with the lines and the reasons rather than a count. */
create or replace function public.erp_print_release_wave(p_wave_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  w        erp.release_wave%rowtype;
  a        erp.release_area%rowtype;
  v_short  int;
  v_detail text;
begin
  perform erp.authorise('logistics.despatch');

  select * into w from erp.release_wave
   where tenant_id = v_tenant and id = p_wave_id for update;
  if not found then
    raise exception 'ERPWARE_WAVE_NOT_FOUND: %', p_wave_id using errcode = '23503';
  end if;

  select * into a from erp.release_area
   where tenant_id = v_tenant and id = w.release_area_id;

  select count(*), string_agg(
           i.code || ' short ' || l.shortfall_quantity || ' of ' || l.quantity ||
           ' (' || case coalesce(l.shortfall_cause, 'unallocated')
             when 'no_stock_at_site' then 'nothing available at this site'
             when 'awaiting_replenishment' then 'replenishment raised, not yet done'
             when 'not_in_release_area' then 'stock is not in the release area'
             else 'not allocated yet' end || ')', '; ' order by i.code)
    into v_short, v_detail
    from erp.release_wave_line l
    join erp.item i on i.id = l.item_id and i.tenant_id = l.tenant_id
   where l.tenant_id = v_tenant and l.wave_id = p_wave_id
     and l.status <> 'allocated';

  if coalesce(a.gate_printing, false) and v_short > 0 then
    raise exception
      'ERPWARE_PRINT_GATED: % line(s) have not allocated in full, so nothing prints yet',
      v_short
      using errcode = '23514',
      detail = v_detail,
      hint = 'Complete the replenishment tasks and allocate the wave again, or '
             'turn printing gating off for this release area.';
  end if;

  update erp.release_wave
     set status = 'released', released_at = coalesce(released_at, now()),
         printed_at = now(), updated_at = now()
   where id = p_wave_id;

  perform erp.append_event('release.printed', 'release_wave', p_wave_id,
    jsonb_build_object('lines', (select count(*) from erp.release_wave_line l
                                  where l.wave_id = p_wave_id)));

  return jsonb_build_object('wave_id', p_wave_id, 'printed', true);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_configuration_columns(text)',
    'public.erp_export_configuration(text)',
    'public.erp_import_configuration(text,jsonb,boolean)',
    'public.erp_seed_demo_configuration()',
    'public.erp_wave_print_readiness(uuid)',
    'public.erp_allocate_release_wave(uuid)',
    'public.erp_print_release_wave(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

select erp.apply_row_security();