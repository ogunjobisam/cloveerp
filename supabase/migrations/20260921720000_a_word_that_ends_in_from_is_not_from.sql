set lock_timeout = '30s';

-- =============================================================================
-- 20260921720000  A word that ends in "from" is not FROM
-- -----------------------------------------------------------------------------
-- erp.missing_relation_report() finds a schema-qualified name sitting where a
-- relation goes by looking for one of from, join, update, into or delete from,
-- some whitespace, and a name in one of the product's schemas. Its end was
-- anchored — \M, for a reason written beside it — and its start was not. So the
-- keyword was found INSIDE a longer word, and a plpgsql local whose name merely
-- ends in one, declared with a schema-qualified type,
--
--     v_from   erp.change_set_status;
--
-- was read as the keyword FROM, the whitespace after it, and a relation. The
-- type is not a relation, to_regclass() said so, and the report named it as a
-- table that does not exist. On 21 September that refused
-- erp.bootstrap_change_set() on a build and cost a cycle; it was worked round by
-- renaming the variable (20260921470000), as v_from and v_to had been worked
-- round in 20260917130000 before it. A name like that is invisible to everything
-- until the day it is declared, and the fix each time was to make the code
-- worse for the check's sake.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 1. erp.missing_relation_report() is re-emitted with \m before the keyword
--    alternation, mirroring the \M at the other end of the name. \m matches at
--    the start of a word and the underscore is a word character, so v_from,
--    p_join, x_update and v_delete_from are no longer keywords, while from, FROM,
--    a line that begins with from, and a keyword after a tab or a line break all
--    still are. Nothing else about the function changes: same signature, same
--    schemas, same lookahead, same exemption register.
--
-- 2. A guard, run here once, that measures what the anchor does to the whole
--    product before it is trusted. The report reads every plpgsql routine in six
--    schemas, so the anchor's blast radius is the product. It counts the
--    candidate matches — before to_regclass() has said whether any of them is
--    missing — with the old pattern and the new, refuses if the new finds none
--    (a pattern that has stopped matching reports nothing, and a report that
--    says nothing is what a clean product looks like), refuses if it finds more
--    (an anchor can only remove), and names every routine that lost one.
--
--    The report's own findings are the wrong thing to measure here: they are
--    zero on a healthy build before and after, so they cannot tell a pattern
--    that works from one that matches nothing.
--
-- 3. erp_test.missing_relation_report_suite(), so the anchor cannot be lost
--    again. It plants real routines and reads the report's answer about them:
--    locals named for every keyword, with a schema-qualified type, are not
--    reported; a relation that is not there IS reported after each keyword, in
--    either case and across a line break, next to a local of that kind; and a
--    name written into erp_meta.missing_relation_exemption is left out, which
--    shows the register is still reachable. A case first shows that the same
--    fixture, read WITHOUT the anchor, is the false positive — otherwise the
--    case that says "not reported" could pass because the fixture never
--    tripped anything.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not do, and why
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The renames are not undone. erp.stock_move_between_sites() and
-- erp.bootstrap_change_set() are correct as they stand; a name that was changed
-- to placate a check is not changed back to prove the check was wrong.
--
-- The lookahead is not touched. It excludes a name followed by "(", which is
-- right for `from erp.foo(...)` and also excludes `insert into erp.foo (a, b)`,
-- an insert with a column list, so an INSERT that names its columns is not read
-- by this report at all. That is a second, separate gap — it hides findings
-- where this one invented them — and closing it can ADD findings, which this
-- change by construction cannot. It is raised separately for that reason.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The report, anchored at both ends
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.missing_relation_report()
returns table (schema_name text, function_name text, relation text)
language sql
stable
set search_path to ''
as $$
  -- A schema-qualified name in the position a relation goes — after FROM, JOIN,
  -- UPDATE, INSERT INTO or DELETE FROM — that does not resolve to one.
  --
  -- The pattern is anchored at both ends, and each anchor is there for a
  -- failure the other cannot prevent.
  --
  -- \m anchors the start of the keyword at a word boundary. Without it the
  -- keyword is found inside a longer word: a plpgsql local whose name only ends
  -- in one — v_from, v_join, v_update, v_into, p_from — and that is declared with
  -- a schema-qualified type has the keyword as its last characters, whitespace
  -- after it, and a name after that, which is everything the pattern asks for.
  -- `v_from erp.change_set_status;` reported an enum as a table that does not
  -- exist, refused erp.bootstrap_change_set() on 21 September, and could only be
  -- worked round by renaming the variable. The underscore is a word character, so
  -- \m leaves v_from alone and still finds from, FROM, and a keyword that follows
  -- a tab or a line break. It can only remove findings: what it removes is a
  -- match whose keyword was the tail of a longer word, which is never a relation.
  --
  -- \M anchors the end of the name at a word boundary. Without it the regex
  -- engine backtracks a character at a time to satisfy the lookahead below and
  -- reports every table in the product as missing, one letter short of its own
  -- name, which is a check that finds nothing by finding everything.
  --
  -- Between them the two anchors say the same thing from both sides: a keyword
  -- is a whole word, and a name is a whole name. Take either away and the check
  -- reads text that is not there — the start, a variable; the end, a table one
  -- letter short.
  --
  -- The lookahead excludes a name followed by "(", because `from erp.foo(...)`
  -- is a set-returning function and not a relation at all. That distinction is
  -- the difference between two findings and five hundred.
  with body as (
    select n.nspname::text as sch, p.proname::text as fn, p.prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
       and p.prokind = 'f'
       and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql')
  ), named as (
    select b.sch, b.fn,
           lower((regexp_matches(
             b.prosrc,
             '\m(?:from|join|update|into|delete\s+from)\s+'
             '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M(?!\s*\()',
             'gi'))[1]) as rel
      from body b
  )
  select distinct nm.sch, nm.fn, nm.rel
    from named nm
   where to_regclass(nm.rel) is null
     and not exists (select 1 from erp_meta.missing_relation_exemption x
                      where x.relation = nm.rel)
   order by 1, 2, 3
