set lock_timeout = '30s';

-- =============================================================================
-- 20260924550000  The catalogue has a cadence
-- -----------------------------------------------------------------------------
-- Every push walks every check in erp.ci_check_catalogue(), and on 24 September
-- the walk on main took 27 minutes: 348 checks, of which five took 20 minutes
-- between them and the other 343 took seven. The five are the demonstration
-- suites. Each provisions an organisation and trades it through the doors —
-- days of documents, journals, bills and month closes, then the catch-up over
-- the same ground again — inside a fixture that is rolled back. Their cost is
-- what the fixture does, not what the schema is, and 20260921120000 already
-- says so. Nothing they prove is proved by anything faster.
--
-- What the wait buys is the question. The deploy applies a merged migration to
-- live within seventy seconds and proves it with erp.platform_assurance(),
-- fifteen seconds of read-only checks. The pull request's build is the only
-- proof that runs a suite before a migration reaches live, so the structural
-- assertions and the fast suites have to stay there. The demonstration suites
-- prove the routine that brings invented books in a non-live organisation up
-- to date. A defect there found at 02:30 rather than on the pull request costs
-- a demonstration a day; the twenty minutes on every push cost the person
-- waiting on the merge, every time.
--
-- ── WHAT THIS IS, AND WHAT IT IS NOT ─────────────────────────────────────────
--
-- A register, erp_meta.check_cadence, naming the checks the nightly owes and a
-- push does not. It is not an off switch and cannot become one:
--
--   * A row names a catalogue check or the build refuses (CADENCE_STALE), so
--     a renamed suite cannot leave a row that reads as covered.
--   * The nightly runs from an empty cluster and owes every check, so a row
--     defers a check by at most a day. There is no cadence that owes nothing.
--   * erp.assert_ci_ran() takes the cadence that ran and still refuses a push
--     that left an unregistered check unrun, and any name the catalogue does
--     not carry. The negative proof in .github/workflows/schema.yml — create
--     a check, hand the list back without it — refuses at both cadences.
--   * The register is read by supabase/ci/run_checks.sh, which prints what it
--     leaves to the nightly and by name, so a push log says what it did not do.
--
-- Five rows, each with its reason, each a suite the catalogue walks at the
-- nightly regardless. Nothing else changes cadence. erp.ci_check_catalogue()
-- itself is untouched: the set of checks is the same, and so is every figure
-- the documents quote from it.
--
-- ── THE COVERAGE SUITE GROWS BY THREE ────────────────────────────────────────
--
-- erp_test.ci_coverage_suite() proves the runner's contract, so it takes the
-- three claims above as cases 11 to 13 and pins 14, at both ends. Redefined
-- whole rather than patched, because a suite is its text.
--
-- ── WHAT THIS COSTS ON A REAL DATABASE ───────────────────────────────────────
--
-- A table with five rows, two routines redefined, and a block at the foot that
-- reads the catalogue. Its cost is the size of the schema. No suite is run
-- from here (20260920310000): the catalogue runs erp_test.ci_coverage_suite()
-- on the build, against the definition actually deployed.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.check_cadence (
  schema_name   text not null,
  function_name text not null,
  -- The only cadence a row can name. A push runs everything not listed here;
  -- there is no row that means "never".
  cadence       text not null default 'nightly',
  rationale     text not null,
  registered_at timestamptz not null default now(),
  primary key (schema_name, function_name),
  constraint check_cadence_is_nightly
    check (cadence = 'nightly'),
  constraint check_cadence_explains
    check (length(btrim(rationale)) >= 40)
);

comment on table erp_meta.check_cadence is
  'The catalogue checks a push leaves to the nightly build, each with the '
  'reason its fixture costs minutes rather than seconds. Every row must name '
  'a check erp.ci_check_catalogue() carries, the nightly owes every check '
  'regardless, and erp.assert_ci_ran() refuses a push that left anything '
  'unregistered unrun. A register of what waits a day, never of what is off.';

