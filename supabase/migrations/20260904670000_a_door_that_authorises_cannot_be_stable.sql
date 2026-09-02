-- ─────────────────────────────────────────────────────────────────────────────
-- A public door that authorises cannot be STABLE.
--
-- The onboarding interview showed "0 of 0 questions answered" against a
-- question bank of nineteen. Nothing was wrong with the data, the row-level
-- security, the grants or the permission: the door itself could not run.
--
-- PostgREST executes a function declared STABLE or IMMUTABLE inside a
-- READ ONLY transaction. That is a sound optimisation and it is what the
-- volatility declaration asks for. But erp.authorise() is not a read: §18.3
-- has it record every access decision — granted or refused — through
-- erp.log_access_decision(), which inserts into erp.access_log. So the first
-- thing a STABLE door does is write, and PostgreSQL refuses:
--
--   [25006] cannot execute INSERT in a read-only transaction
--
-- The door fails for every caller, including one holding the permission. It
-- fails identically whether the answer would have been yes or no, which is
-- why this looked like an empty question bank rather than a refusal.
--
-- Note what does NOT reproduce it: calling the door from ordinary SQL, or
-- from a suite, or from psql. There the transaction is read-write and the
-- insert succeeds. Only the deployed path — PostgREST reading the volatility
-- and opening a read-only transaction — is broken, which is why every
-- assertion and every suite passed over this for months.
--
-- Six doors were declared STABLE and call erp.authorise(). They are made
-- VOLATILE here. Nothing else about them changes: same body, same gate, same
-- grants. VOLATILE is the honest declaration for a function that writes an
-- audit row, and it costs a read-write transaction, which is what the write
-- needs anyway.
--
-- erp.assert_authorising_doors_are_volatile() keeps the class closed. The
-- alternative fix — making the doors not authorise — is worse: it would trade
-- a visible failure for an unlogged access decision, and §18.3 wants the log.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The six ──────────────────────────────────────────────────────────────────

alter function public.erp_commercial_renewals() volatile;
alter function public.erp_interview_questions(p_session_id uuid) volatile;
alter function public.erp_opening_balance_reconciliation(p_batch_id uuid) volatile;
alter function public.erp_pack_plan(p_pack_code text) volatile;
alter function public.erp_render_output_template(p_code text, p_document_id uuid, p_locale text) volatile;
alter function public.erp_report_extract_content(p_run_id uuid) volatile;

