set lock_timeout = '30s';

-- =============================================================================
-- 20260925800000  The base pack ships only lifecycles something drives
-- -----------------------------------------------------------------------------
-- PR9, the dead configuration gate: node W5 of
-- docs/spec/simplification-review.md names "seeded states with no caller".
-- Checked against the built database before it was built.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * The base content pack shipped fourteen lifecycles and something drives
--     one of them, the transfer order, which the inventory installer ships
--     identically. Nine were for objects that are not documents (allocation,
--     batch, command, container, disposition, inspection, planned order,
--     quality event, recall): nothing starts an object on any of them, and
--     the objects that exist keep their state in a column of their own.
--     Four were document lifecycles no document type names (works order,
--     count, return, supplier invoice), so no document of them can exist; the
--     works order's was superseded by works_order_lifecycle (20260924400000),
--     which said then that removing it was the dead configuration
--     pull request's, and still carried the states 20260925500000 retired.
--   * The pack's acceptance report counted a batch, an allocation, a recall
--     and a count lifecycle as a clause met when nothing could ever move
--     along one.
--   * Nothing would have said so.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * The thirteen leave the base pack. An organisation that applied it keeps
--     its copies made inactive, where nothing is on one and no document type
--     names it; one somebody put to use stays as it is.
--   * The acceptance report loses the four checks that proved only that a
--     lifecycle had been copied. The driver register keeps its rows for the
--     four document lifecycles, for an organisation that kept or restores one.
--   * The dead configuration report names a shipped lifecycle whose object
--     nothing starts, or a shipped state with no way in.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The pack ships none of them, and an organisation's copies are retired
-- ─────────────────────────────────────────────────────────────────────────────

do $pack$
declare
  v_n integer;
begin
  delete from erp_ref.pack_item
   where pack_code = 'base' and object_kind = 'state_machine'
     and object_key in ('allocation', 'batch', 'command', 'container', 'disposition', 'inspection',
                        'planned_order', 'quality_event', 'recall',
                        'works_order', 'count', 'return', 'supplier_invoice');
  get diagnostics v_n = row_count;
  if v_n <> 13 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the base pack lost % lifecycle(s), expected 13', v_n;
  end if;
end
$pack$;

-- The platform withdrawing what it shipped, not an organisation changing its
-- mind, so the live guard comes off for one statement and goes straight back,
-- inside the same transaction (as 20260925700000 did for reasons).
alter table erp.state_machine disable trigger t_state_machine_live_guard;
update erp.state_machine m
   set status = 'inactive', updated_at = now()
 where m.status = 'active'
   and (m.code, m.object_type) in (values
         ('allocation', 'allocation'), ('batch', 'batch'), ('command', 'command'),
         ('container', 'container'), ('disposition', 'disposition'), ('inspection', 'inspection'),
         ('planned_order', 'planned_order'), ('quality_event', 'quality_event'), ('recall', 'recall'),
         ('works_order', 'document'), ('count', 'document'), ('return', 'document'),
         ('supplier_invoice', 'document'))
   and not exists (select 1 from erp.object_state os
                     join erp.state_machine_version v on v.id = os.state_machine_version_id
                    where v.tenant_id = m.tenant_id and v.state_machine_id = m.id)
   and not exists (select 1 from erp.document_type dt
                    where dt.tenant_id = m.tenant_id and dt.status = 'active'
                      and dt.state_machine_code = m.code);
alter table erp.state_machine enable trigger t_state_machine_live_guard;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The acceptance report stops counting them
-- ─────────────────────────────────────────────────────────────────────────────

-- The driver register keeps the four document lifecycles' rows. Each says a
-- screen draws the move, which is still true of a document on one, and the
-- register is read only for lifecycles an organisation holds active: where
-- the copies are retired the rows say nothing, and where somebody kept one in
-- use, or a rollback to an earlier snapshot brings one back, they are what
-- stops its moves reading as undriven (found on review: removing them made
-- either case fail the next deploy).

do $acceptance_report$
declare
  v_sig constant text := 'erp.pack_acceptance_report(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_re  constant text := E'      if not exists \\(select 1 from erp\\.state_machine m\\n\\s*where m\\.tenant_id = v_tenant and m\\.status = ''active''\\n\\s*and m\\.code = ''(batch|allocation|recall|count)''\\) then\\n\\s*v_missing := v_missing \\|\\| ''no [a-z]+ lifecycle; '';\\n\\s*end if;\\n';
  v_hits integer;
begin
  select count(*) into v_hits from regexp_matches(v_def, v_re, 'g');
  if v_hits <> 4 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % lifecycle checks found % time(s), expected 4', v_sig, v_hits;
  end if;
  -- A lifecycle copied is not a clause met: nothing moves along one of these
  -- (20260925800000).
  execute regexp_replace(v_def, v_re, '', 'g');
