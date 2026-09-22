set lock_timeout = '30s';

-- =============================================================================
-- 20260921450000  The tolerances are re-applied as written down
-- -----------------------------------------------------------------------------
-- The repair named in supabase/ci/migrations_edited.txt for three files landed
-- earlier in this pull request: 20260921400000, 20260921430000 and
-- 20260921440000.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- 20260921430000 ended by measuring how many findings its own walk had, so the
-- tolerance would be recorded from the build that landed it rather than typed
-- by somebody with no database to type it from. The build refused it, and was
-- right to.
--
-- A lifecycle is tenant data. An installer seeds it when an organisation is
-- provisioned, and a replay from an empty database provisions none: the
-- demonstration migrations are no-ops away from the live project, and every
-- suite builds its organisation inside a transaction it rolls back. At the
-- moment that file ran there were no active document lifecycles at all. A
-- tolerance measured there would have been measured over nothing, and would
-- have tolerated everything the first time a lifecycle appeared. The check's
-- own refusal for exactly that case is what caught it.
--
-- Measuring on the first RUN instead was the other temptation and is worse than
-- it looks: the build replays from empty for most pull requests, so a number
-- recorded on first run is recorded afresh every time and the ratchet never
-- bites. A line that moves with whatever it is measuring is not a line.
--
-- So both tolerances are literals written into the migrations that land them,
-- the reachability walk is left to erp.ci_check_catalogue() — which runs it
-- after the demonstration is seeded, the first moment in a build at which its
-- question has an answer — and the constraint tying a blocking gate to a nought
-- tolerance is gone, so switching one on stays one statement.
--
-- ── WHY THIS FILE EXISTS AT ALL ──────────────────────────────────────────────
--
-- Those three files were edited, and a migration is written once. An edit is
-- invisible to a build that starts from an empty database and reaches no
-- environment that has already applied the file, so the repair is always a new
-- migration re-applying the definition. Everything below is idempotent and is a
-- no-op on a database that replayed the edited files.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A blocking gate is one column, and nothing has to move with it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The constraint read `not is_blocking or tolerated_findings = 0`. It sounds
-- tidy and it costs the thing the switch is for: flipping a gate to blocking
-- while it still carried a tolerance would have been refused, so the later pull
-- request would have had to write two statements and remember the second. The
-- verdict already ignores the tolerance once a gate is blocking.

alter table erp_meta.enforcement_gate
  drop constraint if exists enforcement_gate_blocking_tolerates_nothing;

comment on column erp_meta.enforcement_gate.is_blocking is
  'The switch. False: findings up to the tolerance are reported and the build '
  'goes on. True: any finding stops the build, and the tolerance below is not '
  'consulted at all. Flipping it is one update statement in a migration, which '
  'is the whole point of it being one column — nothing else has to be changed '
  'with it, so the pull request that flips it is the repairs and one line.';

comment on column erp_meta.enforcement_gate.tolerated_findings is
  'What the check found on the build that landed it, written into the '
  'migration that landed it so that a replay from an empty database lands the '
  'same line rather than measuring a new one. Below it the check reports how '
  'far ahead it is; above it the check refuses even while advisory, so '
  'today''s debt is tolerated and tomorrow''s is not. Ignored once the gate is '
  'blocking.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The two lines, as the edited files now write them
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.enforcement_gate
  (gate, is_blocking, tolerated_findings, landed_in, rationale)
values
  ('reachable_configuration', false, 0, '20260921430000',
   'Landed reporting rather than blocking, as the simplification plan asks, because the states it '
   'finds are the ones the correctness and reseed nodes exist to delete. Anything beyond this '
   'number still refuses. Switch it to blocking in the dead-configuration pull request, once those '
   'nodes have landed and the number is nought.'),
  ('no_state_side_doors', false, 9, '20260921440000',
   'Landed reporting rather than blocking, as the simplification plan asks. Every finding it has '
   'today is an object whose lifecycle is a column because it was never authored as configuration, '
   'and the manufacturing and counting nodes are what bring them over. Anything beyond this number '
   'still refuses. Switch it to blocking in the dead-configuration pull request.')
on conflict (gate) do update set
  is_blocking = excluded.is_blocking,
  tolerated_findings = excluded.tolerated_findings,
  landed_in = excluded.landed_in,
  rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generators, then the proof
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.assert_reachable_configuration() is not run here either, for the
-- reason this whole file exists: there is no organisation in a replay for it to
-- walk. The catalogue runs it once the demonstration is seeded.

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

select erp_test.assert_no_state_side_doors();