select erp_meta.register_table('erp_meta', 'check_cadence', 'platform_internal',
  'Register of catalogue checks the nightly build owes and a push does not. Not tenant data.');

insert into erp_meta.check_cadence (schema_name, function_name, rationale) values
  ('erp_test', 'assert_demonstration_catch_up_suite',
   'Provisions an organisation, seeds fifteen days of trading across four months, runs the '
   'catch-up to today and runs it again: 810 s on the build of 24 September.'),
  ('erp_test', 'assert_demonstration_reopen_suite',
   'Provisions an organisation, seeds a day eighty days back, closes every historic period '
   'through the checklist, then reopens, trades and re-closes them: 185 s, 58 min from empty.'),
  ('erp_test', 'assert_catch_up_budget_suite',
   'Runs the catch-up until it yields at its deadline, so its cost is the statement timeout '
   'it proves the routine respects: 102 s on the build of 24 September.'),
  ('erp_test', 'assert_demonstration_module_catch_up_suite',
   'Provisions an organisation configured before a later module version and trades it through '
   'the catch-up: 58 s on the build of 24 September.'),
  ('erp_test', 'assert_demonstration_close_frontier_suite',
   'Provisions an organisation, seeds a day and runs the catch-up twice, the second trading '
   'three weeks: 30 s on the build of 24 September.')
on conflict (schema_name, function_name) do update
  set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The runner's contract takes the cadence that ran
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The one-argument form is dropped rather than kept beside the new one: two
-- overloads make erp.assert_ci_ran(v_names) ambiguous, and the exemption row
-- in erp_meta.check_run_exemption is keyed by name, so it still covers this.

drop function if exists erp.assert_ci_ran(text[]);

create or replace function erp.assert_ci_ran(p_ran text[], p_cadence text default 'nightly')
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_missing   text;
  v_n_missing integer;
  v_extra     text;
  v_n_extra   integer;
  v_stale     text;
  v_n_stale   integer;
  v_owed      integer;
  v_total     integer;
begin
  if p_cadence is null or p_cadence not in ('push', 'nightly') then
    raise exception 'CLOVEERP_CHECK_CADENCE_UNKNOWN: % is not a cadence the build runs at', coalesce(p_cadence, '(null)')
      using errcode = '22023',
            hint = 'Run the catalogue as push, which owes every check not in erp_meta.check_cadence, or as nightly, which owes every check.';
  end if;

  perform erp.assert_ci_coverage();

  -- A row that names nothing the catalogue carries is a row that reads as a
  -- check deferred when there is no check: a renamed suite would leave one.
  select count(*), string_agg('  ' || k.schema_name || '.' || k.function_name, E'\n' order by k.schema_name, k.function_name)
    into v_n_stale, v_stale
    from erp_meta.check_cadence k
   where not exists (select 1 from erp.ci_check_catalogue() c
                      where c.schema_name = k.schema_name and c.function_name = k.function_name);
  if v_n_stale > 0 then
    raise exception E'CLOVEERP_CHECK_CADENCE_STALE: % cadence row(s) name no catalogue check\n%', v_n_stale, v_stale
      using errcode = '23503',
            hint = 'Delete the row from erp_meta.check_cadence, or give the check back the shape the catalogue gathers: assert_% in erp or erp_test, taking no arguments.';
  end if;

  select count(*), string_agg('  ' || c.qualified_name, E'\n' order by c.seq, c.qualified_name)
    into v_n_missing, v_missing
    from erp.ci_check_catalogue() c
   where c.qualified_name <> all (coalesce(p_ran, '{}'))
     and (p_cadence = 'nightly'
          or not exists (select 1 from erp_meta.check_cadence k
                          where k.schema_name = c.schema_name and k.function_name = c.function_name));
  if v_n_missing > 0 then
    raise exception E'CLOVEERP_CHECK_NOT_RUN: % catalogue check(s) the % cadence owes were not run\n%', v_n_missing, p_cadence, v_missing
      using errcode = '23514',
            hint = 'The runner reads erp.ci_check_catalogue() and erp_meta.check_cadence; a check it did not run was skipped or failed to be listed. Only a check registered there may wait for the nightly.';
  end if;

  select count(*), string_agg('  ' || x, E'\n' order by x)
    into v_n_extra, v_extra
    from unnest(coalesce(p_ran, '{}')) x
   where not exists (select 1 from erp.ci_check_catalogue() c where c.qualified_name = x);
  if v_n_extra > 0 then
    raise exception E'CLOVEERP_CHECK_UNLISTED: the runner ran % name(s) the catalogue does not carry\n%', v_n_extra, v_extra
      using errcode = '23514',
            hint = 'A runner with names of its own has a list of its own. Run the catalogue and nothing else.';
  end if;

  select count(*) into v_total from erp.ci_check_catalogue();
  select count(*) into v_owed
    from erp.ci_check_catalogue() c
   where c.qualified_name = any (coalesce(p_ran, '{}'));
  return format('ci ran %s of %s catalogue checks', v_owed, v_total);
