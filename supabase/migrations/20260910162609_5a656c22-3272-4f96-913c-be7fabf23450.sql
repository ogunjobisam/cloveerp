-- The warehouse has a shape, and the shape decides where things go.
--
-- erp.location has carried parent_location_id, path, capacity, count_class and
-- is_pickable since 0002, and no door exposed any of them: a location could be
-- created flat, with a type and nothing else. So a warehouse could be described
-- as a list of bays and never as a warehouse, and the two routines that decide
-- where stock goes — putaway and replenishment — had nothing to read. Putaway
-- picked the alphabetically first bulk location in the site; replenishment
-- topped up whichever pickable location the aggregate happened to name.
--
-- This adds the missing statement: a storage rule. "This product, or every
-- product of this class, belongs in this place at this site, in this order of
-- preference, for putting away / for picking." Putaway and replenishment read
-- it; commit_allocation reads it too, as a preference after the method has
-- already chosen which stock — a rule decides where, never which.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. The rule
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists erp.storage_rule (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  site_id       uuid not null,
  rule_kind     text not null check (rule_kind in ('putaway', 'pick_face')),
  -- One of three scopes, narrowest first: a named product, a product class,
  -- or everything at the site. Nulls are the widening, not an omission.
  item_id       uuid,
  item_class    text,
  location_id   uuid not null,
  priority      smallint not null default 100,
  -- How much of the rule's location this rule will fill before the next rule
  -- in priority order is used. Null means "as much as it takes".
  max_quantity  numeric(20,6) check (max_quantity is null or max_quantity > 0),
  valid_from    date not null default current_date,
  valid_to      date,
  status        erp.record_status not null default 'active',
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  unique (tenant_id, id),
  foreign key (tenant_id, site_id)     references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, location_id) references erp.location (tenant_id, id) on delete restrict,
  foreign key (tenant_id, item_id)     references erp.item (tenant_id, id) on delete restrict,
  constraint storage_rule_scope_is_one_thing
    check (item_id is null or item_class is null),
  constraint storage_rule_dates_order
    check (valid_to is null or valid_to >= valid_from)
);

create index if not exists storage_rule_lookup
  on erp.storage_rule (tenant_id, site_id, rule_kind, priority)
  where status = 'active';

comment on table erp.storage_rule is
  'Where a product belongs. One kind of rule for the place goods are put away '
  'to, one for the face they are picked from. Read by erp.raise_putaway_tasks, '
  'erp.raise_replenishment_tasks and erp.commit_allocation.';

select erp_meta.register_table('erp', 'storage_rule', 'tenant_scoped',
  'Warehouse layout. Which product belongs in which place, in what order.');

-- The resolver. Narrowest scope first, then the rule's own priority, then the
-- location code so two equal rules never tie by accident. Blocked and inactive
-- targets are not candidates at all.
create or replace function erp.resolve_storage_locations(
  p_item_id uuid, p_site_id uuid, p_kind text)
returns table (location_id uuid, max_quantity numeric, priority smallint)
language sql
stable
set search_path = ''
as $$
  select r.location_id, r.max_quantity, r.priority
    from erp.storage_rule r
    join erp.location l
      on l.tenant_id = r.tenant_id and l.id = r.location_id
    left join erp.item i
      on i.tenant_id = r.tenant_id and i.id = p_item_id
   where r.tenant_id = erp.current_tenant_id()
     and r.site_id = p_site_id
     and r.rule_kind = p_kind
     and r.status = 'active'::erp.record_status
     and r.valid_from <= current_date
     and (r.valid_to is null or r.valid_to >= current_date)
     and (r.item_id = p_item_id
          or (r.item_id is null
              and (r.item_class is null or r.item_class = i.item_class)))
     and l.status = 'active'::erp.record_status
     and coalesce(l.is_blocked, false) = false
   order by (r.item_id is null)::int, (r.item_class is null)::int,
            r.priority, l.code
$$;

comment on function erp.resolve_storage_locations is
  'The places a product belongs at a site, best first: a rule naming the '
  'product beats a rule naming its class, which beats a rule naming neither.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. The layout doors
