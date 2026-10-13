-- A product is made through its operations.
--
-- Manufacturing depth, part 1 of 4 (theme 3 of the post-v1 programme, owner,
-- 13 October 2026). A works order copies its operations from the product's
-- routing (erp.raise_works_order), and its hours are booked against them
-- (erp_book_operation_time); the planning run and the cost roll-up read the
-- routing too. But nothing made a routing: no door, no screen, no seed, so
-- every works order had no operations and no hours could be booked. And a
-- routing names its work centres by code with nothing to say what a work centre
-- can do, so nobody could see whether the floor could make what was planned.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.work_centre: a place the work is done at a site, its hours a day,
--      days a week, efficiency and cost an hour. public.erp_define_work_centre
--      (defines or changes one by its code), erp_retire_work_centre and
--      erp_work_centres.
--   B. public.erp_define_routing: a product's operations in order, each at a
--      work centre of the site, with its set-up and run minutes; a new version
--      supersedes the one in force, as a bill of materials does. Its cost an
--      hour is the work centre's unless the operation says. Withdrawn with
--      erp_withdraw_routing; listed by erp_routings.
--   C. public.erp_work_centre_load: for each work centre, week by week, the
--      minutes it can give and the minutes asked of it — the operations left
--      on released works orders, and the production the latest plan suggests
--      — so an overloaded week is seen before it is late.
--   D. erp_test.work_centre_suite proves A to C.
--
-- Defining work centres and routings asks for production.order, as defining a
-- bill of materials does.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Work centres
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.work_centre (
  id                       uuid primary key default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant(id) on delete cascade,
  site_id                  uuid not null,
  code                     text not null,
  name                     text not null,
  hours_per_day            numeric(5,2) not null,
  days_per_week            integer not null default 5,
  efficiency_pct           numeric(5,2) not null default 100,
  cost_rate_minor_per_hour bigint not null default 0,
  status                   text not null default 'active',
  retired_reason           text,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  constraint work_centre_tenant_id_id_key unique (tenant_id, id),
  constraint work_centre_site_fk foreign key (tenant_id, site_id) references erp.site(tenant_id, id) on delete restrict,
  constraint work_centre_code_shape check (code ~ '^[A-Z0-9][A-Z0-9-]{0,19}$'),
  constraint work_centre_named check (btrim(name) <> ''),
  constraint work_centre_hours check (hours_per_day > 0 and hours_per_day <= 24),
  constraint work_centre_days check (days_per_week between 1 and 7),
  constraint work_centre_efficiency check (efficiency_pct > 0 and efficiency_pct <= 200),
  constraint work_centre_rate check (cost_rate_minor_per_hour >= 0),
  constraint work_centre_status_known check (status in ('active', 'inactive')),
  constraint work_centre_retired_said check (status = 'active' or btrim(coalesce(retired_reason, '')) <> '')
);
create unique index if not exists work_centre_code_once
  on erp.work_centre (tenant_id, site_id, code) where status = 'active';

comment on table erp.work_centre is
  'A work centre (20261013080000): where operations are done at a site, the hours a day and days a week it works, '
  'how efficiently, and what an hour of it costs. Routings name it by code.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'work_centre', 'tenant_scoped', 'A work centre at a site, with its capacity and cost an hour; retired with a reason.')
on conflict (schema_name, table_name) do nothing;

create or replace function erp.define_work_centre(p_site_id uuid, p_code text, p_name text, p_hours_per_day numeric,
                                                  p_days_per_week integer default 5, p_efficiency_pct numeric default 100,
                                                  p_cost_rate_minor_per_hour bigint default 0)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_id     uuid;
