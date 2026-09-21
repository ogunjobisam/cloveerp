set lock_timeout = '30s';

-- =============================================================================
-- 20260921730000  An insert that names its columns is read
-- -----------------------------------------------------------------------------
-- erp.missing_relation_report() finds a schema-qualified name where a relation
-- goes, and refuses a name that is followed by "(" because `from erp.foo(...)`
-- is a set-returning call and not a relation. That refusal was written for
-- FROM and JOIN and it was applied to every keyword, INTO included, and an
-- INSERT that lists its columns is followed by "(" too:
--
--     insert into erp.foo (a, b) values (1, 2);
--
-- So the report has never read one. That is not an edge: read offline over the
-- last definition of every plpgsql routine in the six schemas it reads, 1,793
-- INSERTs that name their columns target 300 different relations from 549
-- routines, and the report saw none of them. It saw the INSERTs that name no
-- columns and every other statement, which is why it looked thorough. A door that
-- inserts into a table that is not there builds green, passes every suite that
-- does not reach it, and raises in front of a user — the exact class
-- 20260904900000 exists to close, left open at its most common statement.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 1. erp.missing_relation_report() is re-emitted with the pattern in two
--    alternatives. The first is what it was: from, join, update, into or
--    delete from, then a name that is not followed by "(". The second is new:
--    insert into, then a name, with no lookahead, because after INSERT INTO a
--    "(" opens a column list and can never open a call. Both stay anchored at a
--    word boundary at both ends (\m before, \M after), so v_from is not FROM
--    and a table is not read one letter short. Nothing else changes: same
--    signature, same six schemas, same exemption register.
--
--    A set-returning call after FROM or JOIN is still not read. The lookahead
--    is kept exactly where it was right and is dropped only where it was wrong.
--
-- 2. What it newly reports, measured, and refused if the measurement is wrong.
--
--      Offline, before writing this: of the 300 relations an INSERT-with-columns
--      names, 289 are also read today by a statement the report does read, so
--      they resolve on any green build; the other 11 are each created by a
--      migration and never dropped; auth.users, the only auth relation named,
--      is created by the host bootstrap. The same resolver, run over the 387
--      names the report already reads, finds every one of them: it has no gaps.
--      A planted INSERT that names an absent table is found by the new pattern
--      and is invisible to the old one. Findings this adds: 0.
--
--      Offline is a prediction. The build is the measurement, so a guard below
--      counts, on the schema as built, the occurrences the new alternative adds,
--      the routines and relations they reach, and how many of those relations
--      are not there and not excused, and says so as a WARNING, which is the one
--      level the build's log keeps. It refuses when the alternative reads
--      nothing (a pattern that matches nothing reports nothing, which is what a
--      clean product looks like), and when the new pattern's candidates are
--      anything but the old pattern's plus exactly the INSERTs that name columns
--      (something else about the pattern moved, most likely the lookahead).
--
--      A finding the build does raise is not silenced here: a name that is wrong
--      is repaired, and a name that is built at run time is written into
--      erp_meta.missing_relation_exemption with its reason, in this migration.
--      erp.assert_no_missing_relations(), at the end, names every one at once.
--
-- 3. Two cases added to erp_test.missing_relation_report_suite(), five to seven.
--    An INSERT that lists its columns into a relation that is not there is
--    reported, in five spellings — a space before the paren, none, a line break
--    before it, upper case, and the keywords split across a line break — while
--    one into a relation that IS there is not; and the same fixture, read with
--    the pattern as it stood, gives no candidate at all, so the case cannot pass
--    by never having been a gap. And a set-returning call after FROM and JOIN is
--    still not reported, shown against the same call read with the lookahead
--    removed, so the case cannot pass by never having been a finding.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not do, and why
-- ─────────────────────────────────────────────────────────────────────────────
--
-- MERGE INTO and COPY are not read. Neither occurs against a schema-qualified
-- name in any plpgsql body in the product, and a pattern that reads what does not
-- occur is a pattern nobody can test.
--
-- The report still reads text, not statements. A comment or a string literal that
-- spells the shape is read as if it were code, as it always was; for that reason
-- the suite assembles its keywords from halves.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The report, with an INSERT read whatever follows its name
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
  -- The pattern has two alternatives because one rule was wrong for one keyword.
  --
  -- The first alternative is from, join, update, into and delete from, and the
  -- name may not be followed by "(": `from erp.foo(...)` is a set-returning
  -- function and not a relation at all. That distinction is the difference between
  -- two findings and five hundred.
  --
  -- The second alternative is insert into, and its name may be followed by
  -- anything. After INSERT INTO a "(" opens a column list, so the lookahead that
  -- is right for FROM excluded every INSERT that names its columns, and the report
  -- never read one. The alternative starts at "insert", which is to the left of the
  -- "into" the first alternative would have found, so a statement is read once, by
  -- whichever alternative reaches it first.
  --
  -- Both are anchored at a word boundary at both ends, and each anchor is there for
  -- a failure the other cannot prevent.
  --
  -- \m anchors the start of the keyword. Without it the keyword is found inside a
  -- longer word: a plpgsql local whose name only ends in one — v_from, v_join,
  -- p_update — and that is declared with a schema-qualified type has the keyword
  -- as its last characters, whitespace after it, and a name after that. The
  -- underscore is a word character, so \m leaves v_from alone and still finds from,
  -- FROM, and a keyword after a tab or a line break.
  --
  -- \M anchors the end of the name. Without it the regex engine backtracks a
  -- character at a time to satisfy the lookahead and reports every table in the
  -- product as missing, one letter short of its own name, which is a check that
  -- finds nothing by finding everything.
  with body as (
    select n.nspname::text as sch, p.proname::text as fn, p.prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
       and p.prokind = 'f'
       and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql')
  ), named as (
    select b.sch, b.fn, lower(coalesce(m[1], m[2])) as rel
      from body b
     cross join lateral regexp_matches(
             b.prosrc,
             '\m(?:'
               '(?:from|join|update|into|delete\s+from)\s+'
               '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M(?!\s*\()'
             '|'
               'insert\s+into\s+'
               '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M'
             ')',
             'gi') m
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
-- 2. What the new alternative reaches, measured on the built schema
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Candidates, not only findings: every place the pattern matches, before anything
-- is asked about whether the relation is there. The three patterns are written out
-- in full because this is a record of one measurement and must not follow the
-- report if the report is edited again.

do $guard$
declare
  v_name constant text :=
    '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)';
  -- The report as 20260921720000 left it.
  v_old constant text :=
    '\m(?:from|join|update|into|delete\s+from)\s+' || v_name || '\M(?!\s*\()';
  -- What this migration adds: an INSERT whose name is followed by "(".
  v_cols constant text :=
    '\minsert\s+into\s+' || v_name || '\M(?=\s*\()';
  -- The report as this migration writes it.
  v_new constant text :=
    '\m(?:(?:from|join|update|into|delete\s+from)\s+' || v_name || '\M(?!\s*\()'
    || '|insert\s+into\s+' || v_name || '\M)';
  v_bodies   integer;
  v_old_n    integer;
  v_new_n    integer;
  v_cols_n   integer;
  v_routines integer;
  v_names    integer;
  v_missing  text[];
begin
  select count(*) into v_bodies
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  select count(*) into v_old_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, v_old, 'gi') m
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  select count(*) into v_new_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, v_new, 'gi') m
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  select count(*), count(distinct (p.oid)), count(distinct lower(m[1])),
         array_agg(distinct lower(m[1]) order by lower(m[1]))
           filter (where to_regclass(lower(m[1])) is null
                     and not exists (select 1 from erp_meta.missing_relation_exemption x
                                      where x.relation = lower(m[1])))
    into v_cols_n, v_routines, v_names, v_missing
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, v_cols, 'gi') m
   where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
     and p.prokind = 'f'
     and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql');

  if v_cols_n = 0 then
    raise exception 'CLOVEERP_INSERT_ALTERNATIVE_MATCHES_NOTHING: no INSERT that names its columns was found in % routine bodies',
      v_bodies
      using hint = 'A pattern that matches nothing reports nothing, which is what a clean product looks like. About 1,800 such statements were counted offline. Do not ship it.';
  end if;

  if v_new_n <> v_old_n + v_cols_n then
    raise exception 'CLOVEERP_INSERT_ALTERNATIVE_MOVED_MORE: the new pattern finds % candidate(s); the old finds % and % INSERT(s) name their columns, so % were expected',
      v_new_n, v_old_n, v_cols_n, v_old_n + v_cols_n
      using hint = 'The new alternative must add exactly the INSERTs that name their columns. If it adds more, the lookahead that keeps a set-returning call out of the first alternative has moved; if it adds fewer, the two alternatives are reading the same statement.';
  end if;

  -- A WARNING and not a notice: the build runs at client_min_messages=warning,
  -- and a measurement nobody can read afterwards is not one.
  raise warning 'insert with a column list: % routine bodies, % candidates before, % after; the new alternative adds % in % routines naming % relations, % not there and not excused%',
    v_bodies, v_old_n, v_new_n, v_cols_n, v_routines, v_names,
    coalesce(cardinality(v_missing), 0),
    coalesce(' (' || array_to_string(v_missing, ', ') || ')', '');
