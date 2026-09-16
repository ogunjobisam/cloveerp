-- =============================================================================
-- 20260916180000  A screen reads what the door returns
-- -----------------------------------------------------------------------------
-- A panel declares a door and the names it reads off each row in one breath —
-- fn: "erp_delivery_performance" and cell: "otif_pct" — and nothing compared
-- the two. The renderer shows a missing key as an em dash and the arithmetic
-- reads it as zero, so a name the door never emits does not fail. It produces a
-- confident, permanently wrong number, which is worse than an error: an error
-- is noticed.
--
-- Nothing in the build could see this class. A suite that proves a door returns
-- the right figures agrees with a screen that asks it for a name it does not
-- have; erp.assert_app_doors_exist() proves the door exists and
-- erp.assert_app_gates_match() proves the gate is the door's, and neither asks
-- what comes back. TypeScript cannot help either: every row is
-- Record<string, unknown>, so r["otif_pct"] type-checks against a door that has
-- never heard of it.
--
-- One static walk over src on 16 September found thirty-five such names on
-- sixteen doors, including six tiles whose arithmetic was structurally
-- constant:
--
--   * Logistics OTIF was 0% and red for every organisation, and "Deliveries"
--     was 0, because erp.delivery_performance() answers by CARRIER —
--     carrier_code, carrier_name, shipments, on_time, on_time_pct,
--     avg_days_late, freight_minor — and the screen asked for otif_pct,
--     deliveries, in_full and party.
--   * Production showed every works order 0 completed and 0 scrapped, and
--     "Completion" was 0% of ordered, because the door says completed and
--     scrapped.
--   * Planning's "Unacknowledged" counted every exception ever raised: it
--     tested !r["is_acknowledged"] against a door that emits acknowledged_at,
--     and the negation of a key that does not exist is true of every row.
--   * Stock's "Below cover" was 0 for ever: it matched health or status
--     against "short", "below", "critical" on a door whose only such column is
--     finding, whose words are "negative on hand", "committed beyond what is on
--     hand", "expiring within thirty days", "never moved", "no movement in six
--     months" and "healthy".
--   * Reporting's "Specification coverage" was 0%: erp.part5_summary() says
--     built_pct, not coverage_pct.
--   * The forecast picker offered blank options and submitted an empty code,
--     because erp_forecast_versions answers with forecast and forecast_name.
--
-- What changes here is the check, not the screens: the screens are corrected in
-- the same commit, and this is what stops the next rename being noticed by a
-- customer. The build harvests every (door, column) pair the desk declares
-- (supabase/ci/app_columns.sh) and hands the list to
-- erp.assert_app_columns_exist(), which derives what each door can produce FROM
-- THE BUILT DATABASE rather than from the migration text — which is the whole
-- point, because a rename lands in the database and only the database knows it
-- happened.
--
-- What a door can produce:
--
--   * returns table (…) or out parameters   → those names;
--   * returns setof <composite>             → that type's columns;
--   * returns jsonb                         → the jsonb_build_object key PATHS
--                                             the body writes, and where the
--                                             body is to_jsonb(x) or
--                                             jsonb_agg(to_jsonb(x)) over an
--                                             erp.* function or view, that
--                                             function's or view's own columns;
--   * a door that is nothing but a call to one routine takes that routine's
--     shape.
--
-- A door's answer is not always flat, so a key is a PATH.
-- public.erp_settlement_statement() answers with one object whose 'lines' key
-- holds an array of objects, each of whose 'candidates' key holds another;
-- public.erp_analytics_contract() answers with 'views', 'credentials' and
-- 'findings', three arrays of different shapes. A picker renders one of them —
-- options: { path: "lines", value: "line_id" } — and line_id is a name of a
-- lines element, not of the answer. So the walk reports 'lines',
-- 'lines.line_id', 'lines.candidates', 'lines.candidates.subledger_item_id',
-- and the harvest asks under the path the declaration names. Union-ing every
-- nested key into one flat set would have been less work and would have said
-- that a picker on 'credentials' may read 'module_code', which belongs to
-- 'views' — the very class of defect this check exists to refuse.
--
-- Then, per pair:
--
--   * the name is one the door produces        → the pair holds;
--   * the door answers with json the text
--     cannot name — a list of plain strings,
--     a shape built somewhere this cannot
--     follow                                   → counted, not failed;
--   * the door does not answer with rows at
--     all                                      → counted, not failed;
--   * erp_meta.app_column_allowance accounts
--     for it, with a written reason            → allowed, and counted;
--   * anything else                            → refused, naming the door, the
--                                                name, and what the door does
--                                                return.
--
-- The register is not a way to be quiet. A row for a pair the door has since
-- gained is refused as stale, and — when the build hands over the whole
-- application — so is a row for a pair no screen names any more. Eight pairs
-- are registered below, and every one of them is a door that cannot answer the
-- question the screen is asking, not a name that needed correcting.
--
-- Proof: erp_test.app_column_suite() (9 cases, wrapper pinned) and the build
-- step "Every column a screen reads is one its door returns".
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register: a pair the door cannot answer, with why it stays
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.app_column_allowance (
  door          text not null check (door ~ '^erp_[a-z0-9_]+$'),
  column_name   text not null check (column_name ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  reason        text not null check (length(btrim(reason)) >= 40),
  registered_at timestamptz not null default now(),
  primary key (door, column_name)
);

select erp_meta.register_table('erp_meta', 'app_column_allowance', 'platform_internal',
  'The (door, column) pairs a screen declares that its door cannot answer, each with why the screen still asks. erp.assert_app_columns_exist() refuses any other unanswerable pair, and refuses a row here whose door has since gained the column or whose pair no screen names any more.');

comment on table erp_meta.app_column_allowance is
  'Specification v1.6 Part 5. A name a screen reads off a door''s rows either '
  'is one the door returns or has a row here saying why the screen asks for '
  'something the door has not got. The default is failure; this is the list of '
  'places where the gap is known, written down, and waiting on a door rather '
  'than on a rename.';

insert into erp_meta.app_column_allowance (door, column_name, reason) values
  -- The logistics OTIF panel, tiles and chart. erp.delivery_performance()
  -- measures the CARRIER's punctuality: carrier_code, carrier_name, shipments,
  -- on_time, on_time_pct, avg_days_late, freight_minor. The screen asks the
  -- customer-facing question — on time in full, by customer — which no door
  -- answers today. Renaming party to carrier_name would put carrier data under
  -- a heading that says Customer, which is a worse lie than a blank, and
  -- otif_pct is not on_time_pct: in full is a different measure from on time.
  ('erp_delivery_performance', 'otif_pct',
   'On time IN FULL by customer. erp.delivery_performance() measures carrier punctuality only (on_time_pct over shipments) and knows nothing about lines delivered short, so no rename makes this true; it wants a door that reads delivery lines against their order lines.'),
  ('erp_delivery_performance', 'deliveries',
   'The count of customer deliveries in the window. The door counts shipments by carrier, which is a different population — one shipment can carry several deliveries — so the figure would be wrong under the right name.'),
  ('erp_delivery_performance', 'in_full',
   'Deliveries that went out complete. Nothing in erp.delivery_performance() compares what was delivered with what was ordered, so there is no column to rename this to.'),
  ('erp_delivery_performance', 'party',
   'The customer a delivery went to. The door groups by carrier; showing carrier_name under a heading that says Customer would be a confident wrong answer rather than an absent one.'),
  ('erp_delivery_performance', 'site',
   'The fallback when a customer cannot be named. The door has neither a customer nor a site, only the carrier, so the fallback has nothing to fall back to either.'),
  -- The two inventory reports know which site a position is at, by id, and
  -- their sibling erp.stock_valuation_report() already carries the code
  -- alongside it. Showing a uuid under a heading that says Site would be
  -- unreadable, so the column stays and the gap is written down.
  ('erp_stock_health', 'site_code',
   'The site a stock position is at, in the code a person reads. erp.stock_health_report() carries site_id only; its sibling erp.stock_valuation_report() carries site_id AND site_code, and this wants the same pair rather than a uuid printed under Site.'),
  ('erp_stock_ageing', 'site_code',
   'The site an ageing band is at, in the code a person reads. erp.stock_ageing_report() carries site_id only, for the same reason and with the same remedy as erp_stock_health.'),
  -- A change request names what it proposes to change by id and type. There is
  -- no human label for the record anywhere in the door.
  ('erp_change_requests', 'object_label',
   'The record a proposed change is against, said in words. public.erp_change_requests emits object_type and object_id and no label of any kind; the id is a uuid, which is not what the Record column is for.')
on conflict (door, column_name) do update set reason = excluded.reason;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Reading the key paths a body builds
-- ═════════════════════════════════════════════════════════════════════════════

-- Most read doors answer with jsonb_build_object('a', x, 'b', y). The keys are
-- at the call's own level and in even positions; a literal in an argument's
-- expression is not a key. A regular expression cannot tell those apart across
-- nested parentheses, so this walks.
--
-- And a door's answer is not always flat. public.erp_settlement_statement()
-- answers with one object whose 'lines' key holds an array of objects, each of
-- whose 'candidates' key holds another; public.erp_analytics_contract() answers
-- with 'views', 'credentials' and 'findings', three arrays of different shapes.
-- A picker renders ONE of those arrays — options: { path: "lines", value:
-- "line_id" } — and line_id is a name of a lines element, not of the answer.
--
-- So a key is reported as a path: 'lines', then 'lines.line_id',
-- 'lines.candidates', 'lines.candidates.subledger_item_id'. Union-ing them all
-- into one flat set would have been less work and would have said that a picker
-- on 'credentials' may read 'module_code', which belongs to 'views' — which is
-- the very class of defect this check exists to refuse. A key's own value is
-- walked for the nested build it holds, which is what makes the path right.
create or replace function erp.jsonb_object_paths(
  p_fragment text, p_prefix text default '', p_depth integer default 0)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  c_call constant text := 'jsonb_build_object';
  v_out  text[] := '{}';
  v_n    integer := length(coalesce(p_fragment, ''));
  v_i    integer := 1;
  v_at   integer;
  v_j    integer;
  v_depth integer;
  v_arg  integer;
  v_from integer;
  v_key  text;
  v_c    text;
  v_lit  text;
  v_slice text;
begin
  -- 'lines.candidates.subledger_item_id' is the deepest anything reads.
  if p_depth > 3 then
    return v_out;
  end if;

  loop
    v_at := position(c_call in substr(p_fragment, v_i));
    exit when v_at = 0;
    v_j := v_i + v_at - 1 + length(c_call);
    -- The default resumption: just past the name, so a call this one is not is
    -- still found. When the call is walked, resumption moves past its close, so
    -- a nested build is reached by the recursion and not a second time here.
    v_i := v_j;
    while v_j <= v_n and substr(p_fragment, v_j, 1) ~ '\s' loop
      v_j := v_j + 1;
    end loop;
    continue when v_j > v_n or substr(p_fragment, v_j, 1) <> '(';

    v_depth := 0;
    v_arg := 0;
    v_key := null;
    v_from := v_j + 1;
    while v_j <= v_n loop
      v_c := substr(p_fragment, v_j, 1);
      if v_c = '''' then
        -- A literal, with '' for an embedded quote. Stepped over whole, so a
        -- comma or a bracket inside it is not punctuation.
        v_j := v_j + 1;
        while v_j <= v_n loop
          if substr(p_fragment, v_j, 1) = '''' then
            exit when substr(p_fragment, v_j + 1, 1) <> '''';
            v_j := v_j + 2;
            continue;
          end if;
          v_j := v_j + 1;
        end loop;
        v_j := v_j + 1;
        continue;
      end if;

      v_slice := null;
      if v_c = '(' or v_c = '[' then
        v_depth := v_depth + 1;
        if v_depth = 1 then
          v_from := v_j + 1;
        end if;
      elsif v_c = ')' or v_c = ']' then
        v_depth := v_depth - 1;
        if v_depth = 0 then
          v_slice := substr(p_fragment, v_from, v_j - v_from);
        end if;
      elsif v_c = ',' and v_depth = 1 then
        v_slice := substr(p_fragment, v_from, v_j - v_from);
      end if;

      if v_slice is not null then
        if v_arg % 2 = 0 then
          -- An even argument is this object's key.
          v_lit := substring(v_slice from '^\s*''([a-z][a-z0-9_]*)''(?:::[a-z]+)?\s*$');
          v_key := v_lit;
          if v_lit is not null and not (p_prefix || v_lit = any(v_out)) then
            v_out := v_out || (p_prefix || v_lit);
          end if;
        elsif v_key is not null then
          -- The odd argument is that key's value: whatever it builds is that
          -- key's own shape.
          v_out := v_out || erp.jsonb_object_paths(v_slice, p_prefix || v_key || '.', p_depth + 1);
        end if;
        if v_depth = 0 then
          exit;
        end if;
        v_arg := v_arg + 1;
        v_from := v_j + 1;
      end if;
      v_j := v_j + 1;
    end loop;
    v_i := v_j + 1;
  end loop;

  return (select coalesce(array_agg(distinct c order by c), '{}'::text[]) from unnest(v_out) c);
end;
$$;
revoke all on function erp.jsonb_object_paths(text, text, integer) from public, anon, authenticated;

comment on function erp.jsonb_object_paths(text, text, integer) is
  'Every key path a function body builds with jsonb_build_object(), read by '
  'walking the call rather than by regular expression: a top-level key as '
  'itself, and the keys of a nested build under the key whose value holds it, '
  'so a picker that renders one array of the answer is judged against that '
  'array. Hand it erp.prosrc_code(prosrc): a key written in a comment is not a '
  'key.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. What a routine or a relation produces
-- ═════════════════════════════════════════════════════════════════════════════

-- null means "this is not a row source the text can read" — a scalar, or a name
-- that does not exist. An empty array means "it answers with json this cannot
-- name". Neither is a failure; both are said plainly so the caller can count
-- them rather than guess.
create or replace function erp.routine_output_columns(
  p_schema text, p_name text, p_depth integer default 0)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cols text[];
  v_got  text[];
  v_oid  oid;
  v_code text;
  v_ret  text;
  v_ns   text;
  v_nm   text;
  r      record;
begin
  if p_depth > 4 then
    return null;
  end if;

  -- A table or a view says its own columns.
  select array_agg(a.attname::text order by a.attnum) into v_cols
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    join pg_catalog.pg_attribute a on a.attrelid = c.oid
   where n.nspname = p_schema and c.relname = p_name
     and c.relkind in ('r', 'v', 'm', 'p', 'f')
     and a.attnum > 0 and not a.attisdropped;
  if v_cols is not null then
    return v_cols;
  end if;

  select p.oid, erp.prosrc_code(p.prosrc), t.typname::text
    into v_oid, v_code, v_ret
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    join pg_catalog.pg_type t on t.oid = p.prorettype
   where n.nspname = p_schema and p.proname = p_name
   order by p.pronargs desc
   limit 1;
  if v_oid is null then
    return null;
  end if;

  -- returns table (…), and out parameters, which are the same thing to a caller.
  -- proargmodes is null when every parameter is in, which is the ordinary case
  -- and the one with no output columns at all.
  select array_agg(p.proargnames[i] order by i) into v_cols
    from pg_catalog.pg_proc p,
         generate_subscripts(p.proargnames, 1) as i
   where p.oid = v_oid
     and p.proargmodes is not null
     and p.proargmodes[i] in ('t', 'o')
     and p.proargnames[i] is not null
     and p.proargnames[i] <> '';
  if v_cols is not null then
    return v_cols;
  end if;

  -- returns setof <composite>: the type's own columns.
  if v_ret not in ('jsonb', 'json') then
    select array_agg(a.attname::text order by a.attnum) into v_cols
      from pg_catalog.pg_type t
      join pg_catalog.pg_class c on c.oid = t.typrelid
      join pg_catalog.pg_attribute a on a.attrelid = c.oid
     where t.oid = (select p.prorettype from pg_catalog.pg_proc p where p.oid = v_oid)
       and c.relkind in ('r', 'v', 'm', 'c', 'p')
       and a.attnum > 0 and not a.attisdropped;
    return v_cols;
  end if;

  -- returns jsonb: the key paths the body writes, plus whatever it wraps whole.
  v_cols := erp.jsonb_object_paths(v_code);

  for r in
    select m[1] as al
      from regexp_matches(v_code,
             '\m(?:to_jsonb|row_to_json)\s*\(\s*([a-z_][a-z0-9_]*)\s*\)', 'gi') m
  loop
    -- The relation or routine that alias is bound to, in a from or a join.
    -- The name is closed with a lookahead so a shorter prefix of it can never
    -- backtrack into standing for the alias: from erp.tax_report(…) t would
    -- otherwise read as erp.tax_repor aliased t.
    select b[1], b[2] into v_ns, v_nm
      from regexp_matches(v_code,
             '\m(?:from|join)\s+(erp[a-z_]*)\.([a-z_][a-z0-9_]*)(?![a-z0-9_])\s*'
             || '(?:\((?:[^()]|\([^()]*\))*\))?\s*(?:as\s+)?' || r.al || '\M', 'i') b;
    if v_ns is not null then
      v_got := erp.routine_output_columns(v_ns, v_nm, p_depth + 1);
      if v_got is not null then
        v_cols := (select coalesce(array_agg(distinct c order by c), '{}'::text[])
                     from unnest(v_cols || v_got) c);
      end if;
    end if;
  end loop;

  -- A door that is nothing but a call takes the shape of what it calls.
  if cardinality(v_cols) = 0 then
    for r in
      select m[1] as ns, m[2] as nm
        from regexp_matches(v_code, '\m(erp[a-z_]*)\.([a-z_][a-z0-9_]*)\s*\(', 'gi') m
    loop
      v_got := erp.routine_output_columns(r.ns, r.nm, p_depth + 1);
      if v_got is not null and cardinality(v_got) > 0 then
        v_cols := (select coalesce(array_agg(distinct c order by c), '{}'::text[])
                     from unnest(v_cols || v_got) c);
      end if;
    end loop;
  end if;

  return v_cols;
end;
$$;
revoke all on function erp.routine_output_columns(text, text, integer) from public, anon, authenticated;

comment on function erp.routine_output_columns(text, text, integer) is
  'Every column name a relation or routine can put in front of a caller, read '
  'from the built database: TABLE parameters, out parameters, a composite '
  'return type''s columns, or — for a jsonb door — the key paths its body '
  'builds (a nested array''s keys under the key that holds it) and the columns '
  'of whatever it wraps with to_jsonb(). null means it is not a row source; an '
  'empty array means it answers with json this cannot name.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The judge
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.app_column_report(p_pairs text[])
returns table(door text, column_name text, verdict text, detail text)
language sql
stable
set search_path = ''
as $$
  with pair as (
    select split_part(x, '|', 1) as door, split_part(x, '|', 2) as column_name
      from unnest(p_pairs) as x
  ),
  -- Materialised, and over the distinct doors, so the walk of a door's body
  -- happens once for the door rather than once for every name read off it.
  named as materialized (
    select distinct p.door from pair p
  ),
  answered as materialized (
    select d.door,
           exists (select 1
                     from pg_catalog.pg_proc pr
                     join pg_catalog.pg_namespace n on n.oid = pr.pronamespace
                    where n.nspname = 'public' and pr.proname = d.door) as present,
           erp.routine_output_columns('public', d.door) as cols
      from named d
  )
  select p.door, p.column_name,
         case
           when not a.present                          then 'missing_door'
           when a.cols is null                         then 'not_a_row_source'
           when p.column_name = any(a.cols)            then 'match'
           when cardinality(a.cols) = 0                then 'opaque'
           when exists (select 1 from erp_meta.app_column_allowance g
                         where g.door = p.door and g.column_name = p.column_name)
                                                       then 'allowed'
           else 'dead'
         end,
         case
           when not a.present then 'no such door in schema public'
           when a.cols is null then 'the door does not answer with rows'
           when cardinality(a.cols) = 0 then 'the door answers with json this cannot name'
           else 'the door returns ' || array_to_string(a.cols, ', ')
         end
    from pair p
    join answered a on a.door = p.door
   order by p.door, p.column_name
$$;
revoke all on function erp.app_column_report(text[]) from public, anon, authenticated;

comment on function erp.app_column_report(text[]) is
  'For each ''door|column'' pair the desk declares: match, allowed (registered '
  'in erp_meta.app_column_allowance), opaque, not_a_row_source, missing_door or '
  'dead, with the names the door does return. Read from the built database, so '
  'a rename in a migration is seen the day it lands.';

create or replace function erp.assert_app_columns_exist(
  p_pairs text[], p_whole_application boolean default false)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n        integer := coalesce(cardinality(p_pairs), 0);
  v_doors    integer;
  v_match    integer;
  v_allowed  integer;
  v_opaque   integer;
  v_dead     integer;
  v_findings text;
  v_answered text[];
  v_stale    text;
begin
  if v_n = 0 then
    raise exception 'CLOVEERP_APP_NAMES_NO_COLUMNS: the list of door and column pairs is empty'
      using errcode = '22023',
            hint = 'supabase/ci/app_columns.sh extracts every (door, column) pair from src; an empty list means the extraction found nothing, which is not a pass.';
  end if;

  -- One walk. Every figure the verdict needs, and the pairs the door does
  -- answer, come out of the same pass.
  select count(*) filter (where r.verdict = 'match'),
         count(*) filter (where r.verdict = 'allowed'),
         count(*) filter (where r.verdict in ('opaque', 'not_a_row_source')),
         count(*) filter (where r.verdict in ('dead', 'missing_door')),
         string_agg(format('  %s reads %s — %s', r.door, r.column_name, r.detail), E'\n'
                    order by r.door, r.column_name)
           filter (where r.verdict in ('dead', 'missing_door')),
         count(distinct r.door),
         coalesce(array_agg(r.door || '|' || r.column_name)
                    filter (where r.verdict = 'match'), '{}'::text[])
    into v_match, v_allowed, v_opaque, v_dead, v_findings, v_doors, v_answered
    from erp.app_column_report(p_pairs) r;

  if v_dead > 0 then
    raise exception E'CLOVEERP_APP_COLUMN_DEAD: % name(s) a screen reads are not names their door returns:\n%',
      v_dead, v_findings
      using errcode = 'P0001',
            hint = 'The door is the answer. Correct the screen to the name the door returns; where the door has not got what the screen needs, say so in erp_meta.app_column_allowance with the reason, and do not leave the screen rendering a zero nobody can tell from a real one.';
  end if;

  -- A register that has stopped being true is a register that hides things. A
  -- row for a pair the door has since gained is stale; so, when the build hands
  -- over the whole application, is a row for a pair no screen names any more.
  select string_agg(format('  %s reads %s — %s', g.door, g.column_name, g.reason), E'\n'
                    order by g.door, g.column_name)
    into v_stale
    from erp_meta.app_column_allowance g
   where (g.door || '|' || g.column_name) = any(v_answered)
      or (p_whole_application
          and not ((g.door || '|' || g.column_name) = any(p_pairs)));
  if v_stale is not null then
    raise exception E'CLOVEERP_APP_COLUMN_REGISTER_STALE: the register accounts for name(s) that no longer need it:\n%',
      v_stale
      using errcode = 'P0001',
            hint = 'Either the door has gained the column, or no screen reads it any more. Remove the row: a register kept past its reason is a list of things nobody is looking at.';
  end if;

  return format('screen columns: %s pair(s) on %s door(s); %s are names the door returns, %s are registered as names it has not got, %s are doors this cannot read',
                v_n, v_doors, v_match, v_allowed, v_opaque);
end;
$$;
revoke all on function erp.assert_app_columns_exist(text[], boolean) from public, anon, authenticated;

comment on function erp.assert_app_columns_exist(text[], boolean) is
  'Refuses any (door, column) pair the desk declares where the column is not '
  'one the door returns and erp_meta.app_column_allowance does not account for '
  'it, and refuses a register row that has stopped being needed. The build '
  'extracts the pairs from src and calls this; the shape half of what '
  'erp.assert_app_gates_match() does for permissions.';

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_app_columns_exist', null,
   'Takes the door and column pairs supabase/ci/app_columns.sh extracts from the application source; only the build can know what the application declares, and it calls this with that list.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_app_columns_exist',
   'Takes the list of door and column pairs the application source declares. A console button has no such list; the build extracts it and calls this.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.app_column_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_ok         boolean;
  v_msg        text;
  v_registered integer;
  v_answerable integer;
begin
  -- 1
  v_msg := erp.assert_app_columns_exist(array['erp_works_orders|order_number']);
  case_name := 'a name the door returns is accepted';
  passed := v_msg like 'screen columns: 1 pair(s) on 1 door(s); 1 are names the door returns%';
  detail := v_msg;
  return next;

  -- 2. The name the production panel used to read, kept as the falsification.
  case_name := 'a name the door does not return is refused, and the door''s own names are given';
  begin
    perform erp.assert_app_columns_exist(array['erp_works_orders|quantity_completed']);
    v_ok := false; v_msg := 'a dead column was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_COLUMN_DEAD%'
        and sqlerrm like '%erp_works_orders reads quantity_completed%'
        and sqlerrm like '%completed%';
    v_msg := left(sqlerrm, 200);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 3. public.erp_timezones answers with a list of plain strings, so there is
  -- no key to name and nothing this can judge.
  case_name := 'a door answering with json this cannot name is counted, not failed';
  v_msg := erp.assert_app_columns_exist(array['erp_timezones|name']);
  passed := v_msg like '%1 are doors this cannot read%';
  detail := v_msg;
  return next;

  -- 4
  case_name := 'a door that does not exist is refused';
  begin
    perform erp.assert_app_columns_exist(array['erp_zz_no_such_door|code']);
    v_ok := false; v_msg := 'a missing door was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_COLUMN_DEAD%' and sqlerrm like '%no such door%';
    v_msg := left(sqlerrm, 160);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 5
  case_name := 'an extraction that found nothing is not a pass';
  begin
    perform erp.assert_app_columns_exist(array[]::text[]);
    v_ok := false; v_msg := 'an empty list was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_NAMES_NO_COLUMNS%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 6
  case_name := 'a pair the register accounts for is allowed';
  v_msg := erp.assert_app_columns_exist(array['erp_delivery_performance|otif_pct']);
  passed := v_msg like '%1 are registered as names it has not got%';
  detail := v_msg;
  return next;

  -- 7. A register row for a name the door does return. Built, judged and undone.
  case_name := 'a register row the door no longer needs is refused as stale';
  v_msg := null;
  begin
    insert into erp_meta.app_column_allowance (door, column_name, reason) values
      ('erp_works_orders', 'order_number',
       'A falsification raised and undone inside erp_test.app_column_suite(); if this row is ever seen in a built database, the suite did not clean up after itself.');
    begin
      perform erp.assert_app_columns_exist(array['erp_works_orders|order_number']);
      v_msg := 'a stale register row was accepted';
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  passed := v_msg like 'CLOVEERP_APP_COLUMN_REGISTER_STALE%'
        and not exists (select 1 from erp_meta.app_column_allowance g
                         where g.door = 'erp_works_orders' and g.column_name = 'order_number');
  detail := left(coalesce(v_msg, 'no verdict'), 160);
  return next;

  -- 8b. A nested array is read under its own path, and a name of one array is
  -- not a name of another in the same answer. This is the property that makes
  -- the path walk worth its length: flattening would pass all four of these.
  case_name := 'a nested array''s names are read under its own path, and not under another array''s';
  v_msg := erp.assert_app_columns_exist(array[
    'erp_settlement_statement|lines.line_id',
    'erp_settlement_statement|lines.candidates.subledger_item_id',
    'erp_analytics_contract|views.module_code']);
  v_ok := v_msg like '%3 are names the door returns%';
  begin
    -- module_code belongs to views, not to credentials.
    perform erp.assert_app_columns_exist(array['erp_analytics_contract|credentials.module_code']);
    v_ok := false;
  exception when others then
    v_ok := v_ok and sqlerrm like 'CLOVEERP_APP_COLUMN_DEAD%'
        and sqlerrm like '%credentials.module_code%';
  end;
  begin
    -- and line_id is a name of a statement's line, not of the statement.
    perform erp.assert_app_columns_exist(array['erp_settlement_statement|line_id']);
    v_ok := false;
  exception when others then
    v_ok := v_ok and sqlerrm like 'CLOVEERP_APP_COLUMN_DEAD%';
  end;
  passed := v_ok;
  detail := v_msg;
  return next;

  -- 9. Every registered pair is still one its door cannot answer.
  case_name := 'every pair in the register is still a pair its door cannot answer';
  select count(*), count(*) filter (where r.verdict <> 'allowed')
    into v_registered, v_answerable
    from erp.app_column_report(
           (select array_agg(g.door || '|' || g.column_name)
              from erp_meta.app_column_allowance g)) r;
  passed := v_registered > 0 and v_answerable = 0;
  detail := format('%s registered pair(s), %s of which the door can answer',
                   v_registered, v_answerable);
  return next;
end;
$$;
revoke all on function erp_test.app_column_suite() from public, anon, authenticated;

create or replace function erp_test.assert_app_column_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _app_column on commit drop as
    select * from erp_test.app_column_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _app_column;
  drop table _app_column;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_APP_COLUMN_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_APP_COLUMN_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail;
  end if;
  return format('screen columns: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_app_column_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The words the corrected screens now say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text, v.note
  from (values
    ('Finding',
     'Column heading on the Stock health panel. erp.stock_health_report() answers with a finding in words — negative on hand, expiring within thirty days, healthy — not with a status code, and the heading now says what the column holds.'),
    ('Positions with a finding',
     'Tile on Stock. It counts the positions erp.stock_health_report() has something to say about; it used to say "Below cover" and count nothing, because no column of that door has ever held the words it matched.'),
    ('not healthy',
     'The hint under the Stock tile that counts positions with a finding: the word the door itself uses for the ones it has nothing to say about.'),
    ('Matched value',
     'Column heading on the Duplicate candidates panel. erp.duplicate_candidates() matches on a normalised key and returns that key; it has never returned a score, which is what the column used to claim to show.')
  ) as v(text, note)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_app_column_suite();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