begin
  perform erp.authorise('production.order', null, p_site_id, null, 'work_centre', null, null);
  if not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id) then
    raise exception 'CLOVEERP_WORK_CENTRE_INVALID: a work centre belongs to one of the organisation''s sites'
      using errcode = '23503', hint = 'Choose the site the work is done at.';
  end if;
  if v_code !~ '^[A-Z0-9][A-Z0-9-]{0,19}$' or nullif(btrim(coalesce(p_name, '')), '') is null
     or coalesce(p_hours_per_day, 0) <= 0 or p_hours_per_day > 24
     or coalesce(p_days_per_week, 5) not between 1 and 7
     or coalesce(p_efficiency_pct, 100) <= 0 or coalesce(p_efficiency_pct, 100) > 200
     or coalesce(p_cost_rate_minor_per_hour, 0) < 0 then
    raise exception 'CLOVEERP_WORK_CENTRE_INVALID: a work centre needs a short code, a name, the hours it works a day (up to 24), one to seven days a week, and an efficiency above nothing'
      using errcode = '23514', hint = 'Give a code such as MIX-1, its name, and the hours it is staffed a day.';
  end if;

  update erp.work_centre w
     set name = btrim(p_name), hours_per_day = p_hours_per_day, days_per_week = coalesce(p_days_per_week, 5),
         efficiency_pct = coalesce(p_efficiency_pct, 100),
         cost_rate_minor_per_hour = coalesce(p_cost_rate_minor_per_hour, 0), updated_at = now()
   where w.tenant_id = v_tenant and w.site_id = p_site_id and w.code = v_code and w.status = 'active'
  returning w.id into v_id;
  if v_id is null then
    insert into erp.work_centre (tenant_id, site_id, code, name, hours_per_day, days_per_week, efficiency_pct,
                                 cost_rate_minor_per_hour)
    values (v_tenant, p_site_id, v_code, btrim(p_name), p_hours_per_day, coalesce(p_days_per_week, 5),
            coalesce(p_efficiency_pct, 100), coalesce(p_cost_rate_minor_per_hour, 0))
    returning id into v_id;
  end if;
  return jsonb_build_object('work_centre_id', v_id, 'code', v_code);
end;
$$;
revoke all on function erp.define_work_centre(uuid, text, text, numeric, integer, numeric, bigint) from public, anon;

create or replace function public.erp_define_work_centre(p_site_id uuid, p_code text, p_name text, p_hours_per_day numeric,
                                                         p_days_per_week integer default 5, p_efficiency_pct numeric default 100,
                                                         p_cost_rate_minor_per_hour bigint default 0)
returns jsonb
language sql
set search_path = ''
as $$ select erp.define_work_centre(p_site_id, p_code, p_name, p_hours_per_day, p_days_per_week, p_efficiency_pct,
                                    p_cost_rate_minor_per_hour) $$;
revoke all on function public.erp_define_work_centre(uuid, text, text, numeric, integer, numeric, bigint) from public, anon;
grant execute on function public.erp_define_work_centre(uuid, text, text, numeric, integer, numeric, bigint) to authenticated, service_role;
comment on function public.erp_define_work_centre(uuid, text, text, numeric, integer, numeric, bigint) is
  'Defines a work centre at a site, or changes the one of that code: its hours a day, days a week, efficiency and cost '
  'an hour (20261013080000). Authorises production.order.';

create or replace function erp.retire_work_centre(p_work_centre_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  w        erp.work_centre%rowtype;
begin
  select x.* into w from erp.work_centre x where x.tenant_id = v_tenant and x.id = p_work_centre_id for update;
  perform erp.authorise('production.order', null, w.site_id, null, 'work_centre', p_work_centre_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_WORK_CENTRE_RETIRE_NEEDS_A_REASON: retiring a work centre needs a reason'
      using errcode = '23514', hint = 'Say why the work centre is no longer used.';
  end if;
  if w.id is null or w.status <> 'active' then
    raise exception 'CLOVEERP_WORK_CENTRE_INVALID: there is no such work centre in use'
      using errcode = '23514', hint = 'Refresh the work centres and choose again.';
  end if;
  if exists (select 1 from erp.routing_operation ro join erp.routing r on r.tenant_id = ro.tenant_id and r.id = ro.routing_id
              where ro.tenant_id = v_tenant and ro.work_centre_code = w.code and r.status = 'active'
                and (r.site_id is null or r.site_id = w.site_id)) then
    raise exception 'CLOVEERP_WORK_CENTRE_IN_USE: a routing in force still sends work to %', w.code
      using errcode = '23514', hint = 'Define the routings that use it again without it, then retire it.';
  end if;
  update erp.work_centre set status = 'inactive', retired_reason = btrim(p_reason), updated_at = now()
   where tenant_id = v_tenant and id = w.id;
  return jsonb_build_object('work_centre_id', w.id, 'retired', true);
end;
$$;
revoke all on function erp.retire_work_centre(uuid, text) from public, anon;

create or replace function public.erp_retire_work_centre(p_work_centre_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.retire_work_centre(p_work_centre_id, p_reason) $$;
revoke all on function public.erp_retire_work_centre(uuid, text) from public, anon;
grant execute on function public.erp_retire_work_centre(uuid, text) to authenticated, service_role;
comment on function public.erp_retire_work_centre(uuid, text) is
  'Retires a work centre no routing in force uses, with a reason (20261013080000). Authorises production.order.';

create or replace function public.erp_work_centres()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'work_centre_id', w.id, 'code', w.code, 'name', w.name, 'site_id', w.site_id, 'site', s.code,
           'hours_per_day', w.hours_per_day, 'days_per_week', w.days_per_week, 'efficiency_pct', w.efficiency_pct,
           'minutes_per_week', round(w.hours_per_day * 60 * w.days_per_week * w.efficiency_pct / 100),
           'cost_rate_minor_per_hour', w.cost_rate_minor_per_hour, 'status', w.status,
           'retired_reason', w.retired_reason) order by w.status, s.code, w.code), '[]'::jsonb)
    from erp.work_centre w
    join erp.site s on s.tenant_id = w.tenant_id and s.id = w.site_id
   where w.tenant_id = erp.current_tenant_id()