-- ═══════════════════════════════════════════════════════════════════════════

drop function if exists public.erp_create_location(uuid, text, text, text);
drop function if exists erp.create_location(uuid, text, text, text);

create or replace function erp.create_location(
  p_site_id uuid,
  p_code text,
  p_name text default null,
  p_location_type text default 'bulk',
  p_parent_location_id uuid default null,
  p_is_pickable boolean default null,
  p_capacity_quantity numeric default null,
  p_capacity_uom text default null,
  p_count_class text default null
) returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
  v_type erp.location_type;
begin
  perform erp.authorise('administration.configure', null, p_site_id, null, 'location', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'CLOVEERP_LOCATION_CODE_REQUIRED: a location needs a code'
      using errcode = '23514';
  end if;

  if not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id) then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503';
  end if;

  if p_parent_location_id is not null
     and not exists (select 1 from erp.location l
                      where l.tenant_id = v_tenant and l.id = p_parent_location_id
                        and l.site_id = p_site_id) then
    raise exception 'CLOVEERP_UNKNOWN_PARENT_LOCATION: % is not a place at this site',
      p_parent_location_id
      using errcode = '23503',
            hint = 'A place sits inside another place at the same site, or inside nothing.';
  end if;

  v_type := p_location_type::erp.location_type;

  insert into erp.location (
    tenant_id, site_id, code, name, location_type, parent_location_id,
    is_pickable, capacity, count_class, status)
  values (
    v_tenant, p_site_id, trim(p_code),
    coalesce(nullif(trim(coalesce(p_name, '')), ''), trim(p_code)),
    v_type, p_parent_location_id,
    coalesce(p_is_pickable, v_type = 'pick'::erp.location_type),
    case when p_capacity_quantity is null then '{}'::jsonb
         else jsonb_build_object('quantity', p_capacity_quantity,
                                 'uom', coalesce(p_capacity_uom, 'EA')) end,
    nullif(trim(coalesce(p_count_class, '')), ''),
    'active')
  returning id into v_id;

  return v_id;
end $$;

create or replace function erp.update_location(
  p_location_id uuid,
  p_name text default null,
  p_location_type text default null,
  p_parent_location_id uuid default null,
  p_is_pickable boolean default null,
  p_capacity_quantity numeric default null,
  p_capacity_uom text default null,
  p_count_class text default null
) returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l erp.location%rowtype;
begin
  select * into l from erp.location
   where tenant_id = v_tenant and id = p_location_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LOCATION: %', p_location_id using errcode = '23503';
  end if;

  perform erp.authorise('administration.configure', null, l.site_id, null,
                        'location', p_location_id);

  if p_parent_location_id is not null then
    if p_parent_location_id = p_location_id then
      raise exception 'CLOVEERP_LOCATION_OWN_PARENT: a place cannot sit inside itself'
        using errcode = '23514';
    end if;
    if not exists (select 1 from erp.location p
                    where p.tenant_id = v_tenant and p.id = p_parent_location_id
                      and p.site_id = l.site_id) then
      raise exception 'CLOVEERP_UNKNOWN_PARENT_LOCATION: % is not a place at this site',
        p_parent_location_id using errcode = '23503';
    end if;
  end if;

  update erp.location
     set name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
         location_type = coalesce(p_location_type::erp.location_type, location_type),
         parent_location_id = coalesce(p_parent_location_id, parent_location_id),
         is_pickable = coalesce(p_is_pickable, is_pickable),
         capacity = case when p_capacity_quantity is null then capacity
                         else jsonb_build_object(
                                'quantity', p_capacity_quantity,
                                'uom', coalesce(p_capacity_uom, capacity ->> 'uom', 'EA')) end,
         count_class = coalesce(nullif(trim(coalesce(p_count_class, '')), ''), count_class),
         updated_at = now()
   where tenant_id = v_tenant and id = p_location_id;

  return p_location_id;
end $$;

