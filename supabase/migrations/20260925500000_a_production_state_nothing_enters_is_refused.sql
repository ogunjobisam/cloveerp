set lock_timeout = '30s';

-- =============================================================================
-- 20260925500000  A production state the product never enters is refused
-- -----------------------------------------------------------------------------
-- PR8, M7: node M7 of docs/spec/simplification-review.md, checked against the
-- built database before it was built.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * A works order could be 'planned', and a planned order 'reviewed' or
--     'firmed', though nothing has ever written any of them: a works order is
--     raised a draft and released from there (its lifecycle, 20260924400000,
--     has no planned state), and a planned order is suggested by a run and
--     converted when it is confirmed. Guards, two indexes, a supply query and
--     two screens still read them, so each read a state that cannot happen.
--   * A production event could be 'started', 'completed' or 'deviation', and
--     nothing has ever recorded one.
--   * Nothing would have said so: the dead configuration report read neither
--     the statuses a table accepts nor the event kinds nobody records.
--
-- The specification also named 'cancelled' on works orders. It is live: the
-- lifecycle cancels a draft or released order (erp.cancel_works_order), and
-- stays. A planned order's 'cancelled' is written by nothing either, but
-- firming refuses it by name (CLOVEERP_PLANNED_ORDER_CANCELLED) and comparing
-- runs leaves it out, so retiring it is a decision about cancelling a
-- suggestion, not a clean-up; it is left, and the report names it as the one
-- planned-order state kept without a writer.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp.works_order refuses 'planned', and erp.planned_order 'reviewed' and
--     'firmed', by a validated constraint named <table>_status_retired. A
--     Postgres enum cannot lose a label, and recreating the type would rewrite
--     both tables under an exclusive lock for no behaviour the constraint does
--     not already give.
--   * The production event kinds are those something records.
--   * Every reader of a retired value reads the states that exist: the
--     release and cancel guards, time booking, the supply planning counts, the
--     two partial indexes, the firming suite and the screens.
--   * The dead configuration report names a status its table accepts that no
--     lifecycle state or writer enters, and an event kind the table allows that
--     nothing records. erp_test.production_dead_states_suite proves both
--     findings fire, and that neither does here.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The tables refuse what the product never enters
-- ─────────────────────────────────────────────────────────────────────────────

-- Nothing has written these, so nothing should move; were a hand-made row to
-- hold one, it goes to the state that took its place rather than stop the
-- migration.
update erp.works_order set status = 'draft' where status = 'planned';
update erp.planned_order set status = 'suggested' where status in ('reviewed', 'firmed');

do $retire$
begin
  if not exists (select 1 from pg_constraint where conname = 'works_order_status_retired'
                  and conrelid = 'erp.works_order'::regclass) then
    alter table erp.works_order add constraint works_order_status_retired
      check (status <> 'planned'::erp.works_order_status);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'planned_order_status_retired'
                  and conrelid = 'erp.planned_order'::regclass) then
    alter table erp.planned_order add constraint planned_order_status_retired
      check (status not in ('reviewed'::erp.planned_order_status, 'firmed'::erp.planned_order_status));
  end if;
end
$retire$;

comment on constraint works_order_status_retired on erp.works_order is
  'A works order is raised a draft and released from there; planned is a state nothing enters (20260925500000).';
comment on constraint planned_order_status_retired on erp.planned_order is
  'A planned order is suggested and converted; reviewed and firmed are states nothing enters (20260925500000).';

alter table erp.production_event drop constraint if exists production_event_event_kind_check;
alter table erp.production_event add constraint production_event_event_kind_check
  check (event_kind = any (array['released', 'issued', 'scrapped', 'time_booked', 'output_received',
                                 'closed', 'cancelled', 'returned', 'output_reversed', 'held']));

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. Every reader reads the states that exist
-- ─────────────────────────────────────────────────────────────────────────────

