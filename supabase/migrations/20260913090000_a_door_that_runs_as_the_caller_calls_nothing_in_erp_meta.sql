-- A door that runs as the caller calls nothing in erp_meta.
--
-- public.erp_set_active_tenant() failed for every caller from 20260830124417
-- until 20260913081000, with "permission denied for schema erp_meta". It was
-- SECURITY INVOKER and its first statement called erp_meta.platform_actor().
-- A signed-in caller has had no USAGE on erp_meta since 20260830024837, so the
-- name could not even be resolved. Two checks stood next to that door and
-- neither said anything:
--
--   * erp.caller_reachable_internal_report() (20260904720000, reading code
--     since 20260904740000) matches erp_meta TABLES classed platform_internal
--     in erp_meta.table_policy. A routine in erp_meta is not a table, so the
--     door was never a candidate.
--
--   * erp.invoker_reach_report() (20260906020000) walks from invoker doors into
--     erp_meta routines, so erp.apply_execute_grants() granted authenticated
--     EXECUTE on erp_meta.platform_actor(), and erp.assert_invoker_doors_executable()
--     found the privilege it expected. EXECUTE is the second thing Postgres
--     checks. USAGE on the schema is the first, and nothing granted it. The
--     grant made the gap look closed.
--
-- So the rule the table report states for tables is stated here for routines:
-- a SECURITY INVOKER public erp_* door that names an erp_meta routine in code,
-- itself or through the invoker erp functions it calls, is a finding. The
-- reach is the table report's own: the door, then one and two invoker erp.*
-- functions matched by name with LIKE, over erp.prosrc_code() so a name in a
-- comment is not a call.
--
-- A sibling rather than a change to that report. Its column is internal_table
-- and its hint says to move the table to erp_ref; for a routine the usual fix
-- is the door running as its owner, and a finding should say so.
--
-- It is walked from the far end. The table report starts at every door and
-- matches each against every invoker erp function, then does it again for the
-- second hop. There are nine routines in erp_meta and six hundred doors, so
-- this report starts at the handful of invoker functions whose code names an
-- erp_meta routine, finds the erp functions that call those, and only then
-- asks which doors call either. The rows are the same as a walk from the
-- doors; the work is a fraction of it. That matters because this is registered
-- in erp_meta.diagnostic_check, and live erp.platform_assurance() already
-- takes 41 to 47 seconds of its 55.
--
-- Measured before writing, by replaying the function definitions in the
-- migrations outside a database, because no database was to hand here: of 555
-- invoker public erp_* doors, one names an erp_meta routine,
-- erp_set_active_tenant, itself, calling erp_meta.platform_actor(). Nothing is
-- reached at three to six hops that two hops miss, and none of the migrations
-- that rewrite bodies with execute replace(...) introduces an erp_meta call.
-- The build's run of the assertion at the end of this file is the measurement
-- that counts.
--
-- That one door is repaired by 20260913081000, which this file follows: it
-- runs as its owner, and its allowance row begins 'UNGATED BY DESIGN:', the
-- only exemption erp.public_api_report() accepts for a definer door that
-- reaches neither erp.authorise() nor erp_meta.require_platform(). Applied
-- without that file, the assertion below refuses this one, which is the point.
--
-- Its limits, written down rather than discovered: it is a textual rule, so a
-- call built in dynamic SQL from pieces is not seen; it stops at two invoker
-- hops, as the table report does; and it names erp_meta only, not every schema
-- a signed-in caller cannot use.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The report
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.caller_reachable_internal_routine_report()
returns table (door text, via text, internal_routine text)
language sql
stable
set search_path = ''
as $$
  with internal as (
    select distinct p.proname
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp_meta'
  ),
  invoker as (
    select n.nspname as sch, p.proname as nm, erp.prosrc_code(p.prosrc) as code,
           n.nspname || '.' || p.proname as fqn
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and not p.prosecdef
       and p.prorettype <> 'pg_catalog.trigger'::regtype
  ),
  -- Every invoker function whose own code calls an erp_meta routine.
  names as materialized (
    select i.sch, i.nm, i.fqn, 'erp_meta.' || m.proname as internal_routine
      from invoker i
      join internal m on i.code ~ ('erp_meta\.' || m.proname || '\s*\(')
  ),
  -- The invoker erp functions a door may call to get there, and which of them
  -- names the routine: the one itself (the table report's lvl1), or one it
  -- calls (lvl2).
  carrier as materialized (
    select n.fqn as callee, n.fqn as via, n.internal_routine
      from names n
     where n.sch = 'erp'
    union
    select c.fqn, n.fqn, n.internal_routine
      from names n
      join invoker c on c.sch = 'erp' and c.code like '%' || n.fqn || '(%'
     where n.sch = 'erp'
  )
  select n.nm, 'the door itself', n.internal_routine
    from names n
   where n.sch = 'public' and n.nm like 'erp\_%'
  union
  select d.nm, k.via, k.internal_routine
    from carrier k
    join invoker d on d.sch = 'public' and d.nm like 'erp\_%'
                  and d.code like '%' || k.callee || '(%'
  order by 1, 2, 3;
$$;

comment on function erp.caller_reachable_internal_routine_report() is
  'Public doors that run as the caller and call a routine in erp_meta, themselves '
  'or through one or two invoker erp functions. A signed-in caller has no USAGE on '
  'erp_meta, so each is refused for every caller that is not a superuser, whatever '
  'EXECUTE the routine carries, and green in every test, which runs privileged.';

revoke all on function erp.caller_reachable_internal_routine_report() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The assertion, and its place in the register
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_no_caller_reachable_internal_routines()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*),
         string_agg(r.door || ' via ' || r.via || ' calls ' || r.internal_routine,
                    E'\n  ' order by r.door, r.via, r.internal_routine)
    into v_count, v_detail
    from erp.caller_reachable_internal_routine_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_CALLER_REACHABLE_INTERNAL_ROUTINE: % finding(s): a door runs as the caller and calls a routine in erp_meta, a schema a signed-in caller cannot use, so every real caller is refused:\n  %',
      v_count, v_detail
      using errcode = 'P0001',
            hint = 'Make the door SECURITY DEFINER with an empty search path and a row in '
                   'erp_meta.security_definer_allowance: gated on erp.authorise or '
                   'erp_meta.require_platform in its reach (20260904720000), or with a rationale '
                   'beginning UNGATED BY DESIGN: that names what refuses instead (20260913081000). '
                   'A grant of EXECUTE on the routine does not help; USAGE on the schema is checked first.';
  end if;

  return format('public doors: none of %s that run as the caller calls a routine in erp_meta',
                (select count(*) from pg_catalog.pg_proc p
                   join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname like 'erp\_%' and not p.prosecdef));
