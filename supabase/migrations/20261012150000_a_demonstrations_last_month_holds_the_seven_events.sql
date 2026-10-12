-- A demonstration's last month holds the seven events.
--
-- From the v1 known-issues list (KI-08). The Definition of Done's seeded month
-- must contain a part receipt, a price variance, a supplier credit note, a
-- part despatch, a customer credit note, a stock adjustment and an inter-site
-- transfer. The builder raises all seven and the demonstration history suites
-- prove it on test data, but nothing counted them in a live demonstration's
-- rebuilt history: the seed script prints totals, which say nothing about the
-- month being shown.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.demonstration_month_report(tenant): for each demonstration holding
--      documents, the 31 days up to its latest document, and each of the seven
--      that is not in them, as a finding. Read from the documents themselves:
--      a goods receipt for less than its order line, a bill line priced off
--      its order line, a supplier credit note, a delivery for less than its
--      order line, a customer credit note, a stock adjustment and a transfer,
--      each committed and none cancelled.
--   B. Registered as a tenant report, demonstration_month, which the platform
--      console's Diagnostics runs for a chosen organisation. A report, not an
--      assertion: a demonstration that drifts is worth saying, and never worth
--      stopping a release for.
--   C. erp_test.demonstration_month_suite proves A on a week of built history
--      and on two days of it.