$$;
revoke all on function public.erp_work_centres() from public, anon;
grant execute on function public.erp_work_centres() to authenticated, service_role;
comment on function public.erp_work_centres() is
  'The organisation''s work centres, those in use first, with the minutes each can give a week (20261013080000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Routings
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.define_routing(p_item_id uuid, p_site_id uuid, p_name text, p_operations jsonb,
                                              p_effective_from date default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_item_code text;
  v_version   integer;
  v_id        uuid;
  op          jsonb;
  v_seq       integer := 0;
  v_wc        erp.work_centre%rowtype;
  v_code      text;
  v_setup     numeric;
  v_run       numeric;
begin
  perform erp.authorise('production.order', null, p_site_id, null, 'routing', null, null);

  select i.code into v_item_code from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id and i.status = 'active'::erp.record_status;
  if v_item_code is null or not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id) then
    raise exception 'CLOVEERP_ROUTING_INVALID: a routing is for a product in use, at one of the organisation''s sites'
      using errcode = '23503', hint = 'Choose the product and the site it is made at.';
  end if;
  if p_operations is null or jsonb_typeof(p_operations) <> 'array' or jsonb_array_length(p_operations) = 0 then
    raise exception 'CLOVEERP_ROUTING_NEEDS_OPERATIONS: a routing needs at least one operation'
      using errcode = '23514', hint = 'Add each step the product goes through, in order, with where it is done.';
  end if;

  update erp.routing r
     set status = 'superseded'::erp.config_version_status, updated_at = now()
   where r.tenant_id = v_tenant and r.item_id = p_item_id and r.site_id = p_site_id
     and r.status = 'active'::erp.config_version_status;

  select coalesce(max(r.version), 0) + 1 into v_version
    from erp.routing r where r.tenant_id = v_tenant and r.item_id = p_item_id and r.site_id = p_site_id;

  insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
  values (v_tenant, 'RT-' || v_item_code || '-V' || v_version, p_item_id, p_site_id, v_version,
          nullif(btrim(coalesce(p_name, '')), ''), 'active'::erp.config_version_status,
          coalesce(p_effective_from, current_date))
  returning id into v_id;

  for op in select value from jsonb_array_elements(p_operations) loop
    v_seq := v_seq + 10;
    v_code := upper(btrim(coalesce(op ->> 'work_centre_code', '')));
    select w.* into v_wc from erp.work_centre w
     where w.tenant_id = v_tenant and w.site_id = p_site_id and w.code = v_code and w.status = 'active';
    v_setup := coalesce(nullif(btrim(coalesce(op ->> 'setup_minutes', '')), '')::numeric, 0);
    v_run := coalesce(nullif(btrim(coalesce(op ->> 'run_minutes_per_unit', '')), '')::numeric, 0);
    if nullif(btrim(coalesce(op ->> 'name', '')), '') is null or v_setup < 0 or v_run < 0 or (v_setup = 0 and v_run = 0) then
      raise exception 'CLOVEERP_ROUTING_INVALID: operation % needs a name and minutes — set-up, run per unit, or both', v_seq / 10
        using errcode = '23514', hint = 'Give each operation its name and how long it takes.';
    end if;
    if v_wc.id is null then
      raise exception 'CLOVEERP_ROUTING_UNKNOWN_WORK_CENTRE: operation % is done at %, which is no work centre in use at the site', v_seq / 10, coalesce(nullif(v_code, ''), 'no work centre')
        using errcode = '23503', hint = 'Define the work centre at the site first, or choose one that is.';
    end if;
    insert into erp.routing_operation (tenant_id, routing_id, seq, code, name, work_centre_code, setup_minutes,
                                       run_minutes_per_unit, cost_rate_minor_per_hour, instructions)
    values (v_tenant, v_id, v_seq, 'OP' || v_seq, btrim(op ->> 'name'), v_code, v_setup, v_run,
            coalesce(nullif(btrim(coalesce(op ->> 'cost_rate_minor_per_hour', '')), '')::bigint, v_wc.cost_rate_minor_per_hour),
            nullif(btrim(coalesce(op ->> 'instructions', '')), ''));
  end loop;
  return v_id;