end;
$$;

revoke all on function erp.assert_no_caller_reachable_internal_routines() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('caller_reachable_internal_routines', 'Doors that run as the caller call nothing in erp_meta',
   'assertion', 'platform', 'erp', 'assert_no_caller_reachable_internal_routines', '',
   'caller_reachable_internal_routine_report', '',
   'A SECURITY INVOKER public door that calls a routine in erp_meta is refused at the schema for every signed-in caller, even with EXECUTE on the routine granted, and passes every test, because tests run privileged.',
   true, 77)
on conflict (code) do update set
  title = excluded.title, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite: doors built to be found, and one called as a signed-in caller
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.caller_reachable_internal_routine_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_owner          text := current_user;
  v_granted_before boolean := pg_catalog.has_function_privilege('authenticated', 'erp_meta.platform_actor()', 'execute');
  v_granted        boolean;
  v_direct         boolean;
  v_one_hop        boolean;
  v_two_hops       boolean;
  v_definer        boolean;
  v_comment        boolean;
  v_rows           text;
  v_state          text;
  v_error          text;
  v_msg            text;
begin
  begin
    -- Two erp functions to stand between a door and erp_meta.
    execute $ddl$
      create function erp.zz_inner_names_erp_meta() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp_meta.platform_rank('support');
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_outer_calls_inner() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.zz_inner_names_erp_meta();
      end $b$
    $ddl$;

    -- Five doors.
    execute $ddl$
      create function public.erp_zz_names_erp_meta() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp_meta.platform_actor();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_one_call_from_erp_meta() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.zz_inner_names_erp_meta();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_two_calls_from_erp_meta() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.zz_outer_calls_inner();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_runs_as_owner_names_erp_meta() returns void
      language plpgsql security definer set search_path = '' as $b$
      begin
        perform erp_meta.platform_actor();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_names_erp_meta_in_a_comment() returns void
      language plpgsql set search_path = '' as $b$
      begin
        -- perform erp_meta.platform_actor();
        /* erp_meta.require_platform('support') */
        perform 1;
      end $b$
    $ddl$;

    select coalesce(bool_or(r.door = 'erp_zz_names_erp_meta' and r.via = 'the door itself'
                            and r.internal_routine = 'erp_meta.platform_actor'), false),
           coalesce(bool_or(r.door = 'erp_zz_one_call_from_erp_meta' and r.via = 'erp.zz_inner_names_erp_meta'
                            and r.internal_routine = 'erp_meta.platform_rank'), false),
           coalesce(bool_or(r.door = 'erp_zz_two_calls_from_erp_meta' and r.via = 'erp.zz_inner_names_erp_meta'
                            and r.internal_routine = 'erp_meta.platform_rank'), false),
           coalesce(bool_or(r.door = 'erp_zz_runs_as_owner_names_erp_meta'), false),
           coalesce(bool_or(r.door = 'erp_zz_names_erp_meta_in_a_comment'), false),
           string_agg(format('%s via %s calls %s', r.door, r.via, r.internal_routine), '; '
                      order by r.door, r.via, r.internal_routine)
      into v_direct, v_one_hop, v_two_hops, v_definer, v_comment, v_rows
      from erp.caller_reachable_internal_routine_report() r
     where r.door like 'erp\_zz\_%';

    -- The first door, called the way the data API calls it, with every
    -- privilege a grant can give it.
    execute 'grant execute on function public.erp_zz_names_erp_meta() to authenticated';
    execute 'grant execute on function erp_meta.platform_actor() to authenticated';
    v_granted := pg_catalog.has_function_privilege('authenticated', 'erp_meta.platform_actor()', 'execute');
    execute 'set local role authenticated';
    begin
      execute 'select public.erp_zz_names_erp_meta()';
      v_error := 'the door was called and nothing refused it';
    exception when others then
      v_state := sqlstate;
      v_error := left(sqlerrm, 200);
    end;
    execute format('set local role %I', v_owner);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := left(sqlerrm, 300); end if;
  end;

  -- 1
  case_name := 'an invoker door that calls an erp_meta routine itself is reported';
  passed := v_msg is null and v_direct;
  detail := coalesce(v_msg, v_rows, 'the report named no fixture door');
  return next;

  -- 2
  case_name := 'an invoker door one invoker erp function away from an erp_meta routine is reported';
  passed := v_msg is null and v_one_hop;
  detail := coalesce(v_msg, 'reported via erp.zz_inner_names_erp_meta, which calls erp_meta.platform_rank');
  return next;

  -- 3
  case_name := 'an invoker door two invoker erp functions away from an erp_meta routine is reported';
  passed := v_msg is null and v_two_hops;
  detail := coalesce(v_msg, 'reported via erp.zz_inner_names_erp_meta, through erp.zz_outer_calls_inner');
  return next;

  -- 4
  case_name := 'a door that runs as its owner may call erp_meta';
  passed := v_msg is null and not v_definer;
  detail := coalesce(v_msg, 'SECURITY DEFINER resolves erp_meta as the owner');
  return next;

  -- 5
  case_name := 'an erp_meta routine named only in a comment is not a call';
  passed := v_msg is null and not v_comment;
  detail := coalesce(v_msg, 'erp.prosrc_code() strips both comment forms before matching');
  return next;

  -- 6
  case_name := 'a signed-in caller is refused at the schema, even with EXECUTE on the routine granted';
  passed := v_msg is null and v_granted and v_state = '42501' and v_error like '%schema erp_meta%';
  detail := coalesce(v_msg, format('EXECUTE granted: %s; %s: %s', v_granted, coalesce(v_state, 'no error'), v_error));
  return next;

  -- 7
  case_name := 'the fixtures were undone';
  passed := not exists (
              select 1 from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where (n.nspname = 'erp' and p.proname in ('zz_inner_names_erp_meta', 'zz_outer_calls_inner'))
                  or (n.nspname = 'public' and p.proname in ('erp_zz_names_erp_meta', 'erp_zz_one_call_from_erp_meta',
                                                              'erp_zz_two_calls_from_erp_meta', 'erp_zz_runs_as_owner_names_erp_meta',
                                                              'erp_zz_names_erp_meta_in_a_comment')))
        and pg_catalog.has_function_privilege('authenticated', 'erp_meta.platform_actor()', 'execute') = v_granted_before;
  detail := 'five doors, two erp functions and the grant on erp_meta.platform_actor() rolled back';
  return next;
end;
$$;
revoke all on function erp_test.caller_reachable_internal_routine_suite() from public, anon, authenticated;

create or replace function erp_test.assert_caller_reachable_internal_routine_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.caller_reachable_internal_routine_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CALLER_REACHABLE_ROUTINE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CALLER_REACHABLE_ROUTINE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('invoker doors and erp_meta routines: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_caller_reachable_internal_routine_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_no_caller_reachable_internal_routines();
select erp_test.assert_caller_reachable_internal_routine_suite();

select erp.assert_no_caller_reachable_internals();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
