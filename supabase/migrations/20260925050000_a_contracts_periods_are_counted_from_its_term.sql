set lock_timeout = '30s';

-- =============================================================================
-- 20260925050000  A contract's periods are counted from its term
-- -----------------------------------------------------------------------------
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * erp.generate_invoice_schedule() stepped from each period's end to the
--     next. A term that starts late in a month lost its day at the first short
--     month and never got it back: a quarterly contract from 29 November ran
--     29 Nov, 28 Feb, 28 May, 28 Aug, 28 Nov, and then a fifth invoice for
--     the one day left before the term ended on 29 November. Any contract
--     starting on the 29th, 30th or 31st was billed a stub period it did not
--     sign for.
--   * erp_test.commercial_renewal_suite starts its contract three hundred days
--     before today, so it failed on exactly the days that start lands on the
--     29th to the 31st, and passed on the rest.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp.contract_period_end() counts every period's end from the start of
--     the term: the start plus n periods, capped at the term's end, which is
--     how the term's own end was computed.
--   * The schedule asks it, and a period already invoiced is recognised by
--     overlapping the new one, not only by starting on the same day, so a
--     schedule written before this does not gain a second invoice for a
--     period it has.
--   * erp_test.contract_period_suite proves the arithmetic on fixed dates,
--     whatever day the build runs on.
-- =============================================================================

create or replace function erp.contract_period_end(p_term_start date, p_months integer, p_period integer, p_term_end date)
returns date
language sql
immutable
set search_path = ''
as $$
  select least((p_term_start + make_interval(months => p_months * p_period))::date, p_term_end)
$$;

revoke all on function erp.contract_period_end(date, integer, integer, date) from public, anon;

comment on function erp.contract_period_end(date, integer, integer, date) is
  'The end of a contract''s p_period-th billing period of p_months: counted from the start '
  'of the term, never from the last period''s end, so a term starting on the 31st keeps its '
  'day after a short month; capped at the term''s end (20260925050000).';

do $schedule$
declare
  v_sig constant text := 'erp.generate_invoice_schedule(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    v_end := least((v_start + make_interval(months => v_months))::date, c.current_term_end);
    if not exists (select 1 from erp_meta.contract_invoice i where i.contract_id = c.id and i.period_start = v_start) then$o$,
    $n$    -- From the start of the term, not the last period's end (20260925050000).
    v_end := erp.contract_period_end(c.current_term_start, v_months, v_periods + 1, c.current_term_end);
    -- A period already invoiced is one this overlaps, so a schedule written
    -- before the counting changed gains nothing.
    if not exists (select 1 from erp_meta.contract_invoice i
                    where i.contract_id = c.id and i.period_start < v_end and i.period_end > v_start) then$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$schedule$;

create or replace function erp_test.contract_period_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_ends text;
begin
  select string_agg(erp.contract_period_end('2025-11-29', 3, n, '2026-11-29')::text, ', ' order by n)
    into v_ends from generate_series(1, 4) n;
  return query select 'a quarterly term from 29 November keeps its day after February, and ends in four periods',
    v_ends = '2026-02-28, 2026-05-29, 2026-08-29, 2026-11-29', v_ends;

  select string_agg(erp.contract_period_end('2024-01-31', 1, n, '2025-01-31')::text, ', ' order by n)
    into v_ends from generate_series(1, 3) n;
  return query select 'a monthly term from 31 January keeps the month''s last day, leap year included',
    v_ends = '2024-02-29, 2024-03-31, 2024-04-30', v_ends;

  return query select 'the last period ends where the term does, and never past it',
    erp.contract_period_end('2025-11-29', 12, 1, '2026-11-29') = '2026-11-29'
    and erp.contract_period_end('2025-11-29', 3, 5, '2026-11-29') = '2026-11-29',
    'capped at the term''s end';
end;
$function$;

revoke all on function erp_test.contract_period_suite() from public, anon;

create or replace function erp_test.assert_contract_period_suite()
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
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.contract_period_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CONTRACT_PERIOD_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A billing period counted from the last one rather than the term''s start drifts after a short month and bills a stub. Read the dates.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_CONTRACT_PERIOD_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_contract_period_suite() from public, anon;

comment on function erp_test.assert_contract_period_suite() is
  'A contract''s billing periods are counted from the start of its term, so a term starting '
  'late in a month is billed the periods it signed for and no stub (20260925050000).';

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
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
