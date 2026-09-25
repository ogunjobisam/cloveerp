set lock_timeout = '30s';

-- =============================================================================
-- 20260926000000  The dead configuration gate blocks
-- -----------------------------------------------------------------------------
-- PR9, last: "flip X2 and X3 to blocking" (docs/spec/simplification-review.md
-- §8). PR1 landed both checks asserting but tolerated (20260921430000,
-- 20260921440000), because they failed against the tree as it was; the
-- cleanups have landed, and they now stop the build.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * X2, every state reachable (erp_test.assert_reachable_configuration),
--     found nothing and still only reported.
--   * X3, no public door writes a state outside its lifecycle
--     (erp_test.assert_no_state_side_doors), tolerated six findings by count:
--     the works order's and the planned order's single writers, which the
--     lifecycle column register names and explains, and the four writers of a
--     count's status, which node I1 (PR10) retires by making a count a
--     document. A count is not a list of who may write: a seventh writer of
--     any of those columns would have been refused, but a new writer that took
--     an old one's place would have passed.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp.lifecycle_column_writer_register() names each routine allowed to
--     write a registered lifecycle column, by its whole signature, and why. The side door report
--     leaves an allowed writer out, names any writer that is not allowed, and
--     names an allowance that no longer writes anything, so the register
--     cannot outlive what it allows.
--   * Both switches block, with nothing tolerated.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. Who may write a lifecycle column, by name
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.lifecycle_column_writer_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(jsonb_build_object(
           'schema_name', x.schema_name, 'table_name', x.table_name, 'column_name', x.column_name,
           'writer', x.writer, 'detail', x.detail))
    from (values
      ('erp', 'works_order', 'status', 'erp.move_works_order(uuid,text,erp.works_order_status,text)',
       'The one door the works order''s lifecycle moves through (20260924400000): it moves the order and the column follows.'),
      ('erp', 'planned_order', 'status', 'erp.firm_planned_order(uuid,text)',
       'A planned order is suggested by a run and converted when it is confirmed; confirming it is the one move it makes.'),
      ('erp', 'count_task', 'status', 'erp.record_count(uuid,numeric)',
       'A count is not yet a document; node I1 (PR10) makes it one and takes this allowance away.'),
      ('erp', 'count_task', 'status', 'erp.recount_task(uuid)',
       'A count is not yet a document; node I1 (PR10) makes it one and takes this allowance away.'),
      ('erp', 'count_task', 'status', 'erp.post_count(uuid)',
       'A count is not yet a document; node I1 (PR10) makes it one and takes this allowance away.'),
      ('erp', 'count_task', 'status', 'erp.settle_approval_outcome(uuid)',
       'A count variance''s approval settles the count; node I1 (PR10) moves it onto the count''s lifecycle.')
    ) as x(schema_name, table_name, column_name, writer, detail)
$$;

revoke all on function erp.lifecycle_column_writer_register() from public, anon;

comment on function erp.lifecycle_column_writer_register() is
  'The routines allowed to write a column erp.lifecycle_column_register() names, each with its '
  'reason (20260926000000). Read by erp.state_side_door_report(): any other writer is a finding, '
  'and so is an allowance that writes nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The report reads it
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig constant text := 'erp.state_side_door_report(jsonb)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- A writer is allowed by its whole signature, so an overload or a
    -- procedure that reuses an allowed name is not allowed with it (found on
    -- review).
    $o$    select n.nspname as ns, p.proname, erp.prosrc_code(p.prosrc) as code$o$,
    $n$    select n.nspname as ns, p.proname, erp.prosrc_code(p.prosrc) as code,
           p.oid::regprocedure::text as ident$n$,
    $o$    select distinct r.ns, r.proname, g.schema_name, g.table_name, g.column_name$o$,
    $n$    select distinct r.ns, r.proname, r.ident, g.schema_name, g.table_name, g.column_name$n$,
    $o$  select 'an object moved by writing its state into a column',
         format('%s.%s writes %s.%s', w.ns, w.proname, w.table_name, w.column_name),
         (select g.detail from reg g
           where g.schema_name = w.schema_name and g.table_name = w.table_name
             and g.column_name = w.column_name)
    from column_write w
$o$,
    $n$  select 'an object moved by writing its state into a column',
         format('%s.%s writes %s.%s', w.ns, w.proname, w.table_name, w.column_name),
         (select g.detail from reg g
           where g.schema_name = w.schema_name and g.table_name = w.table_name
             and g.column_name = w.column_name)
    from column_write w
   -- Unless it is a writer the register allows, by name (20260926000000).
   where not exists (
     select 1 from jsonb_to_recordset(erp.lifecycle_column_writer_register())
                     as a(schema_name text, table_name text, column_name text, writer text)
      where a.schema_name = w.schema_name and a.table_name = w.table_name
        and a.column_name = w.column_name and a.writer = w.ident)

  union all
  -- 3b. An allowance that no longer writes anything (20260926000000): the
  -- register cannot outlive what it allows.
  select 'a writer allowed a lifecycle column that no longer writes it',
         format('%s writes %s.%s', a.writer, a.table_name, a.column_name),
         'The allowance names a routine that does not write the column, or no longer exists. Take the row out: an allowance nobody uses is a door left open for the next writer.'
    from jsonb_to_recordset(erp.lifecycle_column_writer_register())
           as a(schema_name text, table_name text, column_name text, writer text)
   where p_register is null
     and not exists (
       select 1 from column_write w
        where w.schema_name = a.schema_name and w.table_name = a.table_name
          and w.column_name = a.column_name and w.ident = a.writer)
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$report$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. Both switches block
-- ─────────────────────────────────────────────────────────────────────────────

