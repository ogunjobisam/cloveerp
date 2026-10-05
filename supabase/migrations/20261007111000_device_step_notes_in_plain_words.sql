set lock_timeout = '30s';

-- =============================================================================
-- 20261007111000  Device step notes in plain words
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-115). Settings,
-- Devices and scanning, showed internal language: "§14 expects", "The build
-- fails if a step has neither" and each step's database function
-- (erp.receive_against) came from the screen, and the Note column read
-- erp_ref.device_task_handler, whose notes and reasons named a design
-- decision ("D10's evented amendment"), a specification section ("§14.3 says
-- so"), database functions (erp.raise_putaway_tasks(), erp.plan_shipment(),
-- erp.raise_replenishment_tasks()) and a migration version. A reason is also
-- what a device's queued action is told when nothing applies it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Seven rows of erp_ref.device_task_handler say the same thing in plain
--      words: the notes of batch_action, carton_receipt, putaway and
--      replenishment, and the reasons of pack, short_pick and stock_enquiry.
--      What each step applies through, its arguments and whether it writes
--      are unchanged. Each row changes only while it still reads as it did.
--   B. erp.device_task_handler_report() also finds a note or reason that
--      names a specification section, a design decision, a database function
--      or a migration version, so erp.assert_device_task_handlers_sound(),
--      which the build runs, refuses one written later.
--   C. erp_test.device_step_notes_suite.
--
-- The screen's half is in src/routes/operations/devices.tsx: its own two
-- descriptions and empty text are reworded, and a step's database function is
-- no longer printed under its module.
--
-- On production: product data, the same for every organisation; seven rows of
-- erp_ref.device_task_handler are reworded and one report gains a finding. No
-- table is altered and no organisation's rows are touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The notes and reasons in plain words
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.device_task_handler
   set note = 'Stock. Quarantine and block change the batch''s status, with a reason, and the change is recorded. Split, merge and release each have their own screen.'
 where device_task_code = 'batch_action'
   and note = 'Stock. Quarantine and block are a status amendment under a reason, which is D10''s evented amendment. Split, merge and release each have their own function and their own screen.';

update erp_ref.device_task_handler
   set note = 'Inbound. A notified carton by the SSCC on its label: what its notice says it holds, received.'
 where device_task_code = 'carton_receipt'
   and note = 'A notified carton by the SSCC on its label: what its notice says it holds, received (20261005000000).';

update erp_ref.device_task_handler
   set note = 'Inbound. Confirms the destination scan against the putaway task raised for the receipt; a task already done or cancelled is refused by name.'
 where device_task_code = 'putaway'
   and note = 'Inbound. Confirms the destination scan against the putaway task erp.raise_putaway_tasks() raised; a task already done or cancelled is refused by name.';

update erp_ref.device_task_handler
   set note = 'Stock. Confirms the destination scan against the replenishment task raised for the pick face.'
 where device_task_code = 'replenishment'
   and note = 'Stock. Confirms the destination scan against the task erp.raise_replenishment_tasks() raised.';

-- A reason follows "nothing yet applies a pack captured on a device:" in the
-- action's conflict, so it starts in lower case, as it did.
update erp_ref.device_task_handler
   set not_handled_reason = 'packing has no record of its own yet: a shipment is planned from its deliveries, and checking the contents against the order, capturing carton and weight, and printing the label are captured on the device and wait for something to record them'
 where device_task_code = 'pack'
   and not_handled_reason = 'packing has no record of its own yet: a shipment is planned from deliveries by erp.plan_shipment(), and scan-verifying contents against the order, capturing carton and weight, and printing the label are captured on the device and wait for a function to land them';

update erp_ref.device_task_handler
   set not_handled_reason = 'a short pick raises an exception against the pick line and triggers replenishment where stock exists elsewhere; replenishment tasks can be raised, but nothing yet records the shortage against the line it was short on'
 where device_task_code = 'short_pick'
   and not_handled_reason = 'a short pick raises an exception against the pick line and triggers replenishment where stock exists elsewhere; erp.raise_replenishment_tasks() exists, and nothing yet records the shortage against the line it was short on';

update erp_ref.device_task_handler
   set not_handled_reason = 'a stock enquiry shows a position and writes nothing, so a device that queues one has mistaken a read for a write'
 where device_task_code = 'stock_enquiry'
   and not_handled_reason = 'a stock enquiry shows a position and writes nothing; §14.3 says so, and a device that queues one has mistaken a read for a write';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The register's report refuses internal language
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig  constant text := 'erp.device_task_handler_report()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$
  order by 1, 2
