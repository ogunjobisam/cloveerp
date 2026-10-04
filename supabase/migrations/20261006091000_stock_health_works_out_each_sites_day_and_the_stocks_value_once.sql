set lock_timeout = '30s';

-- =============================================================================
-- 20261006091000  Stock health works out each site's day and the stock's value once
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-41). Stock health
-- (public.erp_stock_health, reading erp.stock_health_report) timed out under
-- load.
--
-- For every stock position it did three things again:
--   - it asked erp.local_today(site) what day it is there, which looks up the
--     organisation, the site and its timezone and checks the timezone's name
--     against the server's list;
--   - it read the value from erp.stock_valuation_report(), as a subquery for
--     that one position, so the valuation was worked out again per position;
--   - and, once for all of them, it found each position's last movement by
--     grouping every stock movement the organisation has ever made.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_test.stock_health_reference(): today's body, word for word, kept as
--      the answer the new one must give.
--   B. erp.stock_health_report(), same columns and order: the organisation is
--      asked for once; the day is worked out once per site that holds stock;
--      the valuation is read once and joined; and each position's last
--      movement is the newest of that item's movements at that site, read from
--      the index on (organisation, item, time) and stopping at the first. The
--      valuation is read only when there is stock at all, as before: with no
--      organisation it refuses, and before it was never reached. The site of a
--      position is never empty, so its joins compare by equality.
--   C. erp_test.stock_health_once_suite: an organisation with stock at two
--      sites in different timezones, an allocation beyond what is on hand, a
--      batch expiring within thirty days, a position the ledger never moved,
--      one not moved in six months and one negative. The report is the same as
--      the reference row for row, there and in every organisation in the
--      database; erp_stock_health for each site is the reference filtered; and
--      the body asks the day only in one place.
--
-- On production: one function is edited in place. No table is altered and no
-- row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Today's body, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_health_reference()
returns table(item_id uuid, item_code text, site_id uuid, site_code text, on_hand numeric, committed numeric, available numeric, value_minor bigint, expiring_30d numeric, days_since_last_movement integer, finding text)
language sql
stable
set search_path = ''
as $reference$
  with oh as (
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b
     where b.tenant_id = erp.current_tenant_id()
     group by 1, 2
  ),
  com as (
    select a.item_id, a.site_id, sum(al.quantity) as qty
      from erp.allocation a
      join erp.allocation_line al on al.allocation_id = a.id
     where a.tenant_id = erp.current_tenant_id()
       and al.status in ('reserved','committed','picked')
     group by 1, 2
  ),
  last_move as (
    select m.item_id, m.site_id, max(m.occurred_at) as at
      from erp.stock_movement m
     where m.tenant_id = erp.current_tenant_id()
     group by 1, 2
  ),
  exp30 as (
    select e.item_id, e.site_id, sum(e.quantity) as qty
      from erp.expiry_horizon_report(30) e group by 1, 2
  )
  select oh.item_id, i.code, oh.site_id, s.code,
         oh.qty, coalesce(com.qty, 0), oh.qty - coalesce(com.qty, 0),
         coalesce((select v.value_minor from erp.stock_valuation_report() v
                    where v.item_id = oh.item_id
                      and v.site_id is not distinct from oh.site_id), 0),
         coalesce(exp30.qty, 0),
         -- The day where the stock is standing, not where the database is
         -- (20260920110000). An overnight movement was a day old by breakfast.
         (erp.local_today(oh.site_id)
            - coalesce(last_move.at, now())::date)::integer,
         case
           when oh.qty < 0 then 'negative on hand'
           when coalesce(com.qty, 0) > oh.qty then 'committed beyond what is on hand'
           when coalesce(exp30.qty, 0) > 0 then 'expiring within thirty days'
           when last_move.at is null then 'never moved'
           when last_move.at < now() - interval '180 days' then 'no movement in six months'
           else 'healthy'
         end
    from oh
    join erp.item i on i.id = oh.item_id
    left join erp.site s on s.id = oh.site_id
    left join com on com.item_id = oh.item_id and com.site_id is not distinct from oh.site_id
    left join last_move on last_move.item_id = oh.item_id
                       and last_move.site_id is not distinct from oh.site_id
    left join exp30 on exp30.item_id = oh.item_id and exp30.site_id is not distinct from oh.site_id
   order by i.code
