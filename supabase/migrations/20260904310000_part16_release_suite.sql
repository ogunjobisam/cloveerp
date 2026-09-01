-- =============================================================================
-- Part 16 — the adversarial suite
--
-- §16.5's sentence is the one worth attacking: "Restore is proved by drill, not
-- by log ... verified by running the invariant assertions against the restored
-- data ... A backup that has never been restored is a hope."
--
-- The failure mode that sentence describes is not an absent drill. It is a
-- drill that RAN, was recorded as passed, and proved nothing — because it
-- restored bytes and checked none of them. That is the shape that looks green
-- on a dashboard and is worthless in an incident, so it is what the suite tries
-- hardest to record.
--
-- The register is platform-level and has no tenant, so this suite provisions
-- nothing. It writes to erp_meta directly, cleans up by code prefix, and leaves
-- the shipped commitments untouched.
-- =============================================================================

create or replace function erp_test.release_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_ok boolean; v_msg text; v_id uuid; v_count integer;
begin
  -- ── §16.1 the ladder ──────────────────────────────────────────────────────

  return query select 'every tier can be rebuilt from nothing',
    not exists (select 1 from erp_ref.environment_tier t where not t.rebuilt_from_empty),
    '§16.1: if it cannot be rebuilt from nothing, it is not an environment';

  return query select 'and only live holds real data',
    (select count(*) from erp_ref.environment_tier t where t.holds_real_data) = 1
      and (select t.code from erp_ref.environment_tier t where t.holds_real_data) = 'live',
    'test carries every organisation''s test environment, not its live data';

  return query select 'continuous integration is not long-lived',
    (select not t.is_long_lived from erp_ref.environment_tier t where t.code = 'ci'),
    '§16.1: the only place a green result means anything, because it has no accumulated state';

  -- ── §16.5 a drill that proves nothing must not be recordable as passed ────

  insert into erp_meta.continuity_commitment
    (code, title, commitment, drill_cadence_days, derived_from, seq)
  values ('zztest_commitment', 'Suite commitment', 'A commitment the suite drills.',
          30, 'suite', 9000);

  begin
    insert into erp_meta.restore_drill
      (commitment_code, restored_from, restored_to, outcome, finished_at)
    values ('zztest_commitment', 'backup-2026-09-01', 'isolated-1', 'passed', now());
    v_ok := false; v_msg := 'a passed drill that ran no assertions was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'a drill cannot pass without running assertions', v_ok, v_msg;

  begin
    insert into erp_meta.restore_drill
      (commitment_code, restored_from, restored_to, assertions_run,
       assertions_passed, assertions_failed, outcome, finished_at)
    values ('zztest_commitment', 'backup-2026-09-01', 'isolated-1',
            '{erp.assert_isolation,erp.assert_stock_reconciles}', 1, 1, 'passed', now());
    v_ok := false; v_msg := 'a passed drill with a failed assertion was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'nor with an assertion that failed', v_ok, v_msg;

  begin
    insert into erp_meta.restore_drill
      (commitment_code, restored_from, restored_to, assertions_run,
       assertions_passed, assertions_failed, outcome)
    values ('zztest_commitment', 'backup-2026-09-01', 'isolated-1',
            '{erp.assert_isolation}', 1, 0, 'passed');
    v_ok := false; v_msg := 'a passed drill that never finished was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'nor one that never finished', v_ok, v_msg;

  begin
    insert into erp_meta.restore_drill
      (commitment_code, restored_from, restored_to, outcome, finished_at)
    values ('zztest_commitment', 'backup-2026-09-01', 'isolated-1', 'failed', now());
    v_ok := false; v_msg := 'a failed drill with no note was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'and a failed drill must say what happened', v_ok, v_msg;

  -- ── §16.5 what a real drill looks like ────────────────────────────────────

  insert into erp_meta.restore_drill
    (commitment_code, restored_from, restored_to, assertions_run,
     assertions_passed, assertions_failed, outcome, started_at, finished_at)
  values ('zztest_commitment', 'backup-2026-09-01', 'isolated-1',
          '{erp.assert_isolation,erp.assert_stock_reconciles,erp.assert_subledger_reconciles}',
          3, 0, 'passed', now() - interval '2 days', now() - interval '2 days' + interval '40 minutes')
  returning id into v_id;

  return query select 'a drill that restored and verified is recorded',
    v_id is not null, 'three invariant assertions against the restored data';

  return query select 'and the commitment reads as proved',
    (select r.state from erp.continuity_report() r
      where r.commitment_code = 'zztest_commitment') = 'proved',
    coalesce((select r.state from erp.continuity_report() r
               where r.commitment_code = 'zztest_commitment'), '(none)');

  -- ── §16.5 overdue, and never ──────────────────────────────────────────────

  update erp_meta.restore_drill
     set started_at = now() - interval '100 days',
         finished_at = now() - interval '100 days' + interval '40 minutes'
   where id = v_id;

  return query select 'a drill older than the cadence reads as overdue',
    (select r.state from erp.continuity_report() r
      where r.commitment_code = 'zztest_commitment') = 'overdue',
    'proved by drill on a stated cadence, not by the existence of a backup';

  insert into erp_meta.continuity_commitment
    (code, title, commitment, drill_cadence_days, derived_from, seq)
  values ('zztest_never', 'Never drilled', 'A commitment nobody has drilled.',
          30, 'suite', 9001);

  return query select 'and a commitment never drilled says so plainly',
    (select r.state from erp.continuity_report() r
      where r.commitment_code = 'zztest_never') = 'never drilled',
    '§16.5: a backup that has never been restored is a hope';

  -- ── The assertion still holds, and a hollow drill would break it ──────────

  return query select 'the release assertion passes',
    erp.assert_release_integrity() is not null, 'no findings';

  -- Force the state the constraint prevents, to prove the assertion would
  -- catch a row that predated the constraint.
  alter table erp_meta.restore_drill drop constraint restore_drill_passed_ran_assertions;
  insert into erp_meta.restore_drill
    (commitment_code, restored_from, restored_to, outcome, finished_at)
  values ('zztest_commitment', 'backup-old', 'isolated-old', 'passed', now());

  begin
    perform erp.assert_release_integrity();
    v_ok := false; v_msg := 'a hollow drill passed the assertion';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_RELEASE_INTEGRITY%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and would catch a hollow drill the constraint did not stop',
    v_ok, v_msg;

  delete from erp_meta.restore_drill where restored_from = 'backup-old';
  alter table erp_meta.restore_drill
    add constraint restore_drill_passed_ran_assertions
    check (outcome <> 'passed'
           or (cardinality(assertions_run) > 0
               and coalesce(assertions_failed, 0) = 0
               and finished_at is not null));

  -- ── Clean up ──────────────────────────────────────────────────────────────

  delete from erp_meta.restore_drill where commitment_code like 'zztest%';
  delete from erp_meta.continuity_commitment where code like 'zztest%';

  select count(*) into v_count from erp_meta.continuity_commitment where code like 'zztest%';
  return query select 'the suite leaves nothing behind',
    v_count = 0 and erp.assert_release_integrity() is not null,
    'and the shipped commitments are untouched';
end;
$$;

comment on function erp_test.release_suite is
  'Specification v1.2 Part 16, proven adversarially. The attack is not an absent '
  'drill but a hollow one: recorded as passed, having restored bytes and checked '
  'none of them. That is the shape that looks green and is worthless in an '
  'incident, so it is refused four different ways.';

create or replace function erp_test.assert_release_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _release_result on commit drop as
    select * from erp_test.release_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _release_result;

  if v_total <> 14 then
    raise exception 'ERPWARE_RELEASE_SUITE_SHRANK: % case(s), expected 14', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_RELEASE_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('release: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_release_suite();
