-- =============================================================================
-- A season is fitted only when it repeats
--
-- Specification v1.6 §5.4 (v1.2), "statistical forecasting with model
-- selection, seasonality and event adjustment". Phase 8, file 3 of 10.
--
-- The register said: "Seasonality is not fitted: it needs at least two full
-- cycles of history and claiming it on less would be a fit to noise. Event
-- adjustment is manual through forecast_line.adjustment_reason." Both halves
-- stay true in spirit and stop being gaps:
--
--   * erp.fit_forecast()'s holt_winters branch fits additive seasonality when
--     — and only when — the series holds at least two full cycles of the
--     season the bucket implies (7 for days, 52 for weeks, 12 for months, 4
--     for quarters). Shorter history gets the linear trend it always got, and
--     erp.fit_forecast_explained() says which happened; the model choice
--     records it (seasonal, season_length) so a planner can see that a
--     twelve-month history was not pretended to be a cycle.
--   * erp.forecast_event is an event calendar: a promotion, a launch, a
--     closure — a window with a multiplier and a reason, for a site, an item
--     or everything. erp.run_forecast() applies every event that overlaps a
--     bucket and writes the reason on the line ('event:LAUNCH'); the
--     statistical figure is kept beside the adjusted one. A person's own
--     adjustment goes through erp.adjust_forecast_line(), which needs a reason
--     and refuses a version already signed off.
--
-- erp.select_forecast_method() gains the season so the backtest measures the
-- seasonal fit it would use; its single-argument form is dropped and
-- recreated with the default (an overload would leave two functions with one
-- name in the product schema).
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The fit
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.fit_forecast(numeric[],erp.forecast_method,integer,numeric,integer)'::regprocedure);
begin
  if position('-- Holt''s linear trend. Named holt_winters because that is the enum label' in v_src) = 0
     or position('v_avg1' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.fit_forecast is not the 20260829260000 body';
  end if;
end $$;

create or replace function erp.fit_forecast(p_series numeric[], p_method erp.forecast_method, p_periods integer,
                                            p_alpha numeric default 0.3, p_season integer default 12)
returns numeric[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  n        integer := coalesce(array_length(p_series, 1), 0);
  v_out    numeric[] := '{}';
  v_level  numeric;
  v_trend  numeric := 0;
  v_prev   numeric;
  v_s      numeric[];
  v_avg1   numeric;
  v_avg2   numeric;
  i        integer;
  v_idx    integer;
  v_win    integer;
  v_sum    numeric;
begin
  if n = 0 then return '{}'; end if;

  if p_method = 'moving_average' then
    v_win := least(3, n);
    select avg(x) into v_sum from unnest(p_series[n - v_win + 1 : n]) x;
    for i in 1 .. p_periods loop v_out := v_out || greatest(v_sum, 0); end loop;

  elsif p_method = 'exponential_smoothing' then
    v_level := p_series[1];
    for i in 2 .. n loop
      v_level := p_alpha * p_series[i] + (1 - p_alpha) * v_level;
    end loop;
    for i in 1 .. p_periods loop v_out := v_out || greatest(v_level, 0); end loop;

  elsif p_method = 'holt_winters' and coalesce(p_season, 0) >= 2 and n >= 2 * p_season then
    -- Additive Holt-Winters, fitted only where the season has repeated: the
    -- first cycle seeds the indices, the second seeds the trend, and the
    -- rest of the history smooths all three.
    select avg(x) into v_avg1 from unnest(p_series[1 : p_season]) x;
    select avg(x) into v_avg2 from unnest(p_series[p_season + 1 : 2 * p_season]) x;
    v_level := v_avg1;
    v_trend := (v_avg2 - v_avg1) / p_season;
    v_s := array_fill(0::numeric, array[n]);
    for i in 1 .. p_season loop
      v_s[i] := p_series[i] - v_avg1;
    end loop;
    for i in p_season + 1 .. n loop
      v_prev := v_level;
      v_level := p_alpha * (p_series[i] - v_s[i - p_season]) + (1 - p_alpha) * (v_level + v_trend);
      v_trend := 0.1 * (v_level - v_prev) + 0.9 * v_trend;
      v_s[i] := 0.2 * (p_series[i] - v_level) + 0.8 * v_s[i - p_season];
    end loop;
    for i in 1 .. p_periods loop
      v_idx := n - p_season + ((i - 1) % p_season) + 1;
      v_out := v_out || greatest(v_level + i * v_trend + v_s[v_idx], 0);
    end loop;

  elsif p_method = 'holt_winters' then
    -- Holt's linear trend. Named holt_winters because that is the enum label
    -- B7 chose; seasonality needs at least two full cycles of history and
    -- claiming it on eighteen months of data would be a fit to noise, so
    -- with less than that the branch above is not taken.
    if n < 2 then return erp.fit_forecast(p_series, 'moving_average', p_periods); end if;
    v_level := p_series[1];
    v_trend := p_series[2] - p_series[1];
    for i in 2 .. n loop
      v_prev := v_level;
      v_level := p_alpha * p_series[i] + (1 - p_alpha) * (v_level + v_trend);
      v_trend := 0.1 * (v_level - v_prev) + 0.9 * v_trend;
    end loop;
    for i in 1 .. p_periods loop
      v_out := v_out || greatest(v_level + i * v_trend, 0);
    end loop;

  else
    -- Anything else falls back to the flat mean, and the caller is told which
    -- method was actually used rather than which was asked for.
    select avg(x) into v_sum from unnest(p_series) x;
    for i in 1 .. p_periods loop v_out := v_out || greatest(coalesce(v_sum, 0), 0); end loop;
  end if;

  return v_out;
end;
$$;

create or replace function erp.fit_forecast_explained(p_series numeric[], p_method erp.forecast_method, p_periods integer,
                                                      p_alpha numeric default 0.3, p_season integer default 12)
returns table(forecast numeric[], seasonal boolean, season_length integer)
language sql
immutable
set search_path = ''
as $$
  select erp.fit_forecast(p_series, p_method, p_periods, p_alpha, p_season),
         p_method = 'holt_winters' and coalesce(p_season, 0) >= 2
           and coalesce(array_length(p_series, 1), 0) >= 2 * p_season,
         case when p_method = 'holt_winters' and coalesce(p_season, 0) >= 2
                   and coalesce(array_length(p_series, 1), 0) >= 2 * p_season
              then p_season end
$$;
revoke all on function erp.fit_forecast_explained(numeric[], erp.forecast_method, integer, numeric, integer) from public, anon, authenticated;

comment on function erp.fit_forecast_explained is
  'Specification v1.6 §5.4: the forecast and whether a season was fitted. A '
  'season is fitted only when the history holds two full cycles of it; the '
  'answer is what the model choice records, so nobody reads a twelve-month '
  'trend as a cycle.';

-- The backtest measures what would be used: the season goes in.
drop function if exists erp.select_forecast_method(numeric[]);
create function erp.select_forecast_method(p_series numeric[], p_season integer default 12)
returns table(method erp.forecast_method, mape numeric)
language plpgsql
immutable
set search_path = ''
as $$
declare
  n       integer := coalesce(array_length(p_series, 1), 0);
  v_hold  integer;
  v_train numeric[];
  v_test  numeric[];
  v_pred  numeric[];
  m       erp.forecast_method;
  v_err   numeric;
  v_denom numeric;
  i       integer;
begin
  if n < 6 then
    method := 'moving_average'; mape := null; return next; return;
  end if;

  v_hold := greatest(1, n / 4);
  v_train := p_series[1 : n - v_hold];
  v_test  := p_series[n - v_hold + 1 : n];

  foreach m in array array['moving_average', 'exponential_smoothing', 'holt_winters']::erp.forecast_method[]
  loop
    v_pred := erp.fit_forecast(v_train, m, v_hold, 0.3, p_season);
    v_err := 0; v_denom := 0;
    for i in 1 .. v_hold loop
      v_err := v_err + abs(v_test[i] - v_pred[i]);
      v_denom := v_denom + abs(v_test[i]);
    end loop;
    method := m;
    mape := case when v_denom = 0 then null else round(100 * v_err / v_denom, 2) end;
    return next;
  end loop;
end;
$$;
revoke all on function erp.select_forecast_method(numeric[], integer) from public, anon, authenticated;

alter table erp.forecast_model_choice
  add column if not exists seasonal boolean not null default false,
  add column if not exists season_length integer;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The event calendar
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.forecast_event (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant (id) on delete cascade,
  code        text not null check (code ~ '^[A-Za-z0-9_-]+$'),
  name        text not null,
  entity_id   uuid references erp.entity (id) on delete cascade,
  site_id     uuid references erp.site (id) on delete cascade,
  item_id     uuid references erp.item (id) on delete cascade,
  starts_on   date not null,
  ends_on     date not null,
  multiplier  numeric not null check (multiplier > 0),
  reason      text not null check (length(btrim(reason)) >= 10),
  status      erp.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint forecast_event_window check (ends_on >= starts_on)
);

select erp_meta.register_table('erp', 'forecast_event', 'tenant_scoped',
  'v1.6 §5.4: an event the statistical forecast cannot know about — a promotion, a launch, a closure — as a window and a multiplier with its reason. Operating data beside the forecast, not configuration.');

comment on table erp.forecast_event is
  'Specification v1.6 §5.4, event adjustment. A window and a multiplier the '
  'forecast run applies to every bucket it overlaps, for one item or every '
  'item, at one site or every site. The reason is what the line carries.';

create or replace function erp.upsert_forecast_event(p_code text, p_name text, p_starts_on date, p_ends_on date,
                                                     p_multiplier numeric, p_reason text,
                                                     p_site_id uuid default null, p_item_id uuid default null,
                                                     p_entity_id uuid default null, p_status text default 'active')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('planning.forecast', p_entity_id, p_site_id, null, 'forecast_event', null);
  if coalesce(p_multiplier, 0) <= 0 then
    raise exception 'CLOVEERP_EVENT_MULTIPLIER_INVALID: an event multiplies demand by a positive number, not %', p_multiplier
      using errcode = '23514', hint = '2 doubles the buckets it overlaps; 0.5 halves them; 1 is no event.';
  end if;
  if p_ends_on < p_starts_on then
    raise exception 'CLOVEERP_EVENT_WINDOW_INVALID: % ends before it starts (% to %)', p_code, p_starts_on, p_ends_on
      using errcode = '23514', hint = 'Give the first and last day the event affects demand.';
  end if;
  if length(coalesce(btrim(p_reason), '')) < 10 then
    raise exception 'CLOVEERP_ADJUSTMENT_NEEDS_REASON: an event says why demand will differ'
      using errcode = '23514', hint = 'A reason of at least ten characters: the promotion, the launch, the closure.';
  end if;
  insert into erp.forecast_event (tenant_id, code, name, entity_id, site_id, item_id, starts_on, ends_on, multiplier, reason, status)
  values (v_tenant, p_code, p_name, p_entity_id, p_site_id, p_item_id, p_starts_on, p_ends_on, p_multiplier, btrim(p_reason),
          coalesce(p_status, 'active')::erp.record_status)
  on conflict (tenant_id, code) do update
    set name = excluded.name, entity_id = excluded.entity_id, site_id = excluded.site_id, item_id = excluded.item_id,
        starts_on = excluded.starts_on, ends_on = excluded.ends_on, multiplier = excluded.multiplier,
        reason = excluded.reason, status = excluded.status, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- What the events do to one bucket: every active event overlapping it, for
-- this item or every item, at this site or every site.
create or replace function erp.forecast_event_factor(p_item_id uuid, p_site_id uuid, p_entity_id uuid,
                                                     p_bucket_start date, p_bucket_end date)
returns table(multiplier numeric, codes text)
language sql
stable
set search_path = ''
as $$
  select coalesce(exp(sum(ln(e.multiplier))), 1)::numeric, string_agg(e.code, ',' order by e.code)
    from erp.forecast_event e
   where e.tenant_id = erp.current_tenant_id()
     and e.status = 'active'
     and (e.item_id is null or e.item_id = p_item_id)
     and (e.site_id is null or e.site_id = p_site_id)
     and (e.entity_id is null or e.entity_id = p_entity_id)
     and e.starts_on <= p_bucket_end and e.ends_on >= p_bucket_start
$$;
revoke all on function erp.forecast_event_factor(uuid, uuid, uuid, date, date) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The run knows its season and its events
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.run_forecast(text,integer,integer)'::regprocedure);
begin
  if position('v_pred := erp.fit_forecast(v_series, v_best.method, p_periods);' in v_src) = 0
     or position('select * into v_best from erp.select_forecast_method(v_series) s' in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_forecast is not the 20260829260000 body';
  end if;
end $$;

create or replace function erp.run_forecast(p_forecast_code text, p_periods integer default 6, p_buckets integer default 24)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  f        erp.forecast%rowtype;
  v_ver    uuid;
  v_vnum   integer;
  r        record;
  v_series numeric[];
  v_best   record;
  v_fit    record;
  v_pred   numeric[];
  ev       record;
  i        integer;
  v_start  date;
  v_bstart date;
  v_bend   date;
  v_uom    uuid;
  v_n      integer := 0;
  v_season integer;
begin
  select * into f from erp.forecast
   where tenant_id = v_tenant and code = p_forecast_code and status = 'active';
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FORECAST: %', p_forecast_code using errcode = '23503';
  end if;

  perform erp.authorise('planning.forecast', f.entity_id, f.site_id, null,
                        'forecast', f.id);

  -- The season the bucket implies. A season is only fitted where the history
  -- holds two of them; the fit says which happened.
  v_season := case f.bucket when 'day' then 7 when 'week' then 52 when 'month' then 12 when 'quarter' then 4 else 12 end;

  select coalesce(max(v.version), 0) + 1 into v_vnum
    from erp.forecast_version v where v.tenant_id = v_tenant and v.forecast_id = f.id;

  v_start := (date_trunc(f.bucket, current_date) + ('1 ' || f.bucket)::interval)::date;

  insert into erp.forecast_version (
    tenant_id, forecast_id, version, method, parameters, status,
    horizon_from, horizon_to, note)
  values (v_tenant, f.id, v_vnum, 'moving_average',
          jsonb_build_object('buckets_of_history', p_buckets, 'periods', p_periods, 'season_length', v_season),
          'draft', v_start,
          (v_start + (p_periods || ' ' || f.bucket)::interval)::date,
          'statistical run')
  returning id into v_ver;

  for r in
    select distinct isx.item_id, isx.site_id
      from erp.item_site isx
      join erp.item it on it.id = isx.item_id
     where isx.tenant_id = v_tenant
       and isx.is_stocked
       and isx.status = 'active'
       and it.status = 'active'
       and (f.site_id is null or isx.site_id = f.site_id)
  loop
    select array_agg(c.quantity order by c.bucket_start) into v_series
      from erp.cleansed_demand(r.item_id, r.site_id, p_buckets, f.bucket) c;

    if coalesce(array_length(v_series, 1), 0) = 0
       or (select sum(x) from unnest(v_series) x) = 0 then
      insert into erp.planning_exception (
        tenant_id, entity_id, site_id, item_id, exception_kind, severity,
        message, detail)
      values (v_tenant, f.entity_id, r.site_id, r.item_id, 'no_supply_source',
              'low', 'no demand history to forecast from',
              jsonb_build_object('buckets', p_buckets))
      on conflict do nothing;
      continue;
    end if;

    select * into v_best from erp.select_forecast_method(v_series, v_season) s
     where s.mape is not null order by s.mape limit 1;

    if v_best.method is null then
      select * into v_best from erp.select_forecast_method(v_series, v_season) s limit 1;
    end if;

    select * into v_fit from erp.fit_forecast_explained(v_series, v_best.method, p_periods, 0.3, v_season);
    v_pred := v_fit.forecast;

    select it.stock_uom_id into v_uom from erp.item it where it.id = r.item_id;

    for i in 1 .. p_periods loop
      v_bstart := (v_start + ((i - 1) || ' ' || f.bucket)::interval)::date;
      v_bend := (v_bstart + ('1 ' || f.bucket)::interval - interval '1 day')::date;
      select * into ev from erp.forecast_event_factor(r.item_id, r.site_id, f.entity_id, v_bstart, v_bend);

      -- §5.4, event adjustment: the statistical figure is kept beside the
      -- adjusted one, and the line says which events moved it.
      insert into erp.forecast_line (
        tenant_id, forecast_version_id, item_id, site_id, bucket_start,
        quantity, uom_id, statistical_quantity, adjustment_reason)
      values (v_tenant, v_ver, r.item_id, r.site_id, v_bstart,
              round(v_pred[i] * coalesce(ev.multiplier, 1), 6), v_uom, round(v_pred[i], 6),
              case when ev.codes is not null then 'event:' || ev.codes end);
    end loop;

    insert into erp.forecast_model_choice (
      tenant_id, forecast_version_id, item_id, site_id, method,
      backtest_mape, history_buckets, seasonal, season_length)
    values (v_tenant, v_ver, r.item_id, r.site_id, v_best.method,
            v_best.mape, coalesce(array_length(v_series, 1), 0), v_fit.seasonal, v_fit.season_length)
    on conflict (tenant_id, forecast_version_id, item_id, site_id) do update
      set method = excluded.method, backtest_mape = excluded.backtest_mape,
          seasonal = excluded.seasonal, season_length = excluded.season_length;

    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception
      'CLOVEERP_NOTHING_TO_FORECAST: no stocked item at this site has any demand '
      'history' using errcode = '23514';
  end if;

  update erp.forecast_version fv
     set method = (select mc.method from erp.forecast_model_choice mc
                    where mc.forecast_version_id = v_ver
                    group by mc.method order by count(*) desc, mc.method limit 1),
         parameters = fv.parameters || jsonb_build_object(
           'items_forecast', v_n,
           'items_seasonal', (select count(*) from erp.forecast_model_choice mc
                               where mc.forecast_version_id = v_ver and mc.seasonal),
           'median_backtest_mape',
           (select round(percentile_cont(0.5) within group (order by mc.backtest_mape)::numeric, 2)
              from erp.forecast_model_choice mc
             where mc.forecast_version_id = v_ver and mc.backtest_mape is not null)),
         updated_at = now()
   where fv.id = v_ver;

  return v_ver;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A person's own adjustment
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.adjust_forecast_line(p_line_id uuid, p_quantity numeric, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.forecast_line%rowtype;
  v        erp.forecast_version%rowtype;
begin
  select * into l from erp.forecast_line where tenant_id = v_tenant and id = p_line_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FORECAST_LINE: %', p_line_id using errcode = '23503';
  end if;
  select * into v from erp.forecast_version where tenant_id = v_tenant and id = l.forecast_version_id;
  perform erp.authorise('planning.forecast', null, l.site_id, null, 'forecast_version', v.id);

  if v.status <> 'draft' then
    raise exception 'CLOVEERP_FORECAST_SIGNED_OFF: version % is %, and what was signed off is what it says', v.version, v.status
      using errcode = '23514', hint = 'Run a new version, adjust it, and sign that off.';
  end if;
  if length(coalesce(btrim(p_reason), '')) < 5 then
    raise exception 'CLOVEERP_ADJUSTMENT_NEEDS_REASON: an adjustment to a forecast line says why'
      using errcode = '23514', hint = 'A reason of a few words: what the statistics could not know.';
  end if;
  if coalesce(p_quantity, -1) < 0 then
    raise exception 'CLOVEERP_ADJUSTMENT_NEEDS_REASON: a forecast is not negative' using errcode = '23514',
      hint = 'Give the quantity expected in the bucket, zero included.';
  end if;

  update erp.forecast_line
     set quantity = p_quantity,
         adjustment_reason = btrim(p_reason),
         updated_at = now()
   where id = p_line_id;
end;
$$;

comment on function erp.adjust_forecast_line is
  'Specification v1.6 §5.4, the consensus step: a person overrides a bucket '
  'with a reason, on a draft version only; the statistical figure stays '
  'beside the adjustment.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_upsert_forecast_event(p_code text, p_name text, p_starts_on date, p_ends_on date,
                                                            p_multiplier numeric, p_reason text,
                                                            p_site_id uuid default null, p_item_id uuid default null,
                                                            p_entity_id uuid default null, p_status text default 'active')
returns uuid language sql set search_path = '' as $$
  select erp.upsert_forecast_event(p_code, p_name, p_starts_on, p_ends_on, p_multiplier, p_reason, p_site_id, p_item_id, p_entity_id, p_status);
$$;
create or replace function public.erp_forecast_events()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'code', e.code, 'name', e.name, 'starts_on', e.starts_on, 'ends_on', e.ends_on,
           'multiplier', e.multiplier, 'reason', e.reason, 'status', e.status,
           'site_code', (select s.code from erp.site s where s.id = e.site_id),
           'item_code', (select i.code from erp.item i where i.id = e.item_id),
           'entity_code', (select en.code from erp.entity en where en.id = e.entity_id))
         order by e.starts_on desc, e.code), '[]'::jsonb)
    from erp.forecast_event e
   where e.tenant_id = erp.current_tenant_id();
