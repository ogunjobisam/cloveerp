set lock_timeout = '30s';

-- =============================================================================
-- 20260921430000  Every state is arrived at, and left
-- -----------------------------------------------------------------------------
-- X2 of the simplification plan: "Fails when a seeded state has no transition
-- reaching it, or a seeded transition has no caller anywhere in the tree. This
-- is the assertion that would have caught nine entries in the dead
-- configuration register."
--
-- ── HALF OF IT IS ALREADY HERE, AND SAYING SO MATTERS ────────────────────────
--
-- 20260919990000 landed erp.assert_every_transition_is_driven() two days before
-- the plan was written. It holds every declared transition to
-- erp.transition_driver_register(): a transition nothing is registered to fire,
-- a registered driver that does not exist, a registered driver whose body
-- performs no transition, a register row the lifecycles no longer declare, an
-- allowance with no reason. That is the plan's second half — "a seeded
-- transition has no caller" — done, blocking, and green.
--
-- Writing it again here would be a check that passes while proving nothing,
-- which is the specific failure this repository has built a register against
-- eight times. So this file does not write it again.
--
-- ── WHAT IS ACTUALLY MISSING ─────────────────────────────────────────────────
--
-- States. The existing report walks forward from the initial state and its
-- clause 7 catches a TRANSITION whose from-state nothing reaches. A state with
-- no outgoing transition at all — the closed and cancelled ends of a lifecycle,
-- which is where dead configuration collects — has no transition to be caught
-- by, so nothing looks at it. An ending nothing arrives at is exactly the shape
-- of the clicked close the plan is written to delete.
--
-- The backward walk is missing too. erp.validate_state_machine_version() has
-- both walks and has had since 0013, but it takes a version id, so
-- erp.ci_check_catalogue() cannot see it and only erp.activate_state_machine_
-- version() ever calls it — which means it has never once run over the
-- configuration an installer seeds, because an installer promotes a change set
-- rather than activating a version by hand.
--
-- Three findings, then, over every active document lifecycle:
--
--   1. a state no sequence of driven moves arrives at
--   2. a state a document could reach and never leave
--   3. a lifecycle with no ending at all
--
-- "Driven" means the register's own word: a move a screen draws or a routine
-- performs. A state reachable only by a transition nothing fires is not
-- reachable, and counting it as reachable is how nine dead states stayed in the
-- configuration while a check looked straight at them.
--
-- ── ADVISORY, AND NOT VACUOUS ────────────────────────────────────────────────
--
-- This is expected to find things today; the plan says so and says to land it
-- reporting rather than blocking, and to make it blocking in PR9 once the
-- reseeds have landed. It reads its switch through erp.enforcement_verdict()
-- and 20260921400000 says what that costs and does not cost. Two things are
-- true of it from the first build:
--
--   * it refuses MORE findings than it landed with, so today's debt is
--     tolerated and tomorrow's is not;
--   * it refuses outright if there is no lifecycle to walk, because a walk over
--     nothing is the one way a reachability check can be green and worthless.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The walk
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.reachable_configuration_report(p_register jsonb default null)
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive reg as (
    select r.machine_code, r.transition_code, r.driver
      from jsonb_to_recordset(coalesce(p_register, erp.transition_driver_register()))
             as r(machine_code text, transition_code text, driver text, detail text)
  ),
  machines as (
    select m.tenant_id, m.code as machine_code, v.id as version_id
      from erp.state_machine m
      join erp.state_machine_version v
        on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
     where m.object_type = 'document'
       and m.status = 'active'
       and v.status = 'active'
  ),
  states as (
    select mc.machine_code, mc.version_id, s.code, s.is_initial, s.is_terminal
      from machines mc
      join erp.state s
        on s.tenant_id = mc.tenant_id and s.state_machine_version_id = mc.version_id
  ),
  -- Only the moves something fires. A state reachable solely by a transition
  -- nothing drives is not reachable, whatever the configuration says.
  live as (
    select distinct mc.version_id, mc.machine_code,
           fs.code as from_state, ts.code as to_state
      from machines mc
      join erp.transition t
        on t.tenant_id = mc.tenant_id and t.state_machine_version_id = mc.version_id
      join erp.state fs on fs.tenant_id = t.tenant_id and fs.id = t.from_state_id
      join erp.state ts on ts.tenant_id = t.tenant_id and ts.id = t.to_state_id
      join reg r on r.machine_code = mc.machine_code and r.transition_code = t.code
     where r.driver in ('screen', 'routine')
  ),
  reach (version_id, state_code) as (
    select distinct st.version_id, st.code from states st where st.is_initial
    union
    select l.version_id, l.to_state
      from reach rr
      join live l on l.version_id = rr.version_id and l.from_state = rr.state_code
  ),
  finishes (version_id, state_code) as (
    select distinct st.version_id, st.code from states st where st.is_terminal
    union
    select l.version_id, l.from_state
      from finishes ff
      join live l on l.version_id = ff.version_id and l.to_state = ff.state_code
  )
  -- 1. A state nothing arrives at.
  select 'a state no sequence of moves arrives at',
         min(format('%s.%s', st.machine_code, st.code)),
         'Nothing a person can press and nothing a routine performs puts a '
         'document here, so this state is configuration that cannot happen. '
         'Whatever was supposed to put a document in it is the thing that is '
         'missing, or the state is one to delete.'
    from states st
   where not st.is_initial
     and not exists (select 1 from reach rr
                      where rr.version_id = st.version_id and rr.state_code = st.code)
   group by st.machine_code, st.code

  union all
  -- 2. A state a document could reach and never leave.
  select 'a state a document can reach and never leave',
         min(format('%s.%s', st.machine_code, st.code)),
         'A document can arrive here and no sequence of moves anything drives '
         'reaches an ending from it, so whatever arrives stops for good. A '
         'recount, a release or a cancellation is missing.'
    from states st
   where not st.is_terminal
     and exists (select 1 from reach rr
                  where rr.version_id = st.version_id and rr.state_code = st.code)
     and not exists (select 1 from finishes ff
                      where ff.version_id = st.version_id and ff.state_code = st.code)
   group by st.machine_code, st.code

  union all
  -- 3. A lifecycle that cannot end.
  select 'a lifecycle with no ending',
         st.machine_code,
         'None of its states is marked as an ending, so nothing on this '
         'lifecycle is ever finished and every report of open work counts it '
         'for ever.'
    from states st
   group by st.machine_code
  having not bool_or(st.is_terminal)