end;
$$;
revoke all on function erp.define_routing(uuid, uuid, text, jsonb, date) from public, anon;

create or replace function public.erp_define_routing(p_item_id uuid, p_site_id uuid, p_name text, p_operations jsonb,
                                                     p_effective_from date default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.define_routing(p_item_id, p_site_id, p_name, p_operations, p_effective_from) $$;
revoke all on function public.erp_define_routing(uuid, uuid, text, jsonb, date) from public, anon;
grant execute on function public.erp_define_routing(uuid, uuid, text, jsonb, date) to authenticated, service_role;
comment on function public.erp_define_routing(uuid, uuid, text, jsonb, date) is
  'Defines a product''s routing at a site: its operations in order, each at a work centre, with set-up and run minutes; '
  'a new version supersedes the one in force (20261013080000). Authorises production.order.';

create or replace function erp.withdraw_routing(p_routing_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.routing%rowtype;
begin
  select x.* into r from erp.routing x where x.tenant_id = v_tenant and x.id = p_routing_id for update;
  perform erp.authorise('production.order', null, r.site_id, null, 'routing', p_routing_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_ROUTING_WITHDRAW_NEEDS_A_REASON: withdrawing a routing needs a reason'
      using errcode = '23514', hint = 'Say why the routing no longer applies.';
  end if;
  if r.id is null or r.status <> 'active'::erp.config_version_status then
    raise exception 'CLOVEERP_ROUTING_INVALID: only a routing in force is withdrawn'
      using errcode = '23514', hint = 'Refresh the routings and choose again.';
  end if;
  update erp.routing set status = 'withdrawn'::erp.config_version_status, updated_at = now()
   where tenant_id = v_tenant and id = r.id;
  perform erp.append_event('routing.withdrawn', 'routing', r.id,
                           jsonb_build_object('code', r.code, 'reason', btrim(p_reason)), null);
  return jsonb_build_object('routing_id', r.id, 'withdrawn', true);
end;
$$;
revoke all on function erp.withdraw_routing(uuid, text) from public, anon;

create or replace function public.erp_withdraw_routing(p_routing_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.withdraw_routing(p_routing_id, p_reason) $$;
revoke all on function public.erp_withdraw_routing(uuid, text) from public, anon;
grant execute on function public.erp_withdraw_routing(uuid, text) to authenticated, service_role;
comment on function public.erp_withdraw_routing(uuid, text) is
  'Withdraws a routing in force, with a reason; works orders raised after it carry no operations until another is '
  'defined (20261013080000). Authorises production.order.';

create or replace function public.erp_routings()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'routing_id', r.id, 'code', r.code, 'item_id', r.item_id, 'item', i.code, 'item_name', i.name,
           'site', s.code, 'version', r.version, 'name', r.name, 'status', r.status::text,
           'effective_from', r.effective_from,
           'operations', (select count(*) from erp.routing_operation o where o.tenant_id = r.tenant_id and o.routing_id = r.id),
           'minutes_per_unit', (select coalesce(sum(o.run_minutes_per_unit), 0) from erp.routing_operation o
                                 where o.tenant_id = r.tenant_id and o.routing_id = r.id),
           'setup_minutes', (select coalesce(sum(o.setup_minutes), 0) from erp.routing_operation o
                              where o.tenant_id = r.tenant_id and o.routing_id = r.id),
           'steps', (select string_agg(o.name || ' @ ' || o.work_centre_code, ' → ' order by o.seq)
                       from erp.routing_operation o where o.tenant_id = r.tenant_id and o.routing_id = r.id))
           order by (r.status = 'active'::erp.config_version_status) desc, i.code, r.version desc), '[]'::jsonb)
    from erp.routing r
    join erp.item i on i.tenant_id = r.tenant_id and i.id = r.item_id
    left join erp.site s on s.tenant_id = r.tenant_id and s.id = r.site_id
   where r.tenant_id = erp.current_tenant_id()
$$;
revoke all on function public.erp_routings() from public, anon;
grant execute on function public.erp_routings() to authenticated, service_role;
comment on function public.erp_routings() is
  'The organisation''s routings, those in force first, with their operations in order (20261013080000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The load on each work centre
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_work_centre_load(p_site_id uuid default null, p_weeks integer default 8)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Week by week from this one (20261013080000): what each work centre in use
  -- can give — its hours a day by its days a week, at its efficiency — and
  -- what is asked of it: the operations not yet finished on released works
  -- orders, in the week each order is due to start (or finish, where it names
  -- no start), and the production the latest plan suggests, by the product's
  -- routing, in the week it is to be released. Work already late lands in
  -- this week, where it still has to be done.
  with t as (select erp.current_tenant_id() as tenant_id),
  weeks as (
    select (date_trunc('week', current_date)::date + (7 * n)) as week_start
      from generate_series(0, greatest(least(coalesce(p_weeks, 8), 26), 1) - 1) n
  ),
  centres as (
    select w.* from erp.work_centre w, t
     where w.tenant_id = t.tenant_id and w.status = 'active' and (p_site_id is null or w.site_id = p_site_id)
  ),
  from_orders as (
    select wo.site_id, op.work_centre_code as code,
           greatest(date_trunc('week', coalesce(wo.planned_start, wo.planned_end, current_date))::date,
                    date_trunc('week', current_date)::date) as week_start,
           sum(greatest(coalesce(op.planned_setup_minutes, 0) + coalesce(op.planned_run_minutes, 0)
                        - coalesce(op.actual_minutes, 0), 0)) as minutes
      from t
      join erp.works_order wo on wo.tenant_id = t.tenant_id
                             and wo.status in ('released'::erp.works_order_status, 'in_progress'::erp.works_order_status)
      join erp.works_order_operation op on op.tenant_id = wo.tenant_id and op.works_order_id = wo.id
                                       and op.completed_at is null
     group by 1, 2, 3
  ),
  latest_run as (
    select distinct on (pr.site_id) pr.id, pr.site_id
      from erp.planning_run pr, t
     where pr.tenant_id = t.tenant_id and not pr.is_scenario and pr.finished_at is not null
     order by pr.site_id, pr.finished_at desc
  ),
  from_plan as (
    select po.site_id, ro.work_centre_code as code,
           greatest(date_trunc('week', coalesce(po.release_on, po.required_by, current_date))::date,
                    date_trunc('week', current_date)::date) as week_start,
           sum(coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0) * po.quantity) as minutes
      from t
      join latest_run lr on true
      join erp.planned_order po on po.tenant_id = t.tenant_id and po.planning_run_id = lr.id
                               and po.order_kind = 'production'::erp.planned_order_kind
                               and po.status = 'suggested'::erp.planned_order_status
      join lateral (select r.id from erp.routing r
                     where r.tenant_id = po.tenant_id and r.item_id = po.item_id and r.status = 'active'::erp.config_version_status
                       and (r.site_id is null or r.site_id = po.site_id)
                     order by (r.site_id is not null) desc, r.version desc limit 1) r on true
      join erp.routing_operation ro on ro.tenant_id = po.tenant_id and ro.routing_id = r.id
     group by 1, 2, 3
  ),
  grid as (
    select c.code, c.name, c.site_id, wk.week_start,
           round(c.hours_per_day * 60 * c.days_per_week * c.efficiency_pct / 100) as available,
           coalesce((select sum(f.minutes) from from_orders f
                      where f.site_id = c.site_id and f.code = c.code and f.week_start = wk.week_start), 0) as orders,
           coalesce((select sum(f.minutes) from from_plan f
                      where f.site_id = c.site_id and f.code = c.code and f.week_start = wk.week_start), 0) as planned
      from centres c cross join weeks wk
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'work_centre', g.code, 'name', g.name,
           'site', (select s.code from erp.site s, t where s.tenant_id = t.tenant_id and s.id = g.site_id),
           'week_start', g.week_start, 'available_minutes', g.available,
           'works_order_minutes', round(g.orders), 'planned_minutes', round(g.planned),
           'load_minutes', round(g.orders + g.planned),
           'load_pct', case when g.available > 0 then round(100 * (g.orders + g.planned) / g.available) end,
           'overloaded', g.orders + g.planned > g.available)
           order by g.code, g.week_start), '[]'::jsonb)
    from grid g