$reference$;

revoke all on function erp_test.stock_health_reference() from public, anon;

comment on function erp_test.stock_health_reference() is
  'erp.stock_health_report() as it was before 20261006091000, word for word: the answer stock health must still give '
  '(J-41). Read only by erp_test.stock_health_once_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Each site's day, the valuation and the last movement, once
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'erp.stock_health_report()'::regprocedure);
begin
  if strpos(v_src, '20261006091000') = 0 and md5(v_src) <> '0b1e98651a28f75ffe1001a3bd6fda64' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.stock_health_report() is not the body 20261006091000 expects (md5 %)', md5(v_src);
  end if;
end
$guard$;

create or replace function erp.stock_health_report()
returns table(item_id uuid, item_code text, site_id uuid, site_code text, on_hand numeric, committed numeric, available numeric, value_minor bigint, expiring_30d numeric, days_since_last_movement integer, finding text)
language sql
stable
set search_path = ''
as $$
  -- The organisation, asked once (20261006091000, J-41).
  with t as materialized (
    select erp.current_tenant_id() as id
  ),
  oh as materialized (
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b
     where b.tenant_id = (select t.id from t)
     group by 1, 2
  ),
  com as (
    select a.item_id, a.site_id, sum(al.quantity) as qty
      from erp.allocation a
      join erp.allocation_line al on al.allocation_id = a.id
     where a.tenant_id = (select t.id from t)
       and al.status in ('reserved','committed','picked')
     group by 1, 2
  ),
  exp30 as (
    select e.item_id, e.site_id, sum(e.quantity) as qty
      from erp.expiry_horizon_report(30) e group by 1, 2
  ),
  -- The valuation, worked out once and joined, where it was worked out again
  -- for every position. Only when there is stock: with no organisation it
  -- refuses, and the body it replaced never reached it then.
  val as materialized (
    select v.item_id, v.site_id, v.value_minor
      from erp.stock_valuation_report() v
     where exists (select 1 from oh)
  ),
  -- The day where the stock is standing, not where the database is
  -- (20260920110000), worked out once per site that holds stock.
  today as materialized (
    select d.site_id, erp.local_today(d.site_id) as day
      from (select distinct oh.site_id from oh) d
  )
  select oh.item_id, i.code, oh.site_id, s.code,
         oh.qty, coalesce(com.qty, 0), oh.qty - coalesce(com.qty, 0),
         coalesce(val.value_minor, 0),
         coalesce(exp30.qty, 0),
         (today.day - coalesce(last_move.at, now())::date)::integer,
         case
           when oh.qty < 0 then 'negative on hand'
           when coalesce(com.qty, 0) > oh.qty then 'committed beyond what is on hand'
           when coalesce(exp30.qty, 0) > 0 then 'expiring within thirty days'
           when last_move.at is null then 'never moved'
           when last_move.at < now() - interval '180 days' then 'no movement in six months'
           else 'healthy'
         end
    from oh
    join erp.item i on i.id = oh.item_id
    left join erp.site s on s.id = oh.site_id
    join today on today.site_id = oh.site_id
    left join com on com.item_id = oh.item_id and com.site_id = oh.site_id
    -- The position's newest movement, read from the index on (organisation,
    -- item, time) and stopping at the first, where every movement the
    -- organisation ever made was grouped to find it.
    left join lateral (
      select m.occurred_at as at
        from erp.stock_movement m
       where m.tenant_id = (select t.id from t)
         and m.item_id = oh.item_id
         and m.site_id = oh.site_id
       order by m.occurred_at desc
       limit 1
    ) last_move on true
    left join exp30 on exp30.item_id = oh.item_id and exp30.site_id = oh.site_id
    left join val on val.item_id = oh.item_id and val.site_id = oh.site_id
   order by i.code
