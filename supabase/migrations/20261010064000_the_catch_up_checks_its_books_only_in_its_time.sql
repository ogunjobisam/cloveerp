set lock_timeout = '30s';

-- =============================================================================
-- 20261010064000  The catch-up checks its books only in the time it has
-- -----------------------------------------------------------------------------
-- Found by the review of #448. erp.demonstration_catch_up() stops trading at
-- 60% of the statement's limit and stops billing and closing at 80%
-- (erp.catch_up_deadline()), so it returns and commits instead of being
-- cancelled (20260921130000). After trading, and again after billing, it
-- checks the organisation's books — stock, inventory, the subledger, ageing
-- against control, the trial balance — and it did so whatever the clock
-- said. On a demonstration with a year of trading those checks take time,
-- and a check that runs past the limit cancels the whole statement: every
-- day traded in it is rolled back, and the next deploy starts from the same
-- place. query_canceled is not a condition the routine's handlers can catch.
-- The demonstration now lives on a 1 GB instance and is caught up under a
-- 90-second limit (release.yml), where that is likely rather than possible.
--
-- A deadline alone does not close it: a set of checks that begins just
-- before the deadline, with a fifth of the limit left, still overruns if it
-- needs more than that (the review's COV-7). So the checks also know how
-- long they take. Each set is timed; the longest set of a run is kept, by
-- organisation, on one platform setting the next run reads; and a set
-- starts only with twice the longest known still to run before the
-- statement's own limit. The first run on an organisation knows nothing and
-- has only the deadline — with at least a fifth of the limit, and after
-- trading two fifths, which on the demonstration is eighteen and thirty-six
-- seconds; a set that cannot finish in that would fail the deploy's proof
-- (erp.assert_whole_database_reconciles(), 55 s) just the same.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.demonstration_catch_up(): each of the two sets of checks runs only
--      while the 80% deadline has not passed AND twice the longest a set is
--      known to have taken on this organisation is still left before the
--      limit. Otherwise it is skipped with a note saying so, and what was
--      built commits. The deploy's proof, which runs straight after
--      (erp.assert_whole_database_reconciles(), every organisation), checks
--      the same books and fails the release if they are wrong. A set that
--      ran is timed, and the run's longest is kept on
--      erp_meta.platform_setting 'demonstration.catch_up.check_seconds', an
--      object keyed by organisation id, for the next run. Skipping the
--      checks is not reported as running out of time: that stays what it
--      was, trading, billing or closing stopped by the deadline, which the
--      deploy reads as "more to do".
--   B. erp_test.catch_up_checks_in_time_suite, five cases, and its
--      assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- With no limit, or inside it with room, the checks run exactly as before and
-- a failure still rolls back the phase it checks. No door, permission or
-- screen string.
--
-- On production: one function is replaced and a suite added; no row is
-- written. Production has no demonstration to catch up (20261010061000), so
-- the setting is never written there.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The checks wait for the clock, and for the room they need
-- ─────────────────────────────────────────────────────────────────────────────

do $checks$
declare
  v_sig   constant text := 'erp.demonstration_catch_up()';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old0  constant text := $o$  v_trade_by  timestamptz := erp.catch_up_deadline(0.60);
  v_finish_by timestamptz := erp.catch_up_deadline(0.80);
  v_out_of_time boolean := false;$o$;
  v_new0  constant text := $n$  v_trade_by  timestamptz := erp.catch_up_deadline(0.60);
  v_finish_by timestamptz := erp.catch_up_deadline(0.80);
  v_out_of_time boolean := false;
  -- The room the book checks need (20261010064000): the statement's whole
  -- limit, and the longest a set of them is known to have taken on this
  -- organisation — the last run's, kept on a platform setting, and this
  -- statement's once a set has run. Null when nothing is known yet.
  v_limit_at  timestamptz := erp.catch_up_deadline(1.0);
  v_check_took interval := (select make_interval(secs => (s.value ->> v_tenant::text)::double precision)
                              from erp_meta.platform_setting s
                             where s.key = 'demonstration.catch_up.check_seconds'
                               and jsonb_typeof(s.value -> v_tenant::text) = 'number');
  v_check_started timestamptz;$n$;
  v_old1  constant text := $o$      -- The books after the catching up, or none of it.
      perform erp.assert_stock_reconciles();
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      perform erp.assert_trial_balance_balances();$o$;
  v_new1  constant text := $n$      -- The books after the catching up, or none of it — while there is
      -- room to check them (20261010064000). A check that overran the limit
      -- would cancel the statement and every day traded in it, and
      -- query_canceled is not a condition the handler below can catch; so the
      -- checks start only before the 80% deadline, and only with twice the
      -- longest a set of them is known to have taken on this organisation
      -- still to run. Past that they are left to the deploy's proof, which
      -- checks the same books, and the note says so.
      if (v_finish_by is not null and clock_timestamp() >= v_finish_by)
         or (v_limit_at is not null and v_check_took is not null
             and clock_timestamp() + v_check_took * 2 >= v_limit_at) then
        v_notes := v_notes || to_jsonb(
          'Its books were not checked after trading, because the time this statement is allowed had run out, or would have before they finished; the deploy''s proof checks them.'::text);
      else
        v_check_started := clock_timestamp();
        perform erp.assert_stock_reconciles();
        perform erp.assert_inventory_reconciles();
        perform erp.assert_subledger_reconciles();
        perform erp.assert_ageing_equals_control();
        perform erp.assert_trial_balance_balances();
        v_check_took := greatest(coalesce(v_check_took, interval '0'),
                                 clock_timestamp() - v_check_started);
      end if;$n$;
  v_old2  constant text := $o$    -- The accrual has moved to the creditors, or none of it has.
    perform erp.assert_subledger_reconciles();
    perform erp.assert_ageing_equals_control();
    perform erp.assert_trial_balance_balances();$o$;
  v_new2  constant text := $n$    -- The accrual has moved to the creditors, or none of it has — while
    -- there is room to check (20261010064000), as after trading.
    if (v_finish_by is not null and clock_timestamp() >= v_finish_by)
       or (v_limit_at is not null and v_check_took is not null
           and clock_timestamp() + v_check_took * 2 >= v_limit_at) then
      v_notes := v_notes || to_jsonb(
        'Its books were not checked after billing, because the time this statement is allowed had run out, or would have before they finished; the deploy''s proof checks them.'::text);
    else
      v_check_started := clock_timestamp();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      perform erp.assert_trial_balance_balances();
      v_check_took := greatest(coalesce(v_check_took, interval '0'),
                               clock_timestamp() - v_check_started);
    end if;$n$;
  v_old3  constant text := $o$  return jsonb_build_object(
    'organisation',     v_code,$o$;
  v_new3  constant text := $n$  -- What a set of checks took, kept for the next run's room (20261010064000):
  -- this run's longest, for this organisation, on one setting keyed by
  -- organisation id. Only a run that checked something has anything to say.
  if v_check_started is not null and v_check_took is not null then
    insert into erp_meta.platform_setting as ps (key, value, reason)
    values ('demonstration.catch_up.check_seconds',
            jsonb_build_object(v_tenant::text, round(extract(epoch from v_check_took)::numeric, 3)),
            'How long the demonstration catch-up''s book checks last took, in seconds by organisation, so the next run checks only with room for them (20261010064000).')
    on conflict (key) do update
      set value = coalesce(ps.value, '{}'::jsonb) || excluded.value,
          updated_at = now();
  end if;

  return jsonb_build_object(
    'organisation',     v_code,$n$;
begin
  if strpos(v_src, '20261010064000') > 0 then
    raise notice '% already checks its books in its time; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'dc11585db686aa9de04bb5cd460351eb' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010064000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old0, ''))) / length(v_old0) <> 1
     or (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(replace(v_def, v_old0, v_new0), v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$checks$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.catch_up_checks_in_time_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_uid     uuid := gen_random_uuid();
  v_email   text;
  v_step    text := 'marking a demonstration';
  v_state   text;
  v_tenant  uuid;
  v_limit   text := current_setting('statement_timeout');
  v_late    jsonb;
  v_ontime  jsonb;
  v_noroom  jsonb;
  v_kept    text;
  v_notes   text;
begin
  v_email := 'catchup@zzcit-' || v_tag || '.test';
  begin
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"demonstration"'::jsonb, 'catch_up_checks_in_time_suite');

    -- A demonstration with a few days of trading, so both sets of checks
    -- have books to read.
    v_step := 'a demonstration with history';
    insert into auth.users (id, email) values (v_uid, v_email);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_email, v_uid, 'Catch-up Suite Operator', 'operator');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_tenant := (public.erp_seed_demo() ->> 'tenant_id')::uuid;
    perform erp.seed_demo_history(current_date - 3, null, 1);
    perform set_config('erp.job_tenant_id', v_tenant::text, true);

    -- The statement's time already spent: a one-millisecond limit, read by
    -- erp.catch_up_deadline() and not enforced on a statement already
    -- running, so the catch-up sees every deadline passed.
    v_step := 'the catch-up with its time spent';
    perform set_config('statement_timeout', '1ms', true);
    v_late := erp.demonstration_catch_up();
    perform set_config('statement_timeout', v_limit, true);
    select string_agg(n, ' | ') into v_notes from jsonb_array_elements_text(v_late -> 'notes') n;

    -- ── 1. After trading ────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'with its time spent, the catch-up leaves the books after trading to the deploy''s proof and says so';
    passed := v_notes like '%not checked after trading%';
    detail := coalesce(v_notes, 'no notes');
    return next;

    -- ── 2. After billing, and the trading it could not do is still reported ─
    v_cases := v_cases + 1;
    case_name := 'and the books after billing, and it still reports that its trading ran out of time';
    passed := v_notes like '%not checked after billing%' and (v_late ->> 'ran_out_of_time')::boolean;
    detail := coalesce(v_notes, 'no notes') || ' / ran_out_of_time ' || coalesce(v_late ->> 'ran_out_of_time', '?');
    return next;

    -- ── 3. With time, the checks run ────────────────────────────────────────
    v_step := 'the catch-up with no limit';
    perform set_config('statement_timeout', '0', true);
    v_ontime := erp.demonstration_catch_up();
    perform set_config('statement_timeout', v_limit, true);
    select string_agg(n, ' | ') into v_notes from jsonb_array_elements_text(v_ontime -> 'notes') n;
    v_cases := v_cases + 1;
    case_name := 'with no limit the books are checked after trading and after billing, as before';
    passed := coalesce(v_notes, '') not like '%not checked after%'
              and not coalesce((v_ontime ->> 'ran_out_of_time')::boolean, false);
    detail := coalesce(v_notes, 'no notes');
    return next;

    -- ── 4. And what they took is kept for the next run ──────────────────────
    v_cases := v_cases + 1;
    case_name := 'a run that checked its books keeps how long they took, by organisation, for the next run''s room';
    select s.value ->> v_tenant::text into v_kept
      from erp_meta.platform_setting s
     where s.key = 'demonstration.catch_up.check_seconds';
    passed := v_kept is not null and v_kept::numeric > 0;
    detail := coalesce('kept ' || v_kept || ' s', 'nothing kept');
    return next;

    -- ── 5. A set with no room is left to the proof before any deadline ──────
    --
    -- The checks are known to take an hour, and the statement is allowed ten
    -- minutes: neither deadline has passed, and neither set fits. Not reported
    -- as running out of time, because nothing did; the notes say what was
    -- left to the proof.
    v_step := 'the catch-up with checks known to take an hour';
    update erp_meta.platform_setting s
       set value = jsonb_build_object(v_tenant::text, 3600)
     where s.key = 'demonstration.catch_up.check_seconds';
    perform set_config('statement_timeout', '10min', true);
    v_noroom := erp.demonstration_catch_up();
    perform set_config('statement_timeout', v_limit, true);
    select string_agg(n, ' | ') into v_notes from jsonb_array_elements_text(v_noroom -> 'notes') n;
    v_cases := v_cases + 1;
    case_name := 'a set of checks that would not finish inside the limit is left to the proof before the deadline, and that is not running out of time';
    passed := v_notes like '%not checked after trading%'
              and v_notes like '%not checked after billing%'
              and not coalesce((v_noroom ->> 'ran_out_of_time')::boolean, false);
    detail := coalesce(v_notes, 'no notes') || ' / ran_out_of_time ' || coalesce(v_noroom ->> 'ran_out_of_time', '?');
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('statement_timeout', v_limit, true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CATCH_UP_CHECKS_IN_TIME_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.catch_up_checks_in_time_suite() from public, anon;

comment on function erp_test.catch_up_checks_in_time_suite() is
  'The demonstration catch-up checks its books only while it has room (20261010064000): past its deadline, or with '
  'less than twice the longest a set is known to have taken still to run, it leaves the checks after trading and '
  'after billing to the deploy''s proof and says so, without reporting that as running out of time; a run that '
  'checked keeps how long it took, by organisation; with no limit both sets run as before.';

create or replace function erp_test.assert_catch_up_checks_in_time_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.catch_up_checks_in_time_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CATCH_UP_CHECKS_IN_TIME_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The catch-up checks its books past its deadline or without room for them, where a check that overruns cancels everything it built; or no longer checks them when it has room; or no longer keeps what they took. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_CATCH_UP_CHECKS_IN_TIME_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('catch-up checks in time: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_catch_up_checks_in_time_suite() from public, anon;

comment on function erp_test.assert_catch_up_checks_in_time_suite() is
  'The demonstration catch-up never runs its book checks past its own deadline or without room for them (20261010064000).';

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
select erp.assert_personal_data_register_sound();