$$;
revoke all on function public.erp_work_centre_load(uuid, integer) from public, anon;
grant execute on function public.erp_work_centre_load(uuid, integer) to authenticated, service_role;
comment on function public.erp_work_centre_load(uuid, integer) is
  'Each work centre''s minutes available and asked of it, week by week: operations left on released works orders and '
  'production the latest plan suggests (20261013080000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('routing.withdrawn', 1, 'routing', 'production', 'event.routing.withdrawn',
   'A routing in force was withdrawn, with a reason.',
   '{"type":"object","required":["code","reason"],"properties":{"code":{"type":"string"},"reason":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.routing.withdrawn', 'en', 'Routing withdrawn', 'production', 'Event raised when a routing in force is withdrawn.'),
  ('event.routing.withdrawn', 'de', 'Arbeitsplan zurückgezogen', 'production', 'Ereignis, wenn ein gültiger Arbeitsplan zurückgezogen wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_define_work_centre', 'erp.define_work_centre',
   'Defines or changes a work centre at a site, with its capacity and cost an hour; authorises production.order.'),
  ('erp_retire_work_centre', 'erp.retire_work_centre',
   'Retires a work centre no routing in force uses, with a reason; authorises production.order.'),
  ('erp_define_routing', 'erp.define_routing',
   'Defines a product''s routing at a site, superseding the version in force; authorises production.order.'),
  ('erp_withdraw_routing', 'erp.withdraw_routing',
   'Withdraws a routing in force, with a reason; authorises production.order.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_WORK_CENTRE_INVALID',
  'Defining a work centre without a short code, a name, its hours a day, its days a week or an efficiency, or for another organisation''s site; retiring one not in use.',
  'Capacity is worked out from those figures; one missing or impossible would make every load wrong.',
  'Give a code such as MIX-1, its name, the hours it is staffed a day, and the site.');