create or replace function erp.demonstration_month_report(p_tenant_id uuid default null)
returns table(tenant_code text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  with demo as (
    select t.id, t.code,
           (select max(d.document_date) from erp.document d
             where d.tenant_id = t.id and not d.is_cancelled and d.document_date <= current_date) as last_day
      from erp.tenant t
     where (p_tenant_id is null or t.id = p_tenant_id)
       and erp.tenant_is_demonstration(t.id)
  ),
  win as (
    select id, code, last_day - 30 as first_day, last_day from demo where last_day is not null
  ),
  doc as (
    -- Every committed document of the window, with its type.
    select w.id as tenant_id, d.id, dt.code as type_code, dt.base_type_code as base
      from win w
      join erp.document d on d.tenant_id = w.id and d.document_date between w.first_day and w.last_day
                         and not d.is_cancelled
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id and s.is_committed and s.code <> 'cancelled'
  ),
  seen as (
    select w.id as tenant_id, e.event
      from win w
      cross join lateral (
        -- A goods receipt for less than its order line.
        select 'part receipt' as event
         where exists (select 1 from doc x
                         join erp.document_relation r on r.tenant_id = x.tenant_id and r.from_document_id = x.id
                                                     and r.relation_kind = 'fulfils' and r.to_line_id is not null
                         join erp.document_line ol on ol.tenant_id = r.tenant_id and ol.id = r.to_line_id
                        where x.tenant_id = w.id and x.base = 'receipt' and r.quantity < ol.quantity)
        union all
        -- A bill line priced off the order line it bills, directly or through
        -- the receipt line that fulfilled it.
        select 'price variance'
         where exists (select 1 from doc x
                         join erp.document_line bl on bl.tenant_id = x.tenant_id and bl.document_id = x.id
                         join erp.document_relation r on r.tenant_id = bl.tenant_id and r.from_line_id = bl.id
                                                     and r.to_line_id is not null
                         left join erp.document_relation rf on rf.tenant_id = r.tenant_id and rf.from_line_id = r.to_line_id
                                                           and rf.relation_kind = 'fulfils' and rf.to_line_id is not null
                         join erp.document_line ol on ol.tenant_id = r.tenant_id and ol.id = coalesce(rf.to_line_id, r.to_line_id)
                         join erp.document od on od.tenant_id = ol.tenant_id and od.id = ol.document_id
                         join erp.document_type odt on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
                                                   and odt.base_type_code = 'purchase_order'
                        where x.tenant_id = w.id and x.type_code = 'purchase_invoice'
                          and bl.unit_price_minor is distinct from ol.unit_price_minor)
        union all
        select 'supplier credit note'
         where exists (select 1 from doc x where x.tenant_id = w.id and x.base = 'return_to_supplier')
        union all
        -- A delivery for less than its order line.
        select 'part despatch'
         where exists (select 1 from doc x
                         join erp.document_relation r on r.tenant_id = x.tenant_id and r.from_document_id = x.id
                                                     and r.relation_kind = 'fulfils' and r.to_line_id is not null
                         join erp.document_line ol on ol.tenant_id = r.tenant_id and ol.id = r.to_line_id
                        where x.tenant_id = w.id and x.base = 'delivery' and r.quantity < ol.quantity)
        union all
        select 'customer credit note'
         where exists (select 1 from doc x where x.tenant_id = w.id and x.base = 'credit_reference')
        union all
        select 'stock adjustment'
         where exists (select 1 from doc x where x.tenant_id = w.id and x.base = 'adjustment')
        union all
        select 'inter-site transfer'
         where exists (select 1 from doc x where x.tenant_id = w.id and x.base = 'transfer_order')
      ) e
  )
  select w.code, format('the demonstration''s last month shows no %s', ev.event),
         format('%s to %s', w.first_day, w.last_day)
    from win w
    cross join unnest(array['part receipt', 'price variance', 'supplier credit note', 'part despatch',
                            'customer credit note', 'stock adjustment', 'inter-site transfer'])
         with ordinality as ev(event, n)
   where not exists (select 1 from seen s where s.tenant_id = w.id and s.event = ev.event)
   order by w.code, ev.n
$$;
revoke all on function erp.demonstration_month_report(uuid) from public, anon, authenticated;
comment on function erp.demonstration_month_report(uuid) is
  'For each demonstration holding documents, the seven events the Definition of Done''s seeded month must hold that '
  'are missing from the 31 days up to its latest document (20261012150000). Empty when all seven are there.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('demonstration_month', 'A demonstration''s last month shows every event the demo path needs', 'report', 'tenant',
   'demonstration_month_report', '', null, '',
   'A part receipt, a price variance, a supplier credit note, a part despatch, a customer credit note, a stock '
   'adjustment and an inter-site transfer, each in the 31 days up to the demonstration''s latest document. Says '
   'which are missing; never stops a release.', false, 30)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb, seq = excluded.seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_month_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_from   date;
  v_week   integer;
  v_short  integer;
  v_list   text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzdmo' || v_tag, 'Demonstration Month Suite',
      'admin@demo-zzdmo' || v_tag || '.test', 'Month Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzdmo' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    -- ── 1. Nothing built, nothing to say ────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a demonstration with no documents yet is not reported';
    passed := v_state is null and not exists (select 1 from erp.demonstration_month_report(v_tenant));
    detail := coalesce(v_state, 'no findings');
    return next;

    -- ── 2. Two days of history miss most of the seven ───────────────────────
    -- A Sunday and a Monday: the builder's Monday part receipt and nothing of
    -- Tuesday to Saturday.
    v_step := 'two days of history';
    v_from := date_trunc('month', current_date - interval '60 days')::date;
    v_from := v_from + ((7 - extract(isodow from v_from)::integer) % 7);
    perform erp.seed_demo_history(v_from, v_from + 1, 1);
    select count(*), string_agg(r.finding, '; ') into v_short, v_list from erp.demonstration_month_report(v_tenant) r;
    v_cases := v_cases + 1;
    case_name := 'two days of history are reported for the events they do not hold';
    passed := v_state is null and v_short >= 4;
    detail := coalesce(v_state, format('%s finding(s): %s', v_short, coalesce(v_list, 'none')));
    return next;

    -- ── 3. A full week holds all seven ──────────────────────────────────────
    v_step := 'the rest of the week';
    perform erp.seed_demo_history(v_from + 2, v_from + 8, 1);
    select count(*), string_agg(r.finding, '; ') into v_week, v_list from erp.demonstration_month_report(v_tenant) r;
    v_cases := v_cases + 1;
    case_name := 'a full week of the builder''s history holds all seven, and nothing is reported';
    passed := v_state is null and v_week = 0;
    detail := coalesce(v_state, format('%s finding(s): %s', v_week, coalesce(v_list, 'none')));
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
    raise exception 'CLOVEERP_DEMONSTRATION_MONTH_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.demonstration_month_suite() from public, anon, authenticated;

create or replace function erp_test.assert_demonstration_month_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _demonstration_month on commit drop as
    select * from erp_test.demonstration_month_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _demonstration_month;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATION_MONTH_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DEMONSTRATION_MONTH_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('demonstration month: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_demonstration_month_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
