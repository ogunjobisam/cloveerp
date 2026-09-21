set lock_timeout = '30s';

-- EDITED IN PLACE ON 21 SEPTEMBER, AFTER CI PROVED HALF ITS DIAGNOSIS WRONG.
-- The first version of this file also replaced erp.demonstration_catch_up(),
-- adding a block that brought every outstanding module current ahead of the
-- trading loop, on the assumption that nothing else does. CI's own suite for
-- that change disproved the assumption before this ever reached main:
-- erp.seed_demo_history() already calls erp.ensure_demo_configuration()
-- itself, unconditionally, as the first thing it does on every call
-- (20260905010000), so the added block only ever found modules already
-- current and did nothing. The suite's own fixture then compounded the
-- confusion by deleting an inventory-operations posting rule that has
-- nothing to do with this migration while only rolling the installed version
-- back far enough that the planner correctly refused to replan it — a defect
-- in the fixture, not in any function this migration ships.
--
-- What is kept is the part CI proved: the planner fix below, and the suite
-- that isolates it (erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite),
-- which passed 5/5 in the same run that caught the other mistake. What is
-- lost is the erp.demonstration_catch_up() block and the end-to-end suite
-- that exercised it, both of which are re-applied correctly by
-- 20260921100000, this file's registered repair
-- (supabase/ci/migrations_edited.txt) — corrected to seed its baseline day
-- before rolling a module back rather than after, and to leave
-- inventory-operations alone. Nothing here reached main or any deployed
-- environment before this edit; it was caught on this branch's own CI run.
--
-- =============================================================================
-- 20260921090000  A demonstration updates its modules before it trades
-- -----------------------------------------------------------------------------
-- R0 was reported merged and it is not: the live deploy still refuses on the
-- first day the catch-up tries to build.
--
--   erp.catch_up_demonstrations() took 4.9 s
--   - demo-cbb10384: traded 2026-04-15 to 2026-09-20, 0 document(s); 0 supplier
--     bill(s); 0 month(s) closed, 0 left open
--   - demo-cbb10384: It traded as far as it could and then stopped. 2026-04-15
--     would not build: CLOVEERP_PROMOTION_BREAKS_DETERMINATION...
--
-- ── WHAT IS ACTUALLY WRONG ───────────────────────────────────────────────────
--
-- demo-cbb10384 was configured before 17 September, when sales-lifecycle's and
-- procurement-controls' customer and supplier credit notes shipped
-- (20260918170000). Because erp.seed_demo_history() already calls
-- erp.ensure_demo_configuration() on every invocation — before the "already
-- built" early return, before a single document of the day is touched — the
-- very first call the catch-up makes, erp.seed_demo_history(2026-04-15, null,
-- 1), already tries to bring every outstanding module current before it
-- builds anything, which includes promoting sales-lifecycle's upgrade. That
-- promotion is what fails, not anything about which weekday 2026-04-15
-- happens to be, and not anything missing from erp.demonstration_catch_up()
-- or erp.seed_demo_history(), both of which are already calling the right
-- things in the right order and are untouched by this migration.
--
-- erp.upgrade_module_configuration('sales-lifecycle') authors one change set
-- carrying the sales_credit_note posting rule and, from
-- erp_ref.module_upgrade_account, whatever account that version separately
-- says it needs — and nobody registered one, because every account the rule's
-- posting_lines name (revenue, tax_control, inventory, cost_of_sales,
-- trade_receivable) is a purpose the base finance-posting installer already
-- gives every organisation. That is true on the default chart. It is not
-- proved true in general, and this organisation is exactly the one the
-- product already knows is not general: 20260905020000 found that the live
-- demonstration has every feature switched on, statutory_chart_8_1 among
-- them, specifically because a chart pack's accounts are the pack's own list
-- and can fall behind a purpose a later posting rule starts asking for.
-- erp.plan_module_upgrade() has no way to notice that, because its account arm
-- reads only erp_ref.module_upgrade_account — a second list a module's author
-- must remember to keep in step with every posting rule the same upgrade
-- installs. When the two fall out of step, erp.upgrade_module_configuration()
-- promotes a posting rule this organisation cannot actually post, and
-- erp.promote_change_set()'s determination guard is right to refuse it:
-- CLOVEERP_PROMOTION_BREAKS_DETERMINATION is the guard doing its job on a real
-- gap, not a defect in the guard. The gap is that the planner under-counts
-- what an upgrade needs.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────────
--
-- erp.plan_module_upgrade() derives a required account from the posting rule
-- the SAME upgrade is about to install, in addition to (not instead of)
-- erp_ref.module_upgrade_account. A purpose is planned once whichever list
-- names it, so an upgrade whose author forgot to register the account a new
-- posting rule needs is still planned completely. This is a planner fix, not
-- a data patch for one pack: it closes the class of gap for every module
-- upgrade this product ever ships, on any chart, not the one credit note that
-- happened to expose it — and it runs the moment erp.seed_demo_history() makes
-- its own call to erp.ensure_demo_configuration(), for every demonstration
-- erp.catch_up_demonstrations() finds, not only this one.
--
-- Nothing here weakens erp.promote_change_set()'s determination guard. It
-- still refuses a promotion that genuinely leaves a posting unable to
-- determine an account; what changes is that the plan it is asked to promote
-- now actually contains everything the rule needs.
--
-- ── PROOF ─────────────────────────────────────────────────────────────────────
--
-- erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite() isolates
-- the planner: an organisation on a chart with every standard account except
-- the one a registered-but-unaccounted-for posting rule needs. Before this
-- fix erp.plan_module_upgrade() would not see the gap; after it, the plan
-- names the account, erp.upgrade_module_configuration() creates it in the
-- same change set, the promotion succeeds, and
-- erp.determination_coverage_report() carries no finding for the new rule.
-- The end-to-end proof against a fixture shaped like demo-cbb10384 — calling
-- erp.demonstration_catch_up() itself, the exact routine the deploy runs — is
-- erp_test.demonstration_module_catch_up_suite(), in 20260921100000.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The planner also reads what the posting rule itself needs
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.plan_module_upgrade(p_install_code text)
returns table (object_kind text, object_key text, payload jsonb, to_version integer, effect text, seq integer)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  inst     erp.module_installation%rowtype;
  mi       erp_ref.module_installer%rowtype;