$$;

revoke all on function erp.reachable_configuration_report(jsonb) from public, anon, authenticated;

comment on function erp.reachable_configuration_report(jsonb) is
  'Every state of every active document lifecycle that no sequence of driven '
  'moves arrives at, every state a document could reach and never leave, and '
  'every lifecycle with no ending. p_register overrides the driver register, so '
  'the walk can be falsified against one that fires nothing.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The check
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.assert_reachable_configuration()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_lifecycles integer;
  v_states     integer;
  v_found      integer;
  v_detail     text;
  v_blind      integer;
begin
  select count(distinct m.code),
         count(distinct (m.code, s.code))
    into v_lifecycles, v_states
    from erp.state_machine m
    join erp.state_machine_version v
      on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
    join erp.state s
      on s.tenant_id = v.tenant_id and s.state_machine_version_id = v.id
   where m.object_type = 'document' and m.status = 'active';

  -- A walk over nothing is the one way this can be green and worthless, so it
  -- refuses whatever the switch says. Being advisory is about tolerating
  -- findings, never about tolerating having looked at nothing.
  if coalesce(v_lifecycles, 0) = 0 then
    raise exception 'CLOVEERP_NO_LIFECYCLE_TO_WALK: there is no active document lifecycle, so every state in the product is trivially reachable'
      using errcode = 'P0001',
            hint = 'This check walks the lifecycles an installer seeds. Finding none '
                   'means the walk is looking in the wrong place or the seed did not '
                   'run, not that the configuration is sound.';
  end if;

  -- Falsified before it is believed. Handed a register that fires nothing, the
  -- walk must find more than it finds against the real one; if it does not, it
  -- is not reading the register and its silence means nothing.
  select count(*) into v_blind
    from erp.reachable_configuration_report(
      (select coalesce(jsonb_agg(jsonb_build_object(
                'machine_code', r.machine_code, 'transition_code', r.transition_code,
                'driver', 'undriven', 'detail', 'a register that fires nothing')),
              '[]'::jsonb)
         from jsonb_to_recordset(erp.transition_driver_register())
                as r(machine_code text, transition_code text, driver text, detail text)));

  select count(*), string_agg(format('  %s — %s: %s', r.finding, r.reference, r.detail),
                              E'\n' order by r.reference, r.finding)
    into v_found, v_detail
    from erp.reachable_configuration_report() r;

  if coalesce(v_blind, 0) <= coalesce(v_found, 0) then
    raise exception 'CLOVEERP_REACHABILITY_WALK_IS_BLIND: with every move switched off the walk finds % state(s), no more than the % it finds normally',
      v_blind, v_found
      using errcode = 'P0001',
            hint = 'The walk is not reading which moves anything actually fires, so a '
                   'state reachable only by a move nobody performs is being counted as '
                   'reachable. That is the defect this check exists to find.';
  end if;

  return format('%s; %s state(s) across %s document lifecycle(s) walked',
                erp.enforcement_verdict('reachable_configuration', v_found, v_detail),
                v_states, v_lifecycles);