select erp.register_refusal('CLOVEERP_WORK_CENTRE_RETIRE_NEEDS_A_REASON',
  'Retiring a work centre without a reason.',
  'The next person planning the floor needs to know why it went.',
  'Say why the work centre is no longer used.');
select erp.register_refusal('CLOVEERP_WORK_CENTRE_IN_USE',
  'Retiring a work centre a routing in force still sends work to.',
  'Works orders raised from that routing would be sent to a place that no longer exists.',
  'Define the routings that use it again without it, then retire it.');
select erp.register_refusal('CLOVEERP_ROUTING_INVALID',
  'Defining a routing for a product not in use or a site the organisation does not have, an operation without a name or minutes, or withdrawing one not in force.',
  'A works order copies its operations from the routing; one without a name or a time cannot be booked against.',
  'Choose the product and the site, and give each operation its name and how long it takes.');
select erp.register_refusal('CLOVEERP_ROUTING_NEEDS_OPERATIONS',
  'Defining a routing with no operations.',
  'A routing is the steps a product goes through; with none, there is nothing to book hours against.',
  'Add each step the product goes through, in order.');
select erp.register_refusal('CLOVEERP_ROUTING_UNKNOWN_WORK_CENTRE',
  'Defining a routing with an operation at a work centre that is not in use at the site.',
  'The load on a work centre is added up from its operations; work sent nowhere is never seen.',
  'Define the work centre at the site first, or choose one that is.');
