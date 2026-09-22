set lock_timeout = '30s';

-- =============================================================================
-- 20260921420000  A cycle declares what it costs in steps
-- -----------------------------------------------------------------------------
-- X1 of the simplification plan, and rule 8 of the flow doctrine: "Each cycle
-- declares the maximum number of user actions on its happy path, and an
-- assertion enforces it. Adding a step means changing the declared budget in
-- the same pull request, in the open, with a reason."
--
-- Nothing declared anything of the sort. The word budget appears in this
-- database only as money.
--
-- ── ONE THING THE PLAN SAYS THAT IS NOT TRUE OF THE TREE ─────────────────────
--
-- The plan's X1 reads: "The screens already show step counts per flow, and five
-- are missing while their siblings show one … Make the declared budgets the
-- single source those counts read from."
--
-- The number on a step of a process strip is not a step count. It is a backlog:
-- how many records are sitting AT that step right now, read live from the
-- step's own list. src/components/erp/process-flow.tsx says so where it counts:
-- "The count is what is waiting at the step, never its history." A declared
-- budget cannot be the source of a live backlog, and a check comparing the two
-- would be comparing a queue length against a target and calling any agreement
-- a pass.
--
-- The finding underneath it is real and is a different finding. Ten steps of
-- the eight strips keep no list of their own — not five — and so show a dash.
-- That they show a dash rather than nothing was already repaired: the strip
-- draws a badge on every step and a screen reader says "not counted here", so
-- "none" and "not counted" can already be told apart. What is left is that ten
-- steps have no list, which is a real gap and is counted below, per flow, so
-- the node that repairs it repairs a measured number.
--
-- ── WHAT IS DECLARED HERE, THEN ──────────────────────────────────────────────
--
-- A cycle's step count is the number of distinct verbs its strip offers: the
-- actionFn, the actionFns and the createFn of each of its steps. That is the
-- set of things a person presses to get from one end of the cycle to the other,
-- which is what rule 8 is counting, and it is a structured declaration in the
-- source rather than prose, so reading it couples nothing to wording.
--
-- Each cycle's budget starts at what it costs today. That is deliberate: this
-- node is the framework and not the repair, and a budget set to the plan's
-- target would fail the build for eight cycles on the day the framework lands,
-- which tells nobody anything they do not already know. What it buys from the
-- first build is the ratchet — a ninth verb on the purchase-to-pay strip now
-- fails until somebody raises the number in the open, which is the whole of
-- rule 8's "this is what stops the piling-on from recurring".
--
-- The later nodes — P5 six, S9 seven, M8 four, I8 one and three — lower these
-- numbers and delete the steps in the same change. A lowered budget in a diff
-- is the evidence that the work was done.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The declaration
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.flow_budget (
  -- The cycle's own name, given in src so a reworded title renames nothing.
  flow_code             text not null,
  name                  text not null,
  module_code           text not null references erp_ref.module(code),
  screen_path           text not null,
  -- Rule 8: the most user actions the happy path may cost.
  budget                integer not null check (budget >= 1),
  -- What the strip costs today, held to the source by supabase/ci/flow_steps.sh.
  decision_steps        integer not null check (decision_steps >= 1),
  stages                integer not null check (stages >= 1),
  -- Steps that keep no list of their own, so nothing can be counted at them.
  -- The measured half of the walkthrough's "five screens with no step badge".
  stages_without_a_list integer not null check (stages_without_a_list >= 0),
  rationale             text not null,
  primary key (flow_code),
  constraint flow_budget_within_budget check (decision_steps <= budget),
  constraint flow_budget_list_gap check (stages_without_a_list <= stages),
  constraint flow_budget_explains check (length(btrim(rationale)) >= 40)
);

comment on table erp_meta.flow_budget is
  'One row per cycle: how many user actions its happy path may cost, how many '
  'it costs today, and how many of its steps keep no list of their own. The '
  'single place a step budget is declared, so lowering one is visible in a '
  'diff. Not tenant data.';

comment on column erp_meta.flow_budget.budget is
  'Rule 8 of the flow doctrine. Adding a step means raising this in the same '
  'change, with a reason, where a reviewer will see it.';

comment on column erp_meta.flow_budget.decision_steps is
  'The distinct verbs the cycle''s strip offers today. Written here and held to '
  'the application source by the build, so neither can move without the other.';

