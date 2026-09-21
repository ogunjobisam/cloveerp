set lock_timeout = '30s';

-- =============================================================================
-- 20260921400000  A finding is asserted before it is blocking
-- -----------------------------------------------------------------------------
-- Two checks land in this pull request that are expected to find things on the
-- day they arrive: erp_test.assert_reachable_configuration() and
-- erp_test.assert_no_state_side_doors(). The simplification plan says so, and
-- says to land them "asserting-but-tolerated" and make them blocking later,
-- once the cleanups they exist to drive have landed.
--
-- There are three ways to do that and two of them are not worth having.
--
--   * Comment the check out. Then it is not landed. It is a file somebody has
--     to write again later, with none of the thinking in it that went in now.
--   * Have it return success. Worse: it is in erp.ci_check_catalogue(), the
--     build runs it, the log says ok, and the number beside it is a lie. This
--     repository already knows what a check that passes while proving nothing
--     costs — every register in erp_meta exists because of one.
--   * Run it, compute its real findings, report them in full, and let ONE
--     declared switch decide whether the verdict stops the build.
--
-- This is the third. A check reads its switch through erp.enforcement_verdict()
-- and hands it the number it found and the findings themselves. The switch
-- decides, and nothing else does:
--
--     update erp_meta.enforcement_gate
--        set is_blocking = true
--      where gate = 'reachable_configuration';
--
-- That single statement, in a migration, is the whole of what the later pull
-- request has to write besides the repairs.
--
-- ── WHY IT IS NOT MERELY ADVISORY ────────────────────────────────────────────
--
-- An advisory check that always passes decays into wallpaper within a week, so
-- the tolerance is a number and not a shrug. Each gate records how many
-- findings existed on the day it landed. Below that number the check passes and
-- says by how much it is ahead. Above it the check REFUSES, whether or not it
-- is blocking: today's debt is tolerated, tomorrow's is not. So the two checks
-- landing beside this one already hold the line from the hour they arrive, and
-- making them blocking is the last step rather than the only one.
--
-- The number is written by the migration that lands each check, from the check
-- itself, on the build that lands it. Nobody types it. A figure typed by hand
-- against a database that cannot be queried from a laptop is a figure that is
-- wrong on the first try and costs a build to learn, and — worse — a figure
-- somebody would then be tempted to widen rather than explain.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The switch
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.enforcement_gate (
  -- The check's own name for its switch. One check, one gate.
  gate               text not null,
  -- The whole of the decision. False: findings up to the tolerance are
  -- reported and the build continues. True: any finding stops the build.
  is_blocking        boolean not null default false,
  -- How many findings the check found on the build that landed it. The line
  -- the ratchet holds: more than this refuses even while advisory.
  tolerated_findings integer not null default 0 check (tolerated_findings >= 0),
  -- The migration that recorded the tolerance, so the count can be dated.
  landed_in          text not null,
  landed_at          timestamptz not null default now(),
  -- Why this one is not blocking yet, and what has to happen before it is.
  rationale          text not null,
  primary key (gate),
  constraint enforcement_gate_explains
    check (length(btrim(rationale)) >= 40)
);

comment on table erp_meta.enforcement_gate is
  'One row per check whose verdict is advisory until it is switched to '
  'blocking, with the number of findings it had on the day it landed. '
  'erp.enforcement_verdict() reads it and nothing else decides. Not tenant '
  'data.';

comment on column erp_meta.enforcement_gate.is_blocking is
  'The switch. False: findings up to the tolerance are reported and the build '
  'goes on. True: any finding stops the build, and the tolerance below is not '
  'consulted at all. Flipping it is one update statement in a migration, which '
  'is the whole point of it being one column — nothing else has to be changed '
  'with it, so the pull request that flips it is the repairs and one line.';

comment on column erp_meta.enforcement_gate.tolerated_findings is
  'What the check found on the build that landed it, written into the '
  'migration that landed it so that a replay from an empty database lands the '
  'same line rather than measuring a new one. Below it the check reports how '
  'far ahead it is; above it the check refuses even while advisory, so '
  'today''s debt is tolerated and tomorrow''s is not. Ignored once the gate is '
  'blocking.';

