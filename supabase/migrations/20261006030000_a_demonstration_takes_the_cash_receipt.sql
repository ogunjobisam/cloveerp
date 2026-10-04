set lock_timeout = '30s';

-- =============================================================================
-- 20261006030000  A demonstration takes the cash receipt
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (R-04), and confirmed
-- there: the demonstration holds receivables at version 1, has no cash
-- receipt document type and no receipt. erp.apply_cash() opens a receipt
-- (RCPT-) only when the organisation has an active document type whose base
-- is cash_receipt, which receivables version 2 brings (20260930000000).
-- Without it the cash is posted and nothing is opened, so the Cash in step of
-- the order-to-cash strip stayed empty and Apply cash named no receipt.
--
-- erp.ensure_demo_configuration() installs receivables only when no
-- 'receivables' change set exists. Unlike finance-posting, inventory,
-- sales-lifecycle and procurement-controls, it never upgraded it, and
-- erp.demonstration_catch_up() does not either, so a demonstration configured
-- before 30 September stayed on version 1 however often it traded.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.ensure_demo_configuration(): beside the installer, a receivables
--      that is installed and has something to upgrade is upgraded, through
--      erp.upgrade_module_configuration('receivables'), the way the other
--      modules are. The builder and so the catch-up call it on every day
--      they build.
--   B. erp_test.demonstration_catch_up_suite(): a new case puts the traded
--      demonstration back to receivables version 1, configures it again,
--      and the next cash applied opens a posted receipt. Thirteen cases,
--      from twelve.
--   C. DEMONSTRATIONS ONLY (organisations whose code is like 'demo-%'; not
--      clove-foods, not clove-erp, nobody's own data): every demonstration
--      on an older receivables is upgraded here. An upgrade is authorised to
--      somebody, so it acts as the demonstration's longest-standing
--      administrator who may configure and promote, as
--      erp.catch_up_demonstrations() picks the person it acts as, and puts
--      their own choice of organisation back after.
--
-- Cash applied before this stays without a receipt: that is history, and a
-- receipt is not invented for it. No new words: the receipt's own type and
-- strings come with the upgrade.
--
-- On production: each demonstration still on receivables version 1 gains the
-- cash receipt document type, its state machine and its numbering through one
-- promoted change set, and its installation reads version 2. Every other
-- organisation's rows are untouched. No hot table is altered.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A demonstration upgrades its receivables
-- ─────────────────────────────────────────────────────────────────────────────

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'receivables') then
    perform erp.configure_receivables(7, 45, 90);
    v_did := v_did || '"receivables"'::jsonb;
  end if;
$o$;
  v_new  constant text := $n$  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'receivables') then
    perform erp.configure_receivables(7, 45, 90);
    v_did := v_did || '"receivables"'::jsonb;
  -- Version 2 is the cash receipt (20260930000000): without it cash is
  -- applied and nothing is opened. An organisation configured before that
  -- takes it the way it takes any other change (20261006030000).
  elsif exists (select 1 from erp.module_installation i
                 where i.tenant_id = p_tenant_id and i.install_code = 'receivables')
        and exists (select 1 from erp.plan_module_upgrade('receivables')) then
    perform erp.upgrade_module_configuration('receivables');
    v_did := v_did || '"receivables upgraded"'::jsonb;
  end if;
$n$;
begin
  if strpos(v_src, '20261006030000') > 0 then
    raise notice '% already upgrades receivables; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '40f032d9ebba1a6131d7b156cbbc0527' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006030000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof: a demonstration on version 1 is brought to version 2, and its
--    next cash opens a receipt
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.demonstration_catch_up_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_called jsonb;
begin
$o$,
    $n$  v_called jsonb;
  -- The receivables upgrade (20261006030000).
  v_conf jsonb; v_cust uuid; v_ccy char(3); v_rows jsonb; v_rcpt uuid;
  v_rcv_before integer; v_rcv_after integer;
begin
$n$,
    $o$  -- ── 12. And it does not offer the routine what is not a demonstration ─────
$o$,
    $n$  -- ── 13. A demonstration on receivables version 1 takes the receipt ───────
  --        (20261006030000). Put back the way erp_test.cash_receipt_suite()
  --        puts an organisation back, configured again as the builder does
  --        on every day it builds, and cash applied the way Apply cash does.
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  update erp.document_type set status = 'inactive'
   where tenant_id = v_tenant and code = 'cash_receipt';
  update erp.state_machine set status = 'inactive'
   where tenant_id = v_tenant and code = 'cash_receipt';
  update erp.module_installation i set installer_version = 1
   where i.tenant_id = v_tenant and i.install_code = 'receivables';
  v_conf := erp.ensure_demo_configuration(v_tenant, v_admin);
  select si.party_id, si.currency into v_cust, v_ccy
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.control_kind = 'receivable'
     and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) >= 100
   order by si.due_date, si.id
   limit 1;
  select count(*) into v_rcv_before
    from erp.document d join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'cash_receipt';
  select jsonb_agg(to_jsonb(x)) into v_rows
    from public.erp_apply_cash(v_cust, 100, v_ccy, 'ZZCATCHUP-RCPT') x;
  v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
  select count(*) into v_rcv_after
    from erp.document d join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'cash_receipt';
  case_name := 'a demonstration still on receivables version 1 is upgraded to its current version when it is configured again, and the next cash applied opens a posted receipt';
  passed := (v_conf -> 'installed') ? 'receivables upgraded'
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'receivables')
            = (select mi.current_version from erp_ref.module_installer mi where mi.install_code = 'receivables')
        and not exists (select 1 from erp.plan_module_upgrade('receivables'))
        and v_cust is not null
        and v_rcpt is not null
        and erp.object_current_state('document', v_rcpt) = 'posted'
        and v_rcv_after = v_rcv_before + 1;
  detail := format('configured %s; receipts %s then %s; rows %s',
                   v_conf -> 'installed', v_rcv_before, v_rcv_after, left(coalesce(v_rows::text, 'none'), 200));
  return next;
  perform set_config('request.jwt.claims', '', true);

  -- ── 12. And it does not offer the routine what is not a demonstration ─────