select erp_meta.register_table('erp_meta', 'flow_budget', 'platform_internal',
  'Declared step budgets per cycle, and what each costs today. Not tenant data.');

insert into erp_meta.flow_budget
  (flow_code, name, module_code, screen_path, budget, decision_steps, stages, stages_without_a_list, rationale)
values
  ('p2p', 'Procure to pay', 'procurement', '/procurement', 14, 14, 8, 1,
   'Today''s cost, recorded so a fifteenth verb fails the build. The plan''s target is six, reached by deriving received, closed and ordered rather than clicking them.'),
  ('o2c', 'Order to cash', 'sales', '/sales', 5, 5, 6, 2,
   'Today''s cost of the strip, which is well short of what the cycle really costs: most of order to cash is reached from the document screen rather than the strip. The plan''s target is seven, and reaching it means the strip carrying the cycle.'),
  ('stock', 'Stock', 'inventory', '/inventory', 6, 6, 5, 2,
   'Today''s cost. The plan''s targets are one action per count task and three for a transfer, which is a different shape from the five steps drawn here.'),
  ('money', 'Money', 'finance', '/finance', 9, 9, 7, 2,
   'Today''s cost. Period close alone is sixteen to twenty-four actions a month and is not on this strip at all, so this number understates the cycle.'),
  ('plan', 'Plan', 'planning', '/planning', 4, 4, 5, 2,
   'Today''s cost. Two of its five steps keep no list, so a planner cannot see what is waiting at them.'),
  ('make', 'Making', 'production', '/production', 6, 6, 6, 0,
   'Today''s cost. The plan''s target is four, reached by folding release into firming and installing backflush as the default.'),
  ('quality', 'Quality', 'quality', '/quality', 5, 5, 5, 1,
   'Today''s cost. Raising an inspection has no door at all, so the strip is shorter than the work.'),
  ('despatch', 'Despatch', 'logistics', '/logistics', 4, 4, 4, 0,
   'Today''s cost. Logistics beyond two carriers is out of the simplification plan''s scope and this number is here to hold the line rather than to be lowered.')
on conflict (flow_code) do update set
  name = excluded.name, module_code = excluded.module_code,
  screen_path = excluded.screen_path, budget = excluded.budget,
  decision_steps = excluded.decision_steps, stages = excluded.stages,
  stages_without_a_list = excluded.stages_without_a_list,
  rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The report
-- ═════════════════════════════════════════════════════════════════════════════
--
-- p_drawn is what the build read out of the application source, one row per
-- cycle as 'code|verbs|steps|steps with no list'. Null means "read the register
-- back to itself", which is what the no-argument suite does and what makes the
-- register's own arithmetic checkable without the source in hand.

create or replace function erp.flow_step_budget_report(p_drawn text[] default null)
returns table (flow_code text, verdict text, budget integer, drawn integer, detail text)
language sql
stable
set search_path = ''
as $$
  with drawn as (
    select split_part(x, '|', 1)               as flow_code,
           nullif(split_part(x, '|', 2), '')::integer as verbs,
           nullif(split_part(x, '|', 3), '')::integer as steps,
           nullif(split_part(x, '|', 4), '')::integer as no_list
      from unnest(coalesce(p_drawn,
             (select coalesce(array_agg(format('%s|%s|%s|%s', b.flow_code, b.decision_steps,
                                               b.stages, b.stages_without_a_list)
                                        order by b.flow_code), '{}'::text[])
                from erp_meta.flow_budget b))) as x
  )
  select coalesce(d.flow_code, b.flow_code),
         case
           when b.flow_code is null then 'not_declared'
           when d.flow_code is null then 'not_drawn'
           when d.verbs > b.budget  then 'over_budget'
           when d.verbs is distinct from b.decision_steps
             or d.steps is distinct from b.stages
             or d.no_list is distinct from b.stages_without_a_list then 'drifted'
           else 'within'
         end,
         b.budget,
         d.verbs,
         case
           when b.flow_code is null then
             format('the screens draw a cycle called %L and nothing declares a budget for it', d.flow_code)
           when d.flow_code is null then
             format('%s is declared with a budget of %s and the screens draw no such cycle', b.name, b.budget)
           when d.verbs > b.budget then
             format('%s offers %s action(s) on a budget of %s', b.name, d.verbs, b.budget)
           when d.verbs is distinct from b.decision_steps
             or d.steps is distinct from b.stages
             or d.no_list is distinct from b.stages_without_a_list then
             format('%s is recorded at %s action(s) over %s step(s), %s keeping no list; the screens draw %s, %s and %s',
                    b.name, b.decision_steps, b.stages, b.stages_without_a_list,
                    coalesce(d.verbs::text, 'nothing'), coalesce(d.steps::text, 'nothing'),
                    coalesce(d.no_list::text, 'nothing'))
           else
             format('%s: %s action(s) of %s, %s step(s), %s keeping no list',
                    b.name, d.verbs, b.budget, d.steps, d.no_list)
         end
    from drawn d
    full join erp_meta.flow_budget b on b.flow_code = d.flow_code
   order by 1