do $flip$
declare
  v_n integer;
begin
  update erp_meta.enforcement_gate
     set is_blocking = true, tolerated_findings = 0,
         rationale = rationale || ' Blocking since 20260926000000, PR9: the cleanups it waited for have landed, '
                              || 'and a writer of a lifecycle column is allowed by name, not by count.'
   where gate in ('reachable_configuration', 'no_state_side_doors')
     and not is_blocking;
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % switch(es) flipped, expected 2', v_n;
  end if;
end
$flip$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.dead_configuration_gate_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.dead_configuration_gate_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_found text;
  v_err   text;
begin
  -- 1. Both switches block, and tolerate nothing.
  return query select 'the reachability and side door checks stop the build, and tolerate nothing',
    (select count(*) from erp_meta.enforcement_gate g
      where g.gate in ('reachable_configuration', 'no_state_side_doors')
        and g.is_blocking and g.tolerated_findings = 0) = 2,
    (select string_agg(format('%s %s/%s', g.gate, g.is_blocking, g.tolerated_findings), ', ' order by g.gate)
       from erp_meta.enforcement_gate g where g.gate in ('reachable_configuration', 'no_state_side_doors'));

  -- 2. Nothing writes a lifecycle column but the writers allowed, and every
  --    allowance is used.
  select string_agg(r.finding || ': ' || r.reference, '; ') into v_found
    from erp.state_side_door_report() r;
  return query select 'every writer of a lifecycle column is allowed by name, and every allowance writes',
    v_found is null, coalesce(v_found, 'none');

  -- 3. A new writer of a works order's status is refused by name.
  begin
    execute $planted$
      create function erp.zz_side_door(p_id uuid) returns void language plpgsql set search_path = '' as $body$
      begin
        update erp.works_order set status = 'draft' where id = p_id;
      end;
      $body$
    $planted$;
    -- And one that borrows an allowed writer's name.
    execute $planted$
      create function erp.move_works_order(p_id uuid) returns void language plpgsql set search_path = '' as $body$
      begin
        update erp.works_order set status = 'draft' where id = p_id;
      end;
      $body$
    $planted$;
    select string_agg(r.reference, ', ' order by r.reference) into v_found
      from erp.state_side_door_report() r
     where r.finding = 'an object moved by writing its state into a column';
    begin
      perform erp_test.assert_no_state_side_doors();
      v_err := 'passed';
    exception when others then v_err := left(sqlerrm, 60); end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'a writer of a works order''s status that nobody allowed, even one borrowing an allowed writer''s name, is named, and the side door check stops the build',
    v_found = 'erp.move_works_order writes works_order.status, erp.zz_side_door writes works_order.status'
    and v_err like 'CLOVEERP_ENFORCEMENT_GATE_REFUSES:%',
    coalesce(v_found, 'nothing named') || ' / ' || coalesce(v_err, 'nothing');

  -- 4. An allowance that writes nothing is named.
  begin
    execute $planted$
      create or replace function erp.lifecycle_column_writer_register() returns jsonb language sql
      immutable set search_path = '' as $body$
        select jsonb_build_array(jsonb_build_object(
          'schema_name', 'erp', 'table_name', 'works_order', 'column_name', 'status',
          'writer', 'erp.zz_writes_nothing()', 'detail', 'planted'))
      $body$
    $planted$;
    select string_agg(r.reference, ', ') into v_found
      from erp.state_side_door_report() r
     where r.finding = 'a writer allowed a lifecycle column that no longer writes it';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'an allowance to write a lifecycle column that nothing uses is named',
    v_found = 'erp.zz_writes_nothing() writes works_order.status', coalesce(v_found, 'nothing named');

  -- 5. Nothing is left behind.
  return query select 'the suite leaves nothing behind',
    to_regprocedure('erp.zz_side_door(uuid)') is null
    and to_regprocedure('erp.move_works_order(uuid)') is null
    and jsonb_array_length(erp.lifecycle_column_writer_register()) = 6,
    'the planted door and allowance rolled back';
end;
$function$;

revoke all on function erp_test.dead_configuration_gate_suite() from public, anon;

create or replace function erp_test.assert_dead_configuration_gate_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.dead_configuration_gate_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEAD_CONFIGURATION_GATE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A gate that went back to reporting, a lifecycle column written by somebody not allowed, or an allowance nobody uses, is the case that failed. Read it.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_DEAD_CONFIGURATION_GATE_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_dead_configuration_gate_suite() from public, anon;

comment on function erp_test.assert_dead_configuration_gate_suite() is
  'The reachability and side door checks block, a lifecycle column is written only by the writers '
  'allowed by name, and a writer or an allowance out of line is named (20260926000000).';

-- The generators, which are idempotent and run at the end of every migration.

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
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