$$;
create or replace function public.erp_adjust_forecast_line(p_line_id uuid, p_quantity numeric, p_reason text)
returns void language sql set search_path = '' as $$
  select erp.adjust_forecast_line(p_line_id, p_quantity, p_reason);
$$;
create or replace function public.erp_forecast_lines(p_version_id uuid, p_limit integer default 500)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'item_code', i.code, 'site_code', s.code, 'bucket_start', l.bucket_start,
           'quantity', l.quantity, 'statistical_quantity', l.statistical_quantity,
           'adjustment_reason', l.adjustment_reason,
           'method', mc.method, 'seasonal', mc.seasonal, 'season_length', mc.season_length)
         order by i.code, s.code, l.bucket_start), '[]'::jsonb)
    from (select * from erp.forecast_line fl
           where fl.tenant_id = erp.current_tenant_id() and fl.forecast_version_id = p_version_id
           order by fl.item_id, fl.site_id, fl.bucket_start limit p_limit) l
    join erp.item i on i.id = l.item_id
    join erp.site s on s.id = l.site_id
    left join erp.forecast_model_choice mc on mc.forecast_version_id = l.forecast_version_id
                                          and mc.item_id = l.item_id and mc.site_id = l.site_id;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_upsert_forecast_event(text, text, date, date, numeric, text, uuid, uuid, uuid, text)',
    'erp_forecast_events()',
    'erp_adjust_forecast_line(uuid, numeric, text)',
    'erp_forecast_lines(uuid, integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upsert_forecast_event', 'erp.upsert_forecast_event',
   'Records an event the forecast applies to the buckets it overlaps; authorises planning.forecast.'),
  ('erp_adjust_forecast_line', 'erp.adjust_forecast_line',
   'A person''s adjustment to a draft forecast bucket, with a reason; authorises planning.forecast.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.fit_forecast(numeric[],erp.forecast_method,integer,numeric,integer)',
                         'erp.fit_forecast_explained(numeric[],erp.forecast_method,integer,numeric,integer)',
                         'erp.select_forecast_method(numeric[],integer)',
                         'erp.run_forecast(text,integer,integer)',
                         'erp.forecast_model_choice',
                         'erp.forecast_event',
                         'erp.forecast_event_factor(uuid,uuid,uuid,date,date)',
                         'erp.adjust_forecast_line(uuid,numeric,text)']
 where code = '5.4.statistical_forecasting';

