set lock_timeout = '30s';

-- =============================================================================
-- 20261004980000  The hand allocation answers for one release
-- -----------------------------------------------------------------------------
-- 20261004970000 dropped erp_allocate_landed_cost. The application on main
-- still names it ("Add delivery costs to the stock value", on Purchasing and
-- in Finance), so between the schema deploying and the application publishing,
-- and on any rollback of the application, that action would call a door that
-- no longer exists. The build's release compatibility check refuses exactly
-- that, and names the remedy: keep the door as a shim for one release.
--
-- So it comes back, doing nothing: STABLE, writing nothing, reading nothing,
-- refusing every call by name with where to go instead. The next release that
-- touches landed cost drops it again; the application stops naming it in the
-- same pull request as this.
--
-- The two suite cases that proved the door was gone now prove it refuses:
-- erp_test.hand_allocation_refuses(), read by erp_test.landed_cost_suite and
-- erp_test.procurement_controls_suite.
-- =============================================================================

select erp.register_refusal('CLOVEERP_LANDED_COST_FROM_THE_BILL',
  'Allocating a landed cost by hand, which the product no longer does.',
  'A landed cost lands on the goods from the supplier''s bill that charges it; allocating one by hand raised the stock and left the ledger where it was.',
  'Bill the charge under Purchasing, Bill a landed cost: registering the bill puts it on the goods.');

create or replace function public.erp_allocate_landed_cost(p_landed_cost_id uuid)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
begin
  -- A shim for one release (20261004980000): the application on main names
  -- this door. It refuses every call and touches nothing.
  raise exception 'CLOVEERP_LANDED_COST_FROM_THE_BILL: a landed cost is no longer allocated by hand'
    using errcode = '0A000',
          hint = 'Bill the charge under Purchasing, Bill a landed cost: registering the bill puts it on the goods.';
end;
$$;

revoke all on function public.erp_allocate_landed_cost(uuid) from public, anon;
grant execute on function public.erp_allocate_landed_cost(uuid) to authenticated, service_role;

comment on function public.erp_allocate_landed_cost(uuid) is
  'Retired (20261004970000): kept for one release as a shim that refuses, because the application on main '
  'still names it; a landed cost comes from its bill, erp_bill_landed_cost (20261004980000).';

-- No screen on this pull request names it, so it says who does: the suites,
-- through erp_test.hand_allocation_refuses(), and the application on main
-- until this one publishes.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_allocate_landed_cost', 'suite_evidence', null,
   'Retired by 20261004970000 and kept one release as a shim that refuses, because the application on main '
   'still calls it from "Add delivery costs to the stock value"; erp_test.hand_allocation_refuses() proves it '
   'refuses. Drop it, and this row, in the next release that touches landed cost.')
on conflict (function_name) do update set caller = excluded.caller, reason = excluded.reason;

create or replace function erp_test.hand_allocation_refuses()
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  -- Whether the retired hand allocation refuses by name and changes nothing
  -- (20261004980000): the only thing left of it is the refusal.
  perform public.erp_allocate_landed_cost(gen_random_uuid());
  return false;
exception when others then
  return sqlerrm like 'CLOVEERP_LANDED_COST_FROM_THE_BILL:%'
     and to_regprocedure('erp.allocate_landed_cost(uuid)') is null;
end;
$$;

revoke all on function erp_test.hand_allocation_refuses() from public, anon;

-- The two cases, edited, not rewritten: one anchor over each body.

do $landed$
declare
  v_sig constant text := 'erp_test.landed_cost_suite()';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          and to_regprocedure('public.erp_allocate_landed_cost(uuid)') is null
          and to_regprocedure('erp.allocate_landed_cost(uuid)') is null;$o$;
  v_new constant text := $n$          -- The hand door is a shim that refuses (20261004980000).
          and erp_test.hand_allocation_refuses();$n$;
begin
  if strpos(v_src, '20261004980000') > 0 then
    raise notice '% already reads the shim; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'df0607fa42e1cdceed78110709d80e7b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004980000 expects (md5 %)', v_sig, md5(v_src);
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
  v_old constant text := $o$    to_regprocedure('public.erp_allocate_landed_cost(uuid)') is null
      and to_regprocedure('erp.allocate_landed_cost(uuid)') is null,$o$;
  v_new constant text := $n$    -- The hand door is a shim that refuses (20261004980000).
    erp_test.hand_allocation_refuses(),$n$;
begin
  if strpos(v_src, '20261004980000') > 0 then
    raise notice '% already reads the shim; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '03cb3d320202ff54b7acb3574618ed96' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004980000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$controls$;

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
