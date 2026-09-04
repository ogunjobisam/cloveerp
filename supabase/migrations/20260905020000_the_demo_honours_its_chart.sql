-- The demo honours the chart the organisation chose.
--
-- The first attempt to configure the live demonstration organisation was
-- refused, and the refusal was right:
--
--   CLOVEERP_PROMOTION_BREAKS_DETERMINATION: procurement-lifecycle introduces
--   a way for a posting to fail — goods_receipt on ACME wants account 2300 …
--   purchase_commitment on ACME wants account 8100 …
--
-- That organisation has every feature switched on from the features screen,
-- statutory_chart_8_1 among them. With that capability on, erp.configure_finance()
-- deliberately installs no chart — the chart_8_1 pack ships the accounts — and
-- the product's own order, proved by the suite that shipped the pack, is the
-- pack first and the modules after, because promoting a module whose rules
-- name accounts the company does not have is refused by the determination
-- coverage gate rather than discovered at a month end.
--
-- erp.ensure_demo_configuration() knew nothing of this. It ran the installers
-- straight away, and on an organisation that had chosen §8.1's chart the
-- second installer found an entity with no accounts at all. The suite that
-- proved it did so on a freshly provisioned organisation, which chooses
-- nothing, so the case was never exercised. It now asks: if the organisation
-- chose the statutory chart and does not yet hold the pack, apply the pack,
-- submit, approve and promote its change set, and only then install finance.
-- An organisation on the default chart is untouched.
--
-- And one thing the pack path found that the default path hid.
-- erp.configure_inventory() writes the costing policy's variance account as
-- the literal 9100 — the default chart's purchase price variance — while the
-- posting rule beside it already asks erp.chart_account_code() for the same
-- purpose. Under §8.1's chart that account is 6200, and
-- erp.assert_inventory_sane() reported a costing policy naming an account the
-- entity does not have. The policy now asks the chart the same way the rule
-- does; under the default chart the answer is still 9100.
--
-- Both are patched from the definition the database is carrying, by asserted
-- replacement, as the migration before this one did.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The costing policy's variance account follows the chart
-- ═════════════════════════════════════════════════════════════════════════════

do $inventory$
declare
  v_def  text;
  v_n    text := $n$'variance_account','9100'$n$;
  v_r    text := $r$'variance_account', erp.chart_account_code('purchase_price_variance')$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: expected the literal variance '
      'account once in erp.configure_inventory(), found %.', v_hits;
  end if;
  execute replace(v_def, v_n, v_r);
end
$inventory$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The chart pack first, when the organisation chose it
-- ═════════════════════════════════════════════════════════════════════════════

do $ensure$
declare
  v_def  text;
  v_n1   text := $n$  v_did      jsonb := '[]'::jsonb;
  r          record;
begin$n$;
  v_r1   text := $r$  v_did      jsonb := '[]'::jsonb;
  v_pack     jsonb;
  v_cs       uuid;
  r          record;
