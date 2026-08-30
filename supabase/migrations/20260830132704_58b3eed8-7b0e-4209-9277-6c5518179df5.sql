-- =============================================================================
-- Addendum B, phase 4: item supply defaults and release areas
--
-- Two operational surfaces, both configuration. Nothing here knows the name of
-- a supplier, a channel or a zone: what to buy from whom, and what may be
-- picked from where, are rows a tenant writes.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Item supply
-- -----------------------------------------------------------------------------

create table erp.item_supplier (
  id                  uuid not null default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  item_id             uuid not null references erp.item(id) on delete cascade,
  party_id            uuid not null references erp.party(id) on delete restrict,
  -- Null site means the default everywhere it is not overridden.
  site_id             uuid references erp.site(id) on delete cascade,
  preference_rank     integer not null default 1 check (preference_rank > 0),
  is_default          boolean not null default false,
  split_pct           numeric(6,3) check (split_pct is null or (split_pct > 0 and split_pct <= 100)),
  is_approved_for_use boolean not null default true,
  supplier_item_code  text,
  lead_time_days      integer check (lead_time_days is null or lead_time_days >= 0),
  min_order_quantity  numeric,
  order_multiple      numeric,
  valid_from          date not null default current_date,
  valid_to            date,
  status              erp.record_status not null default 'active',
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  primary key (id),
  check (valid_to is null or valid_to > valid_from)
);

create unique index item_supplier_one_default
  on erp.item_supplier (tenant_id, item_id, coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where is_default and status = 'active' and valid_to is null;

create index on erp.item_supplier (tenant_id, item_id, preference_rank);
create index on erp.item_supplier (tenant_id, party_id);

comment on table erp.item_supplier is
  'Addendum B 2: who this item is bought from, at what rank and split, per site.';

-- -----------------------------------------------------------------------------
-- Release areas
--
-- A release area is a scope of locations, chosen per site and optionally per
-- channel, item class and order type. Stock inside it is allocated stock.
-- -----------------------------------------------------------------------------

create table erp.release_area (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  site_id            uuid not null references erp.site(id) on delete cascade,
  code               text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
  name               text not null,
  name_key           text,
  location_id        uuid references erp.location(id) on delete set null,
  channel_code       text,
  order_type_code    text,
  item_classes       text[],
  replenishment_mode text not null default 'pull'
                     check (replenishment_mode in ('pull', 'push')),
  min_quantity       numeric,
  max_quantity       numeric,
  ageing_hours       integer not null default 72 check (ageing_hours >= 0),
  gate_printing      boolean not null default true,
  valid_from         date not null default current_date,
  valid_to           date,
  status             erp.record_status not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  unique (tenant_id, site_id, code),
  check (max_quantity is null or min_quantity is null or max_quantity >= min_quantity),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.release_area (tenant_id, site_id, status);

comment on table erp.release_area is
  'Addendum B 5: the scope detailed allocation commits against at release. '
  'Stock inside it is allocated: out of count scope and out of reach of other demand.';

-- The wave is the unit of release. It opens over a release area, allocates in
-- detail, and only then may anything print.
create table erp.release_wave (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  release_area_id   uuid not null references erp.release_area(id) on delete cascade,
  code              text not null,
  status            text not null default 'open'
                    check (status in ('open', 'allocated', 'released', 'cancelled')),
  opened_at         timestamptz not null default now(),
  allocated_at      timestamptz,
  released_at       timestamptz,
  printed_at        timestamptz,
  note              text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id),
  unique (tenant_id, release_area_id, code)
);

create index on erp.release_wave (tenant_id, status);

create table erp.release_wave_line (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  wave_id           uuid not null references erp.release_wave(id) on delete cascade,
  document_id       uuid references erp.document(id) on delete set null,
  item_id           uuid not null references erp.item(id) on delete restrict,
  quantity          numeric not null check (quantity > 0),
  allocated_quantity numeric not null default 0,
  shortfall_quantity numeric not null default 0,
  shortfall_cause   text,
  status            text not null default 'pending'
                    check (status in ('pending', 'allocated', 'short', 'cancelled')),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id)
);

create index on erp.release_wave_line (tenant_id, wave_id);

