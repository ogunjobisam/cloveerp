set lock_timeout = '30s';

-- =============================================================================
-- 20261004985000  The hand allocation is gone
-- -----------------------------------------------------------------------------
-- 20261004980000 kept erp_allocate_landed_cost for one release as a shim that
-- refuses, because the application on main still called it. #360 merged and
-- deployed (2 October 2026); the application on main no longer names it, so
-- the shim goes, as it said it would:
--
--   * public.erp_allocate_landed_cost is dropped, and its api_only_door row
--     with it.
--   * CLOVEERP_LANDED_COST_FROM_THE_BILL, which only the shim raised, is
--     removed with its keys, as 20260916020000 removed a refusal nothing
--     raised.
--   * erp_test.hand_allocation_refuses() goes; the two cases that read it
--     prove again that no door allocates a landed cost by hand.
--
-- A landed cost comes from its bill: erp_bill_landed_cost (20261004970000).
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The suites, back to the door being gone
-- ═════════════════════════════════════════════════════════════════════════════

do $landed$
declare
  v_sig constant text := 'erp_test.landed_cost_suite()';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          -- The hand door is a shim that refuses (20261004980000).
          and erp_test.hand_allocation_refuses();$o$;
  v_new constant text := $n$          -- The hand door is gone (20261004985000).
          and to_regprocedure('public.erp_allocate_landed_cost(uuid)') is null
          and to_regprocedure('erp.allocate_landed_cost(uuid)') is null;$n$;
begin
  if strpos(v_src, '20261004985000') > 0 then
    raise notice '% already proves the door is gone; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '9043be05ad2fd7493e4bcb8f52f7d8a0' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004985000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$landed$;

do $controls$
declare
  v_sig constant text := 'erp_test.procurement_controls_suite()';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    -- The hand door is a shim that refuses (20261004980000).
    erp_test.hand_allocation_refuses(),$o$;
  v_new constant text := $n$    -- The hand door is gone (20261004985000).
    to_regprocedure('public.erp_allocate_landed_cost(uuid)') is null
      and to_regprocedure('erp.allocate_landed_cost(uuid)') is null,$n$;
begin
  if strpos(v_src, '20261004985000') > 0 then
    raise notice '% already proves the door is gone; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '66f1aac8d36935868a5a37b9e60f1d68' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004985000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$controls$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The shim, its register row, its refusal and its helper
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp_test.hand_allocation_refuses();
drop function if exists public.erp_allocate_landed_cost(uuid);

delete from erp_meta.api_only_door where function_name = 'erp_allocate_landed_cost';

delete from erp_ref.resource r
 where r.key in (erp_ref.refusal_key('CLOVEERP_LANDED_COST_FROM_THE_BILL', 'refused'),
                 erp_ref.refusal_key('CLOVEERP_LANDED_COST_FROM_THE_BILL', 'why'),
                 erp_ref.refusal_key('CLOVEERP_LANDED_COST_FROM_THE_BILL', 'next_action'));

delete from erp_ref.refusal f
 where f.code = 'CLOVEERP_LANDED_COST_FROM_THE_BILL';

do $gone$
begin
  if to_regprocedure('public.erp_allocate_landed_cost(uuid)') is not null
     or exists (select 1 from erp_meta.api_only_door d where d.function_name = 'erp_allocate_landed_cost')
     or exists (select 1 from erp_ref.refusal f where f.code = 'CLOVEERP_LANDED_COST_FROM_THE_BILL') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the hand allocation shim is not wholly gone';
  end if;
end
$gone$;

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
select erp.assert_part5_coverage();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
