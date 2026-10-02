set lock_timeout = '30s';

-- =============================================================================
-- 20261004975000  The registers follow landed cost from the bill
-- -----------------------------------------------------------------------------
-- 20261004970000 dropped erp.allocate_landed_cost and took procurement
-- controls to version 8. Three checks still named what it replaced:
--
--   * erp_ref.part5_capability's 5.3.landed_cost claimed
--     erp.allocate_landed_cost(uuid), so erp.assert_part5_coverage() refused a
--     capability claiming a function that does not exist. It now claims the
--     bill, its capitalisation and the helper both use.
--   * erp_test.settlement_is_derived_suite and erp_test.cash_receipt_suite pin
--     the version a new organisation installs and an upgrade reaches. They
--     were re-pinned to 7 by 20260930200000; they are re-pinned to 8 here, in
--     the same words. What each case proves is unchanged: the supplier payment
--     still ships at version 7, and still arrives by the upgrade.
-- =============================================================================

update erp_ref.part5_capability
   set artefacts = array['erp.landed_cost',
                         'erp.bill_landed_cost(uuid,uuid,text,bigint,text,bigint,text,date,date)',
                         'erp.capitalise_landed_cost(uuid)',
                         'erp.add_freight_to_receipt_line(uuid,bigint)']
 where code = '5.3.landed_cost'
   and 'erp.allocate_landed_cost(uuid)' = any(artefacts);

do $part5$
begin
  if exists (select 1 from erp_ref.part5_capability c
              where c.code = '5.3.landed_cost' and 'erp.allocate_landed_cost(uuid)' = any(c.artefacts)) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: 5.3.landed_cost still claims the dropped hand allocation';
  end if;
end
$part5$;

-- Re-pinned, not rewritten: one anchor over each body.

do $settlement$
declare
  v_sig constant text := 'erp_test.settlement_is_derived_suite()';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$              -- Seven since 20260930200000: the supplier payment.
              = 7$o$;
  v_new constant text := $n$              -- Seven since 20260930200000: the supplier payment; eight since
              -- 20261004970000: the landed cost bill.
              = 8$n$;
begin
  if strpos(v_src, '20261004970000') > 0 then
    raise notice '% already pins version 8; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '3b8813d7986888e5c6fb57358d610b72' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004975000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$settlement$;

do $cash$
declare
  v_sig   constant text := 'erp_test.cash_receipt_suite()';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$          and (select mi.current_version from erp_ref.module_installer mi
                where mi.install_code = 'procurement-controls') = 7
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 7
          and exists (select 1 from erp.document_type dt$o$,
    $n$          -- The payment ships at version 7; the installer is at 8 since
          -- 20261004970000, the landed cost bill.
          and (select mi.current_version from erp_ref.module_installer mi
                where mi.install_code = 'procurement-controls') = 8
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 8
          and exists (select 1 from erp.document_type dt$n$,
    $o$          and (res ->> 'to_version')::integer = 7 and (res ->> 'promoted')::boolean
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 7$o$,
    $n$          -- Through version 7, which brings the payment, to 8 since 20261004970000.
          and (res ->> 'to_version')::integer = 8 and (res ->> 'promoted')::boolean
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 8$n$];
  v_hits integer;
begin
  if strpos(v_src, '20261004970000') > 0 then
    raise notice '% already pins version 8; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '348acbecb44316a5c244aa4ff0db6100' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004975000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$cash$;

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
select erp.assert_part5_coverage();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
