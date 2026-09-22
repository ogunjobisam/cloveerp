set lock_timeout = '30s';

-- =============================================================================
-- 20260922260000  The ladder stops where the door stops
-- -----------------------------------------------------------------------------
-- W3 part three, which 20260922230000 held back with a question. The answer was
-- option (b): leave the door where it is and make the ladder agree with it. Not
-- option (a) — dunning levels do not become enforcing, because that would let a
-- customer trade at thirty-one days overdue who cannot trade today.
--
-- ── THE CONTRADICTION ────────────────────────────────────────────────────────
--
-- Two numbers say when a customer stops being sold to, and they ship three
-- times apart:
--
--   sales.credit_control.overdue_days_block is 30 in the base pack, and
--   erp.create_document() refuses a customer whose debt is older than that;
--
--   the standard dunning ladder puts its only blocks_trading level at 90.
--
-- So a customer forty days overdue is refused at the door while the chasing
-- worklist says "final demand, not blocking". The screen and the door tell the
-- salesperson two different things about the same customer, and the one the
-- screen tells them is the wrong one.
--
-- ── WHY IT COULD NOT JUST BE SET TO 30 ───────────────────────────────────────
--
-- erp.dunning_worklist() picks the level by
--
--   order by (l.value ->> 'after_days')::integer desc limit 1
--
-- so severity IS after_days. Moving stop from 90 to 30 would sort it below
-- final at 45: a debt of thirty-five days would select stop and read as
-- blocking, a debt of fifty days would select final and read as not. The
-- ladder inverts, which is worse than the disagreement it was meant to fix.
--
-- ── THE RULE ─────────────────────────────────────────────────────────────────
--
-- erp.dunning_ladder_aligned() puts the blocking level on the first day the
-- door refuses, and moves only what has to move to keep the ladder ascending:
--
--   a level already below the door keeps its day, because chasing at seven days
--   is a deliberate choice and not something to round off;
--
--   a level at or above the door is placed in the gap between the highest level
--   still below it and the door itself, evenly, in the order it was written.
--
-- The first day the door refuses is the window plus one, not the window, and
-- the difference is not pedantry. erp.credit_position() reads
--
--   si.due_date < current_date - overdue_days_block
--
-- which is debt OLDER than the window, so a customer exactly thirty days
-- overdue can still trade. A rung at thirty would have the worklist call that
-- customer stopped while the door let them through — the same contradiction
-- this node exists to remove, one day wide.
--
-- The shipped ladder of 7, 45 and 90 against a window of 30 becomes 7, 19 and
-- 31. The demonstration, whose window 20260922230000 opens to 180 so a year of
-- seeded trading is not blocked by its own history, becomes 7, 45 and 181 —
-- both of the earlier levels keep their meaning because both are already
-- below.
--
-- A window of nought is the one case the ladder cannot follow: an organisation
-- that refuses the instant anything is a day overdue has no ladder to climb
-- before it. The levels are then left exactly as they were written rather than
-- collapsed onto each other, because a ladder with every rung on the same day
-- makes erp.dunning_worklist() pick between them arbitrarily.
--
-- ── AND WHAT THIS DOES NOT DO ────────────────────────────────────────────────
--
-- It does not rewrite the ladder of an organisation that already has one. A
-- dunning ladder is a customer's chasing schedule, written by the people who
-- chase; changing every organisation's as a side effect of a deploy is the kind
-- of act that should be somebody's decision. An organisation configured from
-- here on gets an aligned ladder, the demonstration realigns itself, and one
-- that already carries a ladder realigns when it next configures receivables or
-- calls the routine.
--
-- Nor does it touch a ladder whose days the caller stated. erp.configure_
-- receivables(7, 45, 90) still produces 7, 45 and 90: the organisation said so.
-- Only the default — which is now the first day the door refuses, rather than a
-- number that agreed with nothing — is derived.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The rule, in one place
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.dunning_ladder_aligned(p_levels jsonb, p_block_days integer)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_out   jsonb := '[]'::jsonb;
  v_floor integer := -1;
  v_move  integer := 0;
  v_seen  integer := 0;
  lv      jsonb;
  v_day   integer;
  v_stop  integer;