begin
  select * into mi from erp_ref.module_installer m where m.install_code = p_install_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INSTALLER: % is not a module installer this product ships', p_install_code
      using errcode = '23503',
            hint = 'erp_module_installations() lists the installers and their versions.';
  end if;

  select * into inst from erp.module_installation i
   where i.tenant_id = v_tenant and i.install_code = p_install_code;
  if not found then
    raise exception 'CLOVEERP_MODULE_NOT_INSTALLED: this organisation has not installed %', p_install_code
      using errcode = '23503',
            hint = 'Install the module first from /administration/configuration; an upgrade only applies to a module the organisation has.';
  end if;

  return query
    -- Items a later version added that the organisation does not hold. A
    -- posting rule is present when a version of that code is in force; an
    -- account when the company has it; anything else by containment in the
    -- configuration manifest, as the pack planner decides.
    select ui.object_kind, ui.object_key, erp.resolve_account_purposes(ui.payload), ui.to_version,
           case when ui.object_kind = 'posting_rule' then 'a posting rule the organisation lacks'
                else 'configuration the organisation lacks' end,
           ui.seq
      from erp_ref.module_upgrade_item ui
     where ui.install_code = p_install_code
       and ui.to_version > inst.installer_version
       and not (
         case ui.object_kind
           when 'posting_rule' then exists (
             select 1 from erp.posting_rule r
              where r.tenant_id = v_tenant and r.code = ui.object_key and r.status = 'active')
           else coalesce((select m.content from erp.configuration_manifest(array[ui.object_kind]) m
                            where m.object_key = ui.object_key), '{}'::jsonb)
                @> erp.resolve_account_purposes(ui.payload)
         end)

    union all

    -- An account the same upgrade needs, from either of the two places that
    -- say so: a purpose somebody registered separately against this version
    -- (erp_ref.module_upgrade_account), and a purpose named only inside a
    -- posting rule this same upgrade is about to install
    -- (20260921090000). The second source exists because the first is a list
    -- a module's author must remember to keep in step with every posting
    -- rule's own payload; where the two fall out of step, the account this
    -- upgrade actually needs went unplanned, erp.upgrade_module_configuration()
    -- promoted a rule the organisation could not post, and
    -- erp.promote_change_set()'s determination guard refused the whole
    -- upgrade rather than guess at an account. Reading the requirement from
    -- the rule itself as well closes that gap for every future posting rule
    -- an upgrade installs, not only the one that first exposed it.
    select 'account', e.code || '|' || erp.chart_account_code(req.purpose),
           jsonb_build_object(
             'entity', e.code,
             'code', erp.chart_account_code(req.purpose),
             'name', cap.name,
             'account_type', cap.account_type::text,
             'is_postable', true,
             'currency', e.base_currency),
           req.to_version,
           format('an account the company %s lacks', e.code),
           10
      from (
        select ua.purpose, ua.to_version
          from erp_ref.module_upgrade_account ua
         where ua.install_code = p_install_code and ua.to_version > inst.installer_version
        union
        select l.value -> 'account' ->> 'purpose', ui.to_version
          from erp_ref.module_upgrade_item ui
          cross join lateral jsonb_array_elements(coalesce(ui.payload -> 'posting_lines', '[]'::jsonb)) l
         where ui.install_code = p_install_code
           and ui.object_kind = 'posting_rule'
           and ui.to_version > inst.installer_version
           and jsonb_typeof(l.value -> 'account') = 'object'
           and (l.value -> 'account' ->> 'purpose') is not null
      ) req(purpose, to_version)
      join erp_ref.chart_account_purpose cap on cap.purpose = req.purpose
      join erp.entity e on e.tenant_id = v_tenant and e.status = 'active'
     where not exists (
         select 1 from erp.account a
          where a.tenant_id = v_tenant and a.entity_id = e.id
            and a.code = erp.chart_account_code(req.purpose) and a.status = 'active')
     order by 6, 4, 1, 2;