select erp_meta.register_table('erp_meta', 'enforcement_gate', 'platform_internal',
  'Which checks are advisory, what each tolerated on landing, and the one '
  'column that makes one blocking. Not tenant data.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The verdict
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.enforcement_verdict(
  p_gate     text,
  p_found    integer,
  p_findings text default null)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  g erp_meta.enforcement_gate%rowtype;
begin
  select * into g from erp_meta.enforcement_gate where gate = p_gate;

  if not found then
    raise exception
      'CLOVEERP_ENFORCEMENT_GATE_UNKNOWN: there is no switch called %', p_gate
      using errcode = '23503',
            hint = 'A check whose verdict can be advisory reads a switch of its own. '
                   'Register the switch in the migration that lands the check, or name '
                   'the one the check already has.';
  end if;

  if g.is_blocking then
    if coalesce(p_found, 0) > 0 then
      raise exception E'CLOVEERP_ENFORCEMENT_GATE_REFUSES: % — % finding(s)\n%',
        p_gate, p_found, coalesce(p_findings, 'no detail was handed to the switch')
        using errcode = 'P0001',
              detail = coalesce(p_findings, ''),
              hint = 'This check stops the build now. Repair the findings, or '
                     'decide deliberately that it should go back to reporting '
                     'them, which is one update statement in a migration and '
                     'ought to be argued for in the pull request that writes it.';
    end if;
    return format('%s: blocking, and nothing found', p_gate);
  end if;

  if coalesce(p_found, 0) > g.tolerated_findings then
    raise exception E'CLOVEERP_TOLERATED_FINDINGS_GREW: % — % finding(s), % tolerated since %\n%',
      p_gate, p_found, g.tolerated_findings, g.landed_in,
      coalesce(p_findings, 'no detail was handed to the switch')
      using errcode = 'P0001',
            detail = coalesce(p_findings, ''),
            hint = 'This check is not blocking yet, and it still refuses more '
                   'findings than it had when it landed. Repair what this change '
                   'added. Raising the tolerated number is an admission that '
                   'belongs in the pull request, not a way past the build.';
  end if;

  if coalesce(p_found, 0) < g.tolerated_findings then
    return format('%s: advisory — %s finding(s), %s fewer than the %s tolerated since %s; lower the tolerance and take the credit',
                  p_gate, p_found, g.tolerated_findings - coalesce(p_found, 0),
                  g.tolerated_findings, g.landed_in);
  end if;

  return format('%s: advisory — %s finding(s), all of them tolerated since %s',
                p_gate, p_found, g.landed_in);
end;
$$;

revoke all on function erp.enforcement_verdict(text, integer, text) from public, anon, authenticated;

comment on function erp.enforcement_verdict(text, integer, text) is
  'What a check does about what it found: refuses everything when its gate is '
  'blocking, refuses anything above the tolerance when it is not, and reports '
  'the rest in words the build log carries. The only reader of '
  'erp_meta.enforcement_gate.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The switch cannot rot
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two ways it could. A gate nobody reads is a switch for a check that was
-- deleted or renamed, and flipping it would do nothing; a check reading a gate
-- that is not registered refuses on every build, which the verdict above
-- already says, but only when the check is reached. Both are read from the
-- catalogue here, so neither waits for a run.

create or replace function erp.enforcement_gate_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a switch no check reads',
         g.gate,
         'Nothing names this gate, so flipping it changes nothing. Either the '
         'check was renamed and its gate was left behind, or the check is gone '
         'and the row with it.'
    from erp_meta.enforcement_gate g
   where not exists (
     select 1
       from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('erp', 'erp_test')
        and p.proname <> 'enforcement_gate_report'
        and position('''' || g.gate || '''' in p.prosrc) > 0)

  union all

  select 'a check reading a switch that is not registered',
         n.nspname || '.' || p.proname,
         format('It hands %L to the verdict and no such gate exists, so it '
                'refuses on every build.', m[1])
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
         lateral regexp_matches(p.prosrc, 'erp\.enforcement_verdict\(\s*''([a-z_]+)''', 'g') m
   where n.nspname in ('erp', 'erp_test')
     -- This report carries the pattern that finds the call; it is not a caller.
     and p.proname <> 'enforcement_gate_report'
     and not exists (select 1 from erp_meta.enforcement_gate g where g.gate = m[1])
$$;

revoke all on function erp.enforcement_gate_report() from public, anon, authenticated;

comment on function erp.enforcement_gate_report() is
  'Switches no check reads, and checks reading switches nobody registered. The '
  'register of advisory checks can go stale in neither direction.';

create or replace function erp.assert_enforcement_gates_are_read()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s — %s: %s', r.finding, r.reference, r.detail),
                              E'\n' order by r.reference, r.finding)
    into v_count, v_detail
    from erp.enforcement_gate_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_ENFORCEMENT_GATE_STALE: % finding(s)\n%', v_count, v_detail
      using errcode = 'P0001',
            hint = 'Delete the switch whose check has gone, or register the one '
                   'the check is asking for. A switch that decides nothing is '
                   'worse than none: somebody will flip it and believe they have '
                   'turned something on.';
  end if;

  return format('advisory checks: %s switch(es), %s blocking, %s still reporting; %s finding(s) tolerated in all',
    (select count(*) from erp_meta.enforcement_gate),
    (select count(*) from erp_meta.enforcement_gate where is_blocking),
    (select count(*) from erp_meta.enforcement_gate where not is_blocking),
    (select coalesce(sum(tolerated_findings), 0) from erp_meta.enforcement_gate));
end;
$$;

revoke all on function erp.assert_enforcement_gates_are_read() from public, anon, authenticated;

comment on function erp.assert_enforcement_gates_are_read is
  'Every advisory switch is read by a check and every check reads a switch that '
  'exists. Without this the register drifts quietly and a later flip turns on '
  'nothing.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('enforcement_gates_are_read', 'Every advisory switch belongs to a check',
   'assertion', 'platform', 'erp', 'assert_enforcement_gates_are_read', '',
   'enforcement_gate_report', '',
   'Some checks report what they find before they stop the build, so the '
   'repair can be planned rather than forced. Each such check has one switch. '
   'This makes sure every switch belongs to a check that reads it, and that no '
   'check is asking for a switch nobody registered.',
   true, 110)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the proof
-- ═════════════════════════════════════════════════════════════════════════════

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
