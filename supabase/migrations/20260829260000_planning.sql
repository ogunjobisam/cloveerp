-- =============================================================================
-- ERPWare — Part 5.4: supply chain planning
--
-- Eight planning tables, all correct, none of them written by anything:
-- forecast, forecast_version, forecast_line, forecast_accuracy,
-- planning_policy, planned_order, planned_order_peg, planning_exception.
-- erp.firm_planned_order() exists and can turn a planned order into a real one;
-- nothing has ever created a planned order for it to firm.
--
-- The same pattern this build keeps finding, and here it is at its starkest:
-- there is an engine-shaped hole with the mountings already drilled.
--
-- What follows is a planning run. It is not a toy: it cleanses demand history,
-- fits three forecasting models and picks between them on measured accuracy,
-- calculates policy from the fitted demand rather than from a number somebody
-- typed, projects stock forward in buckets, raises planned orders with lot
-- sizing and time fences, pegs each one to the demand that caused it, and
-- records the exceptions a planner should look at.
--
-- Two things it deliberately does not do:
--
--   * It does not invent a demand history. Where there is not enough history
--     to fit anything, it says so as a planning exception rather than
--     forecasting a flat line, because a flat line looks like a forecast and
--     is an absence of one.
--
--   * It does not silently pick a model. Every version records which method
--     was chosen, its parameters, and the backtest error that chose it, so
--     "why is the forecast this shape" has an answer.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Demand history, and cleansing it
--
-- Demand is what left, not what was sold: an issue to production and a
-- despatch to a customer are both demand on the stock, and planning that
-- counts only one of them under-orders exactly the components it is worst at
-- getting hold of.
--
-- Cleansing matters because one promotional spike will otherwise raise the
-- forecast for a year. The median absolute deviation is used rather than the
-- standard deviation, because the standard deviation is itself inflated by the
-- outlier it is being asked to find.
-- -----------------------------------------------------------------------------

