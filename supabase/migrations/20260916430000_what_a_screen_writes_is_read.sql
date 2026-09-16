set lock_timeout = '30s';

-- =============================================================================
-- 20260916430000  What a screen writes is read
-- -----------------------------------------------------------------------------
-- The twin of 20260916180000. That one refuses a name a screen READS off a door
-- that does not return it. This one refuses a value a screen WRITES that
-- nothing reads.
--
-- It is the same defect seen from the other end, and it is the worse half. A
-- name the door does not return renders as an em dash or a zero, which somebody
-- eventually queries. A control that writes a value nothing consults renders
-- perfectly: the field saves, the toast says saved, the value comes back the
-- next time the screen is opened, and the behaviour it promises never happens.
-- Nobody queries a setting that looks like it worked.
--
-- One audit on 16 September found the class repeating:
--
--   * an entire approval-bands screen — bands, departments, named approvers —
--     that changed who approves nothing;
--   * the account determination matrix, and its "record a deliberate override";
--   * a location's capacity, under the words "Holds at most", which put-away
--     has never consulted, and its count_class (A/B/C), which cycle counting
--     has never consulted;
--   * four fields on erp.release_area — channel_code, order_type_code,
--     item_classes, min_quantity — that nothing tests;
--   * erp.item_supplier.split_pct, "Sourcing split %", which splits nothing,
--     and supplier_item_code, "what the supplier calls this on their
--     paperwork", printed on nothing they see;
--   * erp.reason_code.requires_note and requires_approval, enforced by nothing;
--   * a department's default cost centre, a cost centre's parent, and the two
--     locale settings.
--
-- The last group is fixed (20260916140000, 20260916300000, 20260916360000). The
-- repository had also hit this class by hand twice before — 20260904360000 says
-- "erp.scan_rule WAS READ BY NOTHING", 20260906142000 is another — and each
-- time the instance was fixed and the next one left uncovered. So this migration
-- is the check, not the instances.
--
-- ── WHAT IT DOES ─────────────────────────────────────────────────────────────
--
-- Everything is read from the BUILT DATABASE, never from migration text, for the
-- reason the sibling gives: a rename or a new write lands in the database, and
-- only the database knows it happened. Function bodies here are patched after
-- definition with pg_get_functiondef() and replace(), so the file a write was
-- born in is not where it lives.
--
--   1. erp.sql_written_columns() reads the columns a body writes BY NAME:
--      the column list of `insert into <table> (…)`, and the assignment targets
--      of `update <table> … set c = …`. A door is followed one or two hops into
--      the erp.* routines it calls, because a door almost always delegates.
--
--   2. erp.routine_decided_names() reads every name a body uses in a position
--      that CHANGED AN OUTCOME: in a where, a case, a join predicate, an order
--      by, an arithmetic expression, an assignment to something else, or as an
--      argument handed to another routine. A name that appears only as the value
--      half of a jsonb_build_object() pair, or only in a select list, is an
--      ECHO — the screen being shown what it just saved — and is not a read.
--
--   3. erp.write_only_column_report() puts the two together: a column some door
--      can write, that no routine and no view names in a deciding position.
--
-- ── WHAT IT DELIBERATELY DOES NOT COVER, AND WHY ─────────────────────────────
--
-- A check that fires six hundred times is a check somebody switches off. The
-- scope is narrowed three ways, each one stated so it can be argued with:
--
--   * Only the doors that MAINTAIN something — erp_create_*, erp_update_*,
--     erp_upsert_*, erp_set_*, erp_configure_*, erp_define_*. Those are the
--     controls on a configuration or master-data screen, which is where the
--     defect lives. A column written only by a transaction is not covered.
--   * Only columns on a table registered `tenant_scoped`. An append-only table
--     is a record of what happened, and a column on it is evidence rather than
--     configuration; erp_meta and erp_ref are the vendor's own books and the
--     content that ships.
--   * Only a column the caller supplies: some routine in the door's chain takes
--     an argument named p_<column> (or p_<column>_something, as
--     p_capacity_quantity fills capacity). That is what "a screen offers a
--     control" means in this schema. created_at, created_by, updated_at and
--     updated_by are excluded outright — erp.touch_attribution() fills them,
--     not a person.
--
-- ── THE IMPRECISION IT ACCEPTS ───────────────────────────────────────────────
--
-- This is a text rule over function bodies, and a text rule over SQL is never
-- exact. What it gets wrong, on purpose:
--
--   * `select *` and `to_jsonb(t)` read every column of t WITHOUT NAMING ANY,
--     and are NOT counted as reads. That is the deliberate choice, and it is the
--     one that decides whether this check finds anything at all: erp.location's
--     capacity is carried out of the database by three routines that wrap the
--     whole row, and if wrapping a row whole counted as consulting its every
--     column then the defect the audit started from would be invisible here.
--     Handing a row on whole is the same act as a read door handing back its
--     answer — it shows the value to somebody, it does not show that the value
--     changed anything. The cost is real: a row passed whole into another
--     routine that decides on one field, without that field ever being named,
--     reads as unread. Nothing in this schema does that today; when something
--     does, it belongs in the register with that as its reason.
--   * A reference inside a routine that writes the same column is not a read.
--     `update t set c = coalesce(p_c, c) where c is null` is the writer talking
--     to itself. So is `c = excluded.c`. The cost: a routine that genuinely both
--     writes a column and branches on it is invisible, and the column reads as
--     unread.
--   * erp_test.* is not a read. A suite that asserts a value was stored proves
--     the write, not the use — which is exactly how this class survived: every
--     one of these columns has a suite that puts a value in and reads it back.
--   * erp_ai.* is not a read. The intelligence layer is off the transaction
--     path by construction (erp.assert_intelligence_boundary), so a value it
--     consults to make a PROPOSAL has still decided nothing.
--   * The configuration transport is not a read. erp_export_configuration(),
--     erp_import_configuration() and the change-set item marshalling name every
--     column of everything they carry; counting that would make the register
--     empty and the check useless.
--   * Row-security predicates, check constraints and index definitions are not
--     read either. A constraint proves a value is well formed and a policy
--     decides who may see the row; neither is the product consulting the value
--     to decide what to do.
--   * The walk follows a door two hops. A write three routines deep is not seen.
--   * A body is matched as text with its comments stripped, not parsed. A table
--     name inside a string literal that happens to look like an update is a
--     write to this rule; the column must still exist on the table, which
--     throws most of that away.
--
-- Every one of those errs the same way where it can: towards calling something
-- READ. The register is therefore a floor, not a ceiling — there are more
-- write-only columns than it holds, and none of the ones it holds is a
-- false alarm.
--
-- ── THE REGISTER ─────────────────────────────────────────────────────────────
--
-- Thirty-eight columns are grandfathered in erp_meta.write_only_column, each
-- with a written reason. Nineteen of them are deliberate — a note somebody typed
-- for the next person to read, a label, an audit copy, a secret reference handed
-- to the dispatch worker. Nineteen are defects, and their reasons say so in
-- those words, with the date. A defect dressed up as a decision is how this
-- class survived twice already.
--
-- That list is the check's own answer and not a guess, and it took the check two
-- refusals to get there. A first version numbered 20260916400000 was refused for
-- leaving erp.app_user.family_name out of the register; a second, 20260916420000,
-- was refused for keeping seven rows the database no longer agreed with — four
-- columns something had started to decide on, and three the walk no longer sees
-- a maintenance door write from a value its caller supplies. Neither version
-- reached any environment, and each is replaced rather than edited.
--
-- One of those seven is worth saying out loud, because it is where this rule is
-- weaker than a person. erp.location.count_class was named in the audit as a
-- setting cycle counting never consults, and it is: the count programme reads
-- its own selector. But erp.stock_audit_lines() carries the column out beside a
-- status, in a position this rule counts as deciding, so the check calls it read
-- and does not refuse it. A rule over text cannot always tell a report's column
-- from a rule's input, and this one errs towards READ — which is the direction
-- that makes its findings trustworthy and its silence worth less than an audit.
--
-- A NEW write-only column fails the build. So does a register row that has
-- stopped being true — one whose column something now reads, or that no door
-- writes any more — because a register kept past its reason is a list nobody
-- looks at.
--
-- Proof: erp_test.write_only_column_suite() (8 cases, wrapper pinned) and the
-- build step "Every value a screen writes is read by something".
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.write_only_column (
  schema_name   text not null check (schema_name ~ '^[a-z][a-z0-9_]*$'),
  table_name    text not null check (table_name ~ '^[a-z][a-z0-9_]*$'),
  column_name   text not null check (column_name ~ '^[a-z][a-z0-9_]*$'),
  rationale     text not null check (length(btrim(rationale)) >= 40),
  registered_at timestamptz not null default now(),
  primary key (schema_name, table_name, column_name)
);