-- The accuracy row named the one-argument chooser; it now takes the season.
update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.select_forecast_method(numeric[])',
                                            'erp.select_forecast_method(numeric[],integer)')
 where 'erp.select_forecast_method(numeric[])' = any(artefacts);

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.forecast_seasonality_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid; csl uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_item uuid; v_fc uuid; v_ver uuid; v_ver2 uuid;
  v_series numeric[]; v_short numeric[]; fit record; v_best record; v_line uuid; v_stat numeric;
  i integer; v_ok boolean; v_msg text; v_third date;
begin
  begin
    -- Thirty-six months with a peak every twelfth: the shape a season has.
    v_series := '{}';
    for i in 1 .. 36 loop
      v_series := v_series || (100 + case when i % 12 = 0 then 80 else 0 end)::numeric;
    end loop;
    v_short := v_series[1 : 18];

    select * into fit from erp.fit_forecast_explained(v_short, 'holt_winters', 12, 0.3, 12);
    return query select 'eighteen months of a yearly cycle is not a season, and the fit says so',
      not fit.seasonal and fit.season_length is null and array_length(fit.forecast, 1) = 12,
      'a linear trend, not a fit to noise';

    select * into fit from erp.fit_forecast_explained(v_series, 'holt_winters', 12, 0.3, 12);
    return query select 'thirty-six months fits the season, and the peak comes back in the twelfth bucket',
      fit.seasonal and fit.season_length = 12
      and fit.forecast[12] > fit.forecast[1] + 50
      and fit.forecast[12] = (select max(x) from unnest(fit.forecast) x),
      format('bucket 1 %s, bucket 12 %s', round(fit.forecast[1]), round(fit.forecast[12]));

    select * into v_best from erp.select_forecast_method(v_series, 12) s where s.mape is not null order by s.mape limit 1;
    return query select 'the backtest measures the seasonal fit and chooses it',
      v_best.method = 'holt_winters',
      format('%s at %s per cent', v_best.method, v_best.mape);

    -- A real organisation, with the history written as movements.
    select * into r from erp.provision_tenant('zzfse', 'Forecast Season', 'a@zzfse.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zzfse.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csl := erp.configure_planning(95, 7);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csl); perform erp.promote_change_set(csl);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'SKI', 'Ski wax', v_uom, 'active') returning id into v_item;
    insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, planning_policy_code, lead_time_days, min_order_quantity, order_multiple, status)
    values (r.tenant_id, v_item, v_site, true, 'standard', 14, 0, 10, 'active');
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency)
    values (r.tenant_id, r.entity_id, v_site, 'goods_receipt', v_item, v_recv, 'available', 20000, v_uom, 1000, 'GBP');
    for i in 1 .. 36 loop
      insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
                                      quantity, uom_id, unit_cost_minor, currency, occurred_at)
      values (r.tenant_id, r.entity_id, v_site, 'despatch', v_item, v_recv, 'available',
              v_series[i], v_uom, 1000, 'GBP',
              date_trunc('month', current_date) - ((37 - i) || ' months')::interval + interval '10 days');
    end loop;
    insert into erp.forecast (tenant_id, code, name, entity_id, site_id, bucket, status)
    values (r.tenant_id, 'MAIN-M', 'Main monthly', r.entity_id, v_site, 'month', 'active') returning id into v_fc;

    v_ver := erp.run_forecast('MAIN-M', 12, 36);
    return query select 'a monthly run on three years of history records a seasonal model with a twelve-bucket season',
      (select mc.method = 'holt_winters' and mc.seasonal and mc.season_length = 12
         from erp.forecast_model_choice mc where mc.forecast_version_id = v_ver)
      and (select (fv.parameters ->> 'items_seasonal')::integer = 1 and (fv.parameters ->> 'season_length')::integer = 12
             from erp.forecast_version fv where fv.id = v_ver),
      'seasonal, 12';

    -- An event on the third bucket.
    v_third := (date_trunc('month', current_date) + interval '3 months')::date;
    perform erp.upsert_forecast_event('LAUNCH', 'Spring launch', v_third, v_third + 5, 2,
                                      'new range launches; the trade buys ahead', v_site, v_item);
    v_ver2 := erp.run_forecast('MAIN-M', 12, 36);
    select fl.id, fl.statistical_quantity into v_line, v_stat
      from erp.forecast_line fl where fl.forecast_version_id = v_ver2 and fl.bucket_start = v_third;
    return query select 'an event doubles the bucket it overlaps, names itself on the line, and leaves the statistical figure beside it',
      (select fl.quantity = round(fl.statistical_quantity * 2, 6) and fl.adjustment_reason = 'event:LAUNCH'
         from erp.forecast_line fl where fl.id = v_line)
      and (select count(*) from erp.forecast_line fl
            where fl.forecast_version_id = v_ver2 and fl.adjustment_reason is not null) = 1
      and (select count(*) from erp.forecast_line fl
            where fl.forecast_version_id = v_ver2 and fl.quantity <> fl.statistical_quantity) = 1,
      format('bucket %s: statistical %s, adjusted x2', v_third, round(v_stat));

    perform erp.upsert_forecast_event('LAUNCH', 'Spring launch', v_third, v_third + 5, 2,
                                      'new range launches; the trade buys ahead', v_site, v_item, null, 'inactive');
    begin
      perform erp.upsert_forecast_event('BAD', 'No reason', v_third, v_third, 3, 'why');
      v_ok := false; v_msg := 'an event without a reason was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ADJUSTMENT_NEEDS_REASON%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'an event without a reason is refused', v_ok, v_msg;

    -- A person's adjustment.
    begin
      perform erp.adjust_forecast_line(v_line, 50, 'no');
      v_ok := false; v_msg := 'an adjustment without a reason was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ADJUSTMENT_NEEDS_REASON%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'a person''s adjustment needs a reason', v_ok, v_msg;

    perform erp.adjust_forecast_line(v_line, 50, 'the trade told us they are full');
    return query select 'an adjustment moves the bucket and keeps the statistical figure',
      (select fl.quantity = 50 and fl.statistical_quantity = v_stat and fl.adjustment_reason = 'the trade told us they are full'
         from erp.forecast_line fl where fl.id = v_line),
      'adjusted to 50';

    perform erp.sign_off_forecast(v_ver2, 'reviewed');
    begin
      perform erp.adjust_forecast_line(v_line, 60, 'second thoughts');
      v_ok := false; v_msg := 'a signed-off version was adjusted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_FORECAST_SIGNED_OFF%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'a signed-off version cannot be adjusted', v_ok, v_msg;

    return query select 'the register says statistical forecasting is built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.4.statistical_forecasting') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.4.statistical_forecasting'),
      '5.4.statistical_forecasting';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzfse');
  detail := 'the organisation, its history and its forecasts rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_forecast_seasonality_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _forecast_seasonality on commit drop as
    select * from erp_test.forecast_seasonality_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _forecast_seasonality;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_FORECAST_SEASONALITY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_FORECAST_SEASONALITY_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('forecast seasonality: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_forecast_seasonality_suite() from public, anon, authenticated;
revoke all on function erp_test.forecast_seasonality_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_forecast_seasonality_suite();
select erp_test.assert_planning_suite();
select erp.assert_part5_coverage();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