do $readers$
declare
  v_patch constant text[] := array[
    'erp.book_operation_time(uuid,integer,numeric,numeric,numeric)',
    $o$  if wo.status in ('draft', 'planned', 'cancelled') then$o$,
    $n$  if wo.status in ('draft', 'cancelled') then$n$,
    'erp.cancel_works_order(uuid,text)',
    $o$  if wo.status not in ('draft', 'planned', 'released')$o$,
    $n$  if wo.status not in ('draft', 'released')$n$,
    'erp.release_works_order(uuid)',
    $o$  if wo.status not in ('draft', 'planned') then$o$,
    $n$  if wo.status <> 'draft' then$n$,
    'erp.scheduled_supply(uuid,uuid,date,date,boolean)',
    $o$  -- Planned and not yet converted: a firmed order always (somebody acted on
  -- it), a suggestion only while its baseline is the current one. A
  -- scenario's orders and a superseded baseline's suggestions are history,
  -- kept to be read and compared, never supply.$o$,
    $n$  -- Planned and not yet converted: a suggestion, while its baseline is the
  -- current one. A scenario's orders and a superseded baseline's suggestions
  -- are history, kept to be read and compared, never supply. (A confirmed
  -- suggestion is converted at once, so there is no firmed order to count;
  -- 20260925500000.)$n$,
    'erp.scheduled_supply(uuid,uuid,date,date,boolean)',
    $o$     and (po.status = 'firmed'
          or (po.status in ('suggested', 'reviewed')
              and not p_for_scenario
              and not coalesce(pr.is_scenario, false)
              and pr.superseded_by_run_id is null))$o$,
    $n$     and po.status = 'suggested'
     and not p_for_scenario
     and not coalesce(pr.is_scenario, false)
     and pr.superseded_by_run_id is null$n$];
  v_sig  text;
  v_def  text;
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_patch, 1) / 3 loop
    v_sig := v_patch[3*v_i - 2];
    v_def := pg_get_functiondef(v_sig::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, v_patch[3*v_i - 1], ''))) / length(v_patch[3*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    execute replace(v_def, v_patch[3*v_i - 1], v_patch[3*v_i]);
  end loop;
end
$readers$;

do $suite$
declare
  v_sig constant text := 'erp_test.planned_order_firming_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$wo.status::text in ('draft', 'planned')$o$;
  v_new constant text := $n$wo.status = 'draft'$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s), expected 3', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$suite$;

drop index if exists erp.works_order_open;
create index works_order_open on erp.works_order (tenant_id, site_id, status)
  where status in ('draft', 'released', 'in_progress');

drop index if exists erp.planned_order_tenant_id_item_id_site_id_required_by_idx;
create index planned_order_tenant_id_item_id_site_id_required_by_idx
  on erp.planned_order (tenant_id, item_id, site_id, required_by)
  where status = 'suggested';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The dead configuration report sees them
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig constant text := 'erp.dead_configuration_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          and current_date between p.starts_on and p.ends_on)
$o$;
  v_new constant text := $n$          and current_date between p.starts_on and p.ends_on)
  union all
  -- A status its table accepts that nothing enters (20260925500000): not a
  -- state of the object's lifecycle, nor one a function writes, and not
  -- refused by the table's <table>_status_retired constraint.
  select 'a status its table accepts is one nothing enters',
         format('%s.%s', v.type_name, e.enumlabel),
         format('erp.%s accepts %L, which no lifecycle state or writer enters; retire it with a validated %s',
                v.table_name, e.enumlabel, v.constraint_name)
    from (values
            ('works_order_status', 'works_order', 'works_order_status_retired',
             (select array_agg(s ->> 'code')
                from jsonb_array_elements(erp.works_order_lifecycle_item() -> 'payload' -> 'states') s)),
            -- Planning suggests, confirming converts; cancelled is kept
            -- because firming refuses it by name.
            ('planned_order_status', 'planned_order', 'planned_order_status_retired',
             array['suggested', 'converted', 'cancelled'])) v(type_name, table_name, constraint_name, live)
    join pg_catalog.pg_type t on t.typname = v.type_name
    join pg_catalog.pg_namespace tn on tn.oid = t.typnamespace and tn.nspname = 'erp'
    join pg_catalog.pg_enum e on e.enumtypid = t.oid
   where not (e.enumlabel = any (v.live))
     and not exists (
       select 1 from pg_catalog.pg_constraint c
        where c.conrelid = ('erp.' || v.table_name)::regclass
          and c.conname = v.constraint_name and c.convalidated
          and strpos(pg_catalog.pg_get_constraintdef(c.oid), '''' || e.enumlabel || '''') > 0)
  union all
  -- An event kind the table allows that nothing records (20260925500000).
  select 'a production event kind is allowed and nothing records it',
         k.kind,
         format('erp.production_event allows %L and no function that writes production events names it', k.kind)
    from pg_catalog.pg_constraint c
    cross join lateral regexp_matches(pg_catalog.pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
    cross join lateral (select m[1] as kind) k
   where c.conrelid = 'erp.production_event'::regclass
     and c.conname = 'production_event_event_kind_check'
     and not exists (
       select 1 from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('erp', 'public')
        -- Named in the insert itself: a kind that is also a works-order
        -- status (completed) is not recorded because the word is nearby
        -- (found on review).
        and p.prosrc ~ ('insert into erp\.production_event[^;]*''' || k.kind || ''''))
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$report$;

do $register$
declare
  v_sig constant text := 'erp.lifecycle_column_register()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'The same shape as a works order, and carrying two states — reviewed and firmed — that node M7 removes as dead. Its moves belong on the spine with the rest.'$o$;
  v_new constant text := $n$'The same shape as a works order: suggested by a run, converted when confirmed. The two states nothing entered, reviewed and firmed, are refused by planned_order_status_retired (20260925500000). Its moves belong on the spine with the rest.'$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.production_dead_states_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.production_dead_states_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_found text;
begin
  -- 1. Here, neither finding fires.
  select string_agg(r.reference, ', ') into v_found
    from erp.dead_configuration_report() r
   where r.finding in ('a status its table accepts is one nothing enters',
                       'a production event kind is allowed and nothing records it');
  return query select 'no production status or event kind is accepted that nothing enters or records',
    v_found is null, coalesce(v_found, 'none');

  -- 2. The tables refuse the retired states, by validated constraints.
  return query select 'a works order refuses planned, and a planned order reviewed and firmed',
    exists (select 1 from pg_catalog.pg_constraint c
             where c.conrelid = 'erp.works_order'::regclass and c.conname = 'works_order_status_retired'
               and c.convalidated)
    and exists (select 1 from pg_catalog.pg_constraint c
                 where c.conrelid = 'erp.planned_order'::regclass and c.conname = 'planned_order_status_retired'
                   and c.convalidated)
    and not exists (select 1 from erp.works_order wo where wo.status = 'planned')
    and not exists (select 1 from erp.planned_order po where po.status in ('reviewed', 'firmed')),
    'works_order_status_retired, planned_order_status_retired';

  -- 3. The event kinds are those something records.
  return query select 'a production event is never started, completed or a deviation',
    (select not (pg_catalog.pg_get_constraintdef(c.oid) ~ '''(started|completed|deviation)''')
       from pg_catalog.pg_constraint c
      where c.conrelid = 'erp.production_event'::regclass and c.conname = 'production_event_event_kind_check'),
    (select pg_catalog.pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint c
      where c.conrelid = 'erp.production_event'::regclass and c.conname = 'production_event_event_kind_check');

  -- 4. Without its constraint, a retired status is named.
  begin
    alter table erp.works_order drop constraint works_order_status_retired;
    alter table erp.planned_order drop constraint planned_order_status_retired;
    select string_agg(r.reference, ', ' order by r.reference) into v_found
      from erp.dead_configuration_report() r
     where r.finding = 'a status its table accepts is one nothing enters';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'a status a table accepts and nothing enters is named by the dead configuration report',
    v_found = 'planned_order_status.firmed, planned_order_status.reviewed, works_order_status.planned',
    coalesce(v_found, 'nothing named');

  -- 5. An event kind allowed and recorded by nothing is named.
  begin
    alter table erp.production_event drop constraint production_event_event_kind_check;
    alter table erp.production_event add constraint production_event_event_kind_check
      check (event_kind = any (array['released', 'completed', 'deviation']));
    select string_agg(r.reference, ', ' order by r.reference) into v_found
      from erp.dead_configuration_report() r
     where r.finding = 'a production event kind is allowed and nothing records it';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'an event kind the table allows and nothing records is named by the dead configuration report',
    v_found = 'completed, deviation', coalesce(v_found, 'nothing named');

  -- 6. The suite leaves the constraints as it found them.
  return query select 'the suite leaves nothing behind',
    (select count(*) from pg_catalog.pg_constraint c
      where c.conname in ('works_order_status_retired', 'planned_order_status_retired')
        and c.convalidated) = 2
    and (select pg_catalog.pg_get_constraintdef(c.oid) ~ '''output_reversed'''
           from pg_catalog.pg_constraint c
          where c.conrelid = 'erp.production_event'::regclass and c.conname = 'production_event_event_kind_check'),
    'constraints restored';
end;
$function$;

revoke all on function erp_test.production_dead_states_suite() from public, anon;

create or replace function erp_test.assert_production_dead_states_suite()
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
    from erp_test.production_dead_states_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRODUCTION_DEAD_STATES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A production status or event kind accepted that nothing enters or records, or a dead configuration report that no longer sees one, is the case that failed. Read it.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_PRODUCTION_DEAD_STATES_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_production_dead_states_suite() from public, anon;

comment on function erp_test.assert_production_dead_states_suite() is
  'No production status is accepted that nothing enters, no event kind allowed that nothing '
  'records, and the dead configuration report names either (20260925500000).';

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