$$;

comment on function erp.stock_health_report() is
  'Spec 5.2: cover against policy, per product per site, with the site''s own code beside its id so a screen has '
  'something a person can read. The Site column showed an em dash on every row until 20260920130000. Each site''s day, '
  'the valuation and each position''s last movement are worked out once (20261006091000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_health_once_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  v_owner   text := current_user;
  v_step    text := 'every organisation in the database';
  v_state   text;
  tn        record;
  rb        record;
  v_orgs    integer := 0;
  v_rows    integer := 0;
  v_differ  text := '';
  v_n       integer;
  v_entity  uuid;
  v_ccy     char(3);
  v_uom     uuid;
  v_north   uuid;
  v_south   uuid;
  v_nloc    uuid;
  v_sloc    uuid;
  v_plain   uuid;
  v_batched uuid;
  v_still   uuid;
  v_old     uuid;
  v_batch   uuid;
  v_alloc   uuid;
  v_new     jsonb;
  v_ref     jsonb;
  v_findings text;
  v_site    uuid;
  v_sites   integer := 0;
  v_sites_differ text := '';
  v_src     text;
begin
  begin
    -- ── Every organisation already in the database ──────────────────────────
    perform set_config('request.jwt.claims', '', true);
    for tn in select t.id, t.code from erp.tenant t where t.deleted_at is null order by t.code loop
      perform erp.set_job_tenant(tn.id);
      select count(*) into v_n
        from ((select * from erp.stock_health_report()
               except all select * from erp_test.stock_health_reference())
              union all
              (select * from erp_test.stock_health_reference()
               except all select * from erp.stock_health_report())) z;
      v_orgs := v_orgs + 1;
      v_rows := v_rows + (select count(*) from erp.stock_health_report())::integer;
      if v_n > 0 then
        v_differ := v_differ || tn.code || ' (' || v_n || '); ';
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
    -- And nobody at all: no rows, and no refusal, as before.
    select count(*) into v_n from erp.stock_health_report();
    if v_n <> 0 or (select count(*) from erp_test.stock_health_reference()) <> 0 then
      v_differ := v_differ || 'nobody (' || v_n || '); ';
    end if;

    -- ── An organisation with every kind of position ─────────────────────────
    v_step := 'provisioning the organisation';
    select * into rb from erp.provision_tenant(
      'zzsh-' || v_tag, 'Stock Health Suite', 'admin@zzsh-' || v_tag || '.test', 'Health Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzsh-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;

    v_step := 'two sites, a day apart';
    -- The northern depot keeps the time of the Line Islands, fourteen hours
    -- ahead, and the southern one that of American Samoa, eleven behind, so
    -- at any hour their dates differ.
    v_north := erp.create_site('ZZ-NORTH', 'Northern depot', 'warehouse', v_entity);
    v_south := erp.create_site('ZZ-SOUTH', 'Southern depot', 'warehouse', v_entity);
    update erp.site set timezone = 'Pacific/Kiritimati' where id = v_north;
    update erp.site set timezone = 'Pacific/Pago_Pago' where id = v_south;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (rb.tenant_id, v_north, 'ZZ-N-BULK', 'Northern bulk', 'bulk'::erp.location_type, true, 'active'::erp.record_status)
    returning id into v_nloc;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (rb.tenant_id, v_south, 'ZZ-S-BULK', 'Southern bulk', 'bulk'::erp.location_type, true, 'active'::erp.record_status)
    returning id into v_sloc;

    v_step := 'the items';
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZ-SH-PLAIN', 'A widget in two places', v_uom, 'active'::erp.record_status)
    returning id into v_plain;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status, is_batch_controlled)
    values (rb.tenant_id, 'ZZ-SH-BATCH', 'A widget that goes off', v_uom, 'active'::erp.record_status, true)
    returning id into v_batched;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZ-SH-STILL', 'A widget nobody moved', v_uom, 'active'::erp.record_status)
    returning id into v_still;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZ-SH-OLD', 'A widget left alone', v_uom, 'active'::erp.record_status)
    returning id into v_old;
    insert into erp.batch (tenant_id, item_id, batch_number, expires_on, status)
    values (rb.tenant_id, v_batched, 'ZZ-SH-B1', current_date + 10, 'released'::erp.batch_status)
    returning id into v_batch;

    v_step := 'standing the stock';
    -- Forty north and ten south, valued; six of the batch north, going off in
    -- ten days; twelve south, moved four hundred and then two hundred days
    -- ago, so the last movement is not the first.
    perform erp.receive_cost(v_plain, v_north, 40, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
                                    quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (rb.tenant_id, v_entity, v_north, 'receipt_no_order', v_plain, v_nloc, 'available'::erp.stock_status,
            40, v_uom, 500, v_ccy, 'OPENING');
    perform erp.receive_cost(v_plain, v_south, 10, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
                                    quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (rb.tenant_id, v_entity, v_south, 'receipt_no_order', v_plain, v_sloc, 'available'::erp.stock_status,
            10, v_uom, 500, v_ccy, 'OPENING');
    perform erp.receive_cost(v_batched, v_north, 6, 300, v_ccy, v_batch);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, batch_id, to_location_id,
                                    to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (rb.tenant_id, v_entity, v_north, 'receipt_no_order', v_batched, v_batch, v_nloc,
            'available'::erp.stock_status, 6, v_uom, 300, v_ccy, 'OPENING');
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
                                    quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
    values (rb.tenant_id, v_entity, v_south, 'receipt_no_order', v_old, v_sloc, 'available'::erp.stock_status,
            5, v_uom, 200, v_ccy, 'OPENING', now() - interval '400 days'),
           (rb.tenant_id, v_entity, v_south, 'receipt_no_order', v_old, v_sloc, 'available'::erp.stock_status,
            7, v_uom, 200, v_ccy, 'OPENING', now() - interval '200 days');
    -- Negative south: an emergency issue of fifteen against the ten there.
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
                                    quantity, uom_id, reason_code)
    values (rb.tenant_id, v_entity, v_south, 'emergency_issue', v_plain, v_sloc, 'available'::erp.stock_status,
            15, v_uom, 'BREAKDOWN');
    -- A position the ledger has no movement for. Only a balance written
    -- outside the ledger has one (an opening position typed in before it),
    -- so it is written here the way the movement trigger writes a balance.
    perform set_config('erp.ledger_write', 'on', true);
    insert into erp.stock_balance (tenant_id, site_id, location_id, item_id, stock_status, quantity,
                                   owner_party_id, custody_party_id)
    select rb.tenant_id, v_north, v_nloc, v_still, 'available'::erp.stock_status, 3, e.party_id, e.party_id
      from erp.entity e where e.id = v_entity;
    perform set_config('erp.ledger_write', '', true);

    v_step := 'an allocation beyond what is on hand';
    insert into erp.allocation (tenant_id, entity_id, site_id, item_id, quantity, uom_id, demand_kind)
    values (rb.tenant_id, v_entity, v_north, v_plain, 55, v_uom, 'sales_order')
    returning id into v_alloc;
    insert into erp.allocation_line (tenant_id, allocation_id, location_id, quantity, status)
    values (rb.tenant_id, v_alloc, v_nloc, 55, 'reserved'::erp.allocation_status);

    -- ── 1. Row for row, as its administrator ────────────────────────────────
    v_step := 'reading stock health both ways';
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select jsonb_agg(to_jsonb(h) order by h.item_code, h.site_code) into v_new from erp.stock_health_report() h;
    execute format('set local role %I', v_owner);
    select jsonb_agg(to_jsonb(h) order by h.item_code, h.site_code) into v_ref from erp_test.stock_health_reference() h;
    select string_agg(distinct x ->> 'finding', ', ' order by x ->> 'finding') into v_findings
      from jsonb_array_elements(v_ref) x;
    v_cases := v_cases + 1;
    case_name := 'stock health is the same as before, row for row, here and in every organisation in the database';
    passed := v_new = v_ref and v_differ = '' and v_orgs >= 1
          and v_findings = 'committed beyond what is on hand, expiring within thirty days, negative on hand, '
                           'never moved, no movement in six months'
          and (select count(distinct x ->> 'days_since_last_movement') from jsonb_array_elements(v_ref) x) >= 2
          and erp.local_today(v_north) <> erp.local_today(v_south);
    detail := format('%s position(s): %s; %s organisation(s), %s row(s); differing: %s%s',
                     jsonb_array_length(v_ref), v_findings, v_orgs, v_rows, coalesce(nullif(v_differ, ''), 'none'),
                     case when v_new = v_ref then '' else '; the fixture differs from before' end);
    return next;

    -- ── 2. The door, one site at a time ─────────────────────────────────────
    v_step := 'reading the door for each site';
    for v_site in select null::uuid union all select s.id from erp.site s where s.tenant_id = rb.tenant_id loop
      execute 'set local role authenticated';
      select jsonb_agg(x order by x::text) into v_new from jsonb_array_elements(public.erp_stock_health(v_site)) x;
      execute format('set local role %I', v_owner);
      select jsonb_agg(to_jsonb(h) order by to_jsonb(h)::text) into v_ref
        from erp_test.stock_health_reference() h where v_site is null or h.site_id = v_site;
      v_sites := v_sites + 1;
      if v_new is distinct from v_ref then
        v_sites_differ := v_sites_differ || coalesce(v_site::text, 'every site') || '; ';
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'stock health for each site, and for every site, is the reference filtered to it';
    passed := v_sites >= 3 and v_sites_differ = '';
    detail := format('%s reading(s); differing: %s', v_sites, coalesce(nullif(v_sites_differ, ''), 'none'));
    return next;

    -- ── 3. The body ─────────────────────────────────────────────────────────
    v_step := 'reading the body';
    select p.prosrc into v_src from pg_catalog.pg_proc p where p.oid = 'erp.stock_health_report()'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'the day is asked once per site, the valuation once, and no movement history is grouped';
    passed := (length(v_src) - length(replace(v_src, 'erp.local_today(', ''))) / length('erp.local_today(') = 1
          and strpos(v_src, 'erp.local_today(d.site_id)') > 0
          and (length(v_src) - length(replace(v_src, 'erp.stock_valuation_report()', ''))) / length('erp.stock_valuation_report()') = 1
          and (length(v_src) - length(replace(v_src, 'erp.current_tenant_id()', ''))) / length('erp.current_tenant_id()') = 1
          and strpos(v_src, 'max(m.occurred_at)') = 0;
    detail := format('%s characters', length(v_src));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_STOCK_HEALTH_ONCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzsh-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_STOCK_HEALTH_ONCE_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.stock_health_once_suite() from public, anon;

comment on function erp_test.stock_health_once_suite() is
  'Stock health works out each site''s day and the stock''s value once (20261006091000, J-41): the same rows as the '
  'body it replaced, for every kind of position and every organisation, through the door for each site.';

create or replace function erp_test.assert_stock_health_once_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.stock_health_once_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_STOCK_HEALTH_ONCE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Stock health would say otherwise than before, or work the day or the valuation out per position again. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_STOCK_HEALTH_ONCE_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('stock health once: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_stock_health_once_suite() from public, anon;

comment on function erp_test.assert_stock_health_once_suite() is
  'Stock health is what it was, and works each site''s day and the valuation out once (20261006091000).';

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
