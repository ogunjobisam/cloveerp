-- ─────────────────────────────────────────────────────────────────────────────
-- A window that is always quiet
--
-- At 23:59 UTC on 16 September the build failed, on main, in a job that had
-- passed on the same commit an hour earlier:
--
--     CLOVEERP_OUTPUT_CHANNELS_SUITE_FAILED: 29/31
--       a notification below the override severity is held during quiet hours
--       and released when the window ends
--
-- Nothing was wrong with the product. erp_test.output_channels_suite() wants a
-- window that is always quiet, so that the next event is certain to be held,
-- and it asks for one like this:
--
--     erp.set_my_quiet_hours(array[1,2,3,4,5,6,7], '00:00', '23:59', 'UTC', …)
--
-- The window is closed at both ends — erp.is_within_quiet_hours() compares
-- `(p_at at time zone q.timezone)::time between q.starts_at_time and
-- q.ends_at_time` — so 00:00 to 23:59 is every instant of the day except the
-- last fifty-nine seconds of it. For one minute in every twenty-four hours the
-- window the suite calls "always" is shut, the event is delivered instead of
-- held, and the case that follows it (which releases what the first one held)
-- fails too. Two cases, one cause, 1440 minutes between chances to see it.
--
-- THE PRODUCT IS NOT CHANGED. Somebody who asks for 00:00 to 23:59 is asking
-- for a window that ends at 23:59, and that is what they should get; closing
-- the comparison at the far end for everyone would be a worse answer to a
-- clearer question. It is the test that means "all day" and spells it wrongly.
-- '24:00' is a valid time in PostgreSQL and is greater than every time a clock
-- can show, so `between '00:00' and '24:00'` is true whenever it is asked.
--
-- This is the second nondeterminism found in the build today. The first —
-- seven change sets promoted in the order a tied `created_at` happened to sort
-- them — landed as 20260916610000. That one could refuse a promotion; this one
-- could only fail a test, but a test that fails for a reason that is not in
-- the diff costs an hour of somebody deciding whether to believe it.
--
-- The live body is the one 20260904920000 defines, as patched by
-- 20260906100000 (the bootstrap window). It is needle-patched here rather than
-- re-emitted, so that patch is not silently dropped.
-- ─────────────────────────────────────────────────────────────────────────────

do $quiet$
declare
  v_sig    constant text := 'erp_test.output_channels_suite()';
  v_def    text := pg_get_functiondef('erp_test.output_channels_suite()'::regprocedure);
  v_needle constant text :=
    E'  perform erp.set_my_quiet_hours(array[1,2,3,4,5,6,7]::smallint[], ''00:00'', ''23:59'', ''UTC'', ''critical'');\n';
  v_new    constant text :=
       E'  -- ''24:00'' rather than ''23:59'': the comparison is closed at both ends,\n'
    || E'  -- so 23:59 leaves the last fifty-nine seconds of the day outside a window\n'
    || E'  -- this case needs to be always shut. The product is unchanged.\n'
    || E'  perform erp.set_my_quiet_hours(array[1,2,3,4,5,6,7]::smallint[], ''00:00'', ''24:00'', ''UTC'', ''critical'');\n';
begin
  if position('''00:00'', ''24:00''' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already asks for a window that is always quiet', v_sig;
  end if;

  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % does not set its quiet hours exactly once the way the 20260904920000 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('''00:00'', ''24:00''' in v_def) = 0
     or position('erp_test.close_bootstrap_window' in v_def) = 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % was re-emitted without the new window, or without the bootstrap patch it already had', v_sig;
  end if;
end
$quiet$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the suite that was failing
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_output_channels_suite();

select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