begin$r$;
  v_n2   text := $n$  select count(*) into v_ledgers from erp.ledger l where l.tenant_id = p_tenant_id;
  if v_ledgers = 0 then$n$;
  v_r2   text := $r$  -- An organisation that chose §8.1's chart gets no chart from the finance
  -- installer: the chart_8_1 pack ships the accounts, and the product's own
  -- order is the pack first, then the modules, because promoting a module
  -- whose rules name accounts the company does not have is refused.
  if erp.capability_on(p_tenant_id, 'statutory_chart_8_1', current_date)
     and not exists (select 1 from erp.tenant_pack tp
                      where tp.tenant_id = p_tenant_id and tp.pack_code = 'chart_8_1'
                        and tp.status in ('applied', 'promoted')) then
    v_pack := erp.apply_content_pack('chart_8_1');
    v_cs := (v_pack ->> 'change_set_id')::uuid;
    if (select c.status from erp.change_set c where c.id = v_cs) = 'draft' then
      perform erp.submit_change_set(v_cs);
      perform erp.approve_change_set(v_cs);
      perform erp.promote_change_set(v_cs);
    end if;
    v_did := v_did || '"chart_8_1"'::jsonb;
  end if;

  select count(*) into v_ledgers from erp.ledger l where l.tenant_id = p_tenant_id;
  if v_ledgers = 0 then$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1),
    (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: a needle this migration expects '
        'once in erp.ensure_demo_configuration() was found % time(s).', v_hits;
    end if;
  end loop;
  if position('chart_8_1' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: erp.ensure_demo_configuration() '
      'already knows the chart pack; this migration would apply it twice.';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$ensure$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.demo_chart_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  d        record;
  d2       record;
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  v_conf   jsonb;
  v_again  jsonb;
  v_res    jsonb;
  v_ok     boolean;
  v_msg    text;
  v_cases  integer := 0;
  v_slice  date := (date_trunc('month', current_date) - interval '14 months')::date;
begin
  -- ── An organisation that chose §8.1's chart before it had one ──────────────
  select * into d from erp.provision_tenant('zzchart', 'Demo Chart Suite', 'a@zzchart.test', 'Chart Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(d.admin_token);
  update erp.environment set is_live = false where tenant_id = d.tenant_id and is_self;
  perform erp.set_capability('statutory_chart_8_1', true, 'chose §8.1''s chart');

  v_cases := v_cases + 1;
  begin
    v_conf := erp.ensure_demo_configuration(d.tenant_id, d.admin_user_id);
    v_ok := (v_conf -> 'installed' ->> 0) = 'chart_8_1'
        and exists (select 1 from erp.tenant_pack tp where tp.tenant_id = d.tenant_id
                       and tp.pack_code = 'chart_8_1' and tp.status in ('applied', 'promoted'))
        and (select count(*) from erp.account a where a.tenant_id = d.tenant_id) = 20
        and exists (select 1 from erp.account a where a.tenant_id = d.tenant_id and a.code = '2300')
        and not exists (select 1 from erp.account a where a.tenant_id = d.tenant_id and a.code = '1200')
        and (select count(*) from erp.change_set c where c.tenant_id = d.tenant_id
              and c.code in ('finance-posting', 'procurement-lifecycle', 'sales-lifecycle',
                             'inventory-operations', 'receivables', 'master-data-governance')) = 6
        and exists (select 1 from erp.posting_rule pr where pr.tenant_id = d.tenant_id
                       and pr.code = 'goods_receipt' and pr.status = 'active'
                       and pr.posting_lines::text like '%"2300"%');
    v_msg := format('installed %s; %s accounts', v_conf -> 'installed',
                    (select count(*) from erp.account a where a.tenant_id = d.tenant_id));
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 200);
  end;
  return query select 'with the statutory chart chosen, the pack is applied first and every module installs on it'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  v_again := erp.ensure_demo_configuration(d.tenant_id, d.admin_user_id);
  return query select 'and a second call applies nothing'::text,
    jsonb_array_length(v_again -> 'installed') = 0
    and (select count(*) from erp.tenant_pack tp where tp.tenant_id = d.tenant_id and tp.pack_code = 'chart_8_1') = 1,
    format('installed %s', v_again -> 'installed');

  v_cases := v_cases + 1;
  begin
    v_res := erp.seed_demo_history(v_slice, v_slice + 4, 1);
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_subledger_reconciles()
             || '; ' || erp.assert_inventory_reconciles() || '; ' || erp.assert_inventory_sane();
    v_ok := (v_res ->> 'built')::integer >= 20
        and (select variance_account_code from erp.costing_policy cp
              where cp.tenant_id = d.tenant_id order by cp.code limit 1) = '6200';
    v_msg := format('%s documents; policy variance account %s; %s', v_res ->> 'built',
                    (select variance_account_code from erp.costing_policy cp
                      where cp.tenant_id = d.tenant_id order by cp.code limit 1), v_msg);
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 220);
  end;
  return query select 'trading on §8.1''s chart reconciles, and the costing policy names the chart''s own variance account'::text,
    v_ok, v_msg;

  set constraints all immediate;
  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(d.tenant_id);
  delete from erp.tenant where id = d.tenant_id;
  perform erp.end_tenant_purge();

  -- ── And one on the default chart, unchanged ────────────────────────────────
  select * into d2 from erp.provision_tenant('zzdefault', 'Demo Default Chart Suite', 'a@zzdefault.test', 'Default Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(d2.admin_token);
  update erp.environment set is_live = false where tenant_id = d2.tenant_id and is_self;

  v_cases := v_cases + 1;
  begin
    v_conf := erp.ensure_demo_configuration(d2.tenant_id, d2.admin_user_id);
    v_ok := (v_conf -> 'installed' ->> 0) = 'finance'
        and not exists (select 1 from erp.tenant_pack tp where tp.tenant_id = d2.tenant_id)
        and exists (select 1 from erp.account a where a.tenant_id = d2.tenant_id and a.code = '9100')
        and (select variance_account_code from erp.costing_policy cp
              where cp.tenant_id = d2.tenant_id order by cp.code limit 1) = '9100';
    v_msg := format('installed %s; %s', v_conf -> 'installed', erp.assert_inventory_sane());
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 200);
  end;
  set constraints all immediate;
  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(d2.tenant_id);
  delete from erp.tenant where id = d2.tenant_id;
  perform erp.end_tenant_purge();
  return query select 'an organisation on the default chart is untouched, and both suites leave nothing behind'::text,
    v_ok and not exists (select 1 from erp.tenant t where t.code in ('zzchart', 'zzdefault')),
    v_msg;

  if v_cases <> 4 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_chart_suite ran % cases, expected 4', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.demo_chart_suite() from public, anon, authenticated;

create or replace function erp_test.assert_demo_chart_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _demo_chart on commit drop as
    select * from erp_test.demo_chart_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _demo_chart;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMO_CHART_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'The demonstration no longer honours the chart the organisation chose.';
  end if;
  return format('demo chart: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_demo_chart_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Proved here
-- ═════════════════════════════════════════════════════════════════════════════

select erp_test.assert_demo_chart_suite();
select erp_test.assert_demo_history_suite();
select erp.assert_intelligence_boundary();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_diagnostics_registered();
