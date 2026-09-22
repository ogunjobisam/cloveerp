set lock_timeout = '30s';

-- =============================================================================
-- 20260922280000  The demonstration shows its credit control, it is not stopped by it
-- -----------------------------------------------------------------------------
-- 20260922270000 guarded the third place the seeder picks a customer, and
-- seeding a demonstration then got one slice further and refused again:
--
--   CLOVEERP_DOCUMENT_PARTY_REQUIRED: quotation needs a party
--   PL/pgSQL function erp.seed_demo_history(date, date, numeric) line 396
--
-- Line 396 is one of the places that patch did guard. The pick did not find a
-- held customer; it found NO customer, because by the fifth slice the guard had
-- excluded every one of them. A skip that can exclude the whole list is not a
-- skip, and the symptom it produces — a null party, four statements later — is
-- nothing like its cause.
--
-- ── WHY EVERY CUSTOMER ENDS UP HELD, AND WHY THAT IS CORRECT ─────────────────
--
-- erp.seed_demo_history() leaves a fifth of its invoices unpaid and another
-- sixth part-paid, on purpose, and says so where it does it:
--
--   a demonstration in which everything is settled shows no ageing, no dunning
--   and no collections work
--
-- The demonstration trades a year. So every customer ends up carrying an
-- unpaid invoice older than any window worth setting, and erp.credit_position()
-- is right to hold them. The seeded data and the control are both doing what
-- they are meant to; it is the third thing — refusing at order capture — that
-- cannot also be true in a demonstration that has to keep trading.
--
-- ── SO THE DEMONSTRATION STOPS REFUSING ITSELF ───────────────────────────────
--
-- sales.credit_control.check_at_capture exists for exactly this: an
-- organisation that computes credit positions and shows them without refusing
-- the order in front of it. The refusal's own hint names switching it off as
-- one of the three ways past. The demonstration is that organisation.
--
-- Nothing else about the control changes, and nothing W3 wired goes back:
--
--   erp.credit_position() still holds whom it held, on all three arms — the
--   customer stopped by hand, the two on limits the trading presses against,
--   and anybody whose debt has aged past the window;
--
--   erp.dunning_worklist() still carries on_hold and hold_reason, and the sales
--   tile still counts them, so the screens still show a real hold with a real
--   reason rather than an empty list;
--
--   the window stays at 180 and the ladder still stops where the door stops.
--
-- What changes is that the demonstration no longer refuses its own orders. A
-- prospect sees the control reporting, which is what a demonstration of a
-- control is.
--
-- ── AND THE SKIPS COME OUT ───────────────────────────────────────────────────
--
-- All four of them, from 20260922230000 and from 20260922270000 both. They were
-- working around the refusal, and with the refusal gone they only narrow what
-- the demonstration trades — narrowing further every month as more debt ages,
-- until the list empties and the seeder falls over the way it just did. A
-- workaround that degrades with time is worse than the thing it worked around.
--
-- The lesson 20260922270000 wrote down still stands and is worth repeating
-- here, because it is why that patch was believed: its counted-occurrence guard
-- returned the two it expected, which proves an anchor matched everywhere it
-- appears and says nothing about whether the change was the right one. Counting
-- answers "did I patch what I meant to". It has never answered "was that what
-- needed doing".
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The demonstration reports its credit control rather than enforcing it
-- ═════════════════════════════════════════════════════════════════════════════

do $capture$
declare
  v_sig constant text := 'erp.ensure_demo_configuration(uuid, uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'jsonb_build_object(''check_at_capture'', true, ''block_at_limit'', true,';
  v_new constant text :=
    E'jsonb_build_object(''check_at_capture'', false, ''block_at_limit'', true,';
  v_hits integer;
begin
  if position(E'''check_at_capture'', false' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_UNRECOGNISED: % already reports rather than refuses', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_UNRECOGNISED: % sets its credit control % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$capture$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the seeder stops walking past the customers it holds
-- ═════════════════════════════════════════════════════════════════════════════

do $skips$
declare
  v_sig constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  -- The half-order pick, whose guard ends the statement: the semicolon has to
  -- come back with the clause taken away.
  v_semi constant text :=
       E'\n         and not coalesce((select cp.on_hold from erp.credit_position(p.id) cp), false);';
  -- Its other half, and then the two 20260922230000 wrote, which are indented
  -- two spaces less.
  v_deep constant text :=
       E'\n         and not coalesce((select cp.on_hold from erp.credit_position(p.id) cp), false)';
  v_wide constant text :=
       E'\n       and not coalesce((select cp.on_hold from erp.credit_position(p.id) cp), false)';
  v_note270 constant text :=
       E'\n      -- Not a customer the credit control is holding (20260922270000).'
    || E'\n      -- Both halves: the count is what the offset is taken against, so'
    || E'\n      -- filtering one and not the other would walk off the end of the list.';
  v_note230 constant text :=
       E'\n       -- Not a customer the credit control has stopped (20260922230000).';
  v_out text;
  v_left integer;
begin
  if position('erp.credit_position(p.id)' in v_def) = 0 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: % already picks without asking the credit position', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_out := replace(v_def, v_semi, E';');
  v_out := replace(v_out, v_deep, '');
  v_out := replace(v_out, v_wide, '');
  v_out := replace(v_out, v_note270, '');
  v_out := replace(v_out, v_note230, '');

  v_left := (length(v_out) - length(replace(v_out, 'erp.credit_position(p.id)', '')))
              / length('erp.credit_position(p.id)');
  if v_left <> 0 then
    raise exception
      'CLOVEERP_SEEDER_UNRECOGNISED: % still asks the credit position % time(s) after the skips were taken out',
      v_sig, v_left
      using hint = 'Read the deployed body and re-anchor this patch on it. A skip written another way is one this did not find.';
  end if;

  execute v_out;
end
$skips$;

-- And the claim, checked where it is made: the seeder names a demonstration
-- customer in four places and asks the credit position in none of them.

do $none$
declare
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date, date, numeric)'::regprocedure);
  v_pick_t constant text := 'p.code like ''C-%''';
  v_pick integer;
begin
  v_pick := (length(v_def) - length(replace(v_def, v_pick_t, ''))) / length(v_pick_t);
  if v_pick <> 4 or position('erp.credit_position(p.id)' in v_def) > 0 then
    raise exception
      'CLOVEERP_SEEDER_PICKS_UNEXPECTED: the seeder names a demonstration customer % time(s) and asks the credit position %',
      v_pick, case when position('erp.credit_position(p.id)' in v_def) > 0 then 'still' else 'not at all' end
      using hint = 'The demonstration reports its credit control and does not refuse on it, so no pick filters by it.';
  end if;
end
$none$;

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