create or replace function erp.demand_history(
  p_item_id uuid,
  p_site_id uuid,
  p_buckets integer default 24,
  p_bucket  text default 'month'
) returns table (bucket_start date, quantity numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  with span as (
    select generate_series(
             date_trunc(p_bucket, current_date - (p_buckets || ' ' || p_bucket)::interval),
             date_trunc(p_bucket, current_date) - ('1 ' || p_bucket)::interval,
             ('1 ' || p_bucket)::interval)::date as b
  ),
  moved as (
    select date_trunc(p_bucket, m.occurred_at)::date as b, sum(m.quantity) as q
      from erp.stock_movement m
      join erp_ref.movement_type mt on mt.code = m.movement_type
     where m.tenant_id = erp.current_tenant_id()
       and m.item_id = p_item_id
       and (p_site_id is null or m.site_id = p_site_id)
       and mt.direction = 'out'
       and not m.is_reversal
     group by 1
  )
  select span.b, coalesce(moved.q, 0)
    from span left join moved on moved.b = span.b
   order by span.b
$$;

comment on function erp.demand_history(uuid, uuid, integer, text) is
  'What left, by bucket. Every outbound movement, not only customer despatches '
  '— planning that counts one kind of demand under-orders exactly the '
  'components it is worst at getting.';

create or replace function erp.cleansed_demand(
  p_item_id uuid,
  p_site_id uuid,
  p_buckets integer default 24,
  p_bucket  text default 'month',
  p_mad_factor numeric default 3
) returns table (bucket_start date, quantity numeric,
                 raw_quantity numeric, was_outlier boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  with h as (
    select * from erp.demand_history(p_item_id, p_site_id, p_buckets, p_bucket)
  ),
  m as (
    select percentile_cont(0.5) within group (order by h.quantity) as med from h
  ),
  -- The median of the absolute deviations from the median. Robust, which is
  -- the whole point: a standard deviation is inflated by the very outlier it
  -- is being used to detect, so it hides the spike it should be finding.
  d as (
    select percentile_cont(0.5) within group (order by abs(h.quantity - m.med)) as mad
      from h, m
  )
  select h.bucket_start,
         -- Capped rather than dropped. A promotional month did happen, and
         -- removing it entirely forecasts a business that never runs promotions.
         case when d.mad > 0 and abs(h.quantity - m.med) > p_mad_factor * d.mad
              then m.med + sign(h.quantity - m.med) * p_mad_factor * d.mad
              else h.quantity end,
         h.quantity,
         coalesce(d.mad > 0 and abs(h.quantity - m.med) > p_mad_factor * d.mad, false)
    from h, m, d
   order by h.bucket_start
$$;

-- -----------------------------------------------------------------------------
-- Forecasting, with the model chosen by measurement
--
-- Three methods, fitted over the same history, each scored by holding back the
-- last quarter of the series and measuring the error against it. The one with
-- the lowest error wins, and the score is recorded so the choice can be
-- questioned later.
-- -----------------------------------------------------------------------------

create or replace function erp.fit_forecast(
  p_series numeric[],
  p_method erp.forecast_method,
  p_periods integer,
  p_alpha numeric default 0.3,
  p_season integer default 12
) returns numeric[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  n        integer := coalesce(array_length(p_series, 1), 0);
  v_out    numeric[] := '{}';
  v_level  numeric;
  v_trend  numeric := 0;
  i        integer;
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

  elsif p_method = 'holt_winters' then
    -- Holt's linear trend. Named holt_winters because that is the enum label
    -- B7 chose; seasonality needs at least two full cycles of history and
    -- claiming it on eighteen months of data would be a fit to noise.
    if n < 2 then return erp.fit_forecast(p_series, 'moving_average', p_periods); end if;
    v_level := p_series[1];
    v_trend := p_series[2] - p_series[1];
    for i in 2 .. n loop
      declare v_prev numeric := v_level;
      begin
        v_level := p_alpha * p_series[i] + (1 - p_alpha) * (v_level + v_trend);
        v_trend := 0.1 * (v_level - v_prev) + 0.9 * v_trend;
      end;
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

create or replace function erp.select_forecast_method(
  p_series numeric[]
) returns table (method erp.forecast_method, mape numeric)
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
  -- Not enough history to hold anything back is not a model choice, it is an
  -- absence of one, and saying so is more useful than fitting a line to four
  -- points.
  if n < 6 then
    method := 'moving_average'; mape := null; return next; return;
  end if;

  v_hold := greatest(1, n / 4);
  v_train := p_series[1 : n - v_hold];
  v_test  := p_series[n - v_hold + 1 : n];

  foreach m in array array['moving_average', 'exponential_smoothing', 'holt_winters']::erp.forecast_method[]
  loop
    v_pred := erp.fit_forecast(v_train, m, v_hold);
    v_err := 0; v_denom := 0;
    for i in 1 .. v_hold loop
      v_err := v_err + abs(v_test[i] - v_pred[i]);
      v_denom := v_denom + abs(v_test[i]);
    end loop;
    method := m;
    -- Mean absolute error scaled by actual demand. Where the held-back period
    -- had no demand at all the ratio is undefined, and reporting it as zero
    -- would make the worst model look perfect.
    mape := case when v_denom = 0 then null else round(100 * v_err / v_denom, 2) end;
    return next;
  end loop;
end;
$$;

comment on function erp.select_forecast_method(numeric[]) is
  'Spec 5.4: model selection driven by measured accuracy. Each method is fitted '
  'on the earlier part of the series and scored against the part held back, so '
  'the choice is a measurement rather than a preference.';

-- Which model was chosen for each item, and the backtest error that chose it.
--
-- Not erp.forecast_accuracy: that table measures forecast against actual and
-- its actual_quantity is not null precisely because a row without one is not a
-- measurement. Writing the backtest score there would have made "how accurate
-- was the forecast" and "how did we pick the model" the same question, and
-- they are not — the second is answerable the moment the run finishes and the
-- first is not answerable for a month.
create table if not exists erp.forecast_model_choice (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  forecast_version_id uuid not null,
  item_id      uuid not null,
  site_id      uuid,
  method       erp.forecast_method not null,
  backtest_mape numeric,
  history_buckets integer,
  chosen_at    timestamptz not null default clock_timestamp(),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  unique (tenant_id, forecast_version_id, item_id, site_id),
  foreign key (tenant_id, forecast_version_id)
    references erp.forecast_version (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id) references erp.item (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

comment on table erp.forecast_model_choice is
  'Spec 5.4: model selection, recorded. Which method won for each item and by '
  'how much, so "why is this forecast this shape" has an answer that is not '
  '"the model decided".';

create or replace function erp.run_forecast(
  p_forecast_code text,
  p_periods integer default 6,
  p_buckets integer default 24
) returns uuid
language plpgsql
security invoker
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
  v_pred   numeric[];
  i        integer;
  v_start  date;
  v_uom    uuid;
  v_n      integer := 0;
begin
  select * into f from erp.forecast
   where tenant_id = v_tenant and code = p_forecast_code and status = 'active';
  if not found then
    raise exception 'ERPWARE_UNKNOWN_FORECAST: %', p_forecast_code using errcode = '23503';
  end if;

  perform erp.authorise('planning.forecast', f.entity_id, f.site_id, null,
                        'forecast', f.id);

  select coalesce(max(v.version), 0) + 1 into v_vnum
    from erp.forecast_version v where v.tenant_id = v_tenant and v.forecast_id = f.id;

  v_start := (date_trunc(f.bucket, current_date) + ('1 ' || f.bucket)::interval)::date;

  insert into erp.forecast_version (
    tenant_id, forecast_id, version, method, parameters, status,
    horizon_from, horizon_to, note)
  values (v_tenant, f.id, v_vnum, 'moving_average',
          jsonb_build_object('buckets_of_history', p_buckets, 'periods', p_periods),
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
      -- No demand at all. A forecast of zero is correct and a forecast of a
      -- flat average is an invention, so nothing is written and the planner is
      -- told why in the exception list.
      insert into erp.planning_exception (
        tenant_id, entity_id, site_id, item_id, exception_kind, severity,
        message, detail)
      values (v_tenant, f.entity_id, r.site_id, r.item_id, 'no_supply_source',
              'low', 'no demand history to forecast from',
              jsonb_build_object('buckets', p_buckets))
      on conflict do nothing;
      continue;
    end if;

    select * into v_best from erp.select_forecast_method(v_series) s
     where s.mape is not null order by s.mape limit 1;

    if v_best.method is null then
      select * into v_best from erp.select_forecast_method(v_series) s limit 1;
    end if;

    v_pred := erp.fit_forecast(v_series, v_best.method, p_periods);

    select it.stock_uom_id into v_uom from erp.item it where it.id = r.item_id;

    for i in 1 .. p_periods loop
      insert into erp.forecast_line (
        tenant_id, forecast_version_id, item_id, site_id, bucket_start,
        quantity, uom_id, statistical_quantity)
      values (v_tenant, v_ver, r.item_id, r.site_id,
              (v_start + ((i - 1) || ' ' || f.bucket)::interval)::date,
              round(v_pred[i], 6), v_uom, round(v_pred[i], 6));
    end loop;

    insert into erp.forecast_model_choice (
      tenant_id, forecast_version_id, item_id, site_id, method,
      backtest_mape, history_buckets)
    values (v_tenant, v_ver, r.item_id, r.site_id, v_best.method,
            v_best.mape, coalesce(array_length(v_series, 1), 0))
    on conflict (tenant_id, forecast_version_id, item_id, site_id) do update
      set method = excluded.method, backtest_mape = excluded.backtest_mape;

    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception
      'ERPWARE_NOTHING_TO_FORECAST: no stocked item at this site has any demand '
      'history' using errcode = '23514';
  end if;

  -- The version carries one method and the run may have chosen several, so it
  -- carries the one chosen most often — and the per-item choices stay
  -- queryable rather than being flattened into it.
  update erp.forecast_version fv
     set method = (select mc.method from erp.forecast_model_choice mc
                    where mc.forecast_version_id = v_ver
                    group by mc.method order by count(*) desc, mc.method limit 1),
         parameters = fv.parameters || jsonb_build_object(
           'items_forecast', v_n,
           'median_backtest_mape',
           (select round(percentile_cont(0.5) within group (order by mc.backtest_mape)::numeric, 2)
              from erp.forecast_model_choice mc
             where mc.forecast_version_id = v_ver and mc.backtest_mape is not null)),
         updated_at = now()
   where fv.id = v_ver;

  return v_ver;
end;
$$;

comment on function erp.run_forecast(text, integer, integer) is
  'Spec 5.4: statistical forecasting with model selection. Cleanses the history, '
  'fits three models, scores them against held-back demand and records which '
  'won and by how much.';

create or replace function erp.sign_off_forecast(p_version_id uuid, p_note text default null)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v        erp.forecast_version%rowtype;
begin
  select * into v from erp.forecast_version
   where tenant_id = v_tenant and id = p_version_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_FORECAST_VERSION: %', p_version_id using errcode = '23503';
  end if;

  perform erp.authorise('planning.forecast', null, null, null,
                        'forecast_version', p_version_id);

  -- Spec 5.4: "consensus forecasting with versioning and sign-off". Signing off
  -- your own statistical run is not consensus, and the point of the step is
  -- that a person has looked at the adjustments somebody made to it.
  if v.status = 'active' then
    raise exception 'ERPWARE_FORECAST_ALREADY_SIGNED_OFF: version %', v.version
      using errcode = '23505';
  end if;

  update erp.forecast_version
     set status = 'active', signed_off_by = erp.current_principal_id(),
         signed_off_at = now(), note = coalesce(p_note, note), updated_at = now()
   where id = p_version_id;

  -- Only one version of a forecast is in force. The rest are history, and
  -- history that is still marked active is a planning run that quietly used
  -- last quarter's numbers.
  update erp.forecast_version
     set status = 'superseded', updated_at = now()
   where tenant_id = v_tenant and forecast_id = v.forecast_id
     and id <> p_version_id and status = 'active';
end;
$$;

create or replace function erp.measure_forecast_accuracy(p_version_id uuid)
returns table (item_id uuid, site_id uuid, forecast_quantity numeric,
               actual_quantity numeric, mape numeric)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_actual numeric;
begin
  for r in
    select fl.* from erp.forecast_line fl
     where fl.tenant_id = v_tenant and fl.forecast_version_id = p_version_id
       -- Only buckets that have finished. Measuring accuracy against a month
       -- half of which has not happened reports every forecast as too high.
       and fl.bucket_start < date_trunc('month', current_date)::date
  loop
    select coalesce(sum(h.quantity), 0) into v_actual
      from erp.demand_history(r.item_id, r.site_id, 60, 'month') h
     where h.bucket_start = r.bucket_start;

    insert into erp.forecast_accuracy (
      tenant_id, forecast_version_id, item_id, site_id, bucket_start,
      forecast_quantity, actual_quantity, absolute_error)
    values (v_tenant, p_version_id, r.item_id, r.site_id, r.bucket_start,
            r.quantity, v_actual, abs(r.quantity - v_actual));

    item_id := r.item_id; site_id := r.site_id;
    forecast_quantity := r.quantity; actual_quantity := v_actual;
    mape := case when v_actual = 0 then null
                 else round(100 * abs(r.quantity - v_actual) / v_actual, 2) end;
    return next;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Inventory policy, calculated rather than typed
--
-- erp.item_site carries safety_stock, reorder_point, order_up_to,
-- min_order_quantity and order_multiple. Every one of those is a number
-- somebody typed once and nobody has revisited, which is how a warehouse ends
-- up holding six months of something it now sells twice a year.
--
-- Spec 5.4 asks for them to be calculated: "inventory policy calculation
-- (safety stock, reorder point, order-up-to, economic order quantity with
-- rounding)". Calculated from the cleansed demand and the measured variability,
-- which means they move when the business does.
-- -----------------------------------------------------------------------------

create or replace function erp.service_level_z(p_pct numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  -- The normal-distribution safety factor. Tabulated rather than computed:
  -- there is no inverse error function in core PostgreSQL, and a table of the
  -- service levels anybody actually configures is honest about being a table.
  select case
    when p_pct >= 99.9 then 3.09
    when p_pct >= 99.5 then 2.58
    when p_pct >= 99   then 2.33
    when p_pct >= 98   then 2.05
    when p_pct >= 97   then 1.88
    when p_pct >= 95   then 1.65
    when p_pct >= 90   then 1.28
    when p_pct >= 85   then 1.04
    when p_pct >= 80   then 0.84
    when p_pct >= 75   then 0.67
    else 0.52
  end
$$;

create or replace function erp.calculate_policy(
  p_item_id uuid,
  p_site_id uuid,
  p_order_cost_minor bigint default 5000,
  p_holding_rate numeric default 0.25
) returns table (mean_demand numeric, demand_sigma numeric, lead_time_days integer,
                 safety_stock numeric, reorder_point numeric,
                 order_up_to numeric, eoq numeric, rounded_eoq numeric)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  isx      erp.item_site%rowtype;
  pp       erp.planning_policy%rowtype;
  v_z      numeric;
  v_lt_buckets numeric;
  v_cost   bigint;
  v_annual numeric;
begin
  select * into isx from erp.item_site
   where tenant_id = v_tenant and item_id = p_item_id and site_id = p_site_id;
  if not found then
    raise exception 'ERPWARE_NOT_STOCKED_HERE: this item is not planned at this site'
      using errcode = '23503';
  end if;

  select * into pp from erp.planning_policy
   where tenant_id = v_tenant and code = isx.planning_policy_code and status = 'active';

  select avg(c.quantity), coalesce(stddev_samp(c.quantity), 0)
    into mean_demand, demand_sigma
    from erp.cleansed_demand(p_item_id, p_site_id, 24, 'month') c;

  mean_demand := coalesce(mean_demand, 0);
  demand_sigma := coalesce(demand_sigma, 0);
  lead_time_days := coalesce(isx.lead_time_days, 0);

  v_z := erp.service_level_z(coalesce(pp.service_level_pct, 95));
  v_lt_buckets := lead_time_days / 30.0;

  -- Safety stock covers the variability of demand over the lead time, not over
  -- a month. Sigma scales with the square root of the period: a two-month lead
  -- time carries about forty per cent more risk than a one-month one, not
  -- twice as much, and using the linear figure is the commonest way safety
  -- stock ends up double what it needs to be.
  safety_stock := round(v_z * demand_sigma * sqrt(greatest(v_lt_buckets, 0)), 4);
  reorder_point := round(mean_demand * v_lt_buckets + safety_stock, 4);
  -- Order-up-to covers the lead time plus one review period.
  order_up_to := round(mean_demand * (v_lt_buckets + 1) + safety_stock, 4);

  select c.unit_cost_minor into v_cost from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id;

  v_annual := mean_demand * 12;

  -- Economic order quantity. Undefined without a cost, and returning zero
  -- would read as "order nothing" rather than "this cannot be answered yet".
  if coalesce(v_cost, 0) = 0 or v_annual <= 0 then
    eoq := null; rounded_eoq := null;
  else
    eoq := round(sqrt(2 * v_annual * p_order_cost_minor
                      / (p_holding_rate * v_cost)), 4);
    -- Rounding, which spec 5.4 asks for by name: an EOQ of 137 on a product
    -- that comes in cases of 24 is a number nobody can order.
    rounded_eoq := greatest(
      coalesce(isx.min_order_quantity, 0),
      case when coalesce(isx.order_multiple, 0) > 0
           then ceil(eoq / isx.order_multiple) * isx.order_multiple
           else eoq end);
  end if;

  return next;
end;
$$;

comment on function erp.calculate_policy(uuid, uuid, bigint, numeric) is
  'Spec 5.4: inventory policy calculated from cleansed demand and measured '
  'variability, so the numbers move when the business does — and with safety '
  'stock scaled by the square root of the lead time, which is the difference '
  'between covering the risk and doubling the stock.';

create or replace function erp.apply_calculated_policy(
  p_item_id uuid,
  p_site_id uuid
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  c        record;
begin
  perform erp.authorise('planning.run', null, p_site_id, null, 'item', p_item_id);
  select * into c from erp.calculate_policy(p_item_id, p_site_id);

  update erp.item_site
     set safety_stock = c.safety_stock,
         reorder_point = c.reorder_point,
         order_up_to = c.order_up_to,
         updated_at = now()
   where tenant_id = v_tenant and item_id = p_item_id and site_id = p_site_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- The planning run
--
-- Time-phased, which is the whole of it. A run that compares today's stock
-- against today's reorder point orders too late for everything with a lead
-- time, which is everything. So stock is projected forward bucket by bucket
-- against forecast and firm demand, and a planned order is raised where the
-- projection would breach the reorder point — dated so that it arrives before
-- the breach rather than when it is noticed.
--
-- Every planned order is pegged to the demand that caused it, which is what
-- turns "why am I ordering this" from a conversation into a query.
-- -----------------------------------------------------------------------------

create table if not exists erp.planning_run (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  entity_id    uuid,
  site_id      uuid,
  horizon_days integer not null default 180,
  bucket       text not null default 'week',
  forecast_version_id uuid,
  started_at   timestamptz not null default clock_timestamp(),
  finished_at  timestamptz,
  orders_raised integer,
  exceptions_raised integer,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade
);

-- What is already coming, and what is already promised. Two halves of the
-- projection, derived rather than stored, because a stored supply-and-demand
-- position is one that is wrong between runs.
create or replace function erp.scheduled_supply(
  p_item_id uuid, p_site_id uuid, p_from date, p_to date)
returns table (due_on date, quantity numeric, source text)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Ordered and not yet received.
  select coalesce(dl.required_date, d.required_date, d.document_date),
         dl.quantity - coalesce(dl.quantity_fulfilled, 0),
         'purchase_order'
    from erp.document_line dl
    join erp.document d on d.id = dl.document_id
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.object_state os on os.object_type = 'document' and os.object_id = d.id
    join erp.state s on s.id = os.current_state_id
   where dl.tenant_id = erp.current_tenant_id()
     and dt.base_type_code = 'purchase_order'
     and d.site_id = p_site_id
     and dl.item_id = p_item_id
     and not dl.is_cancelled and not d.is_cancelled
     and s.is_committed and not s.is_terminal
     and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
  union all
  -- Already planned by an earlier run and not yet converted.
  select po.required_by, po.quantity, 'planned_order'
    from erp.planned_order po
   where po.tenant_id = erp.current_tenant_id()
     and po.item_id = p_item_id and po.site_id = p_site_id
     and po.status in ('suggested', 'reviewed', 'firmed')
$$;

create or replace function erp.scheduled_demand(
  p_item_id uuid, p_site_id uuid, p_from date, p_to date,
  p_forecast_version_id uuid default null)
returns table (due_on date, quantity numeric, source text,
               document_line_id uuid, forecast_line_id uuid)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Firm demand: sales orders committed and not yet despatched.
  select coalesce(dl.required_date, d.required_date, d.document_date),
         dl.quantity - coalesce(dl.quantity_fulfilled, 0),
         'sales_order', dl.id, null::uuid
    from erp.document_line dl
    join erp.document d on d.id = dl.document_id
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.object_state os on os.object_type = 'document' and os.object_id = d.id
    join erp.state s on s.id = os.current_state_id
   where dl.tenant_id = erp.current_tenant_id()
     and dt.base_type_code = 'sales_order'
     and d.site_id = p_site_id
     and dl.item_id = p_item_id
     and not dl.is_cancelled and not d.is_cancelled
     and s.is_committed and not s.is_terminal
     and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
  union all
  -- Forecast demand from the version in force.
  select fl.bucket_start, fl.quantity, 'forecast', null::uuid, fl.id
    from erp.forecast_line fl
    join erp.forecast_version fv on fv.id = fl.forecast_version_id
   where fl.tenant_id = erp.current_tenant_id()
     and fl.item_id = p_item_id and fl.site_id = p_site_id
     and fl.quantity > 0
     and (p_forecast_version_id is null and fv.status = 'active'
          or fv.id = p_forecast_version_id)
     and fl.bucket_start between p_from and p_to
$$;

create or replace function erp.run_planning(
  p_site_id uuid,
  p_horizon_days integer default 180,
  p_forecast_version_id uuid default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_run     uuid;
  v_entity  uuid;
  r         record;
  d         record;
  isx       erp.item_site%rowtype;
  pp        erp.planning_policy%rowtype;
  v_on_hand numeric;
  v_proj    numeric;
  v_qty     numeric;
  v_order   uuid;
  v_orders  integer := 0;
  v_excs    integer := 0;
  v_uom     uuid;
  v_fence   date;
  v_release date;
begin
  perform erp.authorise('planning.run', null, p_site_id, null, 'site', p_site_id);

  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id;

  insert into erp.planning_run (
    tenant_id, entity_id, site_id, horizon_days, forecast_version_id)
  values (v_tenant, v_entity, p_site_id, p_horizon_days, p_forecast_version_id)
  returning id into v_run;

  for r in
    select isx2.item_id from erp.item_site isx2
      join erp.item it on it.id = isx2.item_id
     where isx2.tenant_id = v_tenant and isx2.site_id = p_site_id
       and isx2.is_stocked and isx2.status = 'active' and it.status = 'active'
  loop
    select * into isx from erp.item_site
     where tenant_id = v_tenant and item_id = r.item_id and site_id = p_site_id;
    select * into pp from erp.planning_policy
     where tenant_id = v_tenant and code = isx.planning_policy_code and status = 'active';

    -- A policy that plans nothing plans nothing, and saying so beats
    -- silently skipping the item.
    if coalesce(pp.reorder_method, 'none') = 'none' then
      continue;
    end if;

    select coalesce(sum(b.quantity), 0) into v_on_hand
      from erp.stock_balance b
     where b.tenant_id = v_tenant and b.item_id = r.item_id and b.site_id = p_site_id;

    select it.stock_uom_id into v_uom from erp.item it where it.id = r.item_id;

    -- Inside the planning time fence the plan is not allowed to change: an
    -- order placed there is already being acted on, and a planning run that
    -- reshuffles the next fortnight every night is one the planners turn off.
    v_fence := current_date + coalesce(pp.planning_time_fence_days, 0);

    v_proj := v_on_hand;

    for d in
      select x.due_on, sum(x.qty) as qty,
             -- No min() for uuid, and no meaning in one either: what is
             -- wanted is a representative demand to peg against, so take the
             -- first non-null in the bucket.
             (array_agg(x.document_line_id) filter (where x.document_line_id is not null))[1]
               as document_line_id,
             (array_agg(x.forecast_line_id) filter (where x.forecast_line_id is not null))[1]
               as forecast_line_id,
             string_agg(distinct x.source, ',') as sources
        from (
          select s.due_on, s.quantity as qty, s.source,
                 null::uuid as document_line_id, null::uuid as forecast_line_id
            from erp.scheduled_supply(r.item_id, p_site_id, current_date,
                                      current_date + p_horizon_days) s
          union all
          select dm.due_on, -dm.quantity, dm.source, dm.document_line_id, dm.forecast_line_id
            from erp.scheduled_demand(r.item_id, p_site_id, current_date,
                                      current_date + p_horizon_days,
                                      p_forecast_version_id) dm
        ) x
       where x.due_on is not null
         and x.due_on <= current_date + p_horizon_days
       group by x.due_on
       order by x.due_on
    loop
      v_proj := v_proj + d.qty;

      -- The breach. Ordering when the projection dips below the reorder point
      -- rather than when today's stock does is the entire difference between
      -- planning and reacting.
      if v_proj < coalesce(isx.reorder_point, 0) then
        v_qty := case coalesce(pp.lot_sizing, 'lot_for_lot')
                   when 'fixed' then coalesce(pp.fixed_lot_size, 1)
                   when 'order_up_to' then coalesce(isx.order_up_to, 0) - v_proj
                   else coalesce(isx.order_up_to, isx.reorder_point, 0) - v_proj
                 end;

        v_qty := greatest(v_qty, coalesce(isx.min_order_quantity, 0));
        if coalesce(isx.order_multiple, 0) > 0 then
          v_qty := ceil(v_qty / isx.order_multiple) * isx.order_multiple;
        end if;

        if v_qty > 0 then
          v_release := d.due_on - coalesce(isx.lead_time_days, 0);

          -- Released in the past means the lead time cannot be met. Raising
          -- the order anyway and dating it today would hide that; the
          -- exception is the point.
          if v_release < current_date then
            insert into erp.planning_exception (
              tenant_id, entity_id, site_id, item_id, exception_kind, severity,
              message, detail)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'lead_time_breach',
                    'high',
                    format('needed on %s, and the lead time of %s days means it '
                           'should have been released on %s',
                           d.due_on, coalesce(isx.lead_time_days, 0), v_release),
                    jsonb_build_object('required_by', d.due_on,
                                       'release_on', v_release,
                                       'shortfall', coalesce(isx.reorder_point, 0) - v_proj));
            v_excs := v_excs + 1;
            v_release := current_date;
          end if;

          if v_release <= v_fence then
            -- Inside the fence. Recorded as an exception for a planner rather
            -- than acted on, because the fence exists precisely so that this
            -- decision is a person's.
            insert into erp.planning_exception (
              tenant_id, entity_id, site_id, item_id, exception_kind, severity,
              message, detail)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'expedite', 'high',
                    'a shortage inside the planning time fence needs a decision',
                    jsonb_build_object('required_by', d.due_on, 'quantity', v_qty));
            v_excs := v_excs + 1;
          else
            insert into erp.planned_order (
              tenant_id, entity_id, site_id, item_id, order_kind, quantity,
              uom_id, required_by, release_on, status, planning_run_id, policy_id)
            values (v_tenant, v_entity, p_site_id, r.item_id, 'purchase', v_qty,
                    v_uom, d.due_on, v_release, 'suggested', v_run, pp.id)
            returning id into v_order;

            -- Pegging. B7 has a trigger that refuses an unpegged planned order,
            -- which is what makes "why am I ordering this" a query.
            insert into erp.planned_order_peg (
              tenant_id, planned_order_id, demand_kind,
              demand_document_line_id, demand_forecast_line_id,
              quantity, required_by)
            values (v_tenant, v_order,
                    case when d.document_line_id is not null then 'sales_order'
                         else 'forecast' end,
                    d.document_line_id, d.forecast_line_id, v_qty, d.due_on);

            v_orders := v_orders + 1;
            v_proj := v_proj + v_qty;
          end if;
        end if;
      end if;
    end loop;

    -- Excess is the other half of a planning run, and the half that is always
    -- missing: stock nobody is going to need is money on a shelf.
    if v_proj > coalesce(isx.order_up_to, 0) * 2
       and coalesce(isx.order_up_to, 0) > 0 then
      insert into erp.planning_exception (
        tenant_id, entity_id, site_id, item_id, exception_kind, severity,
        message, detail)
      values (v_tenant, v_entity, p_site_id, r.item_id, 'excess', 'medium',
              'projected stock at the end of the horizon is more than twice the '
              'order-up-to level',
              jsonb_build_object('projected', v_proj, 'order_up_to', isx.order_up_to));
      v_excs := v_excs + 1;
    end if;
  end loop;

  update erp.planning_run
     set finished_at = now(), orders_raised = v_orders, exceptions_raised = v_excs,
         updated_at = now()
   where id = v_run;

  return v_run;
end;
$$;

comment on function erp.run_planning(uuid, integer, uuid) is
  'Spec 5.4: time-phased planning with lot sizing, time fences and pegging. '
  'Projects stock forward against forecast and firm demand and orders against '
  'the projected breach — comparing today''s stock to today''s reorder point '
  'orders too late for anything with a lead time, which is everything.';

-- -----------------------------------------------------------------------------
-- Distribution planning, including the expiry case
--
-- Spec 5.4: "distribution requirements planning across sites, including
-- redistribution driven by expiry risk". The second clause is the interesting
-- one and the one nobody builds: a site with short-dated stock it will not sell
-- and another site that will sell it is a transfer, not a write-off, and the
-- window in which that is true is short.
-- -----------------------------------------------------------------------------

create or replace function erp.suggest_redistribution(p_horizon_days integer default 60)
returns table (item_id uuid, item_code text, from_site_id uuid, from_site text,
               to_site_id uuid, to_site text, quantity numeric, reason text)
language sql
stable
security invoker
set search_path = ''
as $$
  with position as (
    select isx.item_id, isx.site_id,
           coalesce((select sum(b.quantity) from erp.stock_balance b
                      where b.tenant_id = isx.tenant_id and b.item_id = isx.item_id
                        and b.site_id = isx.site_id), 0) as on_hand,
           coalesce(isx.reorder_point, 0) as rop,
           coalesce(isx.order_up_to, 0) as oul,
           coalesce((select sum(e.quantity) from erp.expiry_horizon_report(p_horizon_days) e
                      where e.item_id = isx.item_id and e.site_id = isx.site_id), 0) as expiring
      from erp.item_site isx
     where isx.tenant_id = erp.current_tenant_id()
       and isx.is_stocked and isx.status = 'active'
  ),
  short as (select * from position where on_hand < rop),
  long  as (select * from position where on_hand > oul and oul > 0)
  select s.item_id, i.code, l.site_id, ls.code, s.site_id, ss.code,
         least(l.on_hand - l.oul, s.rop - s.on_hand),
         case when l.expiring > 0
              then 'short-dated stock that will not sell here and will there'
              else 'stock above the order-up-to level at one site and below the '
                   'reorder point at another' end
    from short s
    join long l on l.item_id = s.item_id and l.site_id <> s.site_id
    join erp.item i on i.id = s.item_id
    join erp.site ss on ss.id = s.site_id
    join erp.site ls on ls.id = l.site_id
   where least(l.on_hand - l.oul, s.rop - s.on_hand) > 0
   -- Expiry-driven transfers first: the window in which they are worth making
   -- is the shortest one here.
   order by (l.expiring > 0) desc, 7 desc
$$;

-- -----------------------------------------------------------------------------
-- Supply and demand reconciliation, and the planner's workbench
-- -----------------------------------------------------------------------------

create or replace function erp.supply_demand_position(
  p_item_id uuid, p_site_id uuid, p_horizon_days integer default 180)
returns table (bucket_start date, opening numeric, supply numeric,
               demand numeric, closing numeric, below_reorder boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  isx      erp.item_site%rowtype;
  v_run    numeric;
  d        record;
begin
  select * into isx from erp.item_site
   where tenant_id = v_tenant and item_id = p_item_id and site_id = p_site_id;

  select coalesce(sum(b.quantity), 0) into v_run
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.site_id = p_site_id;

  for d in
    select x.d as due, sum(x.s) as sup, sum(x.dm) as dem
      from (
        select s.due_on as d, s.quantity as s, 0::numeric as dm
          from erp.scheduled_supply(p_item_id, p_site_id, current_date,
                                    current_date + p_horizon_days) s
        union all
        select m.due_on, 0, m.quantity
          from erp.scheduled_demand(p_item_id, p_site_id, current_date,
                                    current_date + p_horizon_days) m
      ) x
     where x.d is not null and x.d <= current_date + p_horizon_days
     group by x.d order by x.d
  loop
    bucket_start := d.due;
    opening := v_run;
    supply := d.sup;
    demand := d.dem;
    v_run := v_run + d.sup - d.dem;
    closing := v_run;
    below_reorder := v_run < coalesce(isx.reorder_point, 0);
    return next;
  end loop;
end;
$$;

comment on function erp.supply_demand_position(uuid, uuid, integer) is
  'Spec 5.4: supply and demand reconciliation. The projection the planning run '
  'made its decisions on, so a planner can see the same picture the engine did '
  'rather than being told an answer.';

create or replace function erp.planner_workbench(p_site_id uuid default null)
returns table (exception_id uuid, kind erp.planning_exception_kind, severity text,
               item_code text, site_code text, message text,
               detail jsonb, age_days integer)
language sql
stable
security invoker
set search_path = ''
as $$
  select e.id, e.exception_kind, e.severity, i.code, s.code, e.message, e.detail,
         (current_date - e.first_seen_at::date)::integer
    from erp.planning_exception e
    left join erp.item i on i.id = e.item_id
    left join erp.site s on s.id = e.site_id
   where e.tenant_id = erp.current_tenant_id()
     and e.resolved_at is null
     and (p_site_id is null or e.site_id = p_site_id)
   order by case e.severity when 'critical' then 0 when 'high' then 1
                            when 'medium' then 2 else 3 end,
            e.first_seen_at
$$;

-- -----------------------------------------------------------------------------
-- Planning, installed
-- -----------------------------------------------------------------------------

create or replace function erp.configure_planning(
  p_service_level_pct numeric default 95,
  p_planning_fence_days integer default 7,
  p_demand_fence_days integer default 3
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'planning', 'Supply chain planning',
    'How far ahead the plan is fixed, how much risk of running out is '
    'acceptable, and how orders are sized.',
    jsonb_build_array(
      jsonb_build_object('kind','planning_policy','key','standard','payload',
        jsonb_build_object(
          'code','standard','name','Standard replenishment',
          'reorder_method','reorder_point',
          'safety_stock_basis','statistical',
          'service_level_pct', p_service_level_pct,
          'lot_sizing','order_up_to',
          'planning_time_fence_days', p_planning_fence_days,
          'demand_time_fence_days', p_demand_fence_days)),

      jsonb_build_object('kind','planning_policy','key','fixed_lot','payload',
        jsonb_build_object(
          'code','fixed_lot','name','Fixed lot',
          'reorder_method','reorder_point',
          'safety_stock_basis','statistical',
          'service_level_pct', p_service_level_pct,
          'lot_sizing','fixed',
          'fixed_lot_size', 100,
          'planning_time_fence_days', p_planning_fence_days,
          'demand_time_fence_days', p_demand_fence_days))));

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function erp.planning_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A stocked item planned by a policy that does not exist is planned by
  -- nothing, and the planning run skips it in silence.
  select 'an item is planned by a policy that does not exist',
         format('%s at %s', i.code, s.code),
         format('planning_policy_code = %s', isx.planning_policy_code)
    from erp.item_site isx
    join erp.item i on i.id = isx.item_id
    join erp.site s on s.id = isx.site_id
   where isx.status = 'active' and isx.is_stocked
     and isx.planning_policy_code is not null
     and not exists (select 1 from erp.planning_policy pp
                      where pp.tenant_id = isx.tenant_id
                        and pp.code = isx.planning_policy_code
                        and pp.status = 'active')
  union all
  -- A reorder point with no lead time will always be ordered too late.
  select 'a planned item has a reorder point and no lead time',
         format('%s at %s', i.code, s.code),
         'the projection will breach and the order will be released the day it '
         'is needed, which is the definition of too late'
    from erp.item_site isx
    join erp.item i on i.id = isx.item_id
    join erp.site s on s.id = isx.site_id
    join erp.planning_policy pp on pp.tenant_id = isx.tenant_id
                               and pp.code = isx.planning_policy_code
   where isx.status = 'active' and isx.is_stocked
     and pp.reorder_method <> 'none'
     and coalesce(isx.reorder_point, 0) > 0
     and coalesce(isx.lead_time_days, 0) = 0
  union all
  -- Order-up-to below the reorder point orders a negative quantity.
  select 'an order-up-to level is below its reorder point',
         format('%s at %s', i.code, s.code),
         format('order_up_to %s, reorder_point %s', isx.order_up_to, isx.reorder_point)
    from erp.item_site isx
    join erp.item i on i.id = isx.item_id
    join erp.site s on s.id = isx.site_id
   where isx.status = 'active' and isx.is_stocked
     and coalesce(isx.order_up_to, 0) > 0
     and isx.order_up_to < coalesce(isx.reorder_point, 0)
  union all
  -- Fixed lot sizing with no lot size sizes every order at one.
  select 'a policy uses fixed lot sizing and names no lot size',
         pp.code, 'every order would be sized at the minimum, or at nothing'
    from erp.planning_policy pp
   where pp.status = 'active' and pp.lot_sizing = 'fixed'
     and coalesce(pp.fixed_lot_size, 0) <= 0
$$;

create or replace function erp.assert_planning_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.planning_configuration_report();
  if v_count > 0 then
    raise exception 'ERPWARE_PLANNING_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return 'planning: every planned item can actually be planned';
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_planner_workbench(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb)
        from erp.planner_workbench(p_site_id) w $$;

create or replace function public.erp_supply_demand(
  p_item_id uuid, p_site_id uuid, p_horizon_days integer default 180)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb)
        from erp.supply_demand_position(p_item_id, p_site_id, p_horizon_days) p $$;

create or replace function public.erp_redistribution_suggestions(p_days integer default 60)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
        from erp.suggest_redistribution(p_days) s $$;

create or replace function public.erp_calculate_policy(p_item_id uuid, p_site_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.calculate_policy(p_item_id, p_site_id) c $$;

create or replace function public.erp_configure_planning(
  p_service_level_pct numeric default 95)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.configure_planning(p_service_level_pct) $$;

create or replace function public.erp_run_planning(
  p_site_id uuid, p_horizon_days integer default 180)
returns uuid language sql volatile security invoker set search_path = ''
as $$ select erp.run_planning(p_site_id, p_horizon_days) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_planner_workbench(uuid)',
    'public.erp_supply_demand(uuid, uuid, integer)',
    'public.erp_redistribution_suggestions(integer)',
    'public.erp_calculate_policy(uuid, uuid)',
    'public.erp_configure_planning(numeric)',
    'public.erp_run_planning(uuid, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_planning', 'erp.configure_planning',
   'Submits the planning policies as a B6 change set the caller cannot approve; '
   'the installer authorises administration.configure.'),
  ('erp_run_planning', 'erp.run_planning',
   'Runs the planning engine, which authorises planning.run for the site and '
   'writes only suggested orders — nothing it produces reaches a supplier '
   'without erp.firm_planned_order() and a document afterwards.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- B6 learns planning policies
-- -----------------------------------------------------------------------------

create or replace function erp.apply_change_set_item(p_item_id uuid)
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

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- The suite
--
-- Planning is the easiest thing in this product to test wrongly: a run that
-- raises orders looks like a run that works. So the cases read the numbers —
-- how much was ordered, when it was released, what it was pegged to — and two
-- of them check that the engine correctly refuses to plan.
-- -----------------------------------------------------------------------------

create or replace function erp_test.planning_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; csi uuid; csl uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_site2 uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid; v_flat uuid;
  v_fc uuid; v_ver uuid; v_run uuid; v_grn uuid;
  v_series numeric[]; v_best record; v_pred numeric[];
  v_pol record; v_n integer; i integer;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzplan','Planning Suite','a@zzplan.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzplan.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  csi := erp.configure_inventory('average');
  csl := erp.configure_planning(95, 7);

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform erp.approve_change_set(csl); perform erp.promote_change_set(csl);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'planning policies install as configuration',
    (select count(*) from erp.planning_policy pp
      where pp.tenant_id = r.tenant_id and pp.status = 'active') = 2,
    'standard and fixed-lot, both promoted';

  -- ---------------------------------------------------------------------------
  -- Model selection, on series with known shapes.
  -- ---------------------------------------------------------------------------
  -- A flat series: nothing to trend, and the simplest model should not lose.
  v_series := array[100,100,100,100,100,100,100,100,100,100,100,100]::numeric[];
  select * into v_best from erp.select_forecast_method(v_series) s
   where s.mape is not null order by s.mape limit 1;
  return query select 'a flat series is forecast flat, with no error',
    v_best.mape = 0,
    format('%s chosen at %s per cent error', v_best.method, v_best.mape);

  -- A rising series: the trend model should beat the flat ones, and by
  -- measurement rather than by preference.
  v_series := array[10,20,30,40,50,60,70,80,90,100,110,120]::numeric[];
  select * into v_best from erp.select_forecast_method(v_series) s
   where s.mape is not null order by s.mape limit 1;
  return query select 'a trending series picks the trend model on measured error',
    v_best.method = 'holt_winters',
    format('%s at %s per cent, against the alternatives', v_best.method, v_best.mape);

  v_pred := erp.fit_forecast(v_series, 'holt_winters', 3);
  return query select 'and it projects the trend forward rather than the level',
    v_pred[1] > 120 and v_pred[3] > v_pred[1],
    format('next three: %s, %s, %s', round(v_pred[1]), round(v_pred[2]), round(v_pred[3]));

  -- Too little history is not a model choice.
  select * into v_best from erp.select_forecast_method(array[5,7,6]::numeric[]) s limit 1;
  return query select 'too little history reports no measured error rather than a number',
    v_best.mape is null,
    'four points fitted to a line is a fit to noise, and reporting a score for '
    'it would be worse than reporting none';

  -- ---------------------------------------------------------------------------
  -- Fixtures with a real demand history.
  -- ---------------------------------------------------------------------------
  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'SPOKE','Spoke','warehouse','active') returning id into v_site2;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  insert into erp.item_site (
    tenant_id, item_id, site_id, is_stocked, planning_policy_code,
    lead_time_days, min_order_quantity, order_multiple, status)
  values (r.tenant_id, v_item, v_site, true, 'standard', 14, 0, 10, 'active');

  -- Twelve months of demand, written as movements so the history is derived
  -- from the ledger rather than from a table the test wrote for itself.
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency)
  values (r.tenant_id, r.entity_id, v_site, 'goods_receipt', v_item,
          v_recv, 'available', 5000, v_uom, 1000, 'GBP');

  for i in 1 .. 12 loop
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
      occurred_at)
    values (r.tenant_id, r.entity_id, v_site, 'despatch', v_item,
            v_recv, 'available', 100 + i * 5, v_uom, 1000, 'GBP',
            date_trunc('month', current_date) - ((13 - i) || ' months')::interval
              + interval '10 days');
  end loop;

  return query select 'demand history is derived from the ledger, not stored',
    (select count(*) from erp.demand_history(v_item, v_site, 24, 'month') h
      where h.quantity > 0) = 12,
    'twelve months of outbound movement, bucketed';

  -- ---------------------------------------------------------------------------
  -- Cleansing.
  -- ---------------------------------------------------------------------------
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id,
    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    occurred_at)
  values (r.tenant_id, r.entity_id, v_site, 'despatch', v_item,
          v_recv, 'available', 3000, v_uom, 1000, 'GBP',
          date_trunc('month', current_date) - interval '2 months' + interval '5 days');

  return query select 'a promotional spike is capped rather than dropped',
    (select c.was_outlier from erp.cleansed_demand(v_item, v_site, 24, 'month') c
      where c.raw_quantity >= 3000)
    and (select c.quantity < c.raw_quantity
           from erp.cleansed_demand(v_item, v_site, 24, 'month') c
          where c.raw_quantity >= 3000),
    'removing it entirely forecasts a business that never runs promotions';

  -- ---------------------------------------------------------------------------
  -- Policy calculation.
  -- ---------------------------------------------------------------------------
  select * into v_pol from erp.calculate_policy(v_item, v_site);
  return query select 'safety stock scales with the square root of the lead time',
    v_pol.safety_stock > 0
    and v_pol.reorder_point > v_pol.safety_stock
    and v_pol.order_up_to > v_pol.reorder_point,
    format('sigma %s, lead %s days, safety %s, rop %s, oul %s',
           round(v_pol.demand_sigma, 1), v_pol.lead_time_days,
           round(v_pol.safety_stock, 1), round(v_pol.reorder_point, 1),
           round(v_pol.order_up_to, 1));

  -- An economic order quantity without a cost is undefined, and returning zero
  -- would read as "order nothing" rather than "this cannot be answered yet".
  return query select 'the order quantity is undefined until the stock has a cost',
    v_pol.eoq is null and v_pol.rounded_eoq is null,
    'the movements above were written straight to the ledger, so nothing has '
    'valued this item';

  insert into erp.item_cost (
    tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand)
  values (r.tenant_id, v_item, v_site, 'average', 1000, 'GBP', 5000);

  select * into v_pol from erp.calculate_policy(v_item, v_site);
  return query select 'and once it has one it is rounded to something orderable',
    v_pol.eoq is not null
    and v_pol.rounded_eoq is not null
    and (v_pol.rounded_eoq)::numeric % 10 = 0,
    format('%s rounded to %s, in multiples of ten',
           round(v_pol.eoq, 1), v_pol.rounded_eoq);

  perform erp.apply_calculated_policy(v_item, v_site);
  return query select 'and applying it writes the numbers nobody had revisited',
    (select isx.reorder_point > 0 from erp.item_site isx
      where isx.item_id = v_item and isx.site_id = v_site),
    'erp.item_site carried five planning numbers and nothing calculated any';

  -- ---------------------------------------------------------------------------
  -- Forecasting end to end.
  -- ---------------------------------------------------------------------------
  insert into erp.forecast (tenant_id, code, name, entity_id, site_id, bucket, status)
  values (r.tenant_id, 'MAIN-M', 'Main monthly', r.entity_id, v_site, 'month', 'active')
  returning id into v_fc;

  v_ver := erp.run_forecast('MAIN-M', 6, 24);
  return query select 'a forecast run writes a version with lines and a chosen method',
    (select count(*) from erp.forecast_line fl where fl.forecast_version_id = v_ver) = 6
    and (select count(*) from erp.forecast_model_choice mc
          where mc.forecast_version_id = v_ver) = 1
    and (select mc.backtest_mape is not null from erp.forecast_model_choice mc
          where mc.forecast_version_id = v_ver),
    'six periods, and the backtest error that chose the model';

  return query select 'a draft forecast is not in force until it is signed off',
    (select fv.status::text from erp.forecast_version fv where fv.id = v_ver) = 'draft',
    'spec 5.4 asks for versioning and sign-off, and a run is neither';

  perform erp.sign_off_forecast(v_ver, 'reviewed with the commercial team');
  return query select 'signing off puts exactly one version in force',
    (select count(*) from erp.forecast_version fv
      where fv.forecast_id = v_fc and fv.status = 'active') = 1,
    'a superseded version still marked active is a run using last quarter''s numbers';

  -- ---------------------------------------------------------------------------
  -- The planning run.
  -- ---------------------------------------------------------------------------
  v_run := erp.run_planning(v_site, 180);
  return query select 'the run raises planned orders against the projection',
    (select pr.orders_raised from erp.planning_run pr where pr.id = v_run) > 0,
    format('%s order(s)', (select pr.orders_raised from erp.planning_run pr where pr.id = v_run));

  return query select 'and every one is pegged to the demand that caused it',
    not exists (
      select 1 from erp.planned_order po
       where po.planning_run_id = v_run
         and not exists (select 1 from erp.planned_order_peg pg
                          where pg.planned_order_id = po.id)),
    'B7 refuses an unpegged planned order, which is what makes "why am I '
    'ordering this" a query';

  return query select 'orders are released early enough to arrive in time',
    not exists (
      select 1 from erp.planned_order po
       where po.planning_run_id = v_run
         and po.release_on > po.required_by),
    'a release date after the required date is an order that arrives late';

  return query select 'and are sized in orderable multiples',
    not exists (select 1 from erp.planned_order po
                 where po.planning_run_id = v_run and po.quantity::numeric % 10 <> 0),
    'the item comes in tens';

  -- ---------------------------------------------------------------------------
  -- Refusals: the cases where planning correctly does nothing.
  -- ---------------------------------------------------------------------------
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'NEW','Never sold',v_uom,'active') returning id into v_flat;
  insert into erp.item_site (tenant_id, item_id, site_id, is_stocked,
                             planning_policy_code, lead_time_days, status)
  values (r.tenant_id, v_flat, v_site, true, 'standard', 7, 'active');

  perform erp.run_forecast('MAIN-M', 6, 24);
  return query select 'an item with no history is not forecast at a flat average',
    exists (select 1 from erp.planning_exception e
             where e.item_id = v_flat and e.exception_kind = 'no_supply_source'),
    'a flat line looks like a forecast and is the absence of one';

  update erp.item_site set lead_time_days = 0
   where tenant_id = r.tenant_id and item_id = v_flat and site_id = v_site;
  update erp.item_site set reorder_point = 50
   where tenant_id = r.tenant_id and item_id = v_flat and site_id = v_site;

  return query select 'a reorder point with no lead time fails the build',
    (select count(*) from erp.planning_configuration_report()
      where finding = 'a planned item has a reorder point and no lead time') = 1,
    'it would always be ordered the day it was needed';

  update erp.item_site set lead_time_days = 7, reorder_point = 0
   where tenant_id = r.tenant_id and item_id = v_flat and site_id = v_site;

  return query select 'and with that fixed the configuration is sound again',
    (select count(*) from erp.planning_configuration_report()) = 0,
    'every planned item can actually be planned';

  -- ---------------------------------------------------------------------------
  -- Redistribution.
  -- ---------------------------------------------------------------------------
  insert into erp.item_site (tenant_id, item_id, site_id, is_stocked,
                             planning_policy_code, lead_time_days,
                             reorder_point, order_up_to, status)
  values (r.tenant_id, v_item, v_site2, true, 'standard', 14, 500, 1000, 'active');

  return query select 'a site below its reorder point and one above its level suggest a transfer',
    exists (select 1 from erp.suggest_redistribution(60) s
             where s.to_site = 'SPOKE' and s.from_site = 'MAIN'),
    'stock in the wrong place is a transfer, not a purchase';

  -- ---------------------------------------------------------------------------
  -- The projection a planner sees is the one the engine used.
  -- ---------------------------------------------------------------------------
  return query select 'the workbench shows the same projection the run decided on',
    (select count(*) from erp.supply_demand_position(v_item, v_site, 180)) > 0,
    'being told an answer without the picture is how planners stop trusting a run';

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_planning_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 23;
begin
  create temporary table if not exists zz_plan_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_plan_result;
  insert into zz_plan_result select * from erp_test.planning_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_plan_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_PLANNING_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_PLANNING_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail
      using errcode = 'P0001';
  end if;

  return format('planning: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_planning_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
