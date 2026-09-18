set lock_timeout = '30s';

-- =============================================================================
-- 20260920300000  The demonstration catches up outside the migration
-- -----------------------------------------------------------------------------
-- EDITED IN PLACE ON 18 SEPTEMBER, AFTER IT TOOK THE DEPLOY DOWN A SECOND TIME.
-- The first version of this file ended by running
-- erp_test.assert_demonstration_catch_up_suite(), and on the deploy that
-- carried it the replay stopped there:
--
--   ERROR: canceling statement due to statement timeout (SQLSTATE 57014)
--   At statement: 13   select erp_test.assert_demonstration_catch_up_suite()
--
-- The suite stands up a demonstration organisation of its own and runs the
-- whole catch-up against it. On a build from an empty database that fixture is
-- small and the suite takes 46 s. On a database with three organisations and a
-- year of trading it is not small, and it ran past the configured two-minute
-- limit. Nothing about the suite is wrong; it was in the wrong place.
--
-- THAT IS THE THIRD TIME IN TWO DAYS THAT ONE SHAPE HAS TAKEN A DEPLOY DOWN,
-- and it is worth naming rather than only fixing. Cheap in CI, expensive on
-- live: the settings check that scanned every routine body (20260920010000),
-- the catch-up writing journals before the generators (20260920250000), and now
-- a suite whose fixture is small on an empty database and not on a real one.
-- Every time, what made it invisible was that the build and production run
-- different amounts of work through the same statement, so the build's green is
-- evidence about the build and not about production. The question to ask of
-- every statement in a migration is not "does this pass" but "how much work is
-- this on a database with a year of trading in it". This file now answers that
-- question for each of its own, at the foot.
--
-- A suite is the clearest case of all, because a suite BUILDS ITS FIXTURE: its
-- cost is not the schema's size, it is whatever the fixture does, and the
-- fixture is built to be realistic. erp.ci_check_catalogue() picks up every
-- erp_test.assert_%() taking no arguments, so a suite is already run by every
-- build without a migration asking for it. A migration asserts its own
-- governance; it does not need to re-run a behavioural suite at deploy time.
-- 20260919010000 on 17 September is the same lesson with a different suite.
--
-- Registered in supabase/ci/migrations_edited.txt against 20260920310000.
-- 20260920250000, which this file's own head discusses below, HAS now applied
-- on production and is immutable from here.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- 20260920250000 brought every demonstration organisation up to date in its own
-- transaction and then, as every migration does, re-ran the generators. On the
-- first real deploy the replay stopped on it:
--
--   ERROR: cannot ALTER TABLE "journal" because it has pending trigger events
--          (SQLSTATE 55006)
--   At statement: 14   select erp.apply_row_security()
--
-- erp.apply_row_security() issues ALTER TABLE on erp.journal, and PostgreSQL
-- refuses that while the table carries deferred trigger events left by writes
-- earlier in the same transaction. Five months of trading is thousands of
-- journal rows, so the events were there and the ALTER could not run. The
-- deploy stopped at that migration with everything before it recorded and
-- nothing after it applied, and it would have stopped there again on every
-- deploy after it: the file cannot be repaired forward, because a later
-- migration cannot reach inside a transaction that aborts before it.
--
-- So 20260920250000 is edited in place and registered in
-- supabase/ci/migrations_edited.txt against this file. What it kept is a
-- routine, a refusal and a suite — a schema change like any other. What it lost
-- is the running of the routine, which is what this file gives a home to.
--
-- ── WHY CI SAID YES ──────────────────────────────────────────────────────────
--
-- Worth writing down, because a ten-case suite had been added to that file for
-- exactly this class of mistake and it did not catch this one.
--
-- The suite proves the ROUTINE. It stands up an organisation, runs
-- erp.demonstration_catch_up() on it and holds it to what changed. It cannot
-- prove the shape of the FILE — writes, then the generators, in one transaction
-- — because a suite's fixture lives in a subtransaction it rolls back, and
-- nothing runs the generators after it. And on a build from an empty database
-- there is no organisation whose name begins 'demo-' at migration time, so the
-- catching up wrote nothing, no trigger events were pending, and the ALTER
-- succeeded. Both halves were green and the two halves were never joined.
--
-- The general lesson, which is why this file exists rather than a one-line
-- SET CONSTRAINTS: a suite proves what a routine does, not what the file around
-- it does. Where the two differ, move the work until they do not. Writing a
-- demonstration's recent history is not a schema change and has no business in
-- a schema change's transaction, whatever it would take to make the transaction
-- tolerate it.
--
-- ── WHAT WAS WEIGHED ─────────────────────────────────────────────────────────
--
-- SET CONSTRAINTS ALL IMMEDIATE before the generators. One line, and it works:
-- the deferred events fire and the table becomes alterable. Rejected because it
-- is unprovable for the same reason the original was — on a build there are no
-- writes, so the statement is a no-op and the shape stays unexercised — and
-- because it keeps minutes of data writing inside the transaction that holds
-- the schema generators open, which is a large thing to hold for a
-- demonstration's benefit.
--
-- Not running the generators in a migration that changes no schema. True of the
-- file as it now stands, and it would have avoided this. Rejected as the fix,
-- because the convention exists so that a schema change cannot escape them, and
-- deciding case by case which migration is "really" a schema change is how one
-- eventually escapes. 20260920250000 does declare three routines, so it does
-- need erp.apply_execute_grants(); the honest repair is to take the data
-- writing out, not the generators.
--
-- Doing it somewhere that is not a migration at all. Taken. A deploy step is
-- where the build already puts work of this kind — supabase/ci/close_month.sh
-- closes a month through the doors, outside any migration — and it is the only
-- home that also answers the thing this was always going to be wrong about:
-- a migration runs once, so a demonstration it brings up to today is a month
-- stale a month later. A step on the deploy brings it up to the day of every
-- deploy. The first run carries the five months; every run after it carries the
-- days since the last one, which is seconds.
--
-- ── WHAT THIS ADDS ───────────────────────────────────────────────────────────
--
-- erp.catch_up_demonstrations(p_code), which the deploy calls with no argument:
-- for every active organisation whose name begins 'demo-', it finds somebody
-- signed in there who holds what the routine needs, acts as them, checks the
-- organisation it actually resolved to is the one it meant, and calls
-- erp.demonstration_catch_up(). It returns what each one answered and it raises
-- nothing: an organisation that refuses is reported and the next one is tried,
-- because this is demonstration hygiene and a red deploy blocks every branch.
--
-- The argument is for the suite, and only for the suite. Unfiltered, this reads
-- every demonstration on the database, which on live is the real one; a suite
-- that called it that way from inside a migration would do the whole catch-up
-- on the demonstration and then throw it away with its fixture. Named, it
-- touches one organisation. The deploy never passes it.
--
-- Proof: erp_test.demonstration_catch_up_suite() gains two cases, patched into
-- the deployed body rather than restated, and the count guard at both ends
-- moves from ten to twelve. Case 11 calls the caller on the fixture after the
-- routine has already brought it up to date and holds it to finding the
-- organisation, reporting on it and changing nothing — which is every deploy
-- after the first. Case 12 renames the fixture and holds the caller to not
-- offering it to the routine at all.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The caller
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.catch_up_demonstrations(p_code text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- What erp.demonstration_catch_up() needs of the person it acts as. An
  -- organisation whose administrator does not hold all of these is left alone
  -- rather than acted on by the deploy's own role, which holds nothing and
  -- would prove nothing.
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  v_admin  uuid;
  v_out    jsonb := '[]'::jsonb;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
              and (p_code is null or tn.code = p_code)
            order by tn.code
  loop
    begin
      v_admin := null;

      select u.auth_user_id into v_admin
        from erp.app_user u
       where u.tenant_id = t.id
         and u.kind = 'person'::erp.principal_kind
         and u.status = 'active'::erp.principal_status
         and u.auth_user_id is not null
         and (select count(distinct rp.permission_code)
                from erp.user_role ur
                join erp.role r
                  on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                 and r.status = 'active'::erp.record_status
                join erp.role_permission rp
                  on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
               where ur.tenant_id = u.tenant_id
                 and ur.app_user_id = u.id
                 and (ur.valid_from is null or ur.valid_from <= current_date)
                 and (ur.valid_to is null or ur.valid_to >= current_date)
                 and rp.permission_code = any (v_needs)) = array_length(v_needs, 1)
       order by u.created_at, u.id
       limit 1;

      if v_admin is null then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'organisation', t.code,
          'notes', jsonb_build_array(format(
            'Nobody signed in there holds all of %s, so it was left as it was.',
            array_to_string(v_needs, ', ')))));
        continue;
      end if;

      -- As that administrator, in that organisation, transaction-local, the way
      -- supabase/ci/close_month.sh and supabase/ci/seed_demo.sql do it.
      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);

      -- The context that administrator actually resolves to is the one this
      -- writes in. Somebody who belongs to two organisations would otherwise
      -- carry this work into whichever one the database picked, and a
      -- demonstration repair has no business anywhere it was not aimed.
      if erp.current_tenant_id() is distinct from t.id then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'organisation', t.code,
          'notes', jsonb_build_array(
            'Signing in as its administrator resolves to another organisation, so nothing was done there.')));
        continue;
      end if;

      v_out := v_out || jsonb_build_array(erp.demonstration_catch_up());

    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'organisation', t.code,
        'notes', jsonb_build_array(format(
          'It was left as it was, because bringing it up to date refused. %s', sqlerrm))));
    end;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$$;