$n$,
    $o$  if v_cases <> 12 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_catch_up_suite ran % cases, expected 12%',$o$,
    $n$  if v_cases <> 13 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_catch_up_suite ran % cases, expected 13%',$n$];
  i integer;
begin
  if strpos(v_src, '20261006030000') > 0 then
    raise notice '% already proves the receivables upgrade; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a78563800f1d2b5537332d3c805c55ab' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006030000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for i in 1 .. array_length(v_pairs, 1) by 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[i], ''))) / length(v_pairs[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, (i + 1) / 2;
    end if;
    v_def := replace(v_def, v_pairs[i], v_pairs[i + 1]);
  end loop;
  execute v_def;
end
$suite$;

create or replace function erp_test.assert_demonstration_catch_up_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demonstration_catch_up on commit drop as
    select * from erp_test.demonstration_catch_up_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demonstration_catch_up;
  drop table _demonstration_catch_up;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMONSTRATION_CATCH_UP_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  -- Thirteen since the receivables upgrade (20261006030000).
  if v_all <> 13 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demonstration_catch_up_suite ran % cases, expected 13', v_all;
  end if;
  return format('a demonstration is brought up to today and stays that way: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demonstration_catch_up_suite() from public, anon;

comment on function erp_test.demonstration_catch_up_suite() is
  'A demonstration is brought up to today and stays that way; one on receivables version 1 is upgraded when it is '
  'configured again and its next cash opens a receipt (20261006030000).';

comment on function erp_test.assert_demonstration_catch_up_suite() is
  'erp_test.demonstration_catch_up_suite(), thirteen cases (20261006030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Every demonstration there is today, as its administrator, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  r          record;
  v_admin    uuid;
  v_pref     uuid;
  v_pref_at  timestamptz;
  v_had_pref boolean;
  v_res      jsonb;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    continue when not exists (select 1 from erp.module_installation i
                               where i.tenant_id = r.id and i.install_code = 'receivables');
    continue when not exists (select 1 from erp.plan_module_upgrade('receivables'));

    -- An upgrade is authorised to somebody: the demonstration's longest-
    -- standing administrator who may configure and promote, as
    -- erp.catch_up_demonstrations() picks the person it acts as.
    v_admin := null;
    select u.auth_user_id into v_admin
      from erp.app_user u
     where u.tenant_id = r.id
       and u.kind = 'person'::erp.principal_kind
       and u.status = 'active'::erp.principal_status
       and u.auth_user_id is not null
       and erp.has_permission('administration.configure', null, null, null, u.id)
       and erp.has_permission('administration.promote', null, null, null, u.id)
     order by u.created_at, u.id
     limit 1;
    if v_admin is null then
      raise warning 'cash receipt: nobody in % may upgrade its receivables, so it is left on the version it has', r.code;
      continue;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    perform set_config('erp.job_tenant_id', r.id::text, true);
    -- The administrator resolves to the organisation they last chose; it is
    -- made the demonstration for this transaction and put back after.
    select p.active_tenant_id, p.chosen_at into v_pref, v_pref_at
      from erp_meta.principal_preference p
     where p.auth_user_id = v_admin;
    v_had_pref := found;
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
    values (v_admin, r.id, now())
    on conflict (auth_user_id) do update
      set active_tenant_id = excluded.active_tenant_id, chosen_at = excluded.chosen_at;

    if erp.current_tenant_id() is distinct from r.id or erp.current_principal_id() is null then
      raise warning 'cash receipt: % does not resolve to its administrator, so its receivables are left as they are', r.code;
    else
      v_res := erp.upgrade_module_configuration('receivables');
      -- The checks the writes left waiting, fired while still in the
      -- organisation they read, so the generators below can alter the tables.
      set constraints all immediate;
      raise warning 'cash receipt: % upgraded its receivables to version %', r.code, v_res ->> 'to_version';
    end if;

    if v_had_pref then
      update erp_meta.principal_preference
         set active_tenant_id = v_pref, chosen_at = v_pref_at
       where auth_user_id = v_admin;
    else
      delete from erp_meta.principal_preference where auth_user_id = v_admin;
    end if;
    perform set_config('request.jwt.claims', '', true);
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
select erp.assert_personal_data_register_sound();