select erp.register_refusal('CLOVEERP_ROUTING_WITHDRAW_NEEDS_A_REASON',
  'Withdrawing a routing without a reason.',
  'Works orders raised afterwards carry no operations; the next person needs to know why.',
  'Say why the routing no longer applies.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Work centres, routings and their load on the Manufacturing page (20261013080000).'
  from (values
    ('Available (min)'),
    ('Capacity, eight weeks ahead'),
    ('Cost an hour'),
    ('Days a week'),
    ('Define a routing'),
    ('Define a work centre'),
    ('Each step in order, where it is done, and how long: set-up once a run, then minutes for each unit.'),
    ('Efficiency (%)'),
    ('Hours a day'),
    ('Load (%)'),
    ('Minutes a unit'),
    ('Minutes a week'),
    ('No routings yet. Define one from Actions so works orders carry operations to book hours against.'),
    ('No work centres yet. Define one from Actions, and give products routings, to see the load on each week by week.'),
    ('No work centres yet. Define one from Actions.'),
    ('Operations'),
    ('Optional. Useful when a product is made more than one way.'),
    ('Planned (min)'),
    ('Retire a work centre'),
    ('Routing'),
    ('Routings'),
    ('Set-up minutes'),
    ('Short, in capitals, as routings name it.'),
    ('The operations a product goes through at a site, in order, each at a work centre with its set-up and run minutes. A new routing replaces the one in force; works orders raised from now on carry it.'),
    ('The operations each made product goes through, version by version.'),
    ('The share of its hours that turns into work, after breaks and changeovers.'),
    ('What each work centre can give a week against what is asked of it: operations left on released works orders, and production the latest plan suggests.'),
    ('What the floor calls it.'),
    ('Where operations are done at a site: the hours it is staffed a day, the days a week, how efficiently, and what an hour costs. Defining one again by its code changes it.'),
    ('Where the work is done, and what each can give a week.'),
    ('Withdraw a routing'),
    ('Work centre'),
    ('Work centres'),
    ('Works orders (min)')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.work_centre_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_site   uuid;
  v_uom    uuid;
  v_fg     uuid;
  v_rm     uuid;
  v_r1     uuid;
  v_r2     uuid;
  v_wo     uuid;
  v_cs     uuid;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzwct' || v_tag, 'Work Centre Suite',
      'admin@demo-zzwct' || v_tag || '.test', 'Work Centre Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzwct' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'a site, a made product and its material';
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZWCFG' || v_tag, 'Work Centre Widget', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZWCRM' || v_tag, 'Work Centre Steel', v_uom, 'active') returning id into v_rm;

    -- ── 1. Work centres ─────────────────────────────────────────────────────
    v_step := 'work centres';
    perform public.erp_define_work_centre(v_site, 'mix-1', 'Mixer', 7.5, 5, 80, 2400);
    perform public.erp_define_work_centre(v_site, 'PACK-1', 'Packing line', 8, 5, 100, 1800);
    perform public.erp_define_work_centre(v_site, 'MIX-1', 'Mixer one', 8, 5, 75, 2600);
    begin
      perform public.erp_define_work_centre(v_site, 'BAD', 'Too long a day', 25);
      v_ok := false; v_msg := 'a 25-hour day';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_WORK_CENTRE_INVALID%'; v_msg := left(sqlerrm, 90);
    end;
    x := public.erp_work_centres();
    v_cases := v_cases + 1;
    case_name := 'a work centre is defined by its code, changed by defining it again, and refused an impossible day';
    passed := v_state is null and v_ok
          and (select count(*) from erp.work_centre w where w.tenant_id = v_tenant) = 2
          and exists (select 1 from jsonb_array_elements(x) w
                       where w ->> 'code' = 'MIX-1' and w ->> 'name' = 'Mixer one' and (w ->> 'minutes_per_week')::numeric = 1800);
    detail := coalesce(v_state, v_msg || ' | ' || left(x::text, 160));
    return next;

    -- ── 2. A routing at those work centres ──────────────────────────────────
    v_step := 'a routing';
    v_r1 := public.erp_define_routing(v_fg, v_site, 'Standard', '[
      {"name":"Mix","work_centre_code":"MIX-1","setup_minutes":30,"run_minutes_per_unit":2},
      {"name":"Pack","work_centre_code":"pack-1","run_minutes_per_unit":1,"instructions":"Ten to a case"}]'::jsonb);
    v_cases := v_cases + 1;
    case_name := 'a routing''s operations are kept in order, at their work centres, at the work centre''s cost an hour';
    passed := v_state is null
          and (select string_agg(o.name || ':' || o.work_centre_code || ':' || o.cost_rate_minor_per_hour, ',' order by o.seq)
                 from erp.routing_operation o where o.routing_id = v_r1) = 'Mix:MIX-1:2600,Pack:PACK-1:1800'
          and (select r.code from erp.routing r where r.id = v_r1) = 'RT-ZWCFG' || v_tag || '-V1';
    detail := coalesce(v_state, (select string_agg(o.name || ':' || o.work_centre_code, ',') from erp.routing_operation o where o.routing_id = v_r1));
    return next;

    -- ── 3. Refused ──────────────────────────────────────────────────────────
    v_step := 'routings refused';
    begin
      perform public.erp_define_routing(v_fg, v_site, null, '[{"name":"Weld","work_centre_code":"WELD-9","run_minutes_per_unit":3}]'::jsonb);
      v_ok := false; v_msg := 'an unknown work centre';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ROUTING_UNKNOWN_WORK_CENTRE%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_define_routing(v_fg, v_site, null, '[{"name":"Idle","work_centre_code":"MIX-1"}]'::jsonb);
      v_ok := false; v_msg := v_msg || ' | an operation with no minutes';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_ROUTING_INVALID%';
    end;
    begin
      perform public.erp_retire_work_centre((select w.id from erp.work_centre w where w.tenant_id = v_tenant and w.code = 'MIX-1'), 'replaced');
      v_ok := false; v_msg := v_msg || ' | a work centre in use retired';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_WORK_CENTRE_IN_USE%';
    end;
    v_cases := v_cases + 1;
    case_name := 'an unknown work centre, an operation with no time, and retiring a work centre a routing uses are refused';
    passed := v_state is null and v_ok and (select r.status::text from erp.routing r where r.id = v_r1) = 'active';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 4. A works order carries the operations ─────────────────────────────
    v_step := 'a works order';
    -- Production installed, as an organisation does from Configuration; before
    -- go-live its change is promoted as it is made.
    v_cs := erp.configure_production('manual');
    perform public.erp_create_bom(v_fg, null, null, 1, null,
      jsonb_build_array(jsonb_build_object('component_item_id', v_rm, 'quantity', 2)));
    v_wo := erp.raise_works_order(v_fg, v_site, 100, 'assembly', current_date + 1);
    v_cases := v_cases + 1;
    case_name := 'a works order raised for the product carries its routing''s operations, timed for its quantity';
    passed := v_state is null
          and (select string_agg(o.code || ':' || trim_scale(o.planned_setup_minutes) || ':' || trim_scale(o.planned_run_minutes), ',' order by o.seq)
                 from erp.works_order_operation o where o.works_order_id = v_wo) = 'OP10:30:200,OP20:0:100';
    detail := coalesce(v_state, (select string_agg(o.code || ':' || o.planned_setup_minutes || ':' || o.planned_run_minutes, ',')
                                   from erp.works_order_operation o where o.works_order_id = v_wo));
    return next;

    -- ── 5. The load ─────────────────────────────────────────────────────────
    v_step := 'the load';
    update erp.works_order set status = 'released', planned_start = current_date where id = v_wo;
    x := public.erp_work_centre_load(v_site, 4);
    v_cases := v_cases + 1;
    case_name := 'a released order''s operations load their work centres this week, against what each can give';
    passed := v_state is null
          and jsonb_array_length(x) = 8
          and exists (select 1 from jsonb_array_elements(x) l
                       where l ->> 'work_centre' = 'MIX-1' and (l ->> 'week_start')::date = date_trunc('week', current_date)::date
                         and (l ->> 'works_order_minutes')::numeric = 230 and (l ->> 'available_minutes')::numeric = 1800
                         and (l ->> 'load_pct')::numeric = 13 and not (l ->> 'overloaded')::boolean)
          and exists (select 1 from jsonb_array_elements(x) l
                       where l ->> 'work_centre' = 'MIX-1' and (l ->> 'week_start')::date = date_trunc('week', current_date)::date + 7
                         and (l ->> 'load_minutes')::numeric = 0);
    detail := coalesce(v_state, left(x::text, 300));
    return next;

    -- ── 6. A new version, and withdrawn ─────────────────────────────────────
    v_step := 'versions';
    v_r2 := public.erp_define_routing(v_fg, v_site, 'Faster', '[{"name":"Mix","work_centre_code":"MIX-1","run_minutes_per_unit":1.5}]'::jsonb);
    perform public.erp_withdraw_routing(v_r2, 'the new mixer is not commissioned');
    v_cases := v_cases + 1;
    case_name := 'a new routing supersedes the one in force, and is withdrawn with a reason';
    passed := v_state is null
          and (select r.status::text from erp.routing r where r.id = v_r1) = 'superseded'
          and (select r.status::text || ':' || r.version from erp.routing r where r.id = v_r2) = 'withdrawn:2'
          and (select count(*) from jsonb_array_elements(public.erp_routings()) r where r ->> 'item_id' = v_fg::text) = 2;
    detail := coalesce(v_state, public.erp_routings()::text);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_WORK_CENTRE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.work_centre_suite() from public, anon, authenticated;

create or replace function erp_test.assert_work_centre_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _work_centre on commit drop as
    select * from erp_test.work_centre_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _work_centre;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_WORK_CENTRE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_WORK_CENTRE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('work centres and routings: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_work_centre_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
select erp.assert_write_only_columns();
