set lock_timeout = '30s';

-- =============================================================================
-- 20260921440000  A document state moves only by its transitions
-- -----------------------------------------------------------------------------
-- X3 of the simplification plan: "Fails when any function in public writes a
-- document state other than through erp.transition_document. This is what stops
-- derived statuses being clicked back into existence later."
--
-- ── READ LITERALLY IT PROVES NOTHING, SO IT IS NOT READ LITERALLY ────────────
--
-- Not one function in schema public writes a document state, and none ever
-- has. A door is a dozen lines that authorises and delegates; the writing is in
-- erp.*. A check scoped to public would be green on the day it landed, green
-- for ever, and would never have anything to say. That is the exact shape this
-- repository has learned to distrust, so the scope here is every routine in erp
-- and public that is not an assertion or a fixture.
--
-- ── WHAT IT REFUSES ──────────────────────────────────────────────────────────
--
-- 1. A routine writing erp.object_state or erp.state_transition_log directly.
--    erp.perform_transition() says of itself that it is "the only way an
--    object's state changes. There is deliberately no setter", and it earns
--    that by looking the transition up in the version the document started
--    under, from the state the document is actually in, and refusing when there
--    is none. A routine writing the row itself skips all three.
--
-- 2. A routine calling erp.perform_transition('document', …) other than
--    erp.transition_document(). Seven separate migrations have needled
--    behaviour into erp.transition_document(): the approval hold, the posting
--    bridge, the tax point, the receipt and delivery lineage, the credit-note
--    link. A second entrance moves the document and does none of it, and the
--    document is then in a state its ledger has never heard of.
--
-- 3. A routine moving an object's lifecycle by writing a status column,
--    for the objects named in erp.lifecycle_column_register(). This is the
--    class with findings today and the reason the plan expected this check to
--    fail on arrival: production has no state machine at all — it uses the bare
--    enum erp.works_order_status with the moves written into function bodies,
--    so a works order has no transition codes, no permissions on its moves and
--    no line in the state transition log. Planned orders and count tasks are
--    the same shape.
--
-- The register names the three the plan brings onto the document spine (M1, M7
-- and I1) and no others. It is a record of what has been DECIDED about, not an
-- inventory of every status column in the database, and saying so is the honest
-- way to have a number that means something. Its fourth finding holds it to the
-- catalogue, so it cannot name a column that has been renamed away.
--
-- ── ADVISORY, AND NOT VACUOUS ────────────────────────────────────────────────
--
-- It reads its switch through erp.enforcement_verdict(); 20260921400000 says
-- what that costs. It refuses more findings than it landed with from the first
-- build, and it refuses outright if the register is empty, because a register
-- of nothing would make finding nothing the answer for ever.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What is known to move by a column of its own
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.lifecycle_column_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(jsonb_build_object(
           'schema_name', x.schema_name, 'table_name', x.table_name,
           'column_name', x.column_name, 'detail', x.detail))
    from (values
      ('erp', 'works_order', 'status',
       'A works order has no state machine. The moves are written into function bodies against the bare enum, so it has no transition codes, no permission on any move and no line in the state transition log. Node M1 of the simplification plan authors it as configuration like every other cycle.'),
      ('erp', 'planned_order', 'status',
       'The same shape as a works order, and carrying two states — reviewed and firmed — that node M7 removes as dead. Its moves belong on the spine with the rest.'),
      ('erp', 'count_task', 'status',
       'The base type count exists in reference data and no installer ever makes a document type from it, so a count has no number, no lifecycle and no authorisation, and its status is a column somebody sets. Node I1 installs it.')
    ) as x(schema_name, table_name, column_name, detail)
$$;

revoke all on function erp.lifecycle_column_register() from public, anon, authenticated;

comment on function erp.lifecycle_column_register() is
  'The objects whose lifecycle is a column of their own rather than the '
  'document spine, each with the reason and the node that brings it over. What '
  'has been decided about, not every status column there is. Read by '
  'erp.state_side_door_report().';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The report
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
      cross join lateral regexp_matches(
        r.code,
        'update\s+' || replace(g.schema_name || '.' || g.table_name, '.', '\.')
                    || '\M[^;]{0,800}', 'gi') m
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