select erp_meta.register_table('erp_meta', 'write_only_column', 'platform_internal',
  'The columns a maintenance door writes from a value the caller supplied that nothing reads in a position that changes an outcome, each with why it is still written. erp.assert_write_only_columns() refuses any other, and refuses a row here whose column something now reads or that no door writes any more.');

comment on table erp_meta.write_only_column is
  'Specification v1.6 Part 5. A value a screen''s control writes either changes '
  'something or has a row here saying why it is stored anyway. The default is '
  'failure; this is the list of places where a control writes into the dark, '
  'written down, with the deliberate ones told apart from the defects.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The columns a body writes by name
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.sql_written_columns(p_code text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  -- 'schema|table|column' for every column this fragment of SQL names as the
  -- target of a write. An insert with no column list, and an `insert … select *`,
  -- name no column and are not seen; neither is a write built with format() and
  -- executed. The caller checks the column exists, which throws away the noise
  -- a text rule over SQL always produces.
  with code as (select lower(coalesce(p_code, '')) as c),
  -- insert into <schema>.<table> ( a, b, c ). The list cannot contain a
  -- parenthesis, so [^()]* ends it exactly where the closing bracket does.
  ins as (
    select m[1] as sch, m[2] as tbl, btrim(x) as col
      from code,
           regexp_matches(c, '\minsert\s+into\s+(erp[a-z_]*)\.([a-z_][a-z0-9_]*)\s*\(([^()]*)\)', 'g') m,
           unnest(string_to_array(m[3], ',')) x
     where btrim(x) ~ '^[a-z_][a-z0-9_]*$'
  ),
  -- update <schema>.<table> [alias] set a = …, b = …  [where|from|returning …]
  -- Taken in two steps rather than one clever pattern: the statement first, then
  -- the text after `set`, then everything from the first `where`, `from` or
  -- `returning` cut off. A single non-greedy pattern would depend on how the
  -- regular expression engine resolves a greediness preference across a dozen
  -- quantifiers, which is not a thing to depend on.
  upd as (
    select m[1] as sch, m[2] as tbl,
           regexp_replace(
             coalesce(substring(m[3] from '\mset\M(.*)'), ''),
             '\m(?:where|returning|from)\M.*$', '') as assignments
      from code,
           regexp_matches(c, '\mupdate\s+(erp[a-z_]*)\.([a-z_][a-z0-9_]*)([^;]*)', 'g') m
  ),
  tgt as (
    select u.sch, u.tbl, t.hit[1] as col
      from upd u,
           regexp_matches(u.assignments, '(?:^|,)\s*([a-z_][a-z0-9_]*)\s*=(?!=)', 'g') as t(hit)
  )
  select coalesce(array_agg(distinct v order by v), '{}'::text[])
    from (select sch || '|' || tbl || '|' || col as v from ins
          union all
          select sch || '|' || tbl || '|' || col from tgt) z;
$$;
revoke all on function erp.sql_written_columns(text) from public, anon, authenticated;

comment on function erp.sql_written_columns(text) is
  'Every ''schema|table|column'' a fragment of SQL names as the target of an '
  'insert or an update. Hand it erp.prosrc_code(prosrc): a table named in a '
  'comment is not a write. An insert with no column list names no column and is '
  'not seen, which is stated rather than hidden.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The names a body uses to decide something
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
  --    another one is being used, wherever it is used. The json builders are out
  --    for the same reason as in 5: their arguments are an answer, not a use.
  handed as (
    select i[1] from code,
           regexp_matches(c, '\m([a-z_][a-z0-9_]*)\s*\(([^();]{0,200})', 'g') as f(frag),
           regexp_matches(f.frag[2], '(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)', 'g') i
     where f.frag[1] <> all (array['jsonb_build_object','json_build_object','jsonb_build_array',
                              'json_build_array','to_jsonb','to_json','row_to_json',
                              'jsonb_agg','json_agg','format'])
  )
  select coalesce(array_agg(distinct nm order by nm), '{}'::text[])
    from (select nm from kw
          union all select * from op
          union all select * from post
          union all select * from sub
          union all select * from alone
          union all select * from ordered
          union all select * from handed) z(nm);
$$;
revoke all on function erp.routine_decided_names(text) from public, anon, authenticated;

comment on function erp.routine_decided_names(text) is
  'Every name a body uses where an outcome is decided: in a where, a case, a '
  'join predicate, an order by, an arithmetic expression, an assignment to '
  'something else, or as an argument handed to another routine. A name that '
  'appears only as the value half of a jsonb_build_object() pair, or only in a '
  'select list, is an echo of what was just saved and is not here.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The report
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.write_only_column_report()
returns table(schema_name text, table_name text, column_name text,
              written_by text, verdict text, detail text)
language sql
stable
set search_path = ''
as $$
  with fn as materialized (
    select p.oid, n.nspname::text as sch, p.proname::text as nm,
           lower(erp.prosrc_code(p.prosrc)) as code
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where p.prokind = 'f' and p.prosrc is not null
       and n.nspname in ('public', 'erp', 'erp_ref', 'erp_meta', 'erp_ai',
                         'erp_ingress', 'erp_test')
  ),
  -- The doors that MAINTAIN something. A transaction's own columns are out of
  -- scope, and the migration's header says why.
  door as (
    select oid, nm from fn
     where sch = 'public' and nm ~ '^erp_(create|update|upsert|set|configure|define)_'
  ),
  edge as materialized (
    select distinct f.oid as caller, c.oid as callee
      from fn f
      cross join lateral regexp_matches(
        f.code, '\m(erp[a-z_]*)\.([a-z_][a-z0-9_]*)\s*\(', 'g') as m(ref)
      join fn c on c.sch = m.ref[1] and c.nm = m.ref[2]
     where m.ref[1] in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_ingress')
  ),
  -- A door and the routines it reaches in two hops. A door almost always
  -- delegates, and the write is in the delegate.
  reach as materialized (
    select d.oid as door_oid, d.oid as site_oid from door d
    union
    select d.oid, e.callee from door d join edge e on e.caller = d.oid
    union
    select d.oid, e2.callee
      from door d
      join edge e on e.caller = d.oid
      join edge e2 on e2.caller = e.callee
  ),
  wrote as materialized (
    select f.oid,
           split_part(x, '|', 1) as sch,
           split_part(x, '|', 2) as tbl,
           split_part(x, '|', 3) as col
      from fn f, unnest(erp.sql_written_columns(f.code)) x
  ),
  -- Configuration and master data, and not the four columns the attribution
  -- trigger owns.
  col as (
    select tp.schema_name as sch, tp.table_name as tbl, a.attname::text as col
      from erp_meta.table_policy tp
      join pg_catalog.pg_namespace ns on ns.nspname = tp.schema_name
      join pg_catalog.pg_class c
        on c.relnamespace = ns.oid and c.relname = tp.table_name and c.relkind = 'r'
      join pg_catalog.pg_attribute a
        on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where tp.table_class = 'tenant_scoped'
       and a.attname not in ('created_at', 'created_by', 'updated_at', 'updated_by')
  ),
  pair as materialized (
    select distinct w.sch, w.tbl, w.col, r.door_oid, w.oid as site_oid
      from wrote w
      join col cc on cc.sch = w.sch and cc.tbl = w.tbl and cc.col = w.col
      join reach r on r.site_oid = w.oid
  ),
  param as materialized (
    select p.oid, lower(x) as pname
      from pg_catalog.pg_proc p, unnest(coalesce(p.proargnames, '{}'::text[])) x
     where x ~ '^p_'
  ),
  -- The control a screen offers. Some routine in the chain takes the value from
  -- its caller under the column's own name; p_capacity_quantity fills capacity.
  offered as (
    select distinct z.sch, z.tbl, z.col
      from (select sch, tbl, col, site_oid as oid from pair
            union
            select sch, tbl, col, door_oid from pair) z
      join param pm on pm.oid = z.oid
     where pm.pname ~ ('^p_' || z.col || '(_|$)')
  ),
  candidate as materialized (
    select p.sch, p.tbl, p.col, min(d.nm) as door_name
      from pair p
      join door d on d.oid = p.door_oid
      join offered o on o.sch = p.sch and o.tbl = p.tbl and o.col = p.col
     group by p.sch, p.tbl, p.col
  ),
  -- Where a read could be. The test schema proves the write, not the use; the
  -- intelligence layer is off the transaction path; the configuration transport
  -- names every column of everything it carries.
  -- Keyed by oid rather than by name, so an overload is its own site: a read has
  -- to be in the same body as the reference to the table, not merely somewhere
  -- under the same name.
  site as materialized (
    select f.oid::text as key, f.oid, f.code
      from fn f
     where f.sch not in ('erp_test', 'erp_ai')
       and f.nm <> all (array[
         'export_configuration', 'import_configuration', 'configuration_manifest',
         'config_object_columns', 'config_snapshot', 'take_config_snapshot',
         'apply_change_set_item', 'add_change_set_item', 'export_tenant',
         'import_tenant', 'erp_export_configuration', 'erp_import_configuration',
         'erp_export_tenant', 'erp_import_tenant', 'erp_configuration_columns',
         'erp_configuration_entries'])
    union all
    select 'v' || c.oid::text, null::oid,
           lower(pg_catalog.pg_get_viewdef(c.oid))
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('v', 'm')
       and n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_ingress')
  ),
  site_rel as materialized (
    select distinct s.key, s.oid, m.ref[1] as sch, m.ref[2] as tbl
      from site s
      cross join lateral regexp_matches(
        s.code, '\m(erp[a-z_]*)\.([a-z_][a-z0-9_]*)\M', 'g') as m(ref)
  ),
  -- Only the bodies that name a table some door writes need their names read;
  -- the reading is the expensive half.
  site_name as materialized (
    select s.key, x as nm
      from (select distinct sr.key
              from site_rel sr
              join candidate c on c.sch = sr.sch and c.tbl = sr.tbl) k
      join site s on s.key = k.key
      cross join lateral unnest(erp.routine_decided_names(s.code)) x
  ),
  is_read as (
    select distinct c.sch, c.tbl, c.col
      from candidate c
      join site_rel sr on sr.sch = c.sch and sr.tbl = c.tbl
      join site_name sn on sn.key = sr.key and sn.nm = c.col
     where sr.oid is null
        or not exists (select 1 from wrote w
                        where w.oid = sr.oid and w.sch = c.sch
                          and w.tbl = c.tbl and w.col = c.col)
  )
  select c.sch, c.tbl, c.col, c.door_name,
         case
           when r.sch is not null and g.column_name is not null then 'stale_now_read'
           when r.sch is not null                               then 'read'
           when g.column_name is not null                       then 'allowed'
           else 'write_only'
         end,
         case
           when r.sch is not null
             then 'something decides on it'
           else format('%s writes it and nothing decides on it', c.door_name)
         end
    from candidate c
    left join is_read r on r.sch = c.sch and r.tbl = c.tbl and r.col = c.col
    left join erp_meta.write_only_column g
           on g.schema_name = c.sch and g.table_name = c.tbl and g.column_name = c.col
  union all
  select g.schema_name, g.table_name, g.column_name, null::text,
         'stale_not_written',
         'no maintenance door writes it from a value the caller supplies any more'
    from erp_meta.write_only_column g
   where not exists (select 1 from candidate c
                      where c.sch = g.schema_name and c.tbl = g.table_name
                        and c.col = g.column_name)
$$;
revoke all on function erp.write_only_column_report() from public, anon, authenticated;

comment on function erp.write_only_column_report() is
  'For every column a maintenance door writes from a value the caller supplied, '
  'onto a tenant-scoped table: read, allowed (registered in '
  'erp_meta.write_only_column), write_only, or one of the two stale verdicts for '
  'a register row that has stopped being true. Read from the built database, so '
  'a control that starts writing into the dark is seen the day it lands.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The assertion
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_write_only_columns()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_total    integer;
  v_read     integer;
  v_allowed  integer;
  v_dead     integer;
  v_stale    integer;
  v_findings text;
  v_rot      text;
begin
  select count(*) filter (where r.verdict = 'read'),
         count(*) filter (where r.verdict = 'allowed'),
         count(*) filter (where r.verdict = 'write_only'),
         count(*) filter (where r.verdict in ('stale_now_read', 'stale_not_written')),
         count(*) filter (where r.verdict <> 'stale_not_written'),
         string_agg(format('  %s.%s.%s — %s', r.schema_name, r.table_name,
                           r.column_name, r.detail), E'\n'
                    order by r.schema_name, r.table_name, r.column_name)
           filter (where r.verdict = 'write_only'),
         string_agg(format('  %s.%s.%s — %s', r.schema_name, r.table_name,
                           r.column_name, r.detail), E'\n'
                    order by r.schema_name, r.table_name, r.column_name)
           filter (where r.verdict in ('stale_now_read', 'stale_not_written'))
    into v_read, v_allowed, v_dead, v_stale, v_total, v_findings, v_rot
    from erp.write_only_column_report() r;

  -- A harvest that found nothing is not a pass. The walk reads the whole
  -- catalogue; if it comes back empty the walk is broken, not the schema clean.
  if coalesce(v_total, 0) = 0 then
    raise exception 'CLOVEERP_WRITE_ONLY_NO_COLUMNS: no maintenance door was found writing any column'
      using errcode = '22023',
            hint = 'erp.write_only_column_report() walks public.erp_create_*, erp_update_*, erp_upsert_*, erp_set_*, erp_configure_* and erp_define_* into the routines they call. An empty answer means the walk found no doors, which is not a schema with no configuration in it.';
  end if;

  if v_dead > 0 then
    raise exception E'CLOVEERP_WRITE_ONLY_COLUMN: % column(s) a screen writes are read by nothing that decides anything:\n%',
      v_dead, v_findings
      using errcode = 'P0001',
            hint = 'A control that writes a value nothing consults saves, says it saved, and changes nothing. Read the value where the behaviour it promises is decided; if it is deliberately only a note, a label or an audit copy, say so in erp_meta.write_only_column with the reason, and if it is a gap say that instead — a defect written down as a decision is how this class survived twice.';
  end if;

  if v_stale > 0 then
    raise exception E'CLOVEERP_WRITE_ONLY_REGISTER_STALE: the register accounts for % column(s) that no longer need it:\n%',
      v_stale, v_rot
      using errcode = 'P0001',
            hint = 'Either something now decides on the column, or no maintenance door writes it any more. Remove the row: a register kept past its reason is a list nobody is looking at.';
  end if;

  return format('written settings: %s column(s) a maintenance door writes; %s are read by something that decides, %s are registered as written for another reason',
                v_total, v_read, v_allowed);
end;
$$;
revoke all on function erp.assert_write_only_columns() from public, anon, authenticated;

comment on function erp.assert_write_only_columns() is
  'Refuses a column a maintenance door writes from a value the caller supplied '
  'that nothing reads in a position that changes an outcome, unless '
  'erp_meta.write_only_column accounts for it — and refuses a register row that '
  'has stopped being true. The write half of what '
  'erp.assert_app_columns_exist() does for what a screen reads.';

insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_write_only_columns',
   'A build-time walk of every function body in the catalogue, seven regular expressions deep. It belongs in the pull request that lands the write, not behind a button on a live console where erp.platform_assurance() has a second to answer in.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. What is written into the dark today
-- -----------------------------------------------------------------------------
-- Nineteen deliberate, nineteen defects. The defects say so.
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.write_only_column (schema_name, table_name, column_name, rationale) values

  -- ── Deliberate: a note, a label, an audit copy, a hand-off ────────────────
  ('erp', 'account_determination', 'note',
   'Deliberate. The sentence whoever wrote the rule left for whoever reads it next, shown beside the rule on the account determination screen. A note is for a person; the determination is not supposed to branch on prose.'),
  ('erp', 'app_user', 'family_name',
   'Deliberate, and the other half of given_name below. Kept so a person can be addressed properly on a document; what the product shows and sorts by is display_name, which erp.update_profile() derives from the two when the caller leaves it blank.'),
  ('erp', 'app_user', 'given_name',
   'Deliberate. The parts of a name, kept so a person can be addressed properly on a document. What the product shows and sorts by is display_name, which erp.update_profile() derives from these when the caller leaves it blank.'),
  ('erp', 'batch', 'supplier_party_id',
   'Deliberate. Which supplier a batch came from, kept for traceability: erp.trace_batch_upstream() carries it out to whoever is following a recall backwards. Nothing is supposed to decide anything from it.'),
  ('erp', 'change_set_item', 'note',
   'Deliberate. Why this one item is in the change set, written by the person who put it there and shown when the set is reviewed. Promotion decides on the operation and the payload, never on the prose.'),
  ('erp', 'config_version', 'note',
   'Deliberate. The reason a configuration value was changed, kept with the version so the history reads as a history rather than a list of differences. erp.config_history shows it; nothing resolves anything from it.'),
  ('erp', 'forecast_event', 'name',
   'Deliberate. What to call the event on the planning screen — "Black Friday", "factory shutdown". erp.forecast_event_factor() decides with the multiplier and the dates; the name is for the person reading the chart.'),
  ('erp', 'forecast_event', 'reason',
   'Deliberate. Why somebody thinks demand will move, kept beside the multiplier so the number can be argued with later. The forecast arithmetic uses the multiplier.'),
  ('erp', 'item_posting_class', 'reason',
   'Deliberate. Why this item was put in this posting class, which is the sort of decision somebody has to defend at an audit. The posting itself resolves through the class, not through the reason.'),
  ('erp', 'kill_switch', 'reason',
   'Deliberate. Why a capability was switched off, kept so the next person does not switch it back on without knowing. erp.kill_switch_active() decides on is_active; the reason is the record of a judgement.'),
  ('erp', 'notification_channel', 'credential_ref',
   'Deliberate, and the one case where "nothing in the database reads it" is the point. It is a reference to a secret — env:// or vault:// — and erp.claim_webhook_batch() hands it to the dispatch worker, which resolves it outside the database. The database must never be able to decide anything from it.'),
  ('erp', 'party_posting_class', 'reason',
   'Deliberate, for the same reason as erp.item_posting_class.reason: why this customer or supplier sits in this posting class, kept for the person who has to explain it.'),
  ('erp', 'reason_code', 'name',
   'Deliberate. What the reason code is called in the list a person picks from. The code is what documents carry and what rules match on.'),
  ('erp', 'report_pack', 'description',
   'Deliberate. What the report pack is for, shown to whoever is deciding whether to subscribe to it. Assembly decides on the items.'),
  ('erp', 'report_pack', 'name',
   'Deliberate. The pack''s title, shown on the screen and stamped into the manifest erp.assemble_report_pack() writes. It names the output; it does not choose anything.'),
  ('erp', 'resource_override', 'note',
   'Deliberate. Why an organisation was given more of something than its plan allows — a record of a commercial decision, kept where the decision was made. Enforcement reads the limit.'),
  ('erp', 'tenant_capability', 'reason',
   'Deliberate. Why a capability was turned on or off for one organisation. The gate reads is_enabled; the reason is there so the gate can be explained.'),
  ('erp', 'training_scenario', 'starting_state',
   'Deliberate. The situation the trainee is dropped into, written as prose for them to read on the training screen. Nothing in the product is supposed to act on it — that is what makes it training rather than configuration.'),
  ('erp', 'training_scenario', 'task',
   'Deliberate, and for the same reason as starting_state: what the trainee is asked to do, in words, for a person to read and a person to mark.'),

  -- ── Known gaps. Nothing reads these YET. Found 16 September 2026. ─────────
  ('erp', 'account_determination', 'dimensions',
   'A KNOWN GAP as at 16 September 2026, not a decision. The screen offers dimensions to narrow a determination rule to, and erp.determine_account() hands them straight back out without ever matching on them, so a rule scoped to one cost centre applies everywhere. Nothing reads it yet.'),
  ('erp', 'approval_band', 'is_parallel',
   'A KNOWN GAP as at 16 September 2026. The band says its approvers may decide in parallel rather than in turn, and the engine that raises the tasks never asks. Every band is sequential in practice. Nothing reads it yet.'),
  ('erp', 'approval_band', 'tolerance_pct',
   'A KNOWN GAP as at 16 September 2026. The percentage by which a document may move before its approval has to be sought again. erp.approval_chain_version carries a column of the same name that IS read; the band''s own is written by the screen and read by nothing. Nothing reads it yet.'),
  ('erp', 'change_set_item', 'effective_from',
   'A KNOWN GAP as at 16 September 2026. An item can be given a date to take effect on, and promotion applies every item the moment the set is promoted. A date in the future is accepted and ignored. Nothing reads it yet.'),
  ('erp', 'code_template', 'entity_id',
   'A KNOWN GAP as at 16 September 2026. A code template can be scoped to one company, and erp.compose_code() picks the template by code alone, so a template meant for one company composes codes for all of them. Nothing reads it yet.'),
  ('erp', 'cost_model', 'basis',
   'A KNOWN GAP as at 16 September 2026. The basis a cost model works on is chosen on the costing screen and consulted by no valuation: erp.stock_valuation_layer is written the same way whatever it says. Nothing reads it yet.'),
  ('erp', 'item_supplier', 'split_pct',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. "Sourcing split %" splits nothing: erp_resolve_item_supplier() picks one supplier by preference rank and planning raises one order. Nothing reads it yet.'),
  ('erp', 'item_supplier', 'supplier_item_code',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. "What the supplier calls this on their paperwork" is printed on nothing the supplier sees: no purchase order, no despatch note, no remittance carries it. Nothing reads it yet.'),
  ('erp', 'job', 'max_silence_seconds',
   'A KNOWN GAP as at 16 September 2026. How long a job may go without being heard from before somebody should be told. erp.claim_job_runs() and the scheduler''s own integrity check never read it, so a job that stops running quietly stops running quietly. Nothing reads it yet.'),
  ('erp', 'location', 'capacity',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. "Holds at most" is offered on the location screen and put-away has never consulted it; erp.resolve_storage_locations() will send stock to a full bin. Nothing reads it yet.'),
  ('erp', 'printer', 'default_stock',
   'A KNOWN GAP as at 16 September 2026. The label stock loaded in the printer by default, which erp.render_label() never asks for: every render uses the template''s own size and may not fit what is in the tray. Nothing reads it yet.'),
  ('erp', 'reason_code', 'requires_approval',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. A reason code marked as needing approval is enforced by nothing: the movement, the write-off and the amendment all go through without one. Nothing reads it yet.'),
  ('erp', 'reason_code', 'requires_note',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. A reason code marked as needing a note is enforced by nothing: every door that takes a reason code accepts an empty note beside it. Nothing reads it yet.'),
  ('erp', 'release_area', 'channel_code',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. One of four fields on the release area that nothing tests: a wave is allocated to an area without ever comparing the order''s channel with the area''s. Nothing reads it yet.'),
  ('erp', 'release_area', 'item_classes',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. The item classes an area is meant to take. Allocation does not look, so an area restricted to one class takes every class. Nothing reads it yet.'),
  ('erp', 'release_area', 'min_quantity',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. The smallest quantity worth releasing into the area. No wave is held back for being too small. Nothing reads it yet.'),
  ('erp', 'release_area', 'order_type_code',
   'A KNOWN GAP as at 16 September 2026, named in the audit that prompted this check. The order type the area is for. Allocation never compares it with the order being released. Nothing reads it yet.'),
  ('erp', 'storage_rule', 'max_quantity',
   'A KNOWN GAP as at 16 September 2026, and the twin of erp.location.capacity. erp.resolve_storage_locations() selects max_quantity, orders by priority, and never compares the quantity being put away with the maximum the rule allows. Nothing reads it yet.'),
  ('erp', 'uom', 'decimals',
   'A KNOWN GAP as at 16 September 2026. How many decimal places a unit of measure is counted in, offered when the unit is created and used to round nothing: every quantity keeps the precision of the column it lands in. Nothing reads it yet.')

on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.write_only_column_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_ok      boolean;
  v_msg     text;
  v_names   text[];
  v_reg     integer;
  v_wrong   integer;
begin
  -- 1
  case_name := 'an insert names the columns it writes';
  v_names := erp.sql_written_columns(
    'insert into erp.location (code, capacity, count_class) values (a, b, c)');
  passed := v_names @> array['erp|location|capacity', 'erp|location|count_class',
                             'erp|location|code'];
  detail := array_to_string(v_names, ', ');
  return next;

  -- 2. The left of each assignment, and nothing from the where.
  case_name := 'an update names its assignment targets and not what it filters on';
  v_names := erp.sql_written_columns(
    'update erp.location set capacity = x, count_class = y where code = z;');
  passed := v_names @> array['erp|location|capacity', 'erp|location|count_class']
        and not (v_names @> array['erp|location|code']);
  detail := array_to_string(v_names, ', ');
  return next;

  -- 3. The distinction the whole check rests on.
  case_name := 'a value handed straight back to a screen is not a read';
  v_names := erp.routine_decided_names(
    'select jsonb_build_object(''capacity'', l.capacity) from erp.location l');
  passed := not ('capacity' = any(v_names));
  detail := array_to_string(v_names, ', ');
  return next;

  -- 4
  case_name := 'a value tested, ordered by or handed on is a read';
  passed := 'capacity' = any(erp.routine_decided_names(
              'select 1 from erp.location l where l.capacity > 0'))
        and 'capacity' = any(erp.routine_decided_names(
              'select l.code from erp.location l order by l.name, l.capacity'))
        and 'multiplier' = any(erp.routine_decided_names(
              'select exp(sum(ln(e.multiplier))) from erp.forecast_event e'))
        and 'casing' = any(erp.routine_decided_names(
              'v_out := case t.casing when ''upper'' then upper(v_out) else v_out end;'));
  detail := 'where, order by, nested arithmetic, case';
  return next;

  -- 5
  case_name := 'the built schema has no unregistered write-only column';
  v_msg := erp.assert_write_only_columns();
  passed := v_msg like 'written settings:%are registered as written for another reason';
  detail := v_msg;
  return next;

  -- 6. The falsification: remove one register row and the build must refuse.
  case_name := 'a column nothing reads and the register does not account for is refused';
  v_msg := null;
  begin
    delete from erp_meta.write_only_column
     where schema_name = 'erp' and table_name = 'location' and column_name = 'capacity';
    begin
      perform erp.assert_write_only_columns();
      v_msg := 'an unregistered write-only column was accepted';
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  passed := v_msg like 'CLOVEERP_WRITE_ONLY_COLUMN%'
        and v_msg like '%erp.location.capacity%'
        and exists (select 1 from erp_meta.write_only_column g
                     where g.schema_name = 'erp' and g.table_name = 'location'
                       and g.column_name = 'capacity');
  detail := left(coalesce(v_msg, 'no verdict'), 180);
  return next;

  -- 7. And a register row that has stopped being true.
  case_name := 'a register row the schema no longer needs is refused as stale';
  v_msg := null;
  begin
    insert into erp_meta.write_only_column (schema_name, table_name, column_name, rationale)
    values ('erp', 'zz_no_such_table', 'zz_no_such_column',
            'A falsification raised and undone inside erp_test.write_only_column_suite(); if this row is ever seen in a built database then the suite did not clean up after itself.');
    begin
      perform erp.assert_write_only_columns();
      v_msg := 'a stale register row was accepted';
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  passed := v_msg like 'CLOVEERP_WRITE_ONLY_REGISTER_STALE%'
        and not exists (select 1 from erp_meta.write_only_column g
                         where g.table_name = 'zz_no_such_table');
  detail := left(coalesce(v_msg, 'no verdict'), 180);
  return next;

  -- 8. Every row in the register is still a column nothing reads.
  case_name := 'every column in the register is still one nothing decides on';
  select count(*), count(*) filter (where r.verdict <> 'allowed')
    into v_reg, v_wrong
    from erp.write_only_column_report() r
   where exists (select 1 from erp_meta.write_only_column g
                  where g.schema_name = r.schema_name and g.table_name = r.table_name
                    and g.column_name = r.column_name);
  passed := v_reg > 0 and v_wrong = 0;
  detail := format('%s registered column(s), %s of which no longer belong here', v_reg, v_wrong);
  return next;
end;
$$;
revoke all on function erp_test.write_only_column_suite() from public, anon, authenticated;

create or replace function erp_test.assert_write_only_column_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _write_only on commit drop as
    select * from erp_test.write_only_column_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _write_only;
  drop table _write_only;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_WRITE_ONLY_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail;
  end if;
  return format('written settings: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_write_only_column_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Generators, then the checks that read what changed
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

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
