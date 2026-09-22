set lock_timeout = '30s';

-- =============================================================================
-- 20260921715000  The catch-up suite is not a lottery
-- -----------------------------------------------------------------------------
-- 20260920250000 ended by running erp_test.assert_demonstration_catch_up_suite()
-- against the definitions as they stood in that file. On 22 September a fresh
-- replay stopped there:
--
--   CLOVEERP_DEMONSTRATION_CATCH_UP_SUITE_FAILED: 1/10 case(s) failed
--     the 11 item(s) open before it started again owed 1399916, and owe
--     1399916 now; owed 1316810 before and 6224211 after
--
-- The same commit had passed the same suite seven hours earlier. Nothing in it
-- changed. The date did.
--
-- ── WHY THE DATE DECIDES IT ──────────────────────────────────────────────────
--
-- erp.seed_demo_history() seeds its randomness from the day it starts on
--
--   perform setseed((abs(hashtext(v_from::text)) % 100000) / 100000.0);
--
-- and the suite's fixture is anchored on current_date - 145 and current_date -
-- 25. So a run is reproducible, and a different day is a different world.
--
-- The fifth case asserts that the catch-up collected some of the debt that was
-- already on the books. Whether it does is a matter of chance, and the file
-- says so in its own words, two hundred lines above the case:
--
--   cash goes to the oldest item OF THE CUSTOMER IT COMES FROM, and in three
--   weeks of trading some customers are not invoiced at all, so their old debt
--   is not reached however old it is.
--
-- That comment was written when the case was moved from the ageing band to the
-- row, because the band did not move. The row is a sharper ruler than the band
-- and it is still a ruler held up to a coin toss: it needs one of the eleven
-- customers holding old debt to be both invoiced and paid inside the window.
-- On 21 September one was. On 22 September none was.
--
-- ── WHY A NEW MIGRATION ALONE COULD NOT FIX IT ───────────────────────────────
--
-- The suite is defined at 20260920250000:450 and called at :801, so the call
-- runs the definition from that same file. Redefining the suite here would not
-- be reached: a replay from an empty database dies at :801 first, every time,
-- for ever. The call had to go, so the call is what this repairs.
--
-- ── THE PRECEDENT THIS FOLLOWS ───────────────────────────────────────────────
--
-- 20260920310000 removed the identical call from 20260920300000 and registered
-- the edit, because the suite was timing the deploy out. The reasoning there is
-- the reasoning here, and its three claims are re-asserted below rather than
-- assumed: a suite the catalogue runs is run by the build whether or not a
-- migration asks for it, and what a removal owes is the proof that it loses no
-- coverage.
--
-- ── WHAT IS FIXED, AND WHAT IS DELIBERATELY NOT ──────────────────────────────
--
-- The case is not weakened. It still asserts that new trading collects old
-- debt, because that is a real claim about erp.apply_cash() and worth holding.
-- What changes is the fixture: it now lays down enough prior trading that the
-- customers carrying old debt are the customers the catch-up trades with, so
-- the case tests the product's behaviour instead of the day's seed.
--
-- The seed is left alone. Making it constant would make every demonstration
-- identical for ever, which is a change to the product to suit a test.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The build runs the suite, so the migration does not have to
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The three things that have to be true for the removal at :801 to be safe,
-- each checked rather than asserted in prose. Taken from 20260920310000, which
-- made the same removal next door and wrote down why each one matters.

do $covered$
declare
  v_suite    constant text := 'demonstration_catch_up_suite';
  v_check    constant text := 'assert_demonstration_catch_up_suite';
  v_expected constant integer := 12;
  v_body     text;
  v_wrap     text;