comment on function erp.state_side_door_report(jsonb) is
  'Every routine that writes where a document''s state is kept, enters the '
  'lifecycle engine past the document''s own door, or moves a registered object '
  'by setting a status column; and every register row the catalogue no longer '
  'has. p_register overrides the register, so the reading can be falsified.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The check
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.assert_no_state_side_doors()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_registered integer;
  v_routines   integer;
  v_found      integer;
  v_detail     text;
  v_planted    integer;
begin
  select jsonb_array_length(erp.lifecycle_column_register()) into v_registered;

  if coalesce(v_registered, 0) = 0 then
    raise exception 'CLOVEERP_NO_LIFECYCLE_COLUMN_REGISTERED: nothing is registered as moving by a column of its own, so finding nothing would be the answer for ever'
      using errcode = 'P0001',
            hint = 'The register names the objects whose lifecycle is a column rather '
                   'than the document spine. Emptying it does not make them right.';
  end if;

  select count(*) into v_routines
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'public') and p.prokind in ('f', 'p');

  -- Falsified before it is believed. The engine's own state column is planted
  -- in the register, and the reading must come back naming the engine, which is
  -- the one routine in the product that certainly writes it. If it comes back
  -- empty the reading is not reading bodies at all and every silence it reports
  -- means nothing.
  select count(*) into v_planted
    from erp.state_side_door_report(
      jsonb_build_array(jsonb_build_object(
        'schema_name', 'erp', 'table_name', 'object_state',
        'column_name', 'current_state_id',
        'detail', 'the engine''s own column, planted to prove the reading reads')))
   where finding = 'an object moved by writing its state into a column';

  if coalesce(v_planted, 0) = 0 then
    raise exception 'CLOVEERP_SIDE_DOOR_READING_IS_BLIND: a column the product writes all over was planted in the register and the reading found nobody writing it'
      using errcode = 'P0001',
            hint = 'The reading is not seeing assignments in routine bodies, so every '
                   'silence it reports is meaningless. Fix the reading before trusting '
                   'anything it says.';
  end if;

  select count(*), string_agg(format('  %s — %s: %s', r.finding, r.reference, r.detail),
                              E'\n' order by r.reference, r.finding)
    into v_found, v_detail
    from erp.state_side_door_report() r;

  return format('%s; %s routine(s) read, %s object(s) still moved by a column of their own',
                erp.enforcement_verdict('no_state_side_doors', v_found, v_detail),
                v_routines, v_registered);
end;
$$;

revoke all on function erp_test.assert_no_state_side_doors() from public, anon;

comment on function erp_test.assert_no_state_side_doors() is
  'No routine writes a document''s state except by performing a declared '
  'transition, nothing enters the lifecycle engine past the document''s own '
  'door, and no registered object is moved by having a status column set. '
  'Reports its findings while its switch is off and refuses any beyond the '
  'number it landed with.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The switch, and the number it landed with
-- ═════════════════════════════════════════════════════════════════════════════

-- Unlike the reachability walk beside it, this one reads routine bodies and
-- nothing else, so the number below is the same on an empty replay as on a
-- database full of trading. It is still a literal rather than a measurement
-- taken here, for the reason 20260921430000 gives at length: a line that moves
-- with whatever it is measuring is not a line. Nine, made of eight routines
-- moving a works order, a planned order or a count task by setting its status
-- column, and one entrance to the lifecycle engine past the document's own
-- door — erp.advance_orders_for_receipt(), which moves the purchase order a
-- receipt belongs to. That one is deliberate as far as it goes, because
-- erp.transition_document() is what calls it and calling back would recurse;
-- what it costs is that the order's move carries none of what hangs off that
-- door, which is precisely the finding worth keeping in sight.

insert into erp_meta.enforcement_gate
  (gate, is_blocking, tolerated_findings, landed_in, rationale)
values
  ('no_state_side_doors', false, 9, '20260921440000',
   'Landed reporting rather than blocking, as the simplification plan asks. Every finding it has '
   'today is an object whose lifecycle is a column because it was never authored as configuration, '
   'and the manufacturing and counting nodes are what bring them over. Anything beyond this number '
   'still refuses. Switch it to blocking in the dead-configuration pull request.')
on conflict (gate) do update set
  is_blocking = excluded.is_blocking,
  tolerated_findings = excluded.tolerated_findings,
  landed_in = excluded.landed_in,
  rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the proof
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
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();

-- Cheap: it reads routine bodies from the catalogue. Its cost is the size of
-- the schema and not the size of anybody's ledger.
select erp_test.assert_no_state_side_doors();