comment on function erp.catch_up_demonstrations(text) is
  'Brings every demonstration organisation up to today, as an administrator of '
  'each, and answers with what each one did. Raises nothing: an organisation '
  'that refuses is reported and the next one is tried. The deploy calls it with '
  'no argument; the argument names one organisation, which is what the suite '
  'needs and the deploy never wants.';

revoke all on function erp.catch_up_demonstrations(text) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Two more cases, patched into the body that is deployed
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Restating the suite would drop whatever else has been patched into it since
-- 20260920250000 wrote it. Read the deployed body, name what is expected of it,
-- and change that.

do $cases$
declare
  v_sig  constant text := 'erp_test.demonstration_catch_up_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_n    constant text := E'  raise exception ''CLOVEERP_SUITE_UNDO'';\n';
  v_r    constant text := $r$  -- ── 11. The caller finds it, and on every deploy after the first there
  --        is nothing left for it to do ─────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_docs from erp.document d where d.tenant_id = v_tenant;
  v_called := erp.catch_up_demonstrations('demo-zzcatchup');
  select count(*) into v_docs_again from erp.document d where d.tenant_id = v_tenant;
  case_name := 'the caller the deploy runs finds the demonstration, acts as its administrator, reports on it, and on an organisation already up to date changes nothing';
  passed := jsonb_array_length(v_called) = 1
        and v_called -> 0 ->> 'organisation' = 'demo-zzcatchup'
        and (v_called -> 0 ->> 'documents_built')::integer = 0
        and (v_called -> 0 ->> 'bills_raised')::integer = 0
        and (v_called -> 0 ->> 'periods_closed')::integer = 0
        and v_docs_again = v_docs;
  detail := format('%s report(s); %s document(s) before, %s after; %s',
                   jsonb_array_length(v_called), v_docs, v_docs_again,
                   (v_called -> 0) - 'notes');
  return next;

  -- ── 12. And it does not offer the routine what is not a demonstration ─────
  v_cases := v_cases + 1;
  update erp.tenant set code = 'zzcatchup' where id = v_tenant;
  v_called := erp.catch_up_demonstrations('zzcatchup');
  case_name := 'an organisation whose name does not begin demo- is never offered to the routine at all, so the refusal is the second guard and not the first';
  passed := jsonb_array_length(v_called) = 0;
  detail := format('%s report(s) for a name that is not a demonstration''s', jsonb_array_length(v_called));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