$$;

revoke all on function erp.missing_relation_report() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The blast radius, measured
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Candidates, not findings: every place the pattern matches, before anything is
-- asked about whether the relation is there. The two patterns are written out in
-- full because this is a record of one measurement and must not follow the
-- report if the report is edited again.

do $guard$
declare
  v_old constant text :=
    '(?:from|join|update|into|delete\s+from)\s+'
    '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M(?!\s*\()';
  v_new constant text := '\m' || v_old;
  v_before integer;
  v_after  integer;
  v_bodies integer;
  r        record;
begin
  select count(*) into v_bodies
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  select count(*) into v_before
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, v_old, 'gi') m
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  select count(*) into v_after
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, v_new, 'gi') m
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  if v_after = 0 then
    raise exception 'CLOVEERP_ANCHOR_MATCHES_NOTHING: the anchored pattern finds no relation in % routine bodies, where the unanchored one found %',
      v_bodies, v_before
      using hint = 'A pattern that matches nothing reports nothing, which is what a clean product looks like. Do not ship it.';
  end if;

  if v_after > v_before then
    raise exception 'CLOVEERP_ANCHOR_ADDED_MATCHES: the anchored pattern finds % candidate(s) where the unanchored one found %',
      v_after, v_before
      using hint = 'An anchor can only remove matches. Something else about the pattern changed.';
  end if;

  raise notice 'anchor: % routine bodies, % candidate relation names before, % after, % dropped',
    v_bodies, v_before, v_after, v_before - v_after;

  for r in
    select n.nspname::text as sch, p.proname::text as fn,
           (select count(*) from regexp_matches(p.prosrc, v_old, 'gi')) as n_before,
           (select count(*) from regexp_matches(p.prosrc, v_new, 'gi')) as n_after
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
       and p.prokind = 'f'
       and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql')
       and (select count(*) from regexp_matches(p.prosrc, v_old, 'gi'))
        <> (select count(*) from regexp_matches(p.prosrc, v_new, 'gi'))
     order by 1, 2
  loop
    raise notice 'anchor: %.% read % local(s) as a keyword and no longer does',
      r.sch, r.fn, r.n_before - r.n_after;
  end loop;
