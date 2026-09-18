set lock_timeout = '30s';

-- =============================================================================
-- 20260920130000  The stock reports read the site in the header
-- -----------------------------------------------------------------------------
-- The header said MAIN · LND-HO. The Stock forecast listed every row against
-- LEE-WH. The Stock audit's "Balances by location" did the same. On the Reports
-- tab, Valuation showed LEE-WH on every row while Stock health showed an em dash
-- on every row — same products, same page, two answers.
--
-- So a person who has chosen where they are working is shown somewhere else, and
-- is not told.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Which it was
--
-- Both, in different places, and the evidence pointed two ways:
--
--   * public.erp_stock_forecast(p_site_id, p_days) has taken a site since
--     20260910192848. public.erp_stock_audit(p_site_id) and
--     erp_stock_audit_lines(p_site_id, p_location_id) since 20260910182034.
--     None of the three screens has ever passed one. Three doors built to
--     filter and wired to nothing.
--
--   * src/components/erp/session-context.tsx says the opposite in words: "Most
--     pages act on the whole organisation and never read that choice". A page
--     that reads it registers through useScope(), and the header's popover then
--     stops saying the choice does not apply. Two screens register today:
--     raising a document, and Home.
--
--   * public.erp_stock_health(), erp_stock_valuation(), erp_stock_ageing() and
--     erp_count_accuracy() take no argument at all.
--
-- The owner's decision, taken on 18 September: the selector filters them. A
-- header that names a site and a table that ignores it is the kind of quiet
-- disagreement this product exists not to have, and "this page is about the
-- whole organisation" is a thing to say about Home, not about a warehouse's own
-- stock.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The em dash
--
-- Not a filtering fault, and worth separating. erp.stock_health_report() and
-- erp.stock_ageing_report() carry site_id and no site code, while their sibling
-- erp.stock_valuation_report() carries both. 20260916180000 found this, refused
-- to print a uuid under a heading that says Site, and wrote the gap down in
-- erp_meta.app_column_allowance with the remedy stated: "this wants the same
-- pair rather than a uuid printed under Site". This is that remedy. Both
-- register rows go with it, because erp_test.app_column_suite() refuses a row
-- that names a column the door has since learned to answer — a register of
-- known gaps that keeps a closed one is a register nobody can trust.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Count accuracy
--
-- The odd one out: erp.count_accuracy_report() groups by programme and carries
-- no site at all, so it cannot be filtered at the door the way the other three
-- can. erp.count_task has had a site since 0000, so the report takes one and
-- the signature changes — which means erp_ref.part5_capability's artefact list
-- changes with it in the same migration, or erp.assert_part5_coverage() fails
-- the build on a name that no longer resolves.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What a site that holds nothing shows
--
-- Nothing. That is the point and it is worth stating, because LND-HO is an
-- office and an office holds no stock: choosing it will empty these screens. An
-- empty table under a header that names the place is an answer. A full table
-- under a header that names somewhere else is not.
--
-- Proof: erp_test.stock_site_filter_suite(), which stands stock at two sites and
-- asserts each door returns one site's rows for that site, the other's for the
-- other, and both for neither — so a door that ignored its argument would fail
-- twice rather than pass by symmetry.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The two reports carry the code a person reads
--
-- Dropped and recreated rather than replaced: the return type changes, and
-- CREATE OR REPLACE cannot change a function's result columns. The signature
-- does not change, so erp_ref.part5_capability still resolves both.
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp.stock_health_report();

create function erp.stock_health_report()
returns table (item_id uuid, item_code text, site_id uuid, site_code text,
               on_hand numeric, committed numeric, available numeric,
               value_minor bigint, expiring_30d numeric,
               days_since_last_movement integer, finding text)
language sql
stable
security invoker
set search_path = ''
as $$
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
$$;

comment on function erp.stock_health_report() is
  'Spec 5.2: cover against policy, per product per site, with the site''s own '
  'code beside its id so a screen has something a person can read. The Site '
  'column showed an em dash on every row until 20260920130000.';

drop function if exists erp.stock_ageing_report();