$r$;
  v_hits integer;
begin
  if position('catch_up_demonstrations' in v_def) > 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % already calls the caller; this migration would add its cases twice', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new migration version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % undoes its fixture % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  -- The two variables the new cases need, and the count guard at the far end.
  v_def := replace(v_def, E'  v_ok boolean; v_msg text; v_fixture text;\n',
                          E'  v_ok boolean; v_msg text; v_fixture text;\n  v_called jsonb;\n');
  if position('v_called jsonb;' in v_def) = 0 then
    raise exception
      'CLOVEERP_SUITE_UNRECOGNISED: % does not declare its variables where this migration expects', v_sig
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_def := replace(v_def, v_n, v_r);
  v_def := replace(v_def,
    'if v_cases <> 10 then',
    'if v_cases <> 12 then');
  v_def := replace(v_def,
    'demonstration_catch_up_suite ran % cases, expected 10',
    'demonstration_catch_up_suite ran % cases, expected 12');

  execute v_def;
end
$cases$;

-- And the wrapper counts to twelve as well, or a suite that lost a case would
-- report success from one end while the other end said nothing.
do $wrapper$
declare
  v_def text := pg_get_functiondef('erp_test.assert_demonstration_catch_up_suite()'::regprocedure);
begin
  if position('expected 10' in v_def) = 0 then
    raise exception
      'CLOVEERP_WRAPPER_UNRECOGNISED: erp_test.assert_demonstration_catch_up_suite() does not pin ten cases'
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;
  execute replace(replace(v_def, 'v_all <> 10', 'v_all <> 12'), 'expected 10', 'expected 12');
end
$wrapper$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generators, then the assertions
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
-- Nothing here writes a row of anybody's ledger either, which is the whole
-- point: the generators run after a schema change and nothing else.
--
-- The suite is NOT run from here, and that is the second edit this file has
-- taken (see the head of the file). It is in erp.ci_check_catalogue() by name,
-- so every build runs it; 20260920310000 asserts that, which is the claim that
-- makes leaving it out of this file safe rather than merely cheaper.
--
-- What is left, timed on live on 18 September against three organisations and a
-- year of trading, inside a transaction that was rolled back:
--
--   erp.assert_isolation()                    1,156 ms
--   erp.assert_public_api_safe()              1,511 ms
--   erp.assert_ci_coverage()                    154 ms
--   erp.assert_suite_verdicts_strict()            7 ms
--   erp.assert_whole_database_reconciles()    1,740 ms   3 organisations, 54 checks
--                                             ─────────
--                                             4,568 ms
--
-- The reconciliation was the one to suspect and it is not the problem: it grows
-- with the ledger, but 1.7 s against a two-minute limit leaves room for the
-- ledger to grow a great deal. It stays, because it is the only assertion here
-- that would notice a data fault, and because a migration that drops it to save
-- a second and a half is saving the wrong second. The other four are schema
-- introspection: their cost is the size of the schema, which is the same on
-- every database.
--
-- The generators above are not timed here on purpose. They take access
-- exclusive locks across hundreds of objects, so measuring them on live even in
-- a transaction that rolls back would block the application for the duration.
-- Their evidence is that every migration ends with them and every deploy has
-- run them.

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