create or replace function erp.block_location(p_location_id uuid, p_reason_code text default null)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site uuid;
begin
  select site_id into v_site from erp.location
   where tenant_id = v_tenant and id = p_location_id;
  if v_site is null then
    raise exception 'CLOVEERP_UNKNOWN_LOCATION: %', p_location_id using errcode = '23503';
  end if;

  perform erp.authorise('administration.configure', null, v_site, null,
                        'location', p_location_id);

  update erp.location
     set is_blocked = true,
         block_reason_code = nullif(trim(coalesce(p_reason_code, '')), ''),
         updated_at = now()
   where tenant_id = v_tenant and id = p_location_id;

  return p_location_id;
end $$;

create or replace function erp.unblock_location(p_location_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site uuid;
begin
  select site_id into v_site from erp.location
   where tenant_id = v_tenant and id = p_location_id;
  if v_site is null then
    raise exception 'CLOVEERP_UNKNOWN_LOCATION: %', p_location_id using errcode = '23503';
  end if;

  perform erp.authorise('administration.configure', null, v_site, null,
                        'location', p_location_id);

  update erp.location
     set is_blocked = false, block_reason_code = null, updated_at = now()
   where tenant_id = v_tenant and id = p_location_id;

  return p_location_id;
end $$;

create or replace function erp.create_storage_rule(
  p_site_id uuid,
  p_location_id uuid,
  p_rule_kind text default 'putaway',
  p_item_id uuid default null,
  p_item_class text default null,
  p_priority integer default 100,
  p_max_quantity numeric default null
) returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('inventory.adjust', null, p_site_id, null, 'storage_rule', null);

  if p_rule_kind not in ('putaway', 'pick_face') then
    raise exception 'CLOVEERP_STORAGE_RULE_KIND_UNKNOWN: % is not a kind of rule', p_rule_kind
      using errcode = '23514',
            hint = 'A rule is either putaway — where goods are put — or pick_face — where they are picked from.';
  end if;

  if p_item_id is not null and nullif(trim(coalesce(p_item_class, '')), '') is not null then
    raise exception 'CLOVEERP_STORAGE_RULE_SCOPE: name a product or a product class, not both'
      using errcode = '23514';
  end if;

  if not exists (select 1 from erp.location l
                  where l.tenant_id = v_tenant and l.id = p_location_id
                    and l.site_id = p_site_id) then
    raise exception 'CLOVEERP_UNKNOWN_LOCATION: % is not a place at that site', p_location_id
      using errcode = '23503';
  end if;

  insert into erp.storage_rule (
    tenant_id, site_id, rule_kind, item_id, item_class, location_id,
    priority, max_quantity)
  values (
    v_tenant, p_site_id, p_rule_kind, p_item_id,
    nullif(trim(coalesce(p_item_class, '')), ''), p_location_id,
    greatest(coalesce(p_priority, 100), 1)::smallint, p_max_quantity)
  returning id into v_id;

  return v_id;
end $$;

create or replace function erp.remove_storage_rule(p_storage_rule_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site uuid;
begin
  select site_id into v_site from erp.storage_rule
   where tenant_id = v_tenant and id = p_storage_rule_id;
  if v_site is null then
    raise exception 'CLOVEERP_UNKNOWN_STORAGE_RULE: %', p_storage_rule_id using errcode = '23503';
  end if;

  perform erp.authorise('inventory.adjust', null, v_site, null,
                        'storage_rule', p_storage_rule_id);

  update erp.storage_rule
     set status = 'archived'::erp.record_status, updated_at = now()
   where tenant_id = v_tenant and id = p_storage_rule_id;

  return p_storage_rule_id;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. The reads and the public doors
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.erp_locations(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'location_id', l.id, 'code', l.code, 'name', l.name,
           'site', s.code, 'site_id', l.site_id,
           'location_type', l.location_type,
           'parent_location_id', l.parent_location_id,
           'parent', p.code,
           'depth', l.depth,
           'capacity_quantity', (l.capacity ->> 'quantity')::numeric,
           'capacity_uom', l.capacity ->> 'uom',
           'count_class', l.count_class,
           'on_hand', coalesce((select sum(sb.quantity) from erp.stock_balance sb
                                 where sb.tenant_id = l.tenant_id
                                   and sb.location_id = l.id), 0),
           'is_pickable', l.is_pickable, 'is_blocked', l.is_blocked,
           'block_reason_code', l.block_reason_code)
           order by s.code, coalesce(p.code, l.code), l.depth, l.code), '[]'::jsonb)
    from erp.location l
    join erp.site s on s.tenant_id = l.tenant_id and s.id = l.site_id
    left join erp.location p on p.tenant_id = l.tenant_id and p.id = l.parent_location_id
   where l.tenant_id = erp.current_tenant_id()
     and l.status = 'active'::erp.record_status
     and (p_site_id is null or l.site_id = p_site_id);