end;
$$;

revoke all on function erp.plan_module_upgrade(text) from public, anon;

comment on function erp.plan_module_upgrade(text) is
  'What the current version of a module installer would add to this '
  'organisation and it does not hold: the posting rules and configuration a '
  'later version brought, and the accounts each company lacks — read from '
  'erp_ref.module_upgrade_account and from every posting rule the same '
  'upgrade installs (20260921090000), so an account nobody remembered to '
  'register separately is still planned. Empty when the organisation is '
  'current.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Proof — the planner finds an account a posting rule needs but nobody
--    registered separately
-- ═════════════════════════════════════════════════════════════════════════════
--
-- sales-lifecycle's credit note is used because it is the clean negative case:
-- its posting rule (sales_credit_note, version 2) names five accounts by
-- purpose in its own payload — revenue, tax_control, inventory, cost_of_sales,
-- trade_receivable — and erp_ref.module_upgrade_account registers NONE of
-- them, on the assumption that every organisation configured through
-- erp.configure_finance() already holds all five. Before this migration's fix,
-- erp.plan_module_upgrade() had no way to notice when that assumption did not
-- hold for one company; the credit note upgrade would promote and
-- erp.promote_change_set()'s determination guard would refuse it, correctly,
-- for a gap the planner never named. Deactivating the revenue account and
-- rolling the version back reproduces that gap without needing a chart pack.