begin
  if p_levels is null or jsonb_typeof(p_levels) <> 'array' or p_block_days is null then
    return p_levels;
  end if;

  -- The first day the door refuses, which is the window plus one: the door
  -- reads due_date < current_date - window, so debt exactly the window old
  -- still trades.
  v_stop := p_block_days + 1;

  -- The highest day a non-blocking level already sits on below the door, and
  -- how many have to be moved down to it.
  for lv in select value from jsonb_array_elements(p_levels) loop
    if coalesce((lv ->> 'blocks_trading')::boolean, false) then
      continue;
    end if;
    v_day := (lv ->> 'after_days')::integer;
    if v_day is null or v_day >= v_stop then
      v_move := v_move + 1;
    elsif v_day > v_floor then
      v_floor := v_day;
    end if;
  end loop;

  -- No room to put them: the organisation refuses on the first overdue day, or
  -- close enough to it that the rungs would land on each other. Left as written.
  if v_move > 0 and v_stop - v_floor - 1 < v_move then
    return p_levels;
  end if;

  for lv in select value from jsonb_array_elements(p_levels) loop
    if coalesce((lv ->> 'blocks_trading')::boolean, false) then
      v_out := v_out || jsonb_build_array(lv || jsonb_build_object('after_days', v_stop));
    else
      v_day := (lv ->> 'after_days')::integer;
      if v_day is null or v_day >= v_stop then
        v_seen := v_seen + 1;
        v_out := v_out || jsonb_build_array(lv || jsonb_build_object(
          'after_days',
          v_floor + round(v_seen::numeric * (v_stop - v_floor) / (v_move + 1))::integer));
      else
        v_out := v_out || jsonb_build_array(lv);
      end if;
    end if;
  end loop;

  return v_out;
end;
$$;

comment on function erp.dunning_ladder_aligned(jsonb, integer) is
  'A dunning ladder whose blocking level sits on the first day the credit '
  'policy refuses a customer — the overdue window plus one, because the door '
  'refuses debt older than the window — with only the levels that would sort '
  'above it moved down into the gap. The chasing schedule and the door then '
  'agree about every customer instead of disagreeing about some.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What an organisation's ladder is aligned by
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.align_dunning_to_credit_policy(
  p_policy_code text default null,
  p_entity_id   uuid default null,
  p_site_id     uuid default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_days   integer;
begin
  -- The policy is scoped, so the scope has to be asked for: the demonstration
  -- sets its window on its company, not on the organisation.
  v_days := (erp.config_value('sales.credit_control', null, null, p_entity_id, p_site_id)
               ->> 'overdue_days_block')::integer;

  if v_days is null then
    return null;
  end if;

  update erp.dunning_policy d
     set levels = erp.dunning_ladder_aligned(d.levels, v_days),
         updated_at = now()
   where d.tenant_id = v_tenant
     and d.status = 'active'
     and (p_policy_code is null or d.code = p_policy_code)
     and d.levels is distinct from erp.dunning_ladder_aligned(d.levels, v_days);

  return v_days;
end;
$$;

comment on function erp.align_dunning_to_credit_policy(text, uuid, uuid) is
  'Moves an organisation''s dunning ladder onto the day its credit policy stops '
  'a customer, so the chasing worklist and erp.create_document() stop '
  'disagreeing about who is blocked. Returns the day count, or nothing where '
  'the organisation has no credit policy.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The default a new organisation is configured with
-- ═════════════════════════════════════════════════════════════════════════════
--
-- p_stop_days becomes null meaning "the day the door stops them". A caller that
-- states a number still gets it.

create or replace function erp.configure_receivables(
  p_first_reminder_days integer default 7,
  p_final_days integer default 45,
  p_stop_days integer default null)
returns uuid
language plpgsql
set search_path = ''
as $function$
declare
  v_cs     uuid;
  v_window integer;
  v_levels jsonb;
begin
  -- The ladder as written, with the stop level on the day the caller named or,
  -- where they named none, on the ninety this shipped with.
  v_levels := jsonb_build_array(
    jsonb_build_object('code','reminder','after_days',p_first_reminder_days,
                       'action','statement and reminder','blocks_trading',false),
    jsonb_build_object('code','final','after_days',p_final_days,
                       'action','final demand','blocks_trading',false),
    jsonb_build_object('code','stop','after_days',coalesce(p_stop_days, 90),
                       'action','account stopped and passed to collection',
                       'blocks_trading',true));

  -- Where the caller named no day, the ladder follows the door instead
  -- (20260922260000). Where they named one, it is theirs and is left alone.
  if p_stop_days is null then
    v_window := (erp.config_value('sales.credit_control', null, null, null, null)
                   ->> 'overdue_days_block')::integer;
    if v_window is not null then
      v_levels := erp.dunning_ladder_aligned(v_levels, v_window);
    end if;
  end if;

  v_cs := erp.install_module_config(
    'receivables', 'Receivables',
    'When a customer is chased, how, and at what point they stop being sold to.',
    jsonb_build_array(
      -- Cash application is a posting, and B7 refuses a machine-generated
      -- journal line that cannot name the rule that produced it. That refusal
      -- is right: a line nobody can trace to a rule is a line nobody can
      -- explain. So the rule exists, and is promoted like every other.
      jsonb_build_object('kind','posting_rule','key','cash_application','payload',
        jsonb_build_object(
          'code','cash_application','name','Cash application','ledger','GL',
          'event_type','cash.applied',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('bank'),'side','debit','rate',1,
                               'description','Cash received'),
            jsonb_build_object('account', erp.chart_account_code('trade_receivable'),'side','credit','rate',1,
                               'description','Applied to the receivable')))),

      jsonb_build_object('kind','dunning_policy','key','standard','payload',
        jsonb_build_object(
          'code','standard','name','Standard dunning',
          'levels', v_levels))));

  return v_cs;