-- Making them volatile makes them writers in the eyes of
-- erp.assert_public_api_safe(), which is correct and is the register working:
-- a door that may write is registered with the gate it writes behind. The
-- write is the access-log row and nothing else — each of these reads, and the
-- gate is the authorisation that records having been asked.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_interview_questions', 'erp.authorise',
   'A read. Volatile because erp.authorise() records the access decision (§18.3), and a stable declaration would put that write inside PostgREST''s read-only transaction.'),
  ('erp_commercial_renewals', 'erp.authorise',
   'A read of the renewals due. Volatile for the access-log row erp.authorise() writes; nothing else in it writes.'),
  ('erp_opening_balance_reconciliation', 'erp.authorise',
   'A read of one cutover batch''s reconciliation. Volatile for the access-log row erp.authorise() writes.'),
  ('erp_render_output_template', 'erp.authorise',
   'Renders a template for one document and returns it. Volatile for the access-log row erp.authorise() writes; the render is not stored.'),
  ('erp_report_extract_content', 'erp.authorise',
   'Returns the content of one recorded extract run. Volatile for the access-log row erp.authorise() writes.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ── The report ───────────────────────────────────────────────────────────────

create or replace function erp.authorising_door_report()
returns table (door text, volatility text, finding text)
language sql
stable
set search_path = ''
as $$
  select n.nspname || '.' || p.proname
           || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         case p.provolatile when 's' then 'stable' when 'i' then 'immutable' else 'volatile' end,
         'a public door calls erp.authorise(), which writes an access-log row, '
         'but is declared ' || case p.provolatile when 's' then 'stable' else 'immutable' end
           || ', so PostgREST runs it in a read-only transaction and every call fails'
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.provolatile in ('s', 'i')
     and p.prosrc ~ 'erp\.authorise\s*\('
   order by 1;
$$;

comment on function erp.authorising_door_report is
  'Public doors that authorise and are declared non-volatile. PostgREST runs '
  'those in a read-only transaction, and erp.authorise() records the decision '
  'in erp.access_log, so the call raises 25006 for every caller.';

create or replace function erp.assert_authorising_doors_are_volatile()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_doors    integer;
  v_auth     integer;
begin
  select count(*), string_agg(format('  %s [%s]', r.finding, r.door), E'\n' order by r.door)
    into v_count, v_findings
    from erp.authorising_door_report() r;
  if v_count > 0 then
    raise exception E'ERPWARE_AUTHORISING_DOOR_NOT_VOLATILE: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Declare the door volatile. A function that records an access decision writes, and PostgREST honours the volatility by opening a read-only transaction for a stable one.';
  end if;

  select count(*), count(*) filter (where p.prosrc ~ 'erp\.authorise\s*\(')
    into v_doors, v_auth
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'erp\_%';

  return format('doors: %s public entry points, %s authorise and every one of those is volatile',
                v_doors, v_auth);
end;
$$;

comment on function erp.assert_authorising_doors_are_volatile is
  'Fails when a public door calls erp.authorise() and is declared stable or '
  'immutable. Such a door raises 25006 through PostgREST and nowhere else, so '
  'nothing but this notices it.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('authorising_doors', 'A door that authorises is volatile', 'assertion', 'platform',
   'erp', 'assert_authorising_doors_are_volatile', '', 'authorising_door_report', '',
   'erp.authorise() records every access decision, so it writes. PostgREST runs a function declared stable inside a read-only transaction, where that write raises. A door that authorises must therefore be volatile, and this checks that every one is.',
   true, 76)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name, arguments = excluded.arguments,
  detail_function = excluded.detail_function, detail_arguments = excluded.detail_arguments,
  blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.authorising_doors_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_msg text;
begin
  return query select 'no public door authorises from a non-volatile declaration',
    (select count(*) from erp.authorising_door_report()) = 0,
    format('%s finding(s)', (select count(*) from erp.authorising_door_report()));

  v_msg := erp.assert_authorising_doors_are_volatile();
  return query select 'the assertion counts the doors rather than asserting silence',
    v_msg ~ '^doors: \d+ public entry points, \d+ authorise and every one of those is volatile', v_msg;

  return query select 'the six doors this repaired are volatile',
    not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.provolatile <> 'v'
         and p.proname in ('erp_commercial_renewals', 'erp_interview_questions',
                           'erp_opening_balance_reconciliation', 'erp_pack_plan',
                           'erp_render_output_template', 'erp_report_extract_content')),
    'erp_interview_questions and the five beside it';

  -- The mechanism is not demonstrated here on purpose. Proving it needs
  -- `transaction_read_only = on`, which cannot be turned back off once a
  -- statement has run, so a suite that set it would poison the transaction it
  -- shares with every other suite in the run — the wrapper's own DROP TABLE
  -- fails first. What can be checked without flipping the transaction is the
  -- pair of facts the failure is made of, and they are checked below.

  -- erp.authorise writes on the way through, which is the whole reason.
  return query select 'erp.authorise records the decision, so it is a write',
    (select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorise') like '%log_access_decision%',
    'erp.log_access_decision inserts into erp.access_log';

  return query select 'and erp.authorise is itself declared volatile',
    (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorise') = 'v',
    'erp.authorise';
end;
$$;

create or replace function erp_test.assert_authorising_doors_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _authorising_doors_result on commit drop as
    select * from erp_test.authorising_doors_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _authorising_doors_result;
  drop table _authorising_doors_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_AUTHORISING_DOORS_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('authorising doors: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