create or replace function erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   constant uuid := '00000000-0000-4000-8000-00000000acc0';
  v_entity uuid;
  v_code   text;
  v_planned_before integer;
  v_planned_after  integer;
  v_upgraded jsonb;
  v_ok boolean; v_msg text; v_fixture text;
  v_findings integer;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-upgrade-accts', 'Upgrade accounts suite',
                              'admin@zz-upgrade-accts.test', 'Upgrade Accounts Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values (v_auth, 'admin@zz-upgrade-accts.test');
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  -- Read only after the organisation's context is in force: erp.chart_account_code()
  -- needs erp.require_tenant_id(), which is not resolvable before erp.claim_invitation().
  v_code := erp.chart_account_code('revenue');

  -- ── 1. Current, so there is nothing to plan ────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'a freshly configured organisation has nothing outstanding for sales-lifecycle';
  passed := not exists (select 1 from erp.plan_module_upgrade('sales-lifecycle'));
  detail := 'plan_module_upgrade(''sales-lifecycle'') is empty before anything is rolled back';
  return next;

  -- ── 2. Roll it back, and take away an account the credit note needs ───────
  -- erp_ref.module_upgrade_account carries nothing for sales-lifecycle at all
  -- — this reproduces exactly the case it cannot describe.
  v_cases := v_cases + 1;
  update erp.module_installation i set installer_version = 1
   where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle';
  delete from erp.posting_rule r where r.tenant_id = v_tenant and r.code = 'sales_credit_note';
  update erp.account a set status = 'inactive'
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_code;

  select count(*) into v_planned_before
    from erp.plan_module_upgrade('sales-lifecycle') p
   where p.object_kind = 'account' and p.object_key = (
     select e.code || '|' || v_code from erp.entity e where e.id = v_entity);
  case_name := 'with the posting rule gone and its revenue account inactive, the plan names the account the rule needs, from the rule''s own payload rather than a separate register';
  passed := v_planned_before = 1;
  detail := format('%s account item(s) planned for %s under sales-lifecycle, which registers no module_upgrade_account row at all',
                   v_planned_before, v_code);
  return next;

  -- ── 3. The upgrade promotes cleanly and creates it ─────────────────────────
  v_cases := v_cases + 1;
  begin
    v_upgraded := erp.upgrade_module_configuration('sales-lifecycle');
    v_ok := true; v_msg := 'promoted';
  exception when others then
    v_ok := false; v_msg := sqlerrm;
  end;
  case_name := 'the upgrade promotes without erp.promote_change_set() refusing, and the account exists again';
  passed := v_ok
        and (v_upgraded ->> 'promoted')::boolean
        and exists (select 1 from erp.account a
                     where a.tenant_id = v_tenant and a.entity_id = v_entity
                       and a.code = v_code and a.status = 'active')
        and exists (select 1 from erp.posting_rule r
                     where r.tenant_id = v_tenant and r.code = 'sales_credit_note' and r.status = 'active')
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 2;
  detail := v_msg;
  return next;

  -- ── 4. Nothing left outstanding, and no new determination finding ─────────
  v_cases := v_cases + 1;
  select count(*) into v_planned_after from erp.plan_module_upgrade('sales-lifecycle');
  select count(*) into v_findings
    from erp.determination_coverage_report(v_tenant) c
   where c.reference like '%sales_credit_note%';
  case_name := 'the plan is empty again and the posting rule the upgrade installed determines an account cleanly';
  passed := v_planned_after = 0 and v_findings = 0;
  detail := format('%s item(s) still planned, %s determination finding(s) naming sales_credit_note',
                   v_planned_after, v_findings);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-upgrade-accts')
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'zz-upgrade-accts rolled back with everything it did');
  return next;

  if v_cases <> 5 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: plan_module_upgrade_finds_posting_rule_accounts_suite ran % cases, expected 5%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite() from public, anon;

create or replace function erp_test.assert_plan_module_upgrade_finds_posting_rule_accounts_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _plan_upgrade_accts on commit drop as
    select * from erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _plan_upgrade_accts;
  drop table _plan_upgrade_accts;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PLAN_UPGRADE_ACCOUNTS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: plan_module_upgrade_finds_posting_rule_accounts_suite ran % cases, expected 5', v_all;
  end if;
  return format('a module upgrade plans the account its own posting rule needs even when nobody registered it separately: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_plan_module_upgrade_finds_posting_rule_accounts_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_plan_module_upgrade_finds_posting_rule_accounts_suite();

select erp.assert_whole_database_reconciles();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