end;
$guard$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite, five cases to seven
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Everything 20260921720000 says about why this suite spells nothing out holds
-- for the two cases added here, and they are the cases most likely to break it.
-- erp.missing_relation_report() reads every plpgsql body in erp_test, this one
-- included, and an INSERT that names its columns is now read: a single "insert
-- into erp.<name> (" written out anywhere below, in code or in a comment, is a
-- finding about the suite, permanently, whether or not anything was planted.
-- The keywords are assembled from halves and every planted name is handed to
-- format(). The one statement below that does name a relation is the exemption
-- case's insert into the register, whose table exists, so it is read and passes.
--
-- Everything is planted inside one block undone by an exception, as it was.

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
  v_inserts    text;
  v_calls      text;
  v_kw_from    text := 'fr' || 'om';
  v_kw_join    text := 'jo' || 'in';
  v_kw_update  text := 'up' || 'date';
  v_kw_into    text := 'in' || 'to';
  v_kw_insert  text := 'ins' || 'ert';
  v_word       text;
  v_decl       text := '';
  v_body       text;
  v_names      text[] := '{}';
  v_absent     text[];
  v_ins_names  text[] := '{}';
  v_ins_absent text[];
  v_call_names text[] := '{}';
  v_present    text := 'erp_meta.missing_relation_exemption';
  v_found      text[];
  v_excused    text;
  v_hits       integer;
  v_unanchored text;
  v_lookahead  text;
  v_before_ins text;
  n            integer;
begin
  v_locals  := 'zz_anchor_' || v_tag || '_locals';
  v_reads   := 'zz_anchor_' || v_tag || '_reads';
  v_inserts := 'zz_anchor_' || v_tag || '_inserts';
  v_calls   := 'zz_anchor_' || v_tag || '_calls';
  for n in 1..8 loop
    v_names := v_names || format('zz_absent_%s_%s', v_tag, n);
  end loop;
  for n in 1..5 loop
    v_ins_names := v_ins_names || format('zz_absent_%s_ins_%s', v_tag, n);
  end loop;
  for n in 1..3 loop
    v_call_names := v_call_names || format('zz_absent_%s_call_%s', v_tag, n);
  end loop;
  -- What the report says about a name that is not there: lower-cased, qualified.
  select array_agg('erp.' || x order by x) into v_absent from unnest(v_names) x;
  select array_agg('erp.' || x order by x) into v_ins_absent from unnest(v_ins_names) x;

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

    -- An INSERT that names its columns, five ways, into relations that are not
    -- there; and a sixth into one that is, which must not be reported. The
    -- keywords are the halves above and the names go through format().
    v_step := 'planting a routine whose inserts name their columns';
    v_body := E'begin\n'
      || format('  %s %s erp.%s (c) values (1);',
                v_kw_insert, v_kw_into, v_ins_names[1]) || E'\n'
      || format('  %s %s erp.%s(c) values (1);',
                v_kw_insert, v_kw_into, v_ins_names[2]) || E'\n'
      || format(E'  %s %s erp.%s\n    (c, d)\n    values (1, 2);',
                v_kw_insert, v_kw_into, v_ins_names[3]) || E'\n'
      || format('  %s %s erp.%s (c) values (1);',
                upper(v_kw_insert), upper(v_kw_into), v_ins_names[4]) || E'\n'
      || format(E'  %s\n\t%s\n\terp.%s (c) values (1);',
                v_kw_insert, v_kw_into, v_ins_names[5]) || E'\n'
      || format('  %s %s %s (relation, rationale) values (%L, %L);',
                v_kw_insert, v_kw_into, v_present, 'x', 'x') || E'\n'
      || E'end;';
    execute format(
      'create function erp_test.%I() returns void language plpgsql '
      'set search_path = '''' as %L',
      v_inserts, v_body);

    -- A set-returning call in the position a relation goes, after FROM and after
    -- JOIN, with and without a space before the paren. It is not a relation.
    v_step := 'planting a routine that calls set-returning functions';
    v_body := E'begin\n'
      || format('  perform 1 %s erp.%s(1);', v_kw_from, v_call_names[1]) || E'\n'
      || format('  perform 1 %s erp.%s (1);', v_kw_from, v_call_names[2]) || E'\n'
      || format('  perform 1 %s %s x %s erp.%s(1) y on true;',
                v_kw_from, v_present, v_kw_join, v_call_names[3]) || E'\n'
      || E'end;';
    execute format(
      'create function erp_test.%I() returns void language plpgsql '
      'set search_path = '''' as %L',
      v_calls, v_body);

    v_step := 'reading the report';
    select coalesce(array_agg(r.relation order by r.relation), '{}')
      into v_found
      from erp.missing_relation_report() r
     where r.schema_name = 'erp_test' and r.function_name = v_reads;

    -- ── 1. The fixture is the false positive ────────────────────────────────
    -- Without this, case 2 could pass because the planted locals never tripped
    -- anything. This is the pattern as it stood before the start was anchored.
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

    -- ── 4. An INSERT that names its columns is read ─────────────────────────
    -- The fixture is first read with the pattern as 20260921720000 left it, which
    -- gives it no candidate at all: that is the gap, and it is what stops this
    -- case from passing on a fixture that was never invisible.
    v_step := 'reading the inserts';
    v_before_ins :=
      '\m(?:from|join|update|into|delete\s+from)\s+'
      '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M(?!\s*\()';
    select count(*) into v_hits
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
      cross join lateral regexp_matches(p.prosrc, v_before_ins, 'gi') m
     where ns.nspname = 'erp_test' and p.proname = v_inserts;
    select coalesce(array_agg(r.relation order by r.relation), '{}')
      into v_found
      from erp.missing_relation_report() r
     where r.schema_name = 'erp_test' and r.function_name = v_inserts;
    v_cases := v_cases + 1;
    case_name := 'an insert that lists its columns into a relation that is not there is reported, and one into a relation that is there is not';
    passed := v_hits = 0 and v_found = v_ins_absent and to_regclass(v_present) is not null;
    detail := format('the old pattern found %s candidate(s) in six inserts that name their columns; the report names %s of %s absent relations%s',
      v_hits,
      (select count(*) from unnest(v_found) f where f = any (v_ins_absent)), cardinality(v_ins_absent),
      coalesce('; not expected: ' || (select string_agg(f, ', ')
                                        from unnest(v_found) f where f <> all (v_ins_absent)), ''));
    return next;

    -- ── 5. A set-returning call is still not a relation ─────────────────────
    -- The same three calls with the lookahead taken away are three findings, which
    -- is what makes "the report says nothing about them" mean something.
    v_step := 'reading the calls';
    v_lookahead :=
      '\m(?:from|join)\s+'
      '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.zz_absent_[a-z0-9_]*)\M';
    select count(*) into v_hits
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
      cross join lateral regexp_matches(p.prosrc, v_lookahead, 'gi') m
     where ns.nspname = 'erp_test' and p.proname = v_calls;
    select coalesce(array_agg(r.relation order by r.relation), '{}')
      into v_found
      from erp.missing_relation_report() r
     where r.schema_name = 'erp_test' and r.function_name = v_calls;
    v_cases := v_cases + 1;
    case_name := 'a set-returning call after from and join is not reported';
    passed := v_hits = 3 and cardinality(v_found) = 0;
    detail := format('three calls give %s candidate(s) without the lookahead and the report names %s',
                     v_hits, cardinality(v_found));
    return next;

    -- ── 6. The register is still reachable ──────────────────────────────────
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

  -- ── 7. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from pg_catalog.pg_proc p
                          join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
                         where ns.nspname = 'erp_test' and p.proname like 'zz\_anchor\_' || v_tag || '%')
        and not exists (select 1 from erp_meta.missing_relation_exemption x
                         where x.relation like 'erp.zz\_absent\_' || v_tag || '%');
  detail := coalesce(v_state,
                     'all four planted routines and the excused name rolled back');
  return next;

  if v_cases <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: missing_relation_report_suite ran % case(s), expected 7; the fixture stopped %',
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
  'break, beside a local of that kind; an insert that lists its columns into a '
  'relation that is not there is reported in five spellings and one into a '
  'relation that is there is not, the same fixture having given the previous '
  'pattern no candidate; a set-returning call after from and join is not '
  'reported, the same calls being findings without the lookahead; a name in '
  'erp_meta.missing_relation_exemption is left out and the others are not. '
  'Plants four routines and one exemption and rolls all of it back.';

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
      using hint = 'Read the failed case. Either a local named for a keyword was read as a relation, so the start of the keyword is no longer anchored, or a relation that is not there went unreported, so the pattern no longer matches, or an insert that lists its columns went unread, so the lookahead is back on INSERT, or a set-returning call was reported, so it has been dropped from FROM, or the exemption register stopped being read.';
  end if;
  if v_all <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: missing_relation_report_suite ran % case(s), expected 7', v_all
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
-- erp.apply_execute_grants() is not optional: the report, the suite and its
-- wrapper are re-emitted here, and a routine that was never granted passes a
-- build from an empty cluster and fails on a live database.

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