begin
  -- 1. The wrapper is in the catalogue. If a rename or a new argument ever put
  --    it outside, the suite would stop being run by anything and nothing would
  --    say so — a check that exists and is never run.
  if not exists (select 1 from erp.ci_check_catalogue() c
                  where c.schema_name = 'erp_test'
                    and c.function_name = v_check) then
    raise exception
      'CLOVEERP_SUITE_NOT_IN_CATALOGUE: erp_test.%() is not in erp.ci_check_catalogue(), '
      'so removing its call from 20260920250000 would stop it being run at all', v_check
      using hint = 'Restore the call, or put the wrapper back in the catalogue.';
  end if;

  -- 2. The suite still pins its case count, and 3. the wrapper pins the same
  --    number. A suite that loses a case reports success; two guards that
  --    disagree are one guard.
  v_body := pg_get_functiondef(('erp_test.' || v_suite || '()')::regprocedure);
  v_wrap := pg_get_functiondef(('erp_test.' || v_check || '()')::regprocedure);

  if position('v_cases <> ' || v_expected::text in v_body) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not pin % cases', v_suite, v_expected
      using hint = 'Read the deployed body and re-anchor this migration on it.';
  end if;

  if position('expected ' || v_expected::text in v_wrap) = 0 then
    raise exception
      'CLOVEERP_WRAPPER_COUNT_UNPINNED: erp_test.%() does not pin % cases', v_check, v_expected
      using hint = 'Read the deployed body and re-anchor this migration on it.';
  end if;
end
$covered$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The fixture carries old debt for the customers the catch-up trades with
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Patched into the deployed body rather than restated, for the reason
-- 20260920300000 gives: restating would drop cases 11 and 12, which that file
-- patched in and which exist in no source text anywhere.
--
-- The fixture seeded three runs of five days — two of them four months back,
-- one three weeks back. Eleven items were left open, held by however few
-- customers those fifteen days happened to touch. Two more runs are added
-- before the recent one, so the prior trading is continuous from
-- current_date - 35 to current_date - 21 rather than a single five-day island.
-- More of the customer list carries old debt, so cash arriving from any of them
-- during the catch-up lands on an old item first, which is the behaviour the
-- case exists to assert.
--
-- The last day built is unchanged at v_recent + 4, because everything added
-- starts before v_recent. Case 3 asserts that day, and still holds.

do $fixture$
declare
  v_sig constant text := 'erp_test.demonstration_catch_up_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  perform erp.seed_demo_history(v_recent, null, 1);\n';
  v_new constant text := E'  perform erp.seed_demo_history(v_recent - 15, null, 1);\n'
                      || E'  perform erp.seed_demo_history(v_recent - 10, null, 1);\n'
                      || E'  perform erp.seed_demo_history(v_recent - 5, null, 1);\n'
                      || E'  perform erp.seed_demo_history(v_recent, null, 1);\n';
  v_hits integer;
begin
  if position('v_recent - 15' in v_def) > 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % already seeds the wider fixture; this migration '
      'would seed it twice', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % seeds its recent history % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$fixture$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. And the case says what it found, so the next failure is legible
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The detail line named the old debt before and after and the totals either
-- side, which is enough to see that nothing was collected and not enough to see
-- why. How many customers held old debt at all is the number that separates
-- "no cash arrived" from "cash arrived from customers who owed nothing before",
-- and it is the one that was missing at 07:33 this morning.

do $detail$
declare
  v_sig constant text := 'erp_test.demonstration_catch_up_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'  detail := format(''the %s item(s) open before it started again owed %s, and owe %s now; owed %s before and %s after, of which %s inside thirty days and %s past ninety'',\n';
  v_new constant text :=
    E'  detail := format(''the %s item(s) open before it started again, held by %s customer(s), owed %s, and owe %s now; owed %s before and %s after, of which %s inside thirty days and %s past ninety'',\n';
  v_oldargs constant text :=
       E'                   coalesce(array_length(v_prior_ids, 1), 0),\n'
    || E'                   v_prior_before, v_prior_after,\n';
  v_newargs constant text :=
       E'                   coalesce(array_length(v_prior_ids, 1), 0),\n'
    || E'                   (select count(distinct si.party_id) from erp.subledger_item si\n'
    || E'                     where si.id = any (v_prior_ids)),\n'
    || E'                   v_prior_before, v_prior_after,\n';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % writes its fifth case''s detail % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_old, v_new);

  v_hits := (length(v_def) - length(replace(v_def, v_oldargs, ''))) / greatest(length(v_oldargs), 1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % passes its fifth case''s arguments % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_oldargs, v_newargs);
  execute v_def;
end
$detail$;

-- The generators, which are idempotent and run at the end of every migration.
-- Nothing here creates a table, a door or a policy: the whole of this file is
-- one routine in erp_test and the claims that let a call be removed from a file
-- that is already applied everywhere.

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