end;
$guard$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The routines it plants are read by the very report it is testing, and so is
-- the suite's own body: erp.missing_relation_report() reads every plpgsql body
-- in erp_test, this one included. A keyword written next to a schema-qualified
-- name anywhere in here would be a finding about the suite, permanently, whether
-- or not anything had been planted, and the check could never pass. So the
-- keywords are assembled from halves and the names are handed to format(), and
-- the routines it creates carry text the suite's own source does not
-- (erp_test.audit_source_suite() and erp.legacy_refusal_prefix_report() split
-- their needles for the same reason — 20260919940000).
--
-- Everything is planted inside one block that is undone by an exception, and the
-- last case checks that it was.

create or replace function erp_test.missing_relation_report_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  v_cases      integer := 0;
  v_step       text := 'before the fixture started';
  v_state      text;
  v_tag        text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_locals     text;
  v_reads      text;
  v_kw_from    text := 'fr' || 'om';
  v_kw_join    text := 'jo' || 'in';
  v_kw_update  text := 'up' || 'date';
  v_kw_into    text := 'in' || 'to';
  v_word       text;
  v_decl       text := '';
  v_body       text;
  v_names      text[] := '{}';
  v_absent     text[];
  v_found      text[];
  v_excused    text;
  v_hits       integer;
  v_unanchored text;
  n            integer;
begin
  v_locals := 'zz_anchor_' || v_tag || '_locals';
  v_reads  := 'zz_anchor_' || v_tag || '_reads';
  for n in 1..8 loop
    v_names := v_names || format('zz_absent_%s_%s', v_tag, n);
  end loop;
  -- What the report says about a name that is not there: lower-cased, qualified.
  select array_agg('erp.' || x order by x) into v_absent from unnest(v_names) x;

  begin
    -- ── The planted routines ──────────────────────────────────────────────────
    v_step := 'planting a routine whose locals are named for each keyword';
    foreach v_word in array array['from', 'join', 'update', 'into', 'delete_from'] loop
      v_decl := v_decl || format('  v_%s erp.costing_method;', v_word) || E'\n';
    end loop;
    execute format(
      'create function erp_test.%I() returns void language plpgsql '
      'set search_path = '''' as %L',
      v_locals,
      E'declare\n' || v_decl || E'begin\n  null;\nend;');

    v_step := 'planting a routine that reads relations that are not there';
    v_body := E'declare\n  v_from erp.costing_method;\nbegin\n'
      || format('  perform 1 %s erp.%s;', v_kw_from, v_names[1]) || E'\n'
      || format('  perform 1 %s erp.%s x %s erp.%s y on true;',
                v_kw_from, v_names[2], v_kw_join, v_names[3]) || E'\n'
      || format('  %s erp.%s set c = 1;', v_kw_update, v_names[4]) || E'\n'
      || format('  insert %s erp.%s select 1;', v_kw_into, v_names[5]) || E'\n'
      || format('  delete %s erp.%s;', v_kw_from, v_names[6]) || E'\n'
      || format('  PERFORM 1 %s erp.%s;', upper(v_kw_from), v_names[7]) || E'\n'
      || format(E'  perform 1\n\t%s\n\terp.%s;', v_kw_from, v_names[8]) || E'\n'
      || E'end;';
    execute format(
      'create function erp_test.%I() returns void language plpgsql '
      'set search_path = '''' as %L',
      v_reads, v_body);

    v_step := 'reading the report';
    select coalesce(array_agg(r.relation order by r.relation), '{}')
      into v_found
      from erp.missing_relation_report() r
     where r.schema_name = 'erp_test' and r.function_name = v_reads;

    -- ── 1. The fixture is the false positive ────────────────────────────────
    -- Without this, case 2 could pass because the planted locals never tripped
    -- anything. This is the pattern as it stood before this was anchored.
    v_step := 'reading the locals without the anchor';
    v_unanchored :=
      '(?:from|join|update|into|delete\s+from)\s+'
      '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M(?!\s*\()';
    select count(*) into v_hits
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
      cross join lateral regexp_matches(p.prosrc, v_unanchored, 'gi') m
     where ns.nspname = 'erp_test' and p.proname = v_locals;
    v_cases := v_cases + 1;
    case_name := 'read without the anchor, locals named for a keyword are a finding';
    passed := v_hits = 5 and to_regclass('erp.costing_method') is null;
    detail := format('five locals, each ending in a keyword and typed erp.costing_method, give %s candidate(s) unanchored, and that type is %s a relation',
                     v_hits, case when to_regclass('erp.costing_method') is null then 'not' else 'IN FACT' end);
    return next;

    -- ── 2. The anchor keeps them out ────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a local named for a keyword, declared with a schema-qualified type, is not reported';
    passed := not exists (select 1 from erp.missing_relation_report() r
                           where r.schema_name = 'erp_test' and r.function_name = v_locals);
    detail := coalesce(
      'reported: ' || (select string_agg(r.relation, ', ')
                         from erp.missing_relation_report() r
                        where r.schema_name = 'erp_test' and r.function_name = v_locals),
      'v_from, v_join, v_update, v_into and v_delete_from, all typed erp.costing_method, gave the report nothing');
    return next;

    -- ── 3. The real ones are still found ────────────────────────────────────
    -- One of them sits beside a local of that kind, so the anchor is shown to
    -- take out the local and leave everything else.
    v_cases := v_cases + 1;
    case_name := 'a relation that is not there is reported after every keyword, in either case and across a line break';
    passed := v_found = v_absent;
    detail := format('%s of %s named relations reported%s',
      (select count(*) from unnest(v_found) f where f = any (v_absent)), cardinality(v_absent),
      coalesce('; not expected: ' || (select string_agg(f, ', ')
                                        from unnest(v_found) f where f <> all (v_absent)), ''));
    return next;

    -- ── 4. The register is still reachable ──────────────────────────────────
    v_step := 'excusing one of the names';
    v_excused := v_absent[1];
    insert into erp_meta.missing_relation_exemption (relation, rationale)
    values (v_excused, 'A fixture of erp_test.missing_relation_report_suite(). Not shipped: it is undone before the suite returns.');
    select coalesce(array_agg(r.relation order by r.relation), '{}')
      into v_found
      from erp.missing_relation_report() r
     where r.schema_name = 'erp_test' and r.function_name = v_reads;
    v_cases := v_cases + 1;
    case_name := 'a name written in the exemption register is left out and the rest are not';
    passed := v_found = (select array_agg(x order by x) from unnest(v_absent) x where x <> v_excused);
    detail := format('%s reported after excusing %s; %s expected',
                     cardinality(v_found), v_excused, cardinality(v_absent) - 1);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ── 5. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from pg_catalog.pg_proc p
                          join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
                         where ns.nspname = 'erp_test' and p.proname like 'zz\_anchor\_' || v_tag || '%')
        and not exists (select 1 from erp_meta.missing_relation_exemption x
                         where x.relation like 'erp.zz\_absent\_' || v_tag || '%');
  detail := coalesce(v_state,
                     'both planted routines and the excused name rolled back');
  return next;

  if v_cases <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: missing_relation_report_suite ran % case(s), expected 5; the fixture stopped %',
      v_cases, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.missing_relation_report_suite() from public, anon;