select erp_meta.register_table('erp', 'item_supplier', 'tenant_scoped');
select erp_meta.register_table('erp', 'release_area', 'tenant_scoped');
select erp_meta.register_table('erp', 'release_wave', 'tenant_scoped');
select erp_meta.register_table('erp', 'release_wave_line', 'tenant_scoped');

do $$
declare t text;
begin
  foreach t in array array['item_supplier', 'release_area', 'release_wave',
                           'release_wave_line'] loop
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
  ('sourcing.default_recorded', 1, 'item', 'procurement', 'event.sourcing.default_recorded',
   'A default supplier was set for an item at a site.', true),
  ('release.wave_opened', 1, 'release_wave', 'logistics', 'event.release.wave_opened',
   'A release wave was opened over a release area.', true),
  ('release.allocation_completed', 1, 'release_wave', 'logistics', 'event.release.allocation_completed',
   'Detailed allocation ran against a release area scope.', true),
  ('release.printed', 1, 'release_wave', 'logistics', 'event.release.printed',
   'Paperwork printed for a wave that had allocated in full.', true),
  ('replenishment.task_raised', 1, 'warehouse_task', 'logistics', 'event.replenishment.task_raised',
   'A shortfall in a release area raised a directed replenishment task.', true),
  ('replenishment.stock_returned', 1, 'release_area', 'logistics', 'event.replenishment.stock_returned',
   'Untouched release-area stock was returned to bulk.', true)
on conflict (code, version) do nothing;

-- -----------------------------------------------------------------------------
-- Item supply RPCs
-- -----------------------------------------------------------------------------

