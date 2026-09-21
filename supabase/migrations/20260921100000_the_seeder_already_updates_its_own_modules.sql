set lock_timeout = '30s';

-- =============================================================================
-- 20260921100000  The seeder already updates its own modules
-- -----------------------------------------------------------------------------
-- The repair 20260921090000 is registered against (supabase/ci/migrations_edited.txt).
--
-- The first version of 20260921090000 also replaced erp.demonstration_catch_up(),
-- adding a block that brought every outstanding module current ahead of the
-- trading loop, on the assumption that nothing else does. That assumption is
-- false: erp.seed_demo_history() already calls erp.ensure_demo_configuration()
-- itself, unconditionally, as the very first thing it does on every call —
--
--   -- Whatever the organisation is missing, once.
--   perform erp.ensure_demo_configuration(v_tenant, v_actor);
--
-- (20260905010000), before the "already built" early return and before a
-- single document of the day is touched. erp.demonstration_catch_up() calling
-- erp.seed_demo_history() was already enough to bring every module current;
-- the added block only ran the same upgrades a moment earlier and then found
-- nothing left to do.
--
-- CI's own suite for the added block caught this before it reached main.
-- erp_test.demonstration_module_catch_up_suite() rolled a fixture back to an
-- old module version, then called erp.seed_demo_history() to build one day of
-- baseline history for the catch-up to carry on from — and that single call
-- silently undid the rollback via its own internal
-- erp.ensure_demo_configuration(), before the suite's rollback for the actual
-- test case had even run. The report that came back —
-- 'modules upgraded []; ... CLOVEERP_NO_POSTING_RULE_IN_FORCE: no posting rule
-- for stock.adjusted is in force' — was two things at once: the added block
-- correctly finding nothing left to do, and a second, independent mistake in
-- the same fixture, which deleted the inventory-operations posting rule
-- erp.post_movement_finance() has used since version 2 while only rolling the
-- installed version back to 3 — a version erp.plan_module_upgrade() correctly
-- does not replan, because nothing above version 2 asks for it. Both mistakes
-- were in the fixture, not in erp.plan_module_upgrade() or in anything the
-- product runs live, which is exactly why the isolated planner suite in the
-- same migration passed cleanly in the same CI run: it never depended on
-- erp.seed_demo_history()'s own behaviour and never touched a posting rule
-- from a version it was not rolling back to.
--
-- 20260921090000 has been edited in place to drop the unnecessary block and
-- the fixture that exercised it — erp.demonstration_catch_up() needed no
-- change and is not touched by either migration. What is left to supply is
-- the end-to-end proof the task actually asked for: that
-- erp.demonstration_catch_up() — unmodified, exactly as the deploy calls it —
-- now trades a demonstration forward past the point that used to refuse, on a
-- fixture shaped like demo-cbb10384's actual gap.
--
-- ── THE PROOF ─────────────────────────────────────────────────────────────────
--
-- erp_test.demonstration_module_catch_up_suite(): one Monday of ordinary
-- trading while the organisation is still fully current, so there are
-- invoiced, despatched lines a credit note can reach. Then sales-lifecycle
-- alone is rolled back to before the credit note existed (deleting the
-- version-2 posting rule is correct here, unlike the first version's
-- inventory-operations mistake, because sales_credit_note has never existed
-- at any earlier version to fall back to) and the revenue account it needs is
-- made inactive. erp.demonstration_catch_up() is then called exactly as the
-- deploy calls it. It carries on from the Monday, and because
-- erp.seed_demo_history() already calls erp.ensure_demo_configuration() on
-- its own, the very next call upgrades sales-lifecycle before building
-- anything else — which is where the promotion 20260921090000's planner fix
-- repairs actually happens, mid-trade, with no code in this suite calling
-- erp.upgrade_module_configuration() directly. Held to: no day refuses,
-- sales-lifecycle reaches its current version, a customer credit note is
-- actually issued once the span crosses a Friday, and the five reconciliation
-- ties still hold afterward. Pinned at both ends, undone by
-- CLOVEERP_SUITE_UNDO.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Proof — a demonstration shaped like demo-cbb10384 catches up
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.demonstration_module_catch_up_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   constant uuid := '00000000-0000-4000-8000-00000000dccb';
  v_entity uuid;
  v_revenue text;
  -- The Monday of three weeks ago. date_trunc('week', …) is ISO: it lands on
  -- a Monday, and the span from the Tuesday after it to today holds at least
  -- two Fridays, so a customer credit note has more than one chance to find
  -- something to reach.
  v_from   date;
  v_report jsonb;
  v_stopped_notes text;
  v_ccn    integer;
  v_ok boolean; v_msg text; v_fixture text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('demo-zzmodup', 'Module catch-up suite',
                              'admin@demo-zzmodup.test', 'Module Catch-up Admin') t;
  insert into auth.users (id, email) values (v_auth, 'admin@demo-zzmodup.test');
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  -- Read only after the organisation's context is in force: erp.chart_account_code()
  -- needs erp.require_tenant_id(), which is not resolvable before erp.claim_invitation().
  v_revenue := erp.chart_account_code('revenue');
  v_from := date_trunc('week', (current_date - 20)::timestamp)::date;

  -- Built while sales-lifecycle is still current, so this is ordinary trading
  -- for the rollback below to act on — a Monday, not exercising the credit
  -- note itself, which is Friday's block.
  perform erp.seed_demo_history(v_from, v_from, 1);
  set constraints all immediate;

  -- ── 1. An organisation that already trades, rolled back to before the
  --      credit note existed ─────────────────────────────────────────────────
  v_cases := v_cases + 1;
  update erp.module_installation i set installer_version = 1
   where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle';
  delete from erp.posting_rule r where r.tenant_id = v_tenant and r.code = 'sales_credit_note';
  update erp.account a set status = 'inactive'
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_revenue;

  case_name := 'the organisation already trades, and is rolled back to before the credit note existed with one account it needs gone';
  passed := (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 1
        and not exists (select 1 from erp.posting_rule r
                         where r.tenant_id = v_tenant and r.code = 'sales_credit_note' and r.status = 'active')
        and not exists (select 1 from erp.account a
                         where a.tenant_id = v_tenant and a.entity_id = v_entity
                           and a.code = v_revenue and a.status = 'active')
        and exists (select 1 from erp.document d
                     where d.tenant_id = v_tenant and d.their_reference like 'DEMO-%')
        and exists (select 1 from erp.plan_module_upgrade('sales-lifecycle'));
  detail := format('sales-lifecycle at version 1, sales_credit_note posting rule absent, revenue account inactive, history built from %s (a Monday), %s item(s) now planned for sales-lifecycle',
                   v_from, (select count(*) from erp.plan_module_upgrade('sales-lifecycle')));
  return next;

  -- ── 2. The catch-up trades forward, and the module heals itself mid-trade
  --      through erp.seed_demo_history()'s own call to
  --      erp.ensure_demo_configuration() ─────────────────────────────────────
  v_report := erp.demonstration_catch_up();
  v_stopped_notes := (select string_agg(n, ' | ') from jsonb_array_elements_text(v_report -> 'notes') n
                        where n ilike '%would not build%' or n ilike '%refused%');

  v_cases := v_cases + 1;
  case_name := 'no day refuses, sales-lifecycle reaches its current version on its own, and the catch-up trades all the way to today';
  passed := v_stopped_notes is null
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 2
        and (v_report ->> 'traded_to')::date = current_date
        and exists (select 1 from erp.account a
                     where a.tenant_id = v_tenant and a.entity_id = v_entity
                       and a.code = v_revenue and a.status = 'active')
        and exists (select 1 from erp.posting_rule r
                     where r.tenant_id = v_tenant and r.code = 'sales_credit_note' and r.status = 'active');
  detail := format('sales-lifecycle now at version %s; traded to %s, %s document(s); notes %s',
                   (select i.installer_version from erp.module_installation i
                     where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle'),
                   v_report ->> 'traded_to', v_report ->> 'documents_built',
                   coalesce(v_stopped_notes, '(none)'));
  return next;

  -- ── 3. The mechanism the gap was blocking actually ran ─────────────────────
  select count(*) into v_ccn from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'sales_credit_note' and d.their_reference like 'DEMO-%';

  v_cases := v_cases + 1;
  case_name := 'the span crossed at least one Friday, and a customer credit note was issued through the rule the upgrade restored';
  passed := v_ccn > 0;
  detail := format('%s customer credit note(s) issued since the rollback', v_ccn);
  return next;

  -- ── 4. And the books still tie ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_inventory_reconciles()
             || '; ' || erp.assert_subledger_reconciles()
             || '; ' || erp.assert_ageing_equals_control()
             || '; ' || erp.assert_trial_balance_balances();
    v_ok := true;
  exception when others then
    v_ok := false;
    v_msg := left(sqlerrm, 300);
  end;
  case_name := 'after the upgrade and the trading, stock, inventory, the subledgers, the ageing and the trial balance all still agree';
  passed := v_ok;
  detail := v_msg;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'demo-zzmodup')
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'demo-zzmodup rolled back with its trading and its upgrade');
  return next;

  if v_cases <> 5 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_module_catch_up_suite ran % cases, expected 5%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_module_catch_up_suite() from public, anon;

create or replace function erp_test.assert_demonstration_module_catch_up_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_module_catch_up on commit drop as
    select * from erp_test.demonstration_module_catch_up_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_module_catch_up;
  drop table _demo_module_catch_up;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMONSTRATION_MODULE_CATCH_UP_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demonstration_module_catch_up_suite ran % cases, expected 5', v_all;
  end if;
  return format('a demonstration configured before a module''s later version ships still catches up: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demonstration_module_catch_up_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_demonstration_module_catch_up_suite();

select erp.assert_whole_database_reconciles();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