end;
$$;

revoke all on function erp_test.assert_reachable_configuration() from public, anon;

comment on function erp_test.assert_reachable_configuration() is
  'Every seeded state is arrived at by some sequence of moves something '
  'actually fires, and every state a document can reach has a way out to an '
  'ending. Reports its findings while its switch is off and refuses any beyond '
  'the number it landed with; erp_meta.enforcement_gate says which.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The switch, and the number it landed with
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The number is read from the check on the build that lands it rather than
-- typed, because there is no local database to type it from and a figure got
-- wrong here is a figure somebody would widen rather than explain. It is
-- written once: a later replay leaves it where it is.

do $record$
declare
  v_found      integer;
  v_lifecycles integer;
begin
  select count(distinct m.code) into v_lifecycles
    from erp.state_machine m
   where m.object_type = 'document' and m.status = 'active';

  if coalesce(v_lifecycles, 0) = 0 then
    raise exception 'CLOVEERP_NO_LIFECYCLE_TO_WALK: nothing to record a tolerance against'
      using errcode = 'P0001',
            hint = 'A tolerance recorded over no lifecycles would tolerate everything '
                   'the first time one appeared. Land this after the installers.';
  end if;

  select count(*) into v_found from erp.reachable_configuration_report();

  insert into erp_meta.enforcement_gate
    (gate, is_blocking, tolerated_findings, landed_in, rationale)
  values
    ('reachable_configuration', false, v_found, '20260921430000',
     'Landed reporting rather than blocking, as the simplification plan asks, because the states it '
     'finds are the ones the correctness and reseed nodes exist to delete. Anything beyond this '
     'number still refuses. Switch it to blocking in the dead-configuration pull request, once those '
     'nodes have landed and the number is nought.')
  on conflict (gate) do nothing;

  raise notice 'CLOVEERP_TOLERANCE_RECORDED: reachable_configuration tolerates % finding(s) over % document lifecycle(s)',
    (select g.tolerated_findings from erp_meta.enforcement_gate g where g.gate = 'reachable_configuration'),
    v_lifecycles;
end
$record$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the proof
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
select erp.assert_enforcement_gates_are_read();

-- Cheap: it reads the lifecycle configuration and the driver register. No
-- organisation is built and no ledger is touched.
select erp_test.assert_reachable_configuration();
