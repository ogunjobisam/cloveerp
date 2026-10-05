set lock_timeout = '30s';

-- =============================================================================
-- 20261006151000  A refused payment approval says who can approve it
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-46). Approving a
-- payment run you proposed is refused, rightly, with
-- CLOVEERP_SEGREGATION_OF_DUTIES. The refusal raised no hint, so the screen
-- showed the register's next action for that code: "Where the organisation
-- accepts one person doing both, an administrator can record an exception."
-- That is true of invoicing goods you despatched, and not of a payment run:
-- erp.approve_payment_run() has never had an exception, and none can be
-- recorded. The visitor was told to look for something that does not exist.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.payment_run_approver_hint(tenant): what to do instead. In a
--      demonstration, choose its second person under Act as in the account
--      menu and approve as them (or, acting as that person already, go back
--      to yourself). Anywhere else, ask somebody else who may approve
--      payments; no exception can be recorded.
--   B. erp.approve_payment_run()'s refusal carries that hint. The check
--      itself is not touched: the person who proposed a run still cannot
--      approve it. The screen prefers the engine's hint to the register's
--      next action, which stays as it is, being true for invoicing.
--   C. erp_test.payment_run_refusal_hint_suite, two cases.
--
-- On production: one function is added and one is replaced. No row changes.
-- =============================================================================

create or replace function erp.payment_run_approver_hint(p_tenant_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_name text;
begin
  -- Who can approve a payment run its proposer may not (20261006151000, J-46).
  if erp.tenant_is_demonstration(p_tenant_id) then
    if exists (select 1 from erp.demonstration_persona dp
                where dp.tenant_id = p_tenant_id and dp.app_user_id = erp.current_principal_id()) then
      return 'In this demonstration, choose Yourself under Act as in your account menu, then approve the run as yourself. '
             'Nobody approves a run they proposed.';
    end if;
    select u.display_name into v_name
      from erp.demonstration_persona dp
      join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
     where dp.tenant_id = p_tenant_id
       and u.status = 'active'::erp.principal_status and u.auth_user_id is null
     order by dp.code
     limit 1;
    if v_name is not null then
      return format('In this demonstration, choose %s under Act as in your account menu, then approve the run as them. '
                    'Nobody approves a run they proposed.', v_name);
    end if;
  end if;
  return 'Ask somebody else who may approve payments to approve it. Nobody approves a payment run they proposed, '
         'and no exception can be recorded for it.';
end;
$$;

revoke all on function erp.payment_run_approver_hint(uuid) from public, anon;

comment on function erp.payment_run_approver_hint(uuid) is
  'What to do when approving a payment run you proposed is refused: in a demonstration, act as its second '
  'person; elsewhere, ask somebody else who may approve payments (20261006151000, J-46).';

do $approve$
declare
  v_sig  constant text := 'erp.approve_payment_run(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    raise exception
      'CLOVEERP_SEGREGATION_OF_DUTIES: you proposed % and cannot also approve it',
      pp.reference
      using errcode = '42501';
$o$;
  v_new  constant text := $n$    -- And says who can (20261006151000): no exception can be recorded for a
    -- payment run, so the register's next action would send them looking.
    raise exception
      'CLOVEERP_SEGREGATION_OF_DUTIES: you proposed % and cannot also approve it',
      pp.reference
      using errcode = '42501',
            hint = erp.payment_run_approver_hint(v_tenant);
$n$;
begin
  if strpos(v_src, '20261006151000') > 0 then
    raise notice '% already says who can approve; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4ed6b79e8747db731bdf8d931d40fbe2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006151000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$approve$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.payment_run_refusal_hint_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 2;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_auth   uuid;
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_code   text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_supp uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_run uuid;
  v_err    text;
  v_hint   text;
  v_kind   text;
begin
  begin
    foreach v_kind in array array['demonstration', 'organisation'] loop
      -- ── The fixture: a run its proposer tries to approve ──────────────────
      v_step := 'a ' || v_kind || ' whose administrator proposes a run and approves it';
      v_code := case v_kind when 'demonstration' then 'demo-zzph' || v_tag else 'zzph-' || v_tag end;
      v_auth := gen_random_uuid();
      perform set_config('request.jwt.claims', '', true);
      select * into rb from erp.provision_tenant(
        v_code, 'Payment Hint Suite', 'admin@' || v_code || '.test', 'Hint Admin');
      update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
      insert into auth.users (id, email) values (v_auth, 'admin@' || v_code || '.test');
      perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
      perform erp.claim_invitation(rb.admin_token);
      perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

      select e.id into v_entity from erp.entity e
       where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
      select s.id into v_site from erp.site s
       where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
      select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
      insert into erp.item (tenant_id, code, name, stock_uom_id, status)
      values (rb.tenant_id, 'ZPHCOAT', 'Hinted Coat', v_uom, 'active') returning id into v_item;
      v_supp := erp_test.cash_payment_supplier('ZPHSUP');
      v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_supp, 10, 1000, 'ZPH1');
      select l.id into v_pol from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
      v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
      perform erp.receive_against(v_grn, v_pol, 10, null);
      perform erp.transition_document(v_grn, 'post', null);
      perform erp.bill_from_receipt(v_grn, 'ZPH-BILL-1', current_date, current_date + 30, true);
      v_run := erp.propose_payment_run(current_date, null, interval '60 days');

      v_err := null; v_hint := null;
      begin
        perform erp.approve_payment_run(v_run);
        v_err := 'approved';
      exception when others then
        get stacked diagnostics v_err = message_text, v_hint = pg_exception_hint;
      end;

      v_cases := v_cases + 1;
      if v_kind = 'demonstration' then
        case_name := 'in a demonstration the proposer is still refused, and the refusal says to act as its second person';
        passed := v_state is null
              and v_err like 'CLOVEERP_SEGREGATION_OF_DUTIES%'
              and v_hint like '%choose Priya Shah under Act as%'
              and (select pp.status from erp.payment_proposal pp where pp.id = v_run) = 'proposed';
      else
        case_name := 'in an organisation that is not a demonstration the refusal says somebody else approves, and no exception can be recorded';
        passed := v_state is null
              and v_err like 'CLOVEERP_SEGREGATION_OF_DUTIES%'
              and v_hint like 'Ask somebody else who may approve payments%'
              and v_hint like '%no exception can be recorded%'
              and v_hint not like '%Act as%'
              and (select pp.status from erp.payment_proposal pp where pp.id = v_run) = 'proposed';
      end if;
      detail := coalesce(v_state, concat_ws(' / ', v_err, v_hint));
      return next;
    end loop;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PAYMENT_RUN_REFUSAL_HINT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.payment_run_refusal_hint_suite() from public, anon;

comment on function erp_test.payment_run_refusal_hint_suite() is
  'A refused payment approval says who can approve it (20261006151000): in a demonstration its second '
  'person under Act as, elsewhere somebody else, with no exception to look for; the refusal itself unchanged.';

create or replace function erp_test.assert_payment_run_refusal_hint_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.payment_run_refusal_hint_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PAYMENT_RUN_REFUSAL_HINT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A refused payment approval would send its proposer looking for an exception that does not exist. Read the case that failed.';
  end if;
  if v_total <> 2 then
    raise exception 'CLOVEERP_PAYMENT_RUN_REFUSAL_HINT_SUITE_SHRANK: % case(s), expected 2', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('payment run refusal hint: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_payment_run_refusal_hint_suite() from public, anon;

comment on function erp_test.assert_payment_run_refusal_hint_suite() is
  'Approving a payment run you proposed is refused with a hint that says who can approve it (20261006151000).';

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
