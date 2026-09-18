set lock_timeout = '30s';

-- =============================================================================
-- 20260919800000  The read walk sees calls, not keywords
-- -----------------------------------------------------------------------------
-- erp.routine_decided_names() is the instrument behind erp.assert_write_only_
-- columns(): it answers "which names does this body use where an outcome is
-- decided", and the answer is what separates a setting something consults from
-- a control that writes into the dark. It produced a register of thirty-eight
-- findings on 16 September, nineteen called deliberate and nineteen called
-- defects, and four migrations have acted on it since.
--
-- It is wrong in BOTH directions, and neither was found by the check. Both were
-- found by somebody reading one column's arithmetic for another reason.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What it imagined: any word before a bracket is a call
--
-- Pass 7 — "an argument handed to another routine" — matched
--
--     \m([a-z_][a-z0-9_]*)\s*\(([^();]{0,200})
--
-- and counted every name in the two hundred characters that followed. The
-- exclusion list named the json builders and format(), and nothing else. So
--
--     from (select p.amount_minor, pi2.band_from, pi2.band_to, it.code
--
-- in erp.invoice_overage_lines() matched with the "routine name" `from`, and the
-- whole of a derived table's select list was swept in as names something
-- decided on. A select list is a projection. Nothing in it has decided
-- anything.
--
-- That one sweep is the only reason erp.price_item.band_from is not in the
-- register today. Take the keyword exclusion on its own and band_from is a new
-- finding: the price-book screen's "Band from" would be a control that saves,
-- says it saved, and changes nothing — the exact class this check exists to
-- refuse. `as (`, the head of every CTE, and `values (`, the values an insert
-- writes, were being swept the same way.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What it missed: a call inside a call it had already eaten
--
-- regexp_matches with 'g' does not overlap. In the same routine,
--
--     pi.amount_minor / greatest(pi.band_to - coalesce(pi.band_from, 1) + 1, 1)
--
-- pass 7 matched at `greatest(`, and `[^();]{0,200}` ran forward to the next
-- open bracket — consuming `pi.band_to - coalesce` whole. The scan then resumed
-- AFTER `coalesce`, so `coalesce(` was never seen as a call and `pi.band_from`,
-- which is the genuine reader of the column, was never read. No other pass
-- catches it: pass 2 takes `coalesce` as the name after the minus, pass 3 needs
-- an operator after the name and finds a comma, and pass 5 wants a single
-- argument and a closing bracket.
--
-- This is not the two-hundred-character window. The column sits thirty
-- characters into the match. Raising the cap would not have found it, which is
-- why raising the cap is not the fix.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What is done here
--
-- 1. A named constant, erp.routine_decided_names()'s `not_a_call` list, holding
--    the json builders it already had plus thirteen SQL words that can sit in
--    front of an open bracket without a routine being called. Each is there
--    with its reason beside it. The words that OPEN A CONDITION — and, or, not,
--    where, when, case, then, having, if, elsif, between, any, all — are
--    deliberately not in it: what is inside their brackets really is decided on.
--
-- 2. Pass 7 taken by splitting the body at every open bracket instead of by one
--    regular expression. After the split every bracket is its own row: the name
--    of the call is the identifier the segment before it ends with, and the
--    arguments are the start of the segment after it, up to the first closing
--    bracket or semicolon. Nothing is consumed, so a call nested inside another
--    call's arguments is seen. Splitting rather than scanning overlapping
--    because an overlapping scan in SQL means restarting regexp_instr() once per
--    call, which is the length of the body times the number of calls in it; the
--    split is one pass and one window over the pieces.
--
-- What it costs. Pass 7 goes from one non-overlapping sweep to a split, a
-- window and a per-segment substring, all linear in the length of the body —
-- it does not become quadratic. It produces a row per open bracket where it
-- used to produce a row per call that the previous match had not eaten, which
-- is of the order of twice as many. The walk only reads a body that names a
-- table some maintenance door writes, which is the bound that was already
-- keeping this affordable, and erp.assert_write_only_columns() is registered in
-- erp_meta.diagnostic_exemption: it runs in the build, never behind a button on
-- a live console. The 200-character bound on one argument list is kept, and now
-- means something narrower than it did — one argument list rather than a run of
-- text that could span several calls. Widening it to 400 or 1000 changes no
-- verdict in this schema, which is why it is left where it is.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What moves, and what does not
--
-- Nothing. The two corrections are near-inverses on the one column that showed
-- them: the keyword list takes band_from out of the read set, and the split
-- puts it back through the arithmetic that really reads it. Every other column
-- the report calls read is still read, no row of erp_meta.write_only_column
-- becomes stale, and no new column is refused. The register stays at twenty-
-- three rows.
--
-- That is a finding rather than a disappointment. A detector wrong in both
-- directions at once can be green for the wrong reason, and this one was: the
-- only column where the two errors met was the only column that could show
-- either of them. Shipping the keyword list on its own would have opened a
-- finding on erp.price_item.band_from that is not a defect.
--
-- The precision this does NOT fix, said out loud rather than left to be found a
-- third time:
--
--   * An insert's column list is still swept. `insert into erp.location (code,
--     capacity, count_class)` matches pass 7 with the "routine name" location,
--     and its column list is counted as names decided on. The site that writes
--     the column is excluded from its own read, so this only matters where one
--     body inserts into one table and names another table with a column of the
--     same name. Fixing it means telling a column list from an argument list,
--     which needs the statement around it, not the bracket in front of it.
--   * Pass 5 — f(col) — keeps its own builders-only list. The sweep this
--     migration is about cannot happen there: a derived table's select list has
--     more than one identifier in it, and `x in (status)` there really is a
--     comparison. What it can still imagine is a single-column `values (x)`.
--   * A reader that is its own writer is still not counted, and pass 6's window
--     can still read past its clause. Both are stated in 20260916430000 and
--     both err towards calling a name READ, which is the direction that makes a
--     refusal trustworthy.
--
-- Proof: erp_test.write_only_column_suite() cases 9 and 10, one for each
-- direction, pinned to the two fragments above.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The live body is the one 20260916430000 left
-- -----------------------------------------------------------------------------
-- A full re-emission discards whatever is there. So refuse unless what is there
-- is what this migration was written against: the seven-pass body, with pass 7
-- still matching in one regular expression and the exclusion list still naming
-- only the builders.
-- ═════════════════════════════════════════════════════════════════════════════

do $anchor$
declare
  v_sig constant text := 'erp.routine_decided_names(text)';
  v_def constant text := pg_get_functiondef(v_sig::regprocedure);
  n_pass7 constant text :=
    '''\m([a-z_][a-z0-9_]*)\s*\(([^();]{0,200})'', ''g'') as f(frag),';
  n_excl constant text :=
    'where f.frag[1] <> all (array[''jsonb_build_object'',''json_build_object'',''jsonb_build_array'',';
begin
  if (length(v_def) - length(replace(v_def, n_pass7, ''))) / length(n_pass7) <> 1 then
    raise exception 'CLOVEERP_DECIDED_NAMES_UNRECOGNISED: % does not carry the single-regular-expression pass 7 this migration replaces', v_sig
      using hint = 'Something rewrote erp.routine_decided_names() after 20260916430000. Read pg_get_functiondef() of it and rebuild this migration against that body: re-emitting over a body nobody read would throw the later change away.';
  end if;
  if (length(v_def) - length(replace(v_def, n_excl, ''))) / length(n_excl) <> 1 then
    raise exception 'CLOVEERP_DECIDED_NAMES_UNRECOGNISED: % does not carry the builders-only exclusion this migration widens', v_sig
      using hint = 'The exclusion array in pass 7 is not the one 20260916430000 wrote. Read the live body before re-emitting.';
  end if;
  if position('not_a_call' in v_def) > 0 then
    raise exception 'CLOVEERP_DECIDED_NAMES_ALREADY_FIXED: % already names a not_a_call list', v_sig
      using hint = 'Another migration has already done this. Two migrations doing the same thing is how a repair gets applied twice and neither is the one that ran.';
  end if;
end
$anchor$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The instrument
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.routine_decided_names(p_code text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  -- The question is not "does this body mention the column" — every read door
  -- mentions every column it hands back. It is "did the value change anything".
  -- So a name counts when it sits where an outcome is decided, and does not when
  -- it sits where a value is merely passed on.
  --
  -- Seven passes rather than one alternation, because regexp_matches with 'g'
  -- does not overlap: one pattern that could match both `case` and `= x` would
  -- consume the first and lose the second, and `case t.casing when` would read
  -- as nothing at all.
  with code as (select lower(coalesce(p_code, '')) as c),
  -- The words pass 7 must not read as the name of a routine. The first ten are
  -- the json builders it has always had: their arguments are the answer being
  -- handed back, not a use. The rest are SQL syntax, and what follows each of
  -- them is a select list, a target list, or a clause another pass already
  -- reads:
  --
  --   as          a CTE body, or a column alias list — `as f(frag)`
  --   conflict    `on conflict (…)`, the key list of a write
  --   except      the second select of a set operation
  --   exists      `exists (select …)`; the predicate inside it is pass 1
  --   filter      `filter (where …)`; the where inside it is pass 1
  --   from        a derived table — `from (select a, b, c`. THE ONE THAT
  --               MATTERED: this swept a whole select list in as names
  --               something decided on, and on its own it kept
  --               erp.price_item.band_from out of the register.
  --   in          `in (select …)`; the left of the test is pass 3
  --   intersect   the second select of a set operation
  --   join        a joined derived table
  --   lateral     `lateral (select …)`
  --   over        a window frame; its partition by and order by are pass 6
  --   union       the second select of a set operation
  --   values      the values an insert writes, which is the opposite of a read
  --
  -- Not here on purpose: and, or, not, where, when, case, then, having, if,
  -- elsif, between, any and all. Those open a condition and what is inside
  -- their brackets IS decided on; excluding them would lose real reads.
  not_a_call as (
    select array['jsonb_build_object', 'json_build_object', 'jsonb_build_array',
                 'json_build_array', 'to_jsonb', 'to_json', 'row_to_json',
                 'jsonb_agg', 'json_agg', 'format',
                 'as', 'conflict', 'except', 'exists', 'filter', 'from', 'in',
                 'intersect', 'join', 'lateral', 'over', 'union', 'values'] as words
  ),
  -- 1. after a word that opens a condition.
  kw as (
    select m[1] as nm from code, regexp_matches(c,
      '\m(?:where|and|or|on|when|case|then|having|if|elsif|not|using|exists|between|any|all)\M'
      || '\s*(?:not\s+)?\(?\s*(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)', 'g') m
  ),
  -- 2. after a comparison, an arithmetic operator or an assignment. `=>` is a
  --    named argument and `->` is a json path, so both are stepped over.
  op as (
    select m[1] from code, regexp_matches(c,
      '(?:=(?!>)|<>|!=|<=|>=|<(?![@>])|>|\+|\*|/|\|\||-(?!>)|:=)'
      || '\s*(?:any\s*\(|all\s*\()?\s*(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)', 'g') m
  ),
  -- 3. before one.
  post as (
    select m[1] from code, regexp_matches(c,
      '(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)\s*'
      || '(?:=(?!>)|<>|!=|<=|>=|<(?![@>])|>|\+|\*|/|\|\||-(?!>)|:=|\mis\M|\min\M|\mnot\M'
      || '|\mlike\M|\milike\M|\masc\M|\mdesc\M|\minto\M|\mbetween\M)', 'g') m
  ),
  -- 4. the value of a scalar subquery, which is an assignment to something else
  --    however it is spelled.
  sub as (
    select m[1] from code, regexp_matches(c,
      '\(\s*select\s+(?:distinct\s+)?(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)', 'g') m
  ),
  -- 5. the whole of a parenthesised expression — f(col) — which is the value
  --    being transformed. ln(e.multiplier) is a use of multiplier;
  --    to_jsonb(a.item_classes) is not, which is why the json builders are out.
  --    This keeps the builders-only list rather than taking not_a_call: the
  --    sweep 20260919800000 is about cannot happen here, because it wants one
  --    identifier and a closing bracket and a select list has more than one,
  --    and `x in (status)` here really is a comparison.
  alone as (
    select m[2] from code, regexp_matches(c,
      '\m([a-z_][a-z0-9_]*)\s*\(\s*(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)\s*\)', 'g') m
     where m[1] <> all (array['jsonb_build_object','json_build_object','jsonb_build_array',
                              'json_build_array','to_jsonb','to_json','row_to_json',
                              'jsonb_agg','json_agg','format'])
  ),
  -- 6. every name in an order by, group by or partition by. The window is
  --    bounded rather than parsed, so it can read past the clause; that errs
  --    towards calling a name read, which is the safe direction.
  ordered as (
    select i[1] from code,
           regexp_matches(c, '\m(?:order|group|partition)\s+by\s+([^;]{1,200})', 'g') as f(frag),
           regexp_matches(f.frag[1], '(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)', 'g') i
  ),
  -- 7. an argument handed to another routine. A value that leaves this body for
  --    another one is being used, wherever it is used.
  --
  --    Taken by splitting the body at every open bracket rather than by one
  --    regular expression, because regexp_matches with 'g' does not overlap and
  --    a single pattern eats the name of the next call along with the arguments
  --    of this one: `greatest(pi.band_to - coalesce` was consumed whole and the
  --    scan never re-entered at the `coalesce(` holding the column. After the
  --    split every bracket is its own row — the name is the identifier the
  --    piece before the bracket ends with, the arguments are the start of the
  --    piece after it — so nothing is consumed and a call nested one deep is
  --    seen. The two-hundred-character bound is kept and now bounds one
  --    argument list rather than a run of text that could span several calls.
  seg as (
    select substring(s.txt from '\m([a-z_][a-z0-9_]*)\s*$') as nm,
           lead(s.txt) over (order by s.n) as args
      from code, unnest(string_to_array(c, '(')) with ordinality as s(txt, n)
  ),
  -- The calls, once the pieces that are not one have been dropped. Named apart
  -- from `handed` so the exclusion happens before the second regular
  -- expression rather than after it: a body is mostly json builders and
  -- keywords, and reading their arguments only to throw them away is the
  -- expensive half of this pass.
  call_site as (
    select seg.nm, substring(seg.args from '^[^);]{0,200}') as args
      from seg, not_a_call
     where seg.nm is not null
       and seg.args is not null
       and seg.nm <> all (not_a_call.words)
  ),
  handed as (
    select i[1] as nm
      from call_site,
           regexp_matches(call_site.args,
             '(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)', 'g') i
  )
  select coalesce(array_agg(distinct nm order by nm), '{}'::text[])
    from (select nm from kw
          union all select * from op
          union all select * from post
          union all select * from sub
          union all select * from alone
          union all select * from ordered
          union all select nm from handed) z(nm);
$$;
revoke all on function erp.routine_decided_names(text) from public, anon, authenticated;

comment on function erp.routine_decided_names(text) is
  'Every name a body uses where an outcome is decided: in a where, a case, a '
  'join predicate, an order by, an arithmetic expression, an assignment to '
  'something else, or as an argument handed to another routine. A name that '
  'appears only as the value half of a jsonb_build_object() pair, or only in a '
  'select list — a derived table''s included, which 20260919800000 stopped it '
  'reading as a call — is an echo of what was just saved and is not here. A '
  'call nested inside another call''s arguments IS here, which it was not '
  'before that migration.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The falsification, both ways
-- -----------------------------------------------------------------------------
-- erp_test.write_only_column_suite() is patched rather than re-emitted: its
-- last full definition is 20260916430000's and 20260916500000 moved its
-- falsification off erp.location.capacity, which was wired, onto
-- erp.notification_channel.credential_ref, which is deliberate and stays. Both
-- anchors are checked to occur exactly once and that earlier patch is checked
-- to have survived, because re-emitting the 16 September text would put the
-- falsification back on a column that is now read and the suite would fail for
-- a reason that has nothing to do with this file.
--
-- Two cases, one for each direction, pinned to the two fragments from
-- erp.invoice_overage_lines() that showed the defect:
--
--   9   the detector no longer claims a read where a derived table's select
--       list was being swept in
--   10  the detector now sees a read that sits inside a call inside another
--       call's arguments, which the non-overlapping scan used to eat
-- ═════════════════════════════════════════════════════════════════════════════

do $suite$
declare
  v_sig constant text := 'erp_test.write_only_column_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  n_tail constant text :=
$n$  passed := v_reg > 0 and v_wrong = 0;
  detail := format('%s registered column(s), %s of which no longer belong here', v_reg, v_wrong);
  return next;
end;$n$;
  r_tail constant text :=
$r$  passed := v_reg > 0 and v_wrong = 0;
  detail := format('%s registered column(s), %s of which no longer belong here', v_reg, v_wrong);
  return next;

  -- 9. The over-count, from erp.invoice_overage_lines(). Before 20260919800000
  --    pass 7 read `from (` as a call named `from` and swept the derived
  --    table's select list in, which is the only reason
  --    erp.price_item.band_from was not a finding.
  case_name := 'a derived table''s select list is not a read';
  v_names := erp.routine_decided_names(
    'select x.band_from from (select p.amount_minor, pi2.band_from, pi2.band_to from erp.price_item pi2) x');
  passed := not ('band_from' = any(v_names));
  detail := array_to_string(v_names, ', ');
  return next;

  -- 10. The under-count, from the same routine. `greatest(pi.band_to -
  --     coalesce` was consumed whole by the non-overlapping scan, so the
  --     `coalesce(` that actually reads the column was never entered. This is
  --     the arithmetic 20260919010000 kept deliberately as the reader of
  --     erp.price_item.band_from.
  case_name := 'a read inside a call inside another call is a read';
  v_names := erp.routine_decided_names(
    'select pi.amount_minor / greatest(pi.band_to - coalesce(pi.band_from, 1) + 1, 1) from erp.price_item pi');
  passed := 'band_from' = any(v_names);
  detail := array_to_string(v_names, ', ');
  return next;
end;$r$;
begin
  if position('erp.notification_channel.credential_ref' in v_def) = 0
     or position('erp.location.capacity%' in v_def) > 0 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: % does not falsify on erp.notification_channel.credential_ref the way 20260916500000 left it', v_sig
      using hint = 'A later migration moved the falsification again. Read pg_get_functiondef() of the suite and re-point this patch at the column it names now.';
  end if;
  if (length(v_def) - length(replace(v_def, n_tail, ''))) / length(n_tail) <> 1 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: % does not end in the eighth case this migration appends to', v_sig
      using hint = 'The suite body is not the one 20260916430000 wrote and 20260916500000 patched. Read the live body and rebuild the anchor from it.';
  end if;
  execute replace(v_def, n_tail, r_tail);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  -- Matched without the apostrophe: prosrc holds the source text, so the
  -- case name is stored with its quote doubled.
  if position('select list is not a read' in v_def) = 0
     or position('a read inside a call inside another call is a read' in v_def) = 0 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: the two new cases did not land in %', v_sig
      using hint = 'The replacement did not take. Compare the needle with pg_get_functiondef() of the suite.';
  end if;
  if position('erp.notification_channel.credential_ref' in v_def) = 0 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: the patch lost 20260916500000''s falsification target from %', v_sig
      using hint = 'The re-emission dropped an earlier patch, which is the whole reason this migration anchors on the live body.';
  end if;
end
$suite$;

-- The count is pinned at both ends, so eight becomes ten in the wrapper too.
do $count$
declare
  v_sig constant text := 'erp_test.assert_write_only_column_suite()';
  v_def constant text := pg_get_functiondef(v_sig::regprocedure);
  n_count constant text := '  c_expected constant integer := 8;';
  r_count constant text := '  c_expected constant integer := 10;';
begin
  if (length(v_def) - length(replace(v_def, n_count, ''))) / length(n_count) <> 1 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: % does not pin eight cases', v_sig
      using hint = 'Either a later migration already moved the count, or the wrapper was rewritten. Read pg_get_functiondef() of it.';
  end if;
  execute replace(v_def, n_count, r_count);
  if position(r_count in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: the pinned count did not move in %', v_sig;
  end if;
end
$count$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Generators, then the checks that read what changed
-- -----------------------------------------------------------------------------
-- erp.assert_write_only_columns() is the point of the file: it walks every
-- routine body in the catalogue with the corrected instrument and must come
-- back with the same twenty-three registered columns and no new finding. The
-- suite proves the instrument itself, in both directions, on the two fragments
-- that showed the defect.
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_write_only_columns();
select erp_test.assert_write_only_column_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