end;
$$;

revoke all on function erp.assert_ci_ran(text[], text) from public, anon, authenticated;

comment on function erp.assert_ci_ran(text[], text) is
  'The runner hands back the names it ran and the cadence it ran at. Refuses '
  'a name the catalogue does not carry, a check the cadence owes that was not '
  'run (a push owes every check not in erp_meta.check_cadence; the nightly '
  'owes every check), a cadence row naming no catalogue check, and a cadence '
  'the build does not run at.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The coverage suite, with three cases for the cadence
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.ci_coverage_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases    integer := 0;
  v_expected integer;
  v_actual   integer;
  v_names    text[];
  v_msg      text;
  v_tenant   uuid;
  v_ran      boolean;
begin
  -- 1. The catalogue is exactly the set of zero-argument assert_* routines.
  v_cases := v_cases + 1;
  select count(*) into v_expected
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_test') and p.proname like 'assert\_%'
     and p.prokind in ('f', 'p') and p.pronargs = p.pronargdefaults
     and not exists (select 1 from erp_meta.diagnostic_check d
                      where d.schema_name = n.nspname and d.function_name = p.proname
                        and d.scope = 'tenant' and d.function_name <> 'assert_whole_database_reconciles');
  select count(*) into v_actual from erp.ci_check_catalogue();
  case_name := 'the catalogue lists every assertion the build can call bare, and no per-organisation one';
  passed := v_actual = v_expected and v_actual > 100
        and not exists (select 1 from erp.ci_check_catalogue() where function_name = 'assert_subledger_reconciles')
        and exists (select 1 from erp.ci_check_catalogue() where function_name = 'assert_whole_database_reconciles' and phase = 'final');
  detail := format('%s in the catalogue, %s callable bare; the subledger reconciliation is driven, not listed', v_actual, v_expected);
  return next;

  -- 2. An assertion that takes arguments and is accounted for by nothing.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create function erp.assert_zz_takes_args(p_x integer) returns text language sql as $f$ select ''x'' $f$';
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an assertion that takes arguments and is neither driven nor exempt is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%assert_zz_takes_args%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 3. An exemption naming nothing.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp_meta.check_run_exemption (schema_name, function_name, rationale)
    values ('erp', 'assert_zz_missing', 'A rationale long enough to satisfy the constraint and nothing more.');
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an exemption naming a routine that does not exist is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%assert_zz_missing%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 4. An exemption that would turn a runnable check off.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp_meta.check_run_exemption (schema_name, function_name, rationale)
    values ('erp', 'assert_isolation', 'Pretend the isolation assertion cannot be run, which it can.');
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an exemption that hides a check the build could run is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%hides a check%assert_isolation%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 5. A driver that does not call what it drives.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    update erp_meta.check_run_exemption set driven_by = 'erp.assert_isolation'
     where schema_name = 'erp' and function_name = 'assert_posting_rule_balances';
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a driver that does not call the check it drives is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%does not call it%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 6. A suite body with no wrapper.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create function erp_test.zz_orphan_suite() returns table(case_name text, passed boolean, detail text) language sql as $f$ select ''x'', true, ''y'' $f$';
    begin
      perform erp.assert_ci_coverage();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a suite with no wrapper pinning its case count is refused';
  passed := v_msg like 'CLOVEERP_CHECKS_UNRUNNABLE:%' and v_msg like '%zz_orphan_suite%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 7. The runner left one out.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) into v_names
    from erp.ci_check_catalogue() c where c.qualified_name <> 'erp.assert_isolation';
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a catalogue check the runner did not run is refused';
  passed := v_msg like 'CLOVEERP_CHECK_NOT_RUN:%' and v_msg like '%erp.assert_isolation%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 8. The runner ran something of its own.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) || array['erp.assert_zz_nothing'] into v_names
    from erp.ci_check_catalogue() c;
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a name the catalogue does not carry is refused';
  passed := v_msg like 'CLOVEERP_CHECK_UNLISTED:%' and v_msg like '%erp.assert_zz_nothing%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 9. The complete list passes.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) into v_names from erp.ci_check_catalogue() c;
  v_msg := null;
  begin
    v_msg := erp.assert_ci_ran(v_names);
    v_ran := true;
  exception when others then v_msg := sqlerrm; v_ran := false;
  end;
  case_name := 'the complete list is accepted';
  passed := v_ran and v_msg like 'ci ran % of % catalogue checks';
  detail := left(coalesce(v_msg, 'no answer'), 200);
  return next;

  -- 10. The whole database refuses an organisation whose posting rule is unbalanced.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp.tenant (code, name) values ('zz-ci-coverage', 'CI coverage suite')
    returning id into v_tenant;
    insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
    values (v_tenant, 'zz_unbalanced', 'goods_receipt',
            '[{"side":"debit","account":"1200","basis":"document_value","rate":1}]'::jsonb,
            'active', date '2020-01-01');
    begin
      perform erp.assert_whole_database_reconciles();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'the whole-database reconciliation names the organisation whose rule is unbalanced';
  passed := v_msg like 'CLOVEERP_DATABASE_DOES_NOT_RECONCILE:%' and v_msg like '%zz-ci-coverage%zz_unbalanced%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 11. A check registered for the nightly is not owed by a push.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) into v_names
    from erp.ci_check_catalogue() c
   where not exists (select 1 from erp_meta.check_cadence k
                      where k.schema_name = c.schema_name and k.function_name = c.function_name);
  v_msg := null;
  begin
    v_msg := erp.assert_ci_ran(v_names, 'push');
    v_ran := true;
  exception when others then v_msg := sqlerrm; v_ran := false;
  end;
  case_name := 'a push that ran every check but the ones registered for the nightly is accepted';
  passed := v_ran and v_msg like 'ci ran % of % catalogue checks'
        and exists (select 1 from erp_meta.check_cadence);
  detail := left(coalesce(v_msg, 'no answer'), 200);
  return next;

  -- 12. The nightly owes those checks, and says which it did not get.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names, 'nightly');
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'the same list is refused as a nightly, naming a check left out';
  passed := v_msg like 'CLOVEERP_CHECK_NOT_RUN:%'
        and v_msg like '%erp_test.assert_demonstration_reopen_suite%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 13. A push owes every check that is not registered, and a cadence nobody
  --     runs is refused rather than read as one that owes nothing.
  v_cases := v_cases + 1;
  select array_agg(c.qualified_name) into v_names
    from erp.ci_check_catalogue() c
   where c.qualified_name <> 'erp.assert_isolation'
     and not exists (select 1 from erp_meta.check_cadence k
                      where k.schema_name = c.schema_name and k.function_name = c.function_name);
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names, 'push');
  exception when others then v_msg := sqlerrm;
  end;
  passed := v_msg like 'CLOVEERP_CHECK_NOT_RUN:%' and v_msg like '%erp.assert_isolation%';
  detail := left(coalesce(v_msg, 'no refusal'), 120);
  v_msg := null;
  begin
    perform erp.assert_ci_ran(v_names, 'weekly');
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a push still owes an unregistered check, and an unknown cadence is refused';
  passed := passed and v_msg like 'CLOVEERP_CHECK_CADENCE_UNKNOWN:%';
  detail := detail || ' / ' || left(coalesce(v_msg, 'no refusal'), 80);
  return next;

  -- 14. And the falsification was undone.
  v_cases := v_cases + 1;
  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-ci-coverage')
        and not exists (select 1 from pg_catalog.pg_proc where proname in ('assert_zz_takes_args', 'zz_orphan_suite'))
        and not exists (select 1 from erp_meta.check_run_exemption where function_name in ('assert_zz_missing', 'assert_isolation'))
        and (select driven_by from erp_meta.check_run_exemption
              where schema_name = 'erp' and function_name = 'assert_posting_rule_balances') = 'erp.assert_whole_database_reconciles';
  detail := 'no tenant, no routine, no row left behind';
  return next;

  if v_cases <> 14 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 14; the last message the fixture saw was %',
      v_cases, coalesce(v_msg, '(none)');
  end if;
