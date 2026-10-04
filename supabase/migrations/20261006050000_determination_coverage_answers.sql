set lock_timeout = '30s';

-- =============================================================================
-- 20261006050000  What is not covered yet is answered
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-25). On Which
-- accounts things post to, "What is not covered yet?" failed every time it
-- was asked, in every organisation.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- erp.determination_coverage() works its figures out in two statements. The
-- first is a WITH that names its queries combos and covered; the second,
-- `select count(*) from combos`, reads a query the first statement owned, so
-- it raised 42P01 (relation "combos" does not exist) on every call, before
-- anything was counted. And the first statement put the number of gaps where
-- the number of combinations belongs. No suite asked the door:
-- erp_test.determination_coverage_suite reads erp.determination_coverage_report
-- only.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.determination_coverage(): one statement gives both figures, every
--      combination counted and the gaps gathered from the same rows. Same
--      signature and the same answer keys, so public.erp_determination_coverage
--      and the screen are unchanged.
--   B. erp_test.door_runs_suite asks public.erp_determination_coverage() as an
--      administrator, over two transaction types with rules, two product
--      accounting codes and one company: four combinations, and the one with
--      no rule named.
--
-- On production: one function is replaced and a suite extended. No table is
-- altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. One statement gives both figures
-- ─────────────────────────────────────────────────────────────────────────────

do $coverage$
declare
  v_sig  constant text := 'erp.determination_coverage()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select coalesce(jsonb_agg(jsonb_build_object(
           'transaction_type', transaction_type,
           'item_class_code', item_class_code,
           'entity_code', entity_code) order by transaction_type, item_class_code),
         '[]'::jsonb),
         count(*)::int
    into v_gaps, v_total
    from covered where not ok;

  select count(*)::int into v_total from combos;
$o$;
  v_new  constant text := $n$  -- Both figures from one statement (20261006050000). A WITH names its
  -- queries for its own statement only: a second select over combos raised
  -- 42P01 on every call. Every combination is counted, and the gaps are the
  -- ones no rule covers.
  select coalesce(jsonb_agg(jsonb_build_object(
           'transaction_type', transaction_type,
           'item_class_code', item_class_code,
           'entity_code', entity_code) order by transaction_type, item_class_code, entity_code)
           filter (where not ok),
         '[]'::jsonb),
         count(*)::int
    into v_gaps, v_total
    from covered;
$n$;
begin
  if strpos(v_src, '20261006050000') > 0 then
    raise notice '% already counts in one statement; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '025e416f87805bc62bddb6038ddf5d4f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006050000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$coverage$;

comment on function erp.determination_coverage() is
  'Every transaction type with a rule, product accounting code and company combination, and the ones no active rule '
  'covers, worked out in one statement (20261006050000). Read by public.erp_determination_coverage.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof: the door is asked, and counts
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.door_runs_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- What the fixture holds.
    $o1$  v_cases int := 0;
begin
$o1$,
    $n1$  v_cases int := 0;
  v_ent   uuid;
  v_acc   uuid;
  v_fin   uuid;
  v_pack  uuid;
begin
$n1$,
    -- The case, after the determination case.
    $o2$  return query select 'the determination door answers rather than raising'::text,
    v_ok, v_msg;
$o2$,
    $n2$  return query select 'the determination door answers rather than raising'::text,
    v_ok, v_msg;

  -- What is not covered yet (20261006050000). The door raised 42P01 on every
  -- call: its second statement read a WITH query the first one owned. Two
  -- transaction types with rules, two product accounting codes and one
  -- company make four combinations, and one of them has no rule.
  update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
  select e.id into v_ent from erp.entity e where e.tenant_id = r.tenant_id order by e.code limit 1;
  insert into erp.account (tenant_id, entity_id, code, name, account_type)
  values (r.tenant_id, v_ent, '4000', 'Sales', 'income') returning id into v_acc;
  insert into erp.posting_class (tenant_id, kind, code, name)
  values (r.tenant_id, 'item', 'FINISHED', 'Finished goods') returning id into v_fin;
  insert into erp.posting_class (tenant_id, kind, code, name)
  values (r.tenant_id, 'item', 'PACKAGING', 'Packaging') returning id into v_pack;
  insert into erp.account_determination (tenant_id, transaction_type, item_class_id, account_id)
  values (r.tenant_id, 'customer_invoice', v_fin, v_acc),
         (r.tenant_id, 'supplier_invoice', null, v_acc);

  v_cases := v_cases + 1;
  v_ok := false; v_msg := 'did not return';
  begin
    v_out := public.erp_determination_coverage();
    v_ok := (v_out ->> 'combinations')::int = 4
        and (v_out ->> 'gap_count')::int = 1
        and v_out -> 'gaps' -> 0 ->> 'transaction_type' = 'customer_invoice'
        and v_out -> 'gaps' -> 0 ->> 'item_class_code' = 'PACKAGING'
        and not (v_out ->> 'complete')::boolean;
    v_msg := left(v_out::text, 200);
  exception when others then
    v_msg := left(sqlerrm, 90);
  end;
  return query select 'what is not covered yet is answered: four combinations, and the one with no rule'::text,
    v_ok, v_msg;
$n2$,
    -- The count.
    $o3$  if v_cases <> 3 then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_runs_suite ran % cases, expected 3', v_cases;$o3$,
    $n3$  if v_cases <> 4 then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_runs_suite ran % cases, expected 4', v_cases;$n3$];
  v_i integer;
begin
  if strpos(v_src, '20261006050000') > 0 then
    raise notice '% already asks what is not covered yet; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'fe41028d23b34590ddc3669622f49cd1' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006050000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, v_i;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$suite$;

comment on function erp_test.door_runs_suite() is
  'Doors that must answer rather than raise: the export, determination, and what is not covered yet '
  '(20261006050000), asked as an administrator in a throwaway organisation.';

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