end
$acceptance_report$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The dead configuration report sees one
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig constant text := 'erp.dead_configuration_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- A reason category offered that nothing reads (20260925700000): no$o$;
  v_new constant text := $n$  -- A lifecycle the product ships, in a pack or the newest version of a module
  -- upgrade, that nothing drives (20260925800000): for a document, no document
  -- type the product ships and no installer names it; for anything else, no
  -- function starts an object on it. And a shipped state with no way in.
  select 'a shipped lifecycle whose object nothing starts',
         s.source || '/' || s.object_key,
         format('%s ships lifecycle %s for %s objects, and nothing ever puts one on it',
                s.source, s.payload ->> 'code', coalesce(s.payload ->> 'object_type', 'document'))
    from (select 'pack ' || pi.pack_code as source, pi.object_key, pi.payload
            from erp_ref.pack_item pi where pi.object_kind = 'state_machine'
          union all
          select * from (select distinct on (ui.install_code, ui.object_key)
                                format('upgrade %s v%s', ui.install_code, ui.to_version), ui.object_key, ui.payload
                           from erp_ref.module_upgrade_item ui where ui.object_kind = 'state_machine'
                          order by ui.install_code, ui.object_key, ui.to_version desc) u) s
   where case when coalesce(s.payload ->> 'object_type', 'document') = 'document' then
                not exists (select 1 from erp_ref.pack_item d
                             where d.object_kind = 'document_type' and d.payload ->> 'state_machine' = s.payload ->> 'code')
            and not exists (select 1 from erp_ref.module_upgrade_item d
                             where d.object_kind = 'document_type' and d.payload ->> 'state_machine' = s.payload ->> 'code')
            and not exists (select 1 from pg_catalog.pg_proc p
                              join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'erp'
                               and p.prosrc ~ ('''state_machine''\s*,\s*''' || (s.payload ->> 'code') || ''''))
         else
                not exists (select 1 from pg_catalog.pg_proc p
                              join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                             where n.nspname in ('erp', 'public')
                               and p.prosrc ~ ('start_lifecycle\(\s*''' || (s.payload ->> 'object_type') || ''''))
         end
  union all
  select 'a shipped lifecycle state has no way in',
         s.source || '/' || s.object_key || '.' || (st ->> 'code'),
         format('%s: no move of lifecycle %s ends in %s, and it is not where one starts',
                s.source, s.payload ->> 'code', st ->> 'code')
    from (select 'pack ' || pi.pack_code as source, pi.object_key, pi.payload
            from erp_ref.pack_item pi where pi.object_kind = 'state_machine'
          union all
          select * from (select distinct on (ui.install_code, ui.object_key)
                                format('upgrade %s v%s', ui.install_code, ui.to_version), ui.object_key, ui.payload
                           from erp_ref.module_upgrade_item ui where ui.object_kind = 'state_machine'
                          order by ui.install_code, ui.object_key, ui.to_version desc) u) s
    cross join lateral jsonb_array_elements(s.payload -> 'states') st
   where not coalesce((st ->> 'is_initial')::boolean, false)
     and not exists (select 1 from jsonb_array_elements(s.payload -> 'transitions') t
                      where t ->> 'to' = st ->> 'code' and t ->> 'from' is distinct from st ->> 'code')
  union all
  -- A reason category offered that nothing reads (20260925700000): no$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$report$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The starter pack plans fewer items, and the acceptance suite says why
-- ─────────────────────────────────────────────────────────────────────────────

do $acceptance$
declare
  v_sig constant text := 'erp_test.starter_pack_acceptance_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    (res ->> 'items')::integer = 299$o$;
  v_new constant text := $n$    -- 286 since 20260925800000: the thirteen lifecycles nothing drives
    -- left the base pack.
    (res ->> 'items')::integer = 286$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$acceptance$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.shipped_lifecycle_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.shipped_lifecycle_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_found text;
  v_keys  text;
begin
  -- 1. Here, nothing shipped is left undriven.
  select string_agg(d.reference, ', ' order by d.reference) into v_found
    from erp.dead_configuration_report() d
   where d.finding in ('a shipped lifecycle whose object nothing starts',
                       'a shipped lifecycle state has no way in');
  return query select 'every lifecycle the product ships is one something starts, and every state in it has a way in',
    v_found is null, coalesce(v_found, 'none');

  -- 2. The base pack ships the one lifecycle something drives.
  select string_agg(pi.object_key, ', ' order by pi.object_key) into v_keys
    from erp_ref.pack_item pi where pi.pack_code = 'base' and pi.object_kind = 'state_machine';
  return query select 'the base pack ships only the transfer order''s lifecycle, which the inventory installer also ships',
    v_keys = 'transfer_order', coalesce(v_keys, 'none');

  -- 3. A lifecycle shipped for an object nothing starts, with a state no move
  --    enters, is named twice.
  begin
    insert into erp_ref.pack_item (pack_code, object_kind, object_key, payload, provenance, seq)
    values ('base', 'state_machine', 'zz_planted',
            jsonb_build_object('code', 'zz_planted', 'object_type', 'zz_planted', 'name', 'Planted',
              'states', jsonb_build_array(
                jsonb_build_object('code', 'a', 'is_initial', true),
                jsonb_build_object('code', 'b'),
                jsonb_build_object('code', 'z', 'is_terminal', true)),
              'transitions', jsonb_build_array(
                jsonb_build_object('code', 'go', 'from', 'a', 'to', 'z'))),
            'a planted item the suite rolls back', 99999);
    select string_agg(d.reference, ', ' order by d.reference) into v_found
      from erp.dead_configuration_report() d
     where d.finding in ('a shipped lifecycle whose object nothing starts',
                         'a shipped lifecycle state has no way in');
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'a shipped lifecycle nothing starts, and a state in it no move enters, are named by the dead configuration report',
    v_found = 'pack base/zz_planted, pack base/zz_planted.b', coalesce(v_found, 'nothing named');

  -- 4. Nothing is left behind.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp_ref.pack_item pi where pi.object_key = 'zz_planted'),
    'the planted lifecycle rolled back';
end;
$function$;

revoke all on function erp_test.shipped_lifecycle_suite() from public, anon;

create or replace function erp_test.assert_shipped_lifecycle_suite()
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
    from erp_test.shipped_lifecycle_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SHIPPED_LIFECYCLE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A lifecycle the product ships that nothing drives, or a report that no longer sees one, is the case that failed. Read it.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_SHIPPED_LIFECYCLE_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_shipped_lifecycle_suite() from public, anon;

comment on function erp_test.assert_shipped_lifecycle_suite() is
  'The product ships only lifecycles something drives, and the dead configuration report names '
  'one planted (20260925800000).';

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