$$;

revoke all on function erp.flow_step_budget_report(text[]) from public, anon, authenticated;

comment on function erp.flow_step_budget_report(text[]) is
  'Each cycle the screens draw against the budget declared for it: within, '
  'over_budget, drifted, not_declared or not_drawn. With no argument it reads '
  'the register back to itself, which is how the suite checks the arithmetic '
  'without the application source.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The assertion the build calls with what it read
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_flow_step_budgets(p_drawn text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n       integer := coalesce(cardinality(p_drawn), 0);
  v_bad     integer;
  v_within  integer;
  v_detail  text;
  v_actions integer;
  v_nolist  integer;
begin
  if v_n = 0 then
    raise exception 'CLOVEERP_SCREENS_DRAW_NO_CYCLE: the list of cycles the screens draw is empty'
      using errcode = '22023',
            hint = 'The build reads every process strip out of the application source and '
                   'hands the list to this. An empty list means the reading found nothing, '
                   'which is not a pass.';
  end if;

  select count(*) filter (where r.verdict <> 'within'),
         count(*) filter (where r.verdict = 'within'),
         string_agg(format('  %s — %s: %s', r.flow_code, r.verdict, r.detail), E'\n'
                    order by r.flow_code) filter (where r.verdict <> 'within')
    into v_bad, v_within, v_detail
    from erp.flow_step_budget_report(p_drawn) r;

  if v_bad > 0 then
    raise exception E'CLOVEERP_STEP_BUDGET_BROKEN: % cycle(s)\n%', v_bad, v_detail
      using errcode = 'P0001',
            detail = v_detail,
            hint = 'A cycle over its budget has gained a step; take the step out, or raise '
                   'the declared budget in a migration with the reason beside it. A cycle '
                   'that has drifted has changed on the screens without the declaration '
                   'moving with it, which is the same change left half done.';
  end if;

  select sum(b.decision_steps), sum(b.stages_without_a_list)
    into v_actions, v_nolist
    from erp_meta.flow_budget b;

  return format('step budgets: %s cycle(s) within budget, %s action(s) in all; %s step(s) keep no list of their own',
                v_within, v_actions, v_nolist);
end;
$$;

revoke all on function erp.assert_flow_step_budgets(text[]) from public, anon, authenticated;

comment on function erp.assert_flow_step_budgets(text[]) is
  'Refuses a cycle whose strip offers more actions than its declared budget, '
  'and a declaration that has drifted from the screens in either direction. '
  'The build reads the strips and calls this with what it found.';

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_flow_step_budgets', null,
   'Takes the cycles and their verbs as supabase/ci/flow_steps.sh reads them out of the application source; only the build can know what the screens draw, and it calls this with that list.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_flow_step_budgets',
   'Takes the list of cycles the application source declares. A console button has no such list; the build reads it and calls this.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The proof, which the build runs whether or not the source is to hand
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.step_budget_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 6;
  v_cases   integer := 0;
  v_n       integer;
  v_bad     integer;
  v_detail  text;
  v_verdict text;
  v_total   integer;
  v_nolist  integer;
begin
  -- ── 1. Something is declared, and each cycle belongs somewhere ────────────
  select count(*) into v_n from erp_meta.flow_budget;
  select count(*), string_agg(b.flow_code, ', ' order by b.flow_code)
    into v_bad, v_detail
    from erp_meta.flow_budget b
   where not exists (select 1 from erp_ref.module m where m.code = b.module_code);

  v_cases := v_cases + 1;
  case_name := 'every cycle that declares a step budget belongs to a part of the product that exists';
  passed := coalesce(v_n > 0 and v_bad = 0, false);
  detail := format('%s cycle(s) declared; %s naming nothing%s', v_n, v_bad,
                   coalesce(': ' || v_detail, ''));
  return next;

  -- ── 2. Nothing is over its budget ─────────────────────────────────────────
  select count(*), string_agg(format('%s: %s', r.flow_code, r.detail), '; ' order by r.flow_code)
    into v_bad, v_detail
    from erp.flow_step_budget_report() r
   where r.verdict <> 'within';

  v_cases := v_cases + 1;
  case_name := 'no cycle costs more user actions than the budget declared for it';
  passed := coalesce(v_bad = 0, false);
  detail := coalesce(v_detail, format('%s cycle(s), all inside their budgets',
                                      (select count(*) from erp_meta.flow_budget)));
  return next;

  -- ── 3. A budget is a number somebody meant ────────────────────────────────
  select count(*), string_agg(format('%s (budget %s, %s action(s), %s step(s))',
                                     b.flow_code, b.budget, b.decision_steps, b.stages),
                              '; ' order by b.flow_code)
    into v_bad, v_detail
    from erp_meta.flow_budget b
   where b.budget < 1 or b.decision_steps < 1 or b.stages < 1
      or length(btrim(b.rationale)) < 40;

  v_cases := v_cases + 1;
  case_name := 'every declared budget is at least one action, over at least one step, with a reason written beside it';
  passed := coalesce(v_bad = 0, false);
  detail := coalesce(v_detail, 'every cycle declares a budget, a cost and a reason');
  return next;

  -- ── 4. It refuses a cycle that has gained a step ──────────────────────────
  --
  -- Falsified rather than believed. The report is handed one cycle inflated
  -- past its budget and the verdict is read back: a check that cannot be made
  -- to fail is a check nobody can trust when it passes.
  select r.verdict into v_verdict
    from erp.flow_step_budget_report(array[
           (select format('%s|%s|%s|%s', b.flow_code, b.budget + 1, b.stages, b.stages_without_a_list)
              from erp_meta.flow_budget b order by b.flow_code limit 1)]) r
   where r.flow_code = (select b.flow_code from erp_meta.flow_budget b order by b.flow_code limit 1);

  v_cases := v_cases + 1;
  case_name := 'a cycle that has gained an action beyond its budget is refused, which is how anyone knows the check can fail at all';
  passed := coalesce(v_verdict = 'over_budget', false);
  detail := format('one more action than the budget allows reads as %L', coalesce(v_verdict, '(nothing)'));
  return next;

  -- ── 5. It refuses a cycle nobody declared ─────────────────────────────────
  select r.verdict into v_verdict
    from erp.flow_step_budget_report(array['zznosuchcycle|3|3|0']) r
   where r.flow_code = 'zznosuchcycle';

  v_cases := v_cases + 1;
  case_name := 'a cycle the screens draw and nobody declared a budget for is refused rather than ignored';
  passed := coalesce(v_verdict = 'not_declared', false);
  detail := format('a cycle no register names reads as %L', coalesce(v_verdict, '(nothing)'));
  return next;

  -- ── 6. The steps that count nothing are counted ───────────────────────────
  select sum(b.stages), sum(b.stages_without_a_list) into v_total, v_nolist
    from erp_meta.flow_budget b;

  v_cases := v_cases + 1;
  case_name := 'the steps that keep no list of their own are counted, so the repair has a number rather than a memory';
  passed := coalesce(v_nolist is not null and v_total is not null and v_nolist <= v_total, false);
  detail := format('%s of %s step(s) across %s cycle(s) keep no list, so nothing can be counted at them',
                   v_nolist, v_total, (select count(*) from erp_meta.flow_budget));
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_STEP_BUDGET_SUITE_SHRANK: % case(s), expected %', v_cases, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
end;
$suite$;

revoke all on function erp_test.step_budget_suite() from public, anon;

create or replace function erp_test.assert_step_budget_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _step_budget on commit drop as
    select * from erp_test.step_budget_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _step_budget;
  drop table _step_budget;
  if v_fail > 0 then
    raise exception E'CLOVEERP_STEP_BUDGET_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_STEP_BUDGET_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a cycle declares what it costs in steps: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_step_budget_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the proof
-- ═════════════════════════════════════════════════════════════════════════════

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
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();

-- Cheap: it reads one register of eight rows and the module list. No
-- organisation is built and no ledger is touched.
select erp_test.assert_step_budget_suite();