end;
$$;

revoke all on function erp_test.ci_coverage_suite() from public, anon;

create or replace function erp_test.assert_ci_coverage_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _ci_coverage on commit drop as
    select * from erp_test.ci_coverage_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _ci_coverage;
  drop table _ci_coverage;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CI_COVERAGE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 14 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ci_coverage_suite ran % cases, expected 14', v_all;
  end if;
  return format('ci coverage: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_ci_coverage_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Every row names a suite the catalogue walks
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The claim that makes a row safe is that the nightly runs the check anyway.
-- That is true only of a check the catalogue carries, so each row is held to
-- it here, in this transaction, and the two ends of the coverage suite are
-- held to the same count.

do $cadence$
declare
  k         record;
  v_phase   text;
  v_rows    integer;
  v_body    text;
  v_wrap    text;
begin
  select count(*) into v_rows from erp_meta.check_cadence;
  if v_rows <> 5 then
    raise exception 'CLOVEERP_CADENCE_REGISTER_UNEXPECTED: % row(s) in erp_meta.check_cadence, expected 5', v_rows
      using errcode = '23514',
            hint = 'This migration registers five suites and no other; a different count is a different change.';
  end if;

  for k in select schema_name, function_name from erp_meta.check_cadence order by 1, 2 loop
    select c.phase into v_phase
      from erp.ci_check_catalogue() c
     where c.schema_name = k.schema_name and c.function_name = k.function_name;
    if v_phase is distinct from 'suite' then
      raise exception
        'CLOVEERP_CADENCE_NOT_A_SUITE: %.% is registered for the nightly and is % in erp.ci_check_catalogue()',
        k.schema_name, k.function_name, coalesce('phase ' || v_phase, 'not')
        using errcode = '23503',
              hint = 'Only a suite the catalogue walks may wait for the nightly. Take the row out or give the check its shape back.';
    end if;
    raise notice 'the nightly owes %.%, and the catalogue walks it as a %', k.schema_name, k.function_name, v_phase;
  end loop;

  v_body := pg_get_functiondef('erp_test.ci_coverage_suite()'::regprocedure);
  v_wrap := pg_get_functiondef('erp_test.assert_ci_coverage_suite()'::regprocedure);
  if position('v_cases <> 14' in v_body) = 0 or position('v_all <> 14' in v_wrap) = 0 then
    raise exception 'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.ci_coverage_suite() and its wrapper must both pin 14 cases'
      using errcode = '23514',
            hint = 'A suite that loses a case reports success. Pin the same number inside the suite and in the wrapper.';
  end if;
end
$cadence$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ── Proved ───────────────────────────────────────────────────────────────────
--
-- The ordinary schema proof, at the cost of the schema's size. No suite is run
-- from here; the catalogue runs erp_test.ci_coverage_suite() on the build.

select erp.assert_whole_database_reconciles();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