comment on function erp_test.missing_relation_report_suite() is
  'What erp.missing_relation_report() reads and what it leaves alone. A local '
  'whose name ends in a keyword and whose type is schema-qualified is not a '
  'relation, and the fixture is first shown to be a finding without the anchor '
  'so that the case cannot pass by never tripping anything; a relation that is '
  'not there is reported after each keyword, in either case and across a line '
  'break, beside a local of that kind; a name in erp_meta.missing_relation_exemption '
  'is left out and the others are not. Plants two routines and one exemption and '
  'rolls all of it back.';

create or replace function erp_test.assert_missing_relation_report_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _missing_relation_report on commit drop as
    select * from erp_test.missing_relation_report_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _missing_relation_report;
  drop table _missing_relation_report;
  if v_fail > 0 then
    raise exception E'CLOVEERP_MISSING_RELATION_REPORT_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case. Either a local named for a keyword was read as a relation, so the start of the keyword is no longer anchored, or a relation that is not there went unreported, so the pattern no longer matches, or the exemption register stopped being read.';
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: missing_relation_report_suite ran % case(s), expected 5', v_all
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('missing relation report: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_missing_relation_report_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.apply_execute_grants() is not optional: the suite and its wrapper are two
-- new routines, and a routine that was never granted passes a build from an
-- empty cluster and fails on a live database.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_governed_views_are_safe();

select erp_test.assert_missing_relation_report_suite();
select erp.assert_no_missing_relations();

select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