create or replace function public.erp_item_suppliers(
  p_item_id uuid default null,
  p_site_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('procurement.read');
  select coalesce(jsonb_agg(x order by x->>'item_code', x->>'preference_rank'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'item_supplier_id', s.id, 'item_id', s.item_id, 'item_code', i.code,
      'item_name', i.name, 'party_id', s.party_id, 'supplier', p.name,
      'site_id', s.site_id, 'site_code', st.code,
      'preference_rank', s.preference_rank, 'is_default', s.is_default,
      'split_pct', s.split_pct, 'is_approved_for_use', s.is_approved_for_use,
      'supplier_item_code', s.supplier_item_code,
      'lead_time_days', s.lead_time_days,
      'min_order_quantity', s.min_order_quantity, 'order_multiple', s.order_multiple,
      'valid_from', s.valid_from, 'valid_to', s.valid_to, 'status', s.status) as x
      from erp.item_supplier s
      join erp.item i on i.id = s.item_id and i.tenant_id = s.tenant_id
      join erp.party p on p.id = s.party_id and p.tenant_id = s.tenant_id
      left join erp.site st on st.id = s.site_id and st.tenant_id = s.tenant_id
     where s.tenant_id = erp.current_tenant_id()
       and (p_item_id is null or s.item_id = p_item_id)
       and (p_site_id is null or s.site_id is null or s.site_id = p_site_id)) q;
  return v_out;
end;
$$;

create or replace function public.erp_set_item_supplier(
  p_item_id            uuid,
  p_party_id           uuid,
  p_site_id            uuid default null,
  p_preference_rank    integer default 1,
  p_is_default         boolean default false,
  p_split_pct          numeric default null,
  p_is_approved_for_use boolean default true,
  p_supplier_item_code text default null,
  p_lead_time_days     integer default null,
  p_min_order_quantity numeric default null,
  p_reason             text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_regulated boolean;
  v_approved  boolean;
  v_total     numeric;
begin
  perform erp.authorise('master_data.write');

  if not exists (select 1 from erp.party_role r
                  where r.tenant_id = v_tenant and r.party_id = p_party_id
                    and r.role_kind = 'supplier' and r.status = 'active') then
    raise exception 'ERPWARE_NOT_A_SUPPLIER: that party does not hold the supplier role'
      using errcode = '23514';
  end if;

  -- A regulated item may only default to a supplier that is on the approved
  -- list. The check is on the data, not on any particular item class.
  select coalesce(i.regulatory <> '{}'::jsonb, false) into v_regulated
    from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id;

  select coalesce(bool_or(r.is_approved), false) into v_approved
    from erp.party_role r
   where r.tenant_id = v_tenant and r.party_id = p_party_id
     and r.role_kind = 'supplier' and r.status = 'active'
     and (r.approval_expires_at is null or r.approval_expires_at >= current_date);

  if coalesce(p_is_default, false) and v_regulated and not v_approved then
    raise exception
      'ERPWARE_SUPPLIER_NOT_APPROVED: a regulated item cannot default to an unapproved supplier'
      using errcode = '23514';
  end if;

  select s.id into v_id from erp.item_supplier s
   where s.tenant_id = v_tenant and s.item_id = p_item_id and s.party_id = p_party_id
     and s.site_id is not distinct from p_site_id and s.status = 'active'
     and s.valid_to is null;

  if coalesce(p_is_default, false) then
    update erp.item_supplier
       set is_default = false, updated_at = now()
     where tenant_id = v_tenant and item_id = p_item_id
       and site_id is not distinct from p_site_id
       and is_default and status = 'active' and valid_to is null
       and (v_id is null or id <> v_id);
  end if;

  if v_id is null then
    insert into erp.item_supplier (
      tenant_id, item_id, party_id, site_id, preference_rank, is_default,
      split_pct, is_approved_for_use, supplier_item_code, lead_time_days,
      min_order_quantity)
    values (v_tenant, p_item_id, p_party_id, p_site_id,
            coalesce(p_preference_rank, 1), coalesce(p_is_default, false),
            p_split_pct, coalesce(p_is_approved_for_use, true), p_supplier_item_code,
            p_lead_time_days, p_min_order_quantity)
    returning id into v_id;
  else
    update erp.item_supplier
       set preference_rank = coalesce(p_preference_rank, preference_rank),
           is_default = coalesce(p_is_default, is_default),
           split_pct = p_split_pct,
           is_approved_for_use = coalesce(p_is_approved_for_use, is_approved_for_use),
           supplier_item_code = p_supplier_item_code,
           lead_time_days = p_lead_time_days,
           min_order_quantity = p_min_order_quantity,
           updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  -- Splits that add to more than the whole are a data error, not a rounding
  -- question: the buyer would place more than the requirement.
  select sum(s.split_pct) into v_total from erp.item_supplier s
   where s.tenant_id = v_tenant and s.item_id = p_item_id
     and s.site_id is not distinct from p_site_id
     and s.status = 'active' and s.valid_to is null;

  if coalesce(v_total, 0) > 100 then
    raise exception 'ERPWARE_SPLIT_OVER_100: the sourcing split for this item totals %%%',
      v_total using errcode = '23514';
  end if;

  if coalesce(p_is_default, false) then
    perform erp.append_event('sourcing.default_recorded', 'item', p_item_id,
      jsonb_build_object('party_id', p_party_id, 'site_id', p_site_id,
                         'reason', p_reason));
  end if;

  return jsonb_build_object('item_supplier_id', v_id);
end;
$$;

create or replace function public.erp_end_item_supplier(
  p_item_supplier_id uuid,
  p_reason           text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('master_data.write');
  update erp.item_supplier
     set valid_to = current_date, status = 'retired', is_default = false,
         updated_at = now()
   where tenant_id = v_tenant and id = p_item_supplier_id;
  return jsonb_build_object('item_supplier_id', p_item_supplier_id,
                            'reason', p_reason);
end;
$$;

/** Who a replenishment, an MRP order or a manual purchase order buys from. */
create or replace function public.erp_resolve_item_supplier(
  p_item_id uuid,
  p_site_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_out    jsonb;
begin
  perform erp.authorise('procurement.read');

  select jsonb_build_object(
    'item_supplier_id', s.id, 'party_id', s.party_id, 'supplier', p.name,
    'site_id', s.site_id, 'scope', case when s.site_id is null then 'item' else 'site' end,
    'preference_rank', s.preference_rank, 'is_default', s.is_default,
    'split_pct', s.split_pct, 'lead_time_days', s.lead_time_days,
    'min_order_quantity', s.min_order_quantity,
    'approved', coalesce(bool_or(r.is_approved), false))
    into v_out
    from erp.item_supplier s
    join erp.party p on p.id = s.party_id and p.tenant_id = s.tenant_id
    left join erp.party_role r
      on r.tenant_id = s.tenant_id and r.party_id = s.party_id
     and r.role_kind = 'supplier' and r.status = 'active'
   where s.tenant_id = v_tenant
     and s.item_id = p_item_id
     and s.status = 'active'
     and s.is_approved_for_use
     and s.valid_from <= current_date
     and (s.valid_to is null or s.valid_to > current_date)
     and (s.site_id is null or p_site_id is null or s.site_id = p_site_id)
   group by s.id, p.name
   order by (s.site_id is not null and s.site_id = p_site_id) desc,
            s.is_default desc, s.preference_rank
   limit 1;

  if v_out is null then
    raise exception 'ERPWARE_NO_SUPPLIER: no supplier is configured for this item here'
      using errcode = 'P0002';
  end if;

  return v_out;
end;
$$;

-- -----------------------------------------------------------------------------
-- Release areas
-- -----------------------------------------------------------------------------

create or replace function public.erp_release_areas(p_site_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('logistics.read');
  select coalesce(jsonb_agg(x order by x->>'site_code', x->>'code'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'release_area_id', a.id, 'code', a.code, 'name', a.name,
      'site_id', a.site_id, 'site_code', s.code,
      'location_id', a.location_id, 'location_code', l.code,
      'channel_code', a.channel_code, 'order_type_code', a.order_type_code,
      'item_classes', coalesce(to_jsonb(a.item_classes), 'null'::jsonb),
      'replenishment_mode', a.replenishment_mode,
      'min_quantity', a.min_quantity, 'max_quantity', a.max_quantity,
      'ageing_hours', a.ageing_hours, 'gate_printing', a.gate_printing,
      'on_hand', coalesce((
        select sum(b.quantity) from erp.stock_balance b
         where b.tenant_id = a.tenant_id and b.location_id = a.location_id), 0),
      'status', a.status) as x
      from erp.release_area a
      join erp.site s on s.id = a.site_id and s.tenant_id = a.tenant_id
      left join erp.location l on l.id = a.location_id and l.tenant_id = a.tenant_id
     where a.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or a.site_id = p_site_id)) q;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_release_area(
  p_site_id            uuid,
  p_code               text,
  p_name               text,
  p_location_id        uuid default null,
  p_replenishment_mode text default 'pull',
  p_channel_code       text default null,
  p_order_type_code    text default null,
  p_item_classes       text default null,
  p_min_quantity       numeric default null,
  p_max_quantity       numeric default null,
  p_ageing_hours       integer default 72,
  p_gate_printing      boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_id      uuid;
  v_classes text[];
begin
  perform erp.authorise('logistics.plan');

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select a.id into v_id from erp.release_area a
   where a.tenant_id = v_tenant and a.site_id = p_site_id and a.code = upper(p_code);

  if v_id is null then
    insert into erp.release_area (
      tenant_id, site_id, code, name, location_id, replenishment_mode,
      channel_code, order_type_code, item_classes, min_quantity, max_quantity,
      ageing_hours, gate_printing)
    values (v_tenant, p_site_id, upper(p_code), p_name, p_location_id,
            coalesce(p_replenishment_mode, 'pull'), p_channel_code, p_order_type_code,
            v_classes, p_min_quantity, p_max_quantity, coalesce(p_ageing_hours, 72),
            coalesce(p_gate_printing, true))
    returning id into v_id;
  else
    update erp.release_area
       set name = p_name, location_id = p_location_id,
           replenishment_mode = coalesce(p_replenishment_mode, replenishment_mode),
           channel_code = p_channel_code, order_type_code = p_order_type_code,
           item_classes = v_classes, min_quantity = p_min_quantity,
           max_quantity = p_max_quantity,
           ageing_hours = coalesce(p_ageing_hours, ageing_hours),
           gate_printing = coalesce(p_gate_printing, gate_printing),
           updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('release_area_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_open_release_wave(
  p_release_area_id uuid,
  p_code            text default null,
  p_note            text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_code   text := coalesce(nullif(btrim(p_code), ''),
                            'WAVE-' || to_char(now(), 'YYYYMMDDHH24MISS'));
begin
  perform erp.authorise('logistics.plan');

  insert into erp.release_wave (tenant_id, release_area_id, code, note)
  values (v_tenant, p_release_area_id, v_code, p_note)
  returning id into v_id;

  perform erp.append_event('release.wave_opened', 'release_wave', v_id,
    jsonb_build_object('release_area_id', p_release_area_id, 'code', v_code));

  return jsonb_build_object('wave_id', v_id, 'code', v_code);
end;
$$;

create or replace function public.erp_add_wave_line(
  p_wave_id     uuid,
  p_item_id     uuid,
  p_quantity    numeric,
  p_document_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('logistics.plan');

  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'ERPWARE_QUANTITY_INVALID: a wave line needs a positive quantity'
      using errcode = '23514';
  end if;

  insert into erp.release_wave_line (tenant_id, wave_id, item_id, quantity, document_id)
  values (v_tenant, p_wave_id, p_item_id, p_quantity, p_document_id)
  returning id into v_id;

  return jsonb_build_object('wave_line_id', v_id);
end;
$$;

/**
 * Detailed allocation against the release area scope only.
 *
 * What the area cannot cover is a shortfall, and a shortfall raises directed
 * replenishment rather than a shortage: the stock exists, it is simply in the
 * wrong place. Push areas top up to their maximum; pull areas move exactly
 * what the wave is short.
 */
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
  v_take     numeric;
  v_short    numeric;
  v_target   numeric;
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

    v_take  := least(v_here, r.quantity);
    v_short := r.quantity - v_take;

    update erp.release_wave_line
       set allocated_quantity = v_take,
           shortfall_quantity = v_short,
           shortfall_cause = case when v_short > 0 then 'not_in_release_area' end,
           status = case when v_short > 0 then 'short' else 'allocated' end,
           updated_at = now()
     where id = r.id;

    if v_short > 0 then
      v_shorts := v_shorts + 1;

      -- Push tops the area up to its maximum; pull moves only the shortfall.
      v_target := case
        when a.replenishment_mode = 'push' and a.max_quantity is not null
          then greatest(v_short, a.max_quantity - v_here)
        else v_short
      end;

      -- Somewhere in the site that is not the release area itself.
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

        perform erp.append_event('replenishment.task_raised', 'warehouse_task', r.id,
          jsonb_build_object('wave_id', p_wave_id, 'item_id', r.item_id,
                             'quantity', v_target, 'mode', a.replenishment_mode));
      end if;
    end if;
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

/** Printing is a consequence of allocation, not a separate act of will. */
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
begin
  perform erp.authorise('logistics.despatch');

  select * into w from erp.release_wave
   where tenant_id = v_tenant and id = p_wave_id for update;
  if not found then
    raise exception 'ERPWARE_WAVE_NOT_FOUND: %', p_wave_id using errcode = '23503';
  end if;

  select * into a from erp.release_area
   where tenant_id = v_tenant and id = w.release_area_id;

  select count(*) into v_short from erp.release_wave_line l
   where l.tenant_id = v_tenant and l.wave_id = p_wave_id
     and l.status <> 'allocated';

  if a.gate_printing and v_short > 0 then
    raise exception
      'ERPWARE_PRINT_GATED: % line(s) have not allocated in full, so nothing prints yet',
      v_short using errcode = '23514';
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

create or replace function public.erp_release_waves(
  p_release_area_id uuid default null,
  p_limit           integer default 100)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('logistics.read');
  select coalesce(jsonb_agg(x order by x->>'opened_at' desc), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'wave_id', w.id, 'code', w.code, 'status', w.status,
      'release_area_id', w.release_area_id, 'release_area', a.code,
      'site_code', s.code,
      'opened_at', w.opened_at, 'allocated_at', w.allocated_at,
      'printed_at', w.printed_at,
      'lines', (select count(*) from erp.release_wave_line l
                 where l.tenant_id = w.tenant_id and l.wave_id = w.id),
      'short_lines', (select count(*) from erp.release_wave_line l
                       where l.tenant_id = w.tenant_id and l.wave_id = w.id
                         and l.status = 'short')) as x
      from erp.release_wave w
      join erp.release_area a on a.id = w.release_area_id and a.tenant_id = w.tenant_id
      join erp.site s on s.id = a.site_id and s.tenant_id = a.tenant_id
     where w.tenant_id = erp.current_tenant_id()
       and (p_release_area_id is null or w.release_area_id = p_release_area_id)
     limit least(greatest(coalesce(p_limit, 100), 1), 500)) q;
  return v_out;
end;
$$;

create or replace function public.erp_release_wave_lines(p_wave_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('logistics.read');
  select coalesce(jsonb_agg(x order by x->>'item_code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'wave_line_id', l.id, 'item_id', l.item_id, 'item_code', i.code,
      'item_name', i.name, 'quantity', l.quantity,
      'allocated_quantity', l.allocated_quantity,
      'shortfall_quantity', l.shortfall_quantity,
      'shortfall_cause', l.shortfall_cause, 'status', l.status) as x
      from erp.release_wave_line l
      join erp.item i on i.id = l.item_id and i.tenant_id = l.tenant_id
     where l.tenant_id = erp.current_tenant_id() and l.wave_id = p_wave_id) q;
  return v_out;
end;
$$;

/**
 * Stock that has sat in a release area past its ageing period and is not
 * claimed by an open wave goes back to bulk. Allocated stock that nothing
 * needs is worse than no stock at all: it hides from counting and from
 * everybody else's demand.
 */
create or replace function public.erp_age_back_release_area(p_release_area_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  a        erp.release_area%rowtype;
  r        record;
  v_to     uuid;
  v_tasks  int := 0;
begin
  perform erp.authorise('logistics.plan');

  select * into a from erp.release_area
   where tenant_id = v_tenant and id = p_release_area_id;
  if not found or a.location_id is null then
    raise exception 'ERPWARE_RELEASE_AREA_NOT_STOCKED: this area has no location'
      using errcode = '23514';
  end if;

  for r in
    select b.item_id, sum(b.quantity) as qty
      from erp.stock_balance b
     where b.tenant_id = v_tenant and b.location_id = a.location_id
       and b.quantity > 0
       and b.updated_at < now() - make_interval(hours => a.ageing_hours)
       and not exists (
         select 1 from erp.release_wave_line l
           join erp.release_wave w on w.id = l.wave_id and w.tenant_id = l.tenant_id
          where l.tenant_id = v_tenant and l.item_id = b.item_id
            and w.release_area_id = a.id and w.status in ('open', 'allocated'))
     group by b.item_id
  loop
    select l.id into v_to from erp.location l
     where l.tenant_id = v_tenant and l.site_id = a.site_id
       and l.id <> a.location_id and l.status = 'active' and not l.is_blocked
     order by (l.location_type = 'bulk') desc, l.code
     limit 1;

    exit when v_to is null;

    insert into erp.warehouse_task (
      tenant_id, site_id, kind, item_id, from_location_id, to_location_id,
      stock_status, quantity, status, note)
    values (v_tenant, a.site_id, 'putaway', r.item_id, a.location_id, v_to,
            'available', r.qty, 'open',
            'Aged back from release area ' || a.code);
    v_tasks := v_tasks + 1;
  end loop;

  if v_tasks > 0 then
    perform erp.append_event('replenishment.stock_returned', 'release_area',
      p_release_area_id, jsonb_build_object('tasks', v_tasks,
                                            'ageing_hours', a.ageing_hours));
  end if;

  return jsonb_build_object('release_area_id', p_release_area_id, 'tasks', v_tasks);
end;
$$;

/** Locations that are release areas, so counting and other demand skip them. */
create or replace function public.erp_release_area_locations()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('inventory.read');
  select coalesce(jsonb_agg(distinct a.location_id), '[]'::jsonb) into v_out
    from erp.release_area a
   where a.tenant_id = erp.current_tenant_id()
     and a.status = 'active' and a.location_id is not null;
  return v_out;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_item_suppliers(uuid,uuid)',
    'public.erp_set_item_supplier(uuid,uuid,uuid,integer,boolean,numeric,boolean,text,integer,numeric,text)',
    'public.erp_end_item_supplier(uuid,text)',
    'public.erp_resolve_item_supplier(uuid,uuid)',
    'public.erp_release_areas(uuid)',
    'public.erp_upsert_release_area(uuid,text,text,uuid,text,text,text,text,numeric,numeric,integer,boolean)',
    'public.erp_open_release_wave(uuid,text,text)',
    'public.erp_add_wave_line(uuid,uuid,numeric,uuid)',
    'public.erp_allocate_release_wave(uuid)',
    'public.erp_print_release_wave(uuid)',
    'public.erp_release_waves(uuid,integer)',
    'public.erp_release_wave_lines(uuid)',
    'public.erp_age_back_release_area(uuid)',
    'public.erp_release_area_locations()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

select erp.apply_row_security();