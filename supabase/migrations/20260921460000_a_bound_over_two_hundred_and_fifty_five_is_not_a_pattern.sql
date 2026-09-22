set lock_timeout = '30s';

-- =============================================================================
-- 20260921460000  A bound over two hundred and fifty-five is not a pattern
-- -----------------------------------------------------------------------------
-- The repair named in supabase/ci/migrations_edited.txt for 20260921440000.
--
-- erp.state_side_door_report() found each update of a registered lifecycle
-- column by matching the statement from its UPDATE to its semicolon, and wrote
-- the run of characters as `[^;]{0,800}`. PostgreSQL will not accept a
-- repetition count above 255 in a regular expression, so the function raised
-- "invalid regular expression: invalid repetition count(s)" the first time it
-- ran, at the end of the file that created it.
--
-- Nothing offline caught it, and it is worth being precise about why rather
-- than adding a rule for it. Both offline readings this pull request used are
-- Python: the pglast parse, which sees the body as a string literal and never
-- looks inside it, and the count prediction, whose own copy of the pattern is
-- a Python regular expression where a bound of eight hundred is ordinary. The
-- pattern was only ever wrong in the one dialect that had to run it.
--
-- The fix is not a smaller bound. A bound is the wrong instrument: an UPDATE
-- runs to its semicolon however long it is, and a number chosen to fit under
-- the limit would quietly stop reading longer statements — a check that goes
-- half blind rather than refusing, which is worse than the error. It is
-- unbounded now.
--
-- Idempotent, and a no-op on a database that replayed the corrected file.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The reading, re-applied
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.state_side_door_report(p_register jsonb default null)
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with reg as (
    select r.schema_name, r.table_name, r.column_name, r.detail
      from jsonb_to_recordset(coalesce(p_register, erp.lifecycle_column_register()))
             as r(schema_name text, table_name text, column_name text, detail text)
  ),
  -- Every routine that could be a door or something a door reaches. Assertions
  -- and fixtures are not: a suite that plants a broken state on purpose is the
  -- thing that proves the guard, not a breach of it.
  routine as (
    select n.nspname as ns, p.proname, erp.prosrc_code(p.prosrc) as code
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and p.prokind in ('f', 'p')
       and p.proname not like 'assert\_%'
       and p.proname not like '%\_suite'
  ),
  -- Each update of a registered table, cut at its WHERE so a status read in a
  -- condition is not mistaken for a status written in an assignment.
  column_write as (
    select distinct r.ns, r.proname, g.schema_name, g.table_name, g.column_name
      from routine r
      cross join reg g
      -- Unbounded on purpose: a repetition count over 255 is not a regular
      -- expression this database will accept, and a statement runs to its
      -- semicolon however long it is.
      cross join lateral regexp_matches(
        r.code,
        'update\s+' || replace(g.schema_name || '.' || g.table_name, '.', '\.')
                    || '\M[^;]*', 'gi') m
     where regexp_replace(lower(m[1]), '\mwhere\M.*', '')
             ~ ('\m' || g.column_name || '\s*=')
  )
  -- 1. The state row written without a transition behind it.
  select 'a document state written without a transition',
         r.ns || '.' || r.proname,
         'It writes where a document''s state is kept rather than moving the '
         'document. The move is not looked up, the guard is not evaluated, the '
         'permission is not asked for and the history records nothing.'
    from routine r
   where r.proname not in ('perform_transition', 'start_lifecycle')
     and r.code ~* '(update|delete\s+from)\s+erp\.object_state\M|insert\s+into\s+erp\.(object_state|state_transition_log)\M'

  union all
  -- 2. The machine entered past the document's own door.
  select 'a document lifecycle entered past the door that carries it',
         r.ns || '.' || r.proname,
         'It moves a document by the generic engine instead of the document '
         'door, so the approval hold, the posting, the tax point and the '
         'lineage that hang off that door all fail to happen and the document '
         'ends up in a state its ledger never heard of.'
    from routine r
   where r.proname <> 'transition_document'
     and r.code ~ 'erp\.perform_transition\(\s*''document'''

  union all
  -- 3. The lifecycle that moves by having a column set.
  select 'an object moved by writing its state into a column',
         format('%s.%s writes %s.%s', w.ns, w.proname, w.table_name, w.column_name),
         (select g.detail from reg g
           where g.schema_name = w.schema_name and g.table_name = w.table_name
             and g.column_name = w.column_name)
    from column_write w

  union all
  -- 4. The register holding itself to the catalogue.
  select 'a lifecycle register row naming a column that is not there',
         format('%s.%s.%s', g.schema_name, g.table_name, g.column_name),
         'The register has drifted: the column was renamed or dropped and the '
         'row was left behind, so it is reporting green over nothing.'
    from reg g
   where not exists (
     select 1
       from pg_catalog.pg_attribute a
       join pg_catalog.pg_class c on c.oid = a.attrelid
       join pg_catalog.pg_namespace nn on nn.oid = c.relnamespace
      where nn.nspname = g.schema_name and c.relname = g.table_name
        and a.attname = g.column_name and a.attnum > 0 and not a.attisdropped)
$$;
revoke all on function erp.state_side_door_report(jsonb) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the proof
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.assert_no_state_side_doors() is run from here, as it was from the
-- file this repairs: it reads routine bodies out of the catalogue and needs no
-- organisation, so its cost is the size of the schema. Its falsification —
-- planting the engine's own state column and refusing if the reading comes back
-- empty — is what would have caught this had the pattern merely stopped
-- matching instead of refusing outright.

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

select erp_test.assert_no_state_side_doors();