end;
$function$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. And the demonstration, which opens its own door to 180
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20260922230000 raises overdue_days_block to 180 so a year of seeded trading
-- is not blocked by its own history. That happens after receivables is
-- configured, so the ladder has to follow it afterwards.

do $demo$
declare
  v_sig constant text := 'erp.ensure_demo_configuration(uuid, uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'      set where a real business with these terms would set it.'');\n';
  v_new constant text :=
       E'      set where a real business with these terms would set it.'');\n'
    || E'\n'
    || E'  -- And the ladder follows the door (20260922260000). The window above is\n'
    || E'  -- six times the shipped one, so without this the worklist would call a\n'
    || E'  -- customer blocked at ninety days whom the door lets trade until a\n'
    || E'  -- hundred and eighty.\n'
    || E'  perform erp.align_dunning_to_credit_policy(null, v_entity, null);\n';
  v_hits integer;
begin
  if position('align_dunning_to_credit_policy' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_UNRECOGNISED: % already follows its own door', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_UNRECOGNISED: % sets the window that stops supply % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$demo$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The case that matters is the fourth: for every day count, the ladder and the
-- door give the same answer about the same customer. The three before it are
-- the shape that makes it possible, and the fifth is the one that stops this
-- becoming a rule that overrides the people who chase.

create or replace function erp_test.dunning_ladder_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hex     text := replace(gen_random_uuid()::text, '-', '');
  a1        uuid := gen_random_uuid();
  a2        uuid := gen_random_uuid();
  r         record;
  r2        record;
  v_cs      uuid;
  v_window  integer;
  v_levels  jsonb;
  v_stop    integer;
  v_first   integer;
  v_d       integer;
  v_agree   boolean := true;
  v_where   text;
  v_cases   integer := 0;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-dun-' || v_hex, 'Dunning ladder suite',
    'admin@zz-dun-' || v_hex || '.test', 'Dunning Ladder Admin');
  update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();
  perform erp_test.promote_if_pending(v_cs);

  -- No day count stated, which is how an organisation configures receivables
  -- unless it has an opinion.
  v_cs := erp.configure_receivables();
  perform erp_test.promote_if_pending(v_cs);

  v_window := (erp.config_value('sales.credit_control', null, null, null, null)
                 ->> 'overdue_days_block')::integer;
  select d.levels into v_levels
    from erp.dunning_policy d where d.tenant_id = r.tenant_id and d.code = 'standard';
  select (l.value ->> 'after_days')::integer into v_stop
    from jsonb_array_elements(v_levels) l
   where coalesce((l.value ->> 'blocks_trading')::boolean, false)
   order by (l.value ->> 'after_days')::integer limit 1;

  v_cases := v_cases + 1;
  case_name := 'an organisation that does not say when it stops chasing stops where its door refuses';
  passed := v_window is not null and v_stop = v_window + 1;
  detail := format('the window is %s, so the door refuses from %s, and the ladder stops at %s',
                   v_window, v_window + 1, v_stop);
  return next;

  -- ── 2. Still a ladder ─────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'and it is still a ladder, so the worklist''s most severe level means what it says';
  passed := not exists (
    select 1 from (
      select (l.value ->> 'after_days')::integer as d, l.ordinality as n
        from jsonb_array_elements(v_levels) with ordinality l
    ) x join (
      select (l.value ->> 'after_days')::integer as d, l.ordinality as n
        from jsonb_array_elements(v_levels) with ordinality l
    ) y on y.n = x.n + 1
     where y.d <= x.d);
  detail := format('the days in the order they are written: %s',
                   (select string_agg((l.value ->> 'after_days'), ', ' order by l.ordinality)
                      from jsonb_array_elements(v_levels) with ordinality l));
  return next;

  -- ── 3. What was already below is left alone ───────────────────────────────
  select (l.value ->> 'after_days')::integer into v_first
    from jsonb_array_elements(v_levels) l where l.value ->> 'code' = 'reminder';

  v_cases := v_cases + 1;
  case_name := 'a level already below the door keeps the day it was written on';
  passed := v_first = 7;
  detail := format('the first reminder is still day %s', v_first);
  return next;

  -- ── 4. The node ───────────────────────────────────────────────────────────
  -- For every day count either side of the window, what the chasing worklist
  -- would call the customer and what the door would do to them.
  for v_d in 0 .. v_window + 3 loop
    if coalesce((
      select coalesce((l.value ->> 'blocks_trading')::boolean, false)
        from jsonb_array_elements(v_levels) l
       where v_d >= (l.value ->> 'after_days')::integer
       order by (l.value ->> 'after_days')::integer desc
       limit 1), false) is distinct from (v_d > v_window)
    then
      v_agree := false;
      v_where := coalesce(v_where, v_d::text);
    end if;
  end loop;

  v_cases := v_cases + 1;
  case_name := 'and the ladder and the door agree about every customer, not most of them';
  passed := v_agree;
  detail := coalesce('they part company at ' || v_where || ' days overdue',
                     format('every day from 0 to %s reads the same both ways', v_window + 3));
  return next;

  -- ── 5. An organisation that has an opinion keeps it ───────────────────────
  -- A second organisation, because a module is installed once: configuring
  -- receivables twice in one collides on the change set that installs it.
  select * into r2 from erp.provision_tenant(
    'zz-dun2-' || v_hex, 'Dunning ladder suite, stated',
    'admin@zz-dun2-' || v_hex || '.test', 'Dunning Ladder Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(r2.admin_token);
  v_cs := erp.configure_finance();
  perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_receivables(7, 45, 90);
  perform erp_test.promote_if_pending(v_cs);
  select (l.value ->> 'after_days')::integer into v_stop
    from erp.dunning_policy d, jsonb_array_elements(d.levels) l
   where d.tenant_id = r2.tenant_id and d.code = 'standard'
     and coalesce((l.value ->> 'blocks_trading')::boolean, false);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_cases := v_cases + 1;
  case_name := 'but one that states its own day is left with it';
  passed := v_stop = 90;
  detail := format('it asked to stop at 90 and stops at %s', v_stop);
  return next;

  -- ── 6. And the ladder follows the door when the door moves ────────────────
  perform erp.set_config_value('sales.credit_control',
    jsonb_build_object('check_at_capture', true, 'block_at_limit', true,
                       'tolerance_pct', 5, 'overdue_days_block', 180),
    null, null, null, null, 'dunning ladder suite: a longer rope');
  perform erp.align_dunning_to_credit_policy();

  select d.levels into v_levels
    from erp.dunning_policy d where d.tenant_id = r.tenant_id and d.code = 'standard';

  -- Only the rung that has to move moves. The ladder is 7, 19 and 31 by now,
  -- and opening the door to 180 lifts the stop to 181 and leaves the two
  -- chasing days where the organisation has them: a longer rope to stop
  -- somebody on is not a reason to stop writing to them.
  v_cases := v_cases + 1;
  case_name := 'and when the door moves the ladder follows it, moving only the rung that has to';
  passed := (select (l.value ->> 'after_days')::integer from jsonb_array_elements(v_levels) l
              where l.value ->> 'code' = 'stop') = 181
        and (select (l.value ->> 'after_days')::integer from jsonb_array_elements(v_levels) l
              where l.value ->> 'code' = 'reminder') = 7
        and (select (l.value ->> 'after_days')::integer from jsonb_array_elements(v_levels) l
              where l.value ->> 'code' = 'final') = 19;
  detail := format('the ladder is now %s',
                   (select string_agg((l.value ->> 'after_days'), ', ' order by l.ordinality)
                      from jsonb_array_elements(v_levels) with ordinality l));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 7. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code in ('zz-dun-' || v_hex, 'zz-dun2-' || v_hex))
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its chasing schedule');
  return next;

  if v_cases <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: dunning_ladder_suite ran % cases, expected 7 — %',
      v_cases, coalesce(v_fixture, 'no case was skipped');
  end if;
end;
$$;

comment on function erp_test.dunning_ladder_suite() is
  'The chasing ladder and the credit door carry one number: for every day a '
  'customer is overdue, the worklist and erp.create_document() say the same '
  'thing about them.';

create or replace function erp_test.assert_dunning_ladder_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.dunning_ladder_suite() s;

  if v_total <> 7 then
    raise exception 'CLOVEERP_DUNNING_LADDER_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_DUNNING_LADDER_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A screen that calls a customer stopped while the door lets them trade is the defect this suite exists for.';
  end if;
end;
$$;

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