$$;

create or replace function public.erp_storage_rules(
  p_site_id uuid default null, p_rule_kind text default null)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'storage_rule_id', r.id,
           'site', s.code, 'site_id', r.site_id,
           'rule_kind', r.rule_kind,
           'scope', coalesce(i.code, r.item_class, 'Everything'),
           'item', i.code, 'item_name', i.name, 'item_class', r.item_class,
           'location', l.code, 'location_name', l.name, 'location_id', r.location_id,
           'priority', r.priority,
           'max_quantity', r.max_quantity,
           'is_blocked', l.is_blocked)
           order by s.code, r.rule_kind, r.priority, l.code), '[]'::jsonb)
    from erp.storage_rule r
    join erp.site s on s.tenant_id = r.tenant_id and s.id = r.site_id
    join erp.location l on l.tenant_id = r.tenant_id and l.id = r.location_id
    left join erp.item i on i.tenant_id = r.tenant_id and i.id = r.item_id
   where r.tenant_id = erp.current_tenant_id()
     and r.status = 'active'::erp.record_status
     and (p_site_id is null or r.site_id = p_site_id)
     and (p_rule_kind is null or r.rule_kind = p_rule_kind);
$$;

create or replace function public.erp_create_location(
  p_site_id uuid,
  p_code text,
  p_name text default null,
  p_location_type text default 'bulk',
  p_parent_location_id uuid default null,
  p_is_pickable boolean default null,
  p_capacity_quantity numeric default null,
  p_capacity_uom text default null,
  p_count_class text default null
) returns uuid
language sql
set search_path to ''
as $$ select erp.create_location(p_site_id, p_code, p_name, p_location_type,
                                 p_parent_location_id, p_is_pickable,
                                 p_capacity_quantity, p_capacity_uom, p_count_class) $$;

create or replace function public.erp_update_location(
  p_location_id uuid,
  p_name text default null,
  p_location_type text default null,
  p_parent_location_id uuid default null,
  p_is_pickable boolean default null,
  p_capacity_quantity numeric default null,
  p_capacity_uom text default null,
  p_count_class text default null
) returns uuid
language sql
set search_path to ''
as $$ select erp.update_location(p_location_id, p_name, p_location_type,
                                 p_parent_location_id, p_is_pickable,
                                 p_capacity_quantity, p_capacity_uom, p_count_class) $$;

create or replace function public.erp_block_location(
  p_location_id uuid, p_reason_code text default null)
returns uuid language sql set search_path to ''
as $$ select erp.block_location(p_location_id, p_reason_code) $$;

create or replace function public.erp_unblock_location(p_location_id uuid)
returns uuid language sql set search_path to ''
as $$ select erp.unblock_location(p_location_id) $$;

create or replace function public.erp_create_storage_rule(
  p_site_id uuid,
  p_location_id uuid,
  p_rule_kind text default 'putaway',
  p_item_id uuid default null,
  p_item_class text default null,
  p_priority integer default 100,
  p_max_quantity numeric default null
) returns uuid
language sql
set search_path to ''
as $$ select erp.create_storage_rule(p_site_id, p_location_id, p_rule_kind,
                                     p_item_id, p_item_class, p_priority, p_max_quantity) $$;

create or replace function public.erp_remove_storage_rule(p_storage_rule_id uuid)
returns uuid language sql set search_path to ''
as $$ select erp.remove_storage_rule(p_storage_rule_id) $$;