create function erp.stock_ageing_report()
returns table (item_id uuid, item_code text, site_id uuid, site_code text,
               bucket text, quantity numeric, value_minor bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Ageing is measured from the valuation layers rather than from the balance,
  -- because a balance has no age: it is a number that was updated this morning
  -- whether the stock arrived today or two years ago.
  select l.item_id, i.code, l.site_id, s.code,
         case
           when l.received_at > now() - interval '30 days'  then '0-30'
           when l.received_at > now() - interval '90 days'  then '31-90'
           when l.received_at > now() - interval '180 days' then '91-180'
           when l.received_at > now() - interval '365 days' then '181-365'
           else '365+'
         end,
         sum(l.remaining),
         round(sum(l.remaining * l.unit_cost_minor))::bigint
    from erp.stock_valuation_layer l
    join erp.item i on i.id = l.item_id
    left join erp.site s on s.id = l.site_id
   where l.tenant_id = erp.current_tenant_id()
     and l.remaining > 0
   group by 1, 2, 3, 4, 5
   order by 2, 5
$$;

comment on function erp.stock_ageing_report() is
  'Spec 5.2: ageing analysis, measured from the valuation layers. A balance has '
  'no age — it is a number updated this morning whether the stock arrived today '
  'or two years ago. Carries the site''s code beside its id (20260920130000).';

-- The register of known gaps loses the two this closes. erp_test.app_column_suite()
-- refuses a row naming a column its door has since learned to answer.
delete from erp_meta.app_column_allowance
 where (door, column_name) in (('erp_stock_health', 'site_code'),
                               ('erp_stock_ageing', 'site_code'));

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Count accuracy learns which site it is counting
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp.count_accuracy_report(date);

create function erp.count_accuracy_report(p_since date default null,
                                          p_site_id uuid default null)
returns table (programme_code text, tasks bigint, within_tolerance bigint,
               accuracy_pct numeric, absolute_variance numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Spec 5.2: accuracy reporting. A rate, because the question a count answers
  -- is "are the records trustworthy", and a list of adjustments does not answer
  -- it — a warehouse with a hundred small corrections and one with a hundred
  -- large ones produce the same list and very different answers.
  --
  -- And that question is asked of a place. A rate across every warehouse tells
  -- the one with a problem that the others are fine.
  select p.code,
         count(*),
         count(*) filter (where t.within_tolerance),
         round(100.0 * count(*) filter (where t.within_tolerance)
               / nullif(count(*), 0), 2),
         coalesce(sum(abs(t.variance)), 0)
    from erp.count_task t
    join erp.count_programme p on p.id = t.count_programme_id
   where t.tenant_id = erp.current_tenant_id()
     and t.counted_at is not null
     and (p_since is null or t.counted_at::date >= p_since)
     and (p_site_id is null or t.site_id = p_site_id)
   group by p.code
   order by 4
$$;

comment on function erp.count_accuracy_report(date, uuid) is
  'Spec 5.2: how close the counts came, by programme, for one site or for all '
  'of them. A rate across every warehouse tells the one with a problem that the '
  'others are fine.';

-- The register named the old signature, and erp.assert_part5_coverage() resolves
-- every artefact with to_regprocedure().
update erp_ref.part5_capability
   set artefacts = array_replace(artefacts,
                     'erp.count_accuracy_report(date)',
                     'erp.count_accuracy_report(date,uuid)')
 where 'erp.count_accuracy_report(date)' = any(artefacts);

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The four doors take the site the header names
--
-- Dropped before they are recreated, not overloaded. A zero-argument form
-- beside a one-defaulted-argument form makes every existing call ambiguous, and
-- two suites call public.erp_stock_valuation() with no arguments.
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists public.erp_stock_valuation();
drop function if exists public.erp_stock_health();
drop function if exists public.erp_stock_ageing();
drop function if exists public.erp_count_accuracy();

create function public.erp_stock_valuation(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb)
        from erp.stock_valuation_report() v
       where p_site_id is null or v.site_id = p_site_id $$;

create function public.erp_stock_health(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb)
        from erp.stock_health_report() h
       where p_site_id is null or h.site_id = p_site_id $$;

create function public.erp_stock_ageing(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb)
        from erp.stock_ageing_report() a
       where p_site_id is null or a.site_id = p_site_id $$;

create function public.erp_count_accuracy(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
        from erp.count_accuracy_report(null, p_site_id) c $$;

comment on function public.erp_stock_valuation(uuid) is
  'Cost basis by product and site, for the site the header names or for every '
  'site when it names none.';
comment on function public.erp_stock_health(uuid) is
  'Cover against policy by product and site, for the site the header names or '
  'for every site when it names none.';
comment on function public.erp_stock_ageing(uuid) is
  'How long stock has been standing still, for the site the header names or for '
  'every site when it names none.';
comment on function public.erp_count_accuracy(uuid) is
  'How close the counts came, by programme, for the site the header names or '
  'for every site when it names none.';

do $grants$
declare f text;
begin
  foreach f in array array[
    'public.erp_stock_valuation(uuid)', 'public.erp_stock_health(uuid)',
    'public.erp_stock_ageing(uuid)', 'public.erp_count_accuracy(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end
$grants$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Proof
--
-- Stock is stood at two sites and each door is asked three questions: this
-- site, that site, and no site. A door that ignored its argument would answer
-- all three the same way and fail two of them, so the suite cannot pass by
-- symmetry — which is the failure mode of every "does the filter filter" test
-- written against one site.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.stock_site_filter_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 8;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_ccy char(3); v_uom uuid;
  v_north   uuid; v_south uuid;
  v_nloc    uuid; v_sloc uuid;
  v_item    uuid;
  v_n       integer; v_s integer; v_both integer;
  v_code    text; v_office uuid;
begin
  begin
  v_step := 'provisioning the organisation';
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-site-filter', 'Site filter suite',
                              'admin@zz-site-filter.test', 'Site Filter Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f3', 'admin@zz-site-filter.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f3')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;

  v_step := 'standing stock at two sites';
  v_north := erp.create_site('ZZ-NORTH', 'Northern depot', 'warehouse', v_entity);
  v_south := erp.create_site('ZZ-SOUTH', 'Southern depot', 'warehouse', v_entity);

  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_north, 'ZZ-N-BULK', 'Northern bulk', 'bulk'::erp.location_type,
          true, 'active'::erp.record_status)
  returning id into v_nloc;
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_south, 'ZZ-S-BULK', 'Southern bulk', 'bulk'::erp.location_type,
          true, 'active'::erp.record_status)
  returning id into v_sloc;

  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'ZZ-SITE-1', 'A widget in two places', v_uom, 'active'::erp.record_status)
  returning id into v_item;

  -- Forty north, ten south, at the same cost. No document: this is an opening
  -- position, the way erp_test.stock_adjustment_suite() stands its own.
  perform erp.receive_cost(v_item, v_north, 40, 500, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_north, 'receipt_no_order', v_item, v_nloc,
          'available'::erp.stock_status, 40, v_uom, 500, v_ccy, 'OPENING');

  perform erp.receive_cost(v_item, v_south, 10, 500, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_south, 'receipt_no_order', v_item, v_sloc,
          'available'::erp.stock_status, 10, v_uom, 500, v_ccy, 'OPENING');

  -- ── 1. Valuation ─────────────────────────────────────────────────────────
  v_step := 'asking the valuation for one site, the other, and neither';
  v_cases := v_cases + 1;
  select count(*) into v_n from jsonb_array_elements(public.erp_stock_valuation(v_north)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';
  select count(*) into v_s from jsonb_array_elements(public.erp_stock_valuation(v_south)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';
  select count(*) into v_both from jsonb_array_elements(public.erp_stock_valuation()) x
   where x ->> 'item_code' = 'ZZ-SITE-1';

  case_name := 'the valuation answers for the site it is asked about, and for every site when it is asked about none';
  passed := v_n = 1 and v_s = 1 and v_both = 2;
  detail := format('north %s row(s), south %s, neither %s', v_n, v_s, v_both);
  return next;

  -- ── 2. And the figures are that site's, not the organisation's ───────────
  v_cases := v_cases + 1;
  case_name := 'the quantity the valuation reports for one site is that site''s forty, not the fifty on hand altogether';
  passed := (select (x ->> 'quantity')::numeric
               from jsonb_array_elements(public.erp_stock_valuation(v_north)) x
              where x ->> 'item_code' = 'ZZ-SITE-1') = 40
        and (select (x ->> 'quantity')::numeric
               from jsonb_array_elements(public.erp_stock_valuation(v_south)) x
              where x ->> 'item_code' = 'ZZ-SITE-1') = 10;
  detail := 'forty north and ten south, asked for separately';
  return next;

  -- ── 3. Stock health ──────────────────────────────────────────────────────
  v_step := 'asking stock health for one site';
  v_cases := v_cases + 1;
  select count(*) into v_n from jsonb_array_elements(public.erp_stock_health(v_north)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';
  select count(*) into v_s from jsonb_array_elements(public.erp_stock_health(v_south)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';
  select count(*) into v_both from jsonb_array_elements(public.erp_stock_health()) x
   where x ->> 'item_code' = 'ZZ-SITE-1';

  case_name := 'stock health answers for the site it is asked about';
  passed := v_n = 1 and v_s = 1 and v_both = 2;
  detail := format('north %s row(s), south %s, neither %s', v_n, v_s, v_both);
  return next;

  -- ── 4. And it says which site in words ───────────────────────────────────
  v_cases := v_cases + 1;
  select x ->> 'site_code' into v_code
    from jsonb_array_elements(public.erp_stock_health(v_north)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';

  case_name := 'stock health names the site in the code a person reads, where the Site column showed an em dash';
  passed := v_code = 'ZZ-NORTH';
  detail := format('the row says %s', coalesce(v_code, 'nothing at all'));
  return next;

  -- ── 5. Ageing ────────────────────────────────────────────────────────────
  v_step := 'asking the ageing for one site';
  v_cases := v_cases + 1;
  select count(*) into v_n from jsonb_array_elements(public.erp_stock_ageing(v_north)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';
  select count(*) into v_s from jsonb_array_elements(public.erp_stock_ageing(v_south)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';
  select x ->> 'site_code' into v_code
    from jsonb_array_elements(public.erp_stock_ageing(v_south)) x
   where x ->> 'item_code' = 'ZZ-SITE-1';

  case_name := 'the ageing answers for the site it is asked about, and names it';
  passed := v_n = 1 and v_s = 1 and v_code = 'ZZ-SOUTH';
  detail := format('north %s, south %s, and the southern row says %s',
                   v_n, v_s, coalesce(v_code, 'nothing at all'));
  return next;

  -- ── 6. A site that holds nothing shows nothing ───────────────────────────
  -- The case an office site produces on a real screen, and the one worth being
  -- explicit about: choosing LND-HO empties these tables, and that is an answer
  -- rather than a fault.
  v_step := 'asking about a site that holds no stock';
  v_cases := v_cases + 1;
  v_office := erp.create_site('ZZ-OFFICE', 'Head office', 'office', v_entity);
  case_name := 'a site that holds nothing shows nothing, rather than showing everywhere else';
  passed := jsonb_array_length(public.erp_stock_valuation(v_office)) = 0
        and jsonb_array_length(public.erp_stock_health(v_office)) = 0
        and jsonb_array_length(public.erp_stock_ageing(v_office)) = 0;
  detail := 'an office holds no stock, so the three reports are empty for it';
  return next;

  -- ── 7. Count accuracy takes a site without losing its date ───────────────
  v_step := 'asking count accuracy for a site';
  v_cases := v_cases + 1;
  case_name := 'count accuracy still answers, for a site and for all of them, and still takes a date';
  passed := jsonb_typeof(public.erp_count_accuracy(v_north)) = 'array'
        and jsonb_typeof(public.erp_count_accuracy()) = 'array'
        and (select count(*) from erp.count_accuracy_report(erp.local_today(v_north) - 30, v_north)) >= 0;
  detail := 'the door answers with an array either way, and the report keeps its since-date';
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 8. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant where code = 'zz-site-filter')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000f3');
  detail := coalesce(v_state, 'zz-site-filter rolled back with its depots and its stock');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: stock_site_filter_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.stock_site_filter_suite() from public, anon;

comment on function erp_test.stock_site_filter_suite() is
  'The stock reports answer for the site they are asked about. Stock is stood at '
  'two depots and each door is asked three questions — this site, that site, '
  'neither — so a door that ignored its argument fails twice rather than passing '
  'by symmetry. Also that stock health and the ageing name their site in the '
  'code a person reads, where the Site column showed an em dash, and that a site '
  'holding nothing shows nothing.';

create or replace function erp_test.assert_stock_site_filter_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 8;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _stock_site_filter on commit drop as
    select * from erp_test.stock_site_filter_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _stock_site_filter;
  drop table _stock_site_filter;
  if v_fail > 0 then
    raise exception E'CLOVEERP_STOCK_SITE_FILTER_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: stock_site_filter_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the stock reports read the site they are asked about: %s/%s cases passed',
                v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_stock_site_filter_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_stock_site_filter_suite();
-- The suite whose register rows this removes.
select erp_test.assert_app_column_suite();
select erp_test.assert_inventory_suite();

select erp.assert_part5_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_diagnostics_registered();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_isolation();