$o$;
  v_new  constant text := $n$
  union all

  -- 6. A note or reason is read by the people who scan: on the Devices and
  --    scanning screen, and in the conflict a queued action is told. It names
  --    no specification section, design decision, database function or
  --    migration version (20261007111000, J-115).
  select 'a handler''s words name something only its builders know', h.device_task_code,
         concat_ws(' / ', h.note, h.not_handled_reason)
    from h
   where concat_ws(' ', h.note, h.not_handled_reason)
         ~ '§|\mD[0-9]+\M|\merp[a-z_]*\.|[a-z_]\(\)|[0-9]{14}'

  order by 1, 2
$n$;
begin
  if strpos(v_src, '20261007111000') > 0 then
    raise notice '% already refuses internal language; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4d9253d2af218b4d1d55d33dd2a06657' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007111000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$report$;

comment on function erp.device_task_handler_report() is
  'Checks erp_ref.device_task_handler against erp_ref.device_task and pg_proc: every task has a row, every function '
  'named exists once, every argument is in the right position with the right name and type, and no note or reason '
  'names a specification section, design decision, database function or migration version (20261007111000, J-115). '
  'Read by erp.assert_device_task_handlers_sound().';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.device_step_notes_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  c_words    constant text := '§|\mD[0-9]+\M|\merp[a-z_]*\.|[a-z_]\(\)|[0-9]{14}';
  v_cases    integer := 0;
  v_step     text := 'reading the register';
  v_state    text;
  v_door     jsonb;
  v_bad      text;
  v_found    text;
begin
  begin
    -- ── 1. Every note and reason is in plain words, as the screen reads it ───
    v_door := public.erp_device_task_handlers();
    select string_agg(x ->> 'code', ', ') into v_bad
      from jsonb_array_elements(v_door) x
     where concat_ws(' ', x ->> 'note', x ->> 'not_handled_reason') ~ c_words;
    v_cases := v_cases + 1;
    case_name := 'no step''s note or reason names a section, decision, function or version, and the report agrees';
    passed := jsonb_array_length(v_door) > 0 and v_bad is null
          and not exists (select 1 from erp.device_task_handler_report() r
                           where r.finding = 'a handler''s words name something only its builders know');
    detail := coalesce(v_state, format('%s step(s); in internal language: %s', jsonb_array_length(v_door),
                coalesce(v_bad, 'none')));
    return next;

    -- ── 2. A note naming a section is found ──────────────────────────────────
    v_step := 'a note that names a section';
    update erp_ref.device_task_handler set note = note || ' As §14.3 says.'
     where device_task_code = 'pick';
    select string_agg(r.reference, ', ') into v_found from erp.device_task_handler_report() r
     where r.finding = 'a handler''s words name something only its builders know';
    v_cases := v_cases + 1;
    case_name := 'a note that names a specification section is a finding the build fails on';
    passed := v_found = 'pick';
    detail := coalesce(v_state, format('found against %s', coalesce(v_found, 'nothing')));
    return next;

    -- ── 3. A reason naming a function is found ───────────────────────────────
    v_step := 'a reason that names a function';
    update erp_ref.device_task_handler set note = replace(note, ' As §14.3 says.', '')
     where device_task_code = 'pick';
    update erp_ref.device_task_handler
       set not_handled_reason = not_handled_reason || ', which erp.plan_shipment() does not'
     where device_task_code = 'pack';
    select string_agg(r.reference, ', ') into v_found from erp.device_task_handler_report() r
     where r.finding = 'a handler''s words name something only its builders know';
    v_cases := v_cases + 1;
    case_name := 'a reason that names a database function is a finding the build fails on';
    passed := v_found = 'pack';
    detail := coalesce(v_state, format('found against %s', coalesce(v_found, 'nothing')));
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEVICE_STEP_NOTES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp_ref.device_task_handler h
              where concat_ws(' ', h.note, h.not_handled_reason) ~ '§14\.3 says\.|erp\.plan_shipment\(\) does not') then
    raise exception 'CLOVEERP_DEVICE_STEP_NOTES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it changed rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.device_step_notes_suite() from public, anon;

comment on function erp_test.device_step_notes_suite() is
  'Device step notes in plain words (20261007111000, J-115): no step''s note or reason, as the screen reads them, '
  'names a specification section, design decision, database function or migration version; and a note or reason '
  'written later that does is a finding of erp.device_task_handler_report(), which the build fails on.';

create or replace function erp_test.assert_device_step_notes_suite()
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
    from erp_test.device_step_notes_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEVICE_STEP_NOTES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A device step''s note would show the scanner internal language. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DEVICE_STEP_NOTES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('device step notes in plain words: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_device_step_notes_suite() from public, anon;

comment on function erp_test.assert_device_step_notes_suite() is
  'Device step notes and reasons are in plain words, and the build refuses one that is not (20261007111000).';

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
select erp.assert_device_task_handlers_sound();