revoke all on function public.erp_locations(uuid) from public, anon;
grant execute on function public.erp_locations(uuid) to authenticated, service_role;
revoke all on function public.erp_storage_rules(uuid, text) from public, anon;
grant execute on function public.erp_storage_rules(uuid, text) to authenticated, service_role;
revoke all on function public.erp_create_location(uuid, text, text, text, uuid, boolean, numeric, text, text) from public, anon;
grant execute on function public.erp_create_location(uuid, text, text, text, uuid, boolean, numeric, text, text) to authenticated, service_role;
revoke all on function public.erp_update_location(uuid, text, text, uuid, boolean, numeric, text, text) from public, anon;
grant execute on function public.erp_update_location(uuid, text, text, uuid, boolean, numeric, text, text) to authenticated, service_role;
revoke all on function public.erp_block_location(uuid, text) from public, anon;
grant execute on function public.erp_block_location(uuid, text) to authenticated, service_role;
revoke all on function public.erp_unblock_location(uuid) from public, anon;
grant execute on function public.erp_unblock_location(uuid) to authenticated, service_role;
revoke all on function public.erp_create_storage_rule(uuid, uuid, text, uuid, text, integer, numeric) from public, anon;
grant execute on function public.erp_create_storage_rule(uuid, uuid, text, uuid, text, integer, numeric) to authenticated, service_role;
revoke all on function public.erp_remove_storage_rule(uuid) from public, anon;
grant execute on function public.erp_remove_storage_rule(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_location', 'erp.create_location',
   'Creates a storage place within a site — a zone, an aisle, a bin — under '
   'administration.configure.'),
  ('erp_update_location', 'erp.update_location',
   'Renames a storage place, moves it inside another, sets what it holds and '
   'how often it is counted, under administration.configure.'),
  ('erp_block_location', 'erp.block_location',
   'Blocks a storage place so nothing is put there or picked from it, under '
   'administration.configure. The stock standing in it stays where it is.'),
  ('erp_unblock_location', 'erp.unblock_location',
   'Returns a blocked storage place to use, under administration.configure.'),
  ('erp_create_storage_rule', 'erp.create_storage_rule',
   'States where a product belongs at a site, for putting away or for '
   'picking, under inventory.adjust. Read by put-away, replenishment and '
   'allocation.'),
  ('erp_remove_storage_rule', 'erp.remove_storage_rule',
   'Withdraws a storage rule, under inventory.adjust.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. The routines that now read the layout
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function erp.raise_putaway_tasks(p_site_id uuid)
returns integer language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_created integer := 0;
  r record;
  c record;
  v_target uuid;
  v_standing numeric;
begin
  perform erp.authorise('inventory.adjust', null, p_site_id, null, 'site', p_site_id);

  for r in
    select sb.item_id, sb.batch_id, sb.location_id, sb.stock_status, sum(sb.quantity) as qty
      from erp.stock_balance sb
      join erp.location l on l.tenant_id = sb.tenant_id and l.id = sb.location_id
     where sb.tenant_id = v_tenant
       and sb.site_id = p_site_id
       and sb.quantity > 0
       and l.location_type = 'receiving'::erp.location_type
     group by 1, 2, 3, 4
  loop
    v_target := null;

    -- The layout first: the places the product belongs, best rule first, with
    -- a rule skipped when its place already holds what the rule allows.
    for c in
      select * from erp.resolve_storage_locations(r.item_id, p_site_id, 'putaway')
    loop
      if c.max_quantity is null then
        v_target := c.location_id;
        exit;
      end if;

      select coalesce(sum(sb.quantity), 0) into v_standing
        from erp.stock_balance sb
       where sb.tenant_id = v_tenant and sb.location_id = c.location_id;

      if v_standing < c.max_quantity then
        v_target := c.location_id;
        exit;
      end if;
    end loop;

    -- No rule reaches this product: the old behaviour, which is bulk before
    -- pick face and code order within that.
    if v_target is null then
      select l.id into v_target
        from erp.location l
       where l.tenant_id = v_tenant and l.site_id = p_site_id
         and l.status = 'active'::erp.record_status
         and coalesce(l.is_blocked, false) = false
         and l.location_type in ('bulk'::erp.location_type, 'pick'::erp.location_type)
       order by case when l.location_type = 'bulk'::erp.location_type then 0 else 1 end, l.code
       limit 1;
    end if;

    if v_target is null or v_target = r.location_id then
      continue;
    end if;

    if exists (select 1 from erp.warehouse_task t
                where t.tenant_id = v_tenant and t.status = 'open' and t.kind = 'putaway'
                  and t.item_id = r.item_id and t.from_location_id = r.location_id
                  and coalesce(t.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                      = coalesce(r.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)) then
      continue;
    end if;

    insert into erp.warehouse_task (tenant_id, site_id, kind, item_id, batch_id,
      from_location_id, to_location_id, stock_status, quantity, created_by, updated_by)
    values (v_tenant, p_site_id, 'putaway', r.item_id, r.batch_id,
      r.location_id, v_target, r.stock_status, r.qty, v_actor, v_actor);
    v_created := v_created + 1;
  end loop;

  return v_created;
end $$;

comment on function erp.raise_putaway_tasks is
  'Raises a putaway task for every position standing in a receiving location, '
  'sending it to the place the site''s storage rules name for that product — '
  'skipping a place that is blocked or already holds what its rule allows — '
  'and to the first open bulk location when no rule reaches it.';

create or replace function erp.raise_replenishment_tasks(p_site_id uuid)
returns integer language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_created integer := 0;
  r record;
  v_to uuid;
begin
  perform erp.authorise('inventory.adjust', null, p_site_id, null, 'site', p_site_id);

  for r in
    with pick as (
      select a.item_id,
             sum(a.available) as available,
             sum(a.committed) as committed,
             min(a.location_id) as location_id
        from erp.stock_availability a
        join erp.location l on l.tenant_id = a.tenant_id and l.id = a.location_id
       where a.tenant_id = v_tenant and a.site_id = p_site_id
         and coalesce(l.is_pickable, false) = true
       group by a.item_id
    ), reserve as (
      select sb.item_id, sb.location_id, sb.batch_id, sb.stock_status, sum(sb.quantity) as qty
        from erp.stock_balance sb
        join erp.location l on l.tenant_id = sb.tenant_id and l.id = sb.location_id
       where sb.tenant_id = v_tenant and sb.site_id = p_site_id and sb.quantity > 0
         and coalesce(l.is_pickable, false) = false
         and l.location_type = 'bulk'::erp.location_type
       group by 1, 2, 3, 4
    )
    select p.item_id, p.location_id as to_location_id, rs.location_id as from_location_id,
           rs.batch_id, rs.stock_status,
           least(p.committed - p.available, rs.qty) as qty
      from pick p
      join reserve rs on rs.item_id = p.item_id
     where p.committed > p.available
       and p.location_id is not null
  loop
    if r.qty is null or r.qty <= 0 then
      continue;
    end if;

    -- The pick face the layout names, when it names one.
    select coalesce(
             (select location_id from erp.resolve_storage_locations(r.item_id, p_site_id, 'pick_face') limit 1),
             r.to_location_id)
      into v_to;

    if v_to = r.from_location_id then
      continue;
    end if;

    if exists (select 1 from erp.warehouse_task t
                where t.tenant_id = v_tenant and t.status = 'open' and t.kind = 'replenishment'
                  and t.item_id = r.item_id and t.to_location_id = v_to) then
      continue;
    end if;

    insert into erp.warehouse_task (tenant_id, site_id, kind, item_id, batch_id,
      from_location_id, to_location_id, stock_status, quantity, created_by, updated_by)
    values (v_tenant, p_site_id, 'replenishment', r.item_id, r.batch_id,
      r.from_location_id, v_to, r.stock_status, r.qty, v_actor, v_actor);
    v_created := v_created + 1;
  end loop;

  return v_created;
end $$;

comment on function erp.raise_replenishment_tasks is
  'Tops up a short pick face from bulk reserve, into the face the site''s '
  'storage rules name for the product when they name one.';

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();