set lock_timeout = '30s';

-- =============================================================================
-- 20260922100000  The catch-up trades long enough to prove it collected
-- -----------------------------------------------------------------------------
-- erp_test.assert_demonstration_catch_up_suite() failed identically three
-- times on 22 September, all on the same case: "what it was owed when it
-- stopped was collected". v_prior_before and v_prior_after were bit-for-bit
-- equal — 1,399,916 in every run — while v_owed_after had genuinely grown from
-- new invoices. Three runs eight hours apart is not the shape of an unlucky
-- roll; it is the shape of something that does not vary across runs at all.
--
-- ── WHAT IT IS NOT ───────────────────────────────────────────────────────────
--
-- Not the loop that trades forward to today. erp.seed_demo_history() defaults
-- an open p_to to current_date — v_to := least(coalesce(p_to, current_date),
-- current_date), 20260905010000 — so erp.demonstration_catch_up()'s while loop
-- genuinely calls it in five-day slices until it reaches today, and 'done' is
-- never the null-coalesced accident it looks like on a first read.
--
-- Not erp.apply_cash(). Its oldest-first allocation is unchanged and is the
-- thing erp_test.cash_settlement_suite() (20260919200000) already proves.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- erp.seed_demo_history()'s day loop seeds Postgres's own random stream once
-- per built day — perform setseed((abs(hashtext(v_from::text)) % 100000) /
-- 100000.0), 20260914072000 — deliberately, so that rebuilding the same day
-- twice gives the same figures. Every day the fixture asks for, including
-- every day erp.demonstration_catch_up() trades through to reach today, is an
-- offset from current_date. So the suite's whole trajectory — which customer
-- each new order lands on, whether it is paid, how long the remittance lags —
-- is a pure function of the UTC calendar date the build happens to run on.
-- Same day, same trajectory, every time; a different day, a different one.
-- 21 September traded a fixture that reached the debt-holding customers; 22
-- September traded one that, on the strength of its own seed, did not touch
-- any of them within the window the fixture gave it.
--
-- Cash only reaches the eleven pre-existing items if a new order during
-- catch-up happens to be drawn for one of the (few) customers who hold them,
-- that invoice's payment roll succeeds, and its remittance lands on or before
-- today. Over a three-week catch-up window that is a real chance of missing
-- every one of them, and on 22 September's seed it did.
--
-- ── WHAT THIS CHANGES, AND WHAT IT DOES NOT ──────────────────────────────────
--
-- Widens the sample, not the mechanism. erp_test.demonstration_catch_up_suite()
-- is the only caller this touches; erp.seed_demo_history() and erp.apply_cash()
-- are untouched, because neither is where the defect is. The fixture's "stopped
-- trading" gap moves from three weeks to ten — v_recent from current_date - 25
-- to current_date - 70 — which roughly triples how many days, and so how many
-- new orders, the catch-up has to land a payment on one of the debt-holding
-- customers before the suite asks. It cannot make the case certain: the seed is
-- still whatever the calendar date gives it. It can make missing every one of
-- eleven items across ten weeks of trading a rarer accident than missing them
-- across three, which is the only lever available that does not mean touching
-- erp.apply_cash() to make a test pass.
--
-- The other fixture parameters are untouched: v_old (ten days, four months
-- back) still makes the over-ninety-day claim in case 1, and the case 3 name is
-- the only other place the old gap was spelled out in words a person reads.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The live body this migration patches
-- ═════════════════════════════════════════════════════════════════════════════

do $widen$
declare
  v_sig  constant text := 'erp_test.demonstration_catch_up_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);

  v_old_gap constant text := $o1$  v_recent   constant date := current_date - 25;$o1$;
  v_new_gap constant text := $r1$  v_recent   constant date := current_date - 70;$r1$;

  v_old_name constant text := $o2$  case_name := 'the fixture stopped trading three weeks ago, is owed money that fell due more than ninety days ago, holds receipts nobody has billed, and has never closed a month';$o2$;
  v_new_name constant text := $r2$  case_name := 'the fixture stopped trading ten weeks ago, is owed money that fell due more than ninety days ago, holds receipts nobody has billed, and has never closed a month';$r2$;

  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old_gap, ''))) / length(v_old_gap);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % declares its recent-trading gap % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and re-cut the needle before re-running.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old_name, ''))) / length(v_old_name);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % names the gap in case 3''s case_name % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and re-cut the needle before re-running.';
  end if;

  v_def := replace(v_def, v_old_gap, v_new_gap);
  v_def := replace(v_def, v_old_name, v_new_name);

  -- The count guard this body still has to hold itself to, unmoved by this
  -- patch: this widens a window, it does not add or remove a case.
  if position('v_cases <> 12' in v_def) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % no longer pins itself to 12 cases', v_sig;
  end if;

  execute v_def;
end
$widen$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- No suite is run from here. erp_test.assert_demonstration_catch_up_suite()
-- provisions an organisation of its own and trades it — 20260921120000 says
-- where that belongs — and the catalogue already runs it on every build. What
-- follows is the ordinary schema proof; its cost is the size of the schema,
-- except erp.assert_whole_database_reconciles(), which grows with the ledger
-- and was timed on live at 1.7 s over three organisations.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
