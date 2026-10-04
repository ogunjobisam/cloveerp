set lock_timeout = '30s';

-- =============================================================================
-- 20261006040000  A bill is proposed in one run at a time
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (R-05), and confirmed
-- there: twenty bills stand on both of the demonstration's proposed payment
-- runs, PAY-20261004042631737 and PAY-20261004055349822, one for £84,863.35
-- and the other for £84,859.35. A tester proposed a second run while the
-- first was waiting for its approver, and the second gathered the same bills.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- erp.propose_payment_run() takes every payable item still owing, and every
-- prepayment asked for on an order and not yet paid, with no test that it is
-- already on another run. Paying is safe: erp.pay_payment_run() pays a line
-- no more than is still owing, so money does not leave twice. But two open
-- runs stood for the same bills, each total counting them, and an approver
-- had no way to tell which was meant.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.propose_payment_run(): an item already on a line of a run being
--      put together, proposed or approved is left to that run, held or not,
--      and so is a prepayment order on such a run (its line names the order
--      and no item). It comes back to the next run once that run is paid or
--      withdrawn. Two proposals at once in one organisation wait for each
--      other, so neither can take what the other is taking.
--   B. Two indexes on erp.payment_proposal_line, so the test reads an item's
--      and an order's lines directly instead of every line the organisation
--      has.
--   C. erp_test.bill_in_one_run_suite: a second run proposed while the first
--      waits, and a third while it is approved, take neither the bill nor the
--      prepayment; once the first is paid, the prepayment it held back comes
--      back and the bill it paid does not.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Runs already proposed keep their lines; nothing is taken off a run here.
-- The two runs on live that share twenty bills are cleared by the migration
-- that clears the testers' records, through the withdraw door
-- (20261006041000). A held line is left out as an unheld one is: holds are
-- fixed when a run is proposed, and a bill on two open runs is what this is
-- for.
--
-- On production: erp.propose_payment_run is replaced and two indexes are built
-- on erp.payment_proposal_line, which is not a hot table (it is written only
-- when a run is proposed). No row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A run leaves out what another open run holds
-- ─────────────────────────────────────────────────────────────────────────────

do $propose$
declare
  v_sig  constant text := 'erp.propose_payment_run(date,character,interval)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- One proposal at a time in an organisation.
    $o1$  perform erp.authorise('finance.approve_payment', null, null, null,
                        'payment_proposal', null);
$o1$,
    $n1$  perform erp.authorise('finance.approve_payment', null, null, null,
                        'payment_proposal', null);

  -- Two proposals at once wait for each other (20261006040000): each reads
  -- what the open runs hold, and the second must see what the first took.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('erp.propose_payment_run:' || v_tenant::text));
$n1$,
    -- The items.
    $o2$       and coalesce(si.due_date, current_date)
           <= coalesce(p_payment_date, current_date) + p_include_due_within
  loop$o2$,
    $n2$       and coalesce(si.due_date, current_date)
           <= coalesce(p_payment_date, current_date) + p_include_due_within
       -- A bill is proposed in one run at a time (20261006040000). One already
       -- on a run being put together, proposed or approved is left to that
       -- run, and comes back to the next once that run is paid or withdrawn.
       and not exists (select 1
                         from erp.payment_proposal_line ol
                         join erp.payment_proposal op
                           on op.tenant_id = ol.tenant_id and op.id = ol.payment_proposal_id
                        where ol.tenant_id = v_tenant
                          and ol.subledger_item_id = si.id
                          and op.status in ('draft', 'proposed', 'approved'))
  loop$n2$,
    -- The prepayments.
    $o3$       and coalesce((o.attributes #>> '{prepayment,due_on}')::date, current_date)
           <= coalesce(p_payment_date, current_date) + p_include_due_within
     order by 5, o.document_number$o3$,
    $n3$       and coalesce((o.attributes #>> '{prepayment,due_on}')::date, current_date)
           <= coalesce(p_payment_date, current_date) + p_include_due_within
       -- And a prepayment, the same (20261006040000): its line names the order
       -- and no item.
       and not exists (select 1
                         from erp.payment_proposal_line ol
                         join erp.payment_proposal op
                           on op.tenant_id = ol.tenant_id and op.id = ol.payment_proposal_id
                        where ol.tenant_id = v_tenant
                          and ol.subledger_item_id is null
                          and ol.document_id = o.id
                          and op.status in ('draft', 'proposed', 'approved'))
     order by 5, o.document_number$n3$];
  v_i integer;
begin
  if strpos(v_src, '20261006040000') > 0 then
    raise notice '% already leaves out what another open run holds; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '60f60523491479727d6a9e15cf0a8c68' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006040000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, v_i;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$propose$;

comment on function erp.propose_payment_run(date, character, interval) is
  'Proposes a payment run of what is due to suppliers by the payment date and horizon, holding what is in dispute. '
  'An item or a prepayment already on a run being put together, proposed or approved is left to that run (20261006040000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The lines an item and an order are on
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists payment_proposal_line_subledger_item_idx
  on erp.payment_proposal_line (tenant_id, subledger_item_id)
  where subledger_item_id is not null;

create index if not exists payment_proposal_line_prepayment_order_idx
  on erp.payment_proposal_line (tenant_id, document_id)
  where subledger_item_id is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bill_in_one_run_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_supp uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_bill uuid; v_pre_po uuid; v_gross bigint;
  v_run1 uuid; v_run2 uuid; v_run3 uuid; v_run4 uuid;
  v_pay  jsonb;
  -- How many lines of a run name the bill, and the order's prepayment.
  v_b1 integer; v_p1 integer; v_b2 integer; v_p2 integer;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with two administrators, a bill owed and a prepayment asked for';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzb1r-' || v_tag, 'Bill In One Run Suite',
      'admin@zzb1r-' || v_tag || '.test', 'Run Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzb1r-' || v_tag || '.test'),
           (a2, 'second@zzb1r-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@zzb1r-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id into v_entity from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZB1RCOAT', 'One Run Coat', v_uom, 'active') returning id into v_item;
    v_supp := erp_test.cash_payment_supplier('ZB1RSUP');

    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_supp, 10, 1000, 'ZB1R1');
    select l.id into v_pol from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
    v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    v_bill := erp.bill_from_receipt(v_grn, 'ZB1R-BILL-1', current_date, current_date + 30, true);

    v_pre_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_supp, 5, 2000, 'ZB1R2');
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_pre_po;
    perform public.erp_request_prepayment(v_pre_po, (v_gross / 2)::bigint, current_date, 'pro-forma');

    -- ── 1. The first run takes both ─────────────────────────────────────────
    v_step := 'the first run';
    v_run1 := erp.propose_payment_run(current_date, null, interval '60 days');
    select count(*) filter (where l.document_id = v_bill and l.subledger_item_id is not null),
           count(*) filter (where l.document_id = v_pre_po and l.subledger_item_id is null)
      into v_b1, v_p1
      from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run1;
    v_cases := v_cases + 1;
    case_name := 'the first run proposed takes the bill and the order''s prepayment, once each';
    passed := v_state is null and v_b1 = 1 and v_p1 = 1;
    detail := coalesce(v_state, format('bill on %s line(s), prepayment on %s', v_b1, v_p1));
    return next;

    -- ── 2. A second, proposed while the first waits, takes neither ──────────
    v_step := 'a second run while the first waits for its approver';
    v_run2 := erp.propose_payment_run(current_date, null, interval '60 days');
    select count(*) filter (where l.document_id = v_bill),
           count(*) filter (where l.document_id = v_pre_po)
      into v_b2, v_p2
      from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run2;
    v_cases := v_cases + 1;
    case_name := 'a second run proposed while the first waits leaves the bill and the prepayment to the first, and counts neither';
    passed := v_state is null and v_b2 = 0 and v_p2 = 0
          and (select pp.total_minor from erp.payment_proposal pp where pp.id = v_run2) = 0;
    detail := coalesce(v_state, format('bill on %s line(s), prepayment on %s; the second run totals %s',
      v_b2, v_p2, (select pp.total_minor from erp.payment_proposal pp where pp.id = v_run2)));
    return next;

    -- ── 3. Nor once the first is approved ───────────────────────────────────
    v_step := 'the first run approved by the second administrator, and a third proposed';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_run1);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_run3 := erp.propose_payment_run(current_date, null, interval '60 days');
    v_cases := v_cases + 1;
    case_name := 'a third run proposed once the first is approved, and not yet paid, takes neither either';
    passed := v_state is null
          and not exists (select 1 from erp.payment_proposal_line l
                           where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run3
                             and l.document_id in (v_bill, v_pre_po));
    detail := coalesce(v_state, format('%s line(s) of the third run name the bill or the order',
      (select count(*) from erp.payment_proposal_line l
        where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run3
          and l.document_id in (v_bill, v_pre_po))));
    return next;

    -- ── 4. Paid, the first lets go of what it held back ─────────────────────
    -- The prepayment is held on the first run as a person holding it back
    -- would leave it, so paying the run pays the bill and not the prepayment.
    v_step := 'the first run paid with its prepayment held back, and a fourth proposed';
    update erp.payment_proposal_line l
       set is_held = true, hold_reason = 'held back by the suite'
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run1 and l.document_id = v_pre_po;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_pay := erp.pay_payment_run(v_run1);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_run4 := erp.propose_payment_run(current_date, null, interval '60 days');
    v_cases := v_cases + 1;
    case_name := 'once the first run is paid, the prepayment it held back comes back on the next run, and the bill it paid does not';
    passed := v_state is null
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run1) = 'paid'
          and exists (select 1 from erp.payment_proposal_line l
                       where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run4
                         and l.document_id = v_pre_po and l.subledger_item_id is null and not l.is_held)
          and not exists (select 1 from erp.payment_proposal_line l
                           where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run4
                             and l.document_id = v_bill);
    detail := coalesce(v_state, format('the first run is %s; the fourth names the prepayment on %s line(s) and the bill on %s',
      (select pp.status from erp.payment_proposal pp where pp.id = v_run1),
      (select count(*) from erp.payment_proposal_line l
        where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run4 and l.document_id = v_pre_po),
      (select count(*) from erp.payment_proposal_line l
        where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run4 and l.document_id = v_bill)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_BILL_IN_ONE_RUN_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.bill_in_one_run_suite() from public, anon;

comment on function erp_test.bill_in_one_run_suite() is
  'A bill is proposed in one run at a time (20261006040000): a second run proposed while the first waits, '
  'and a third while it is approved, take neither the bill nor the prepayment; paid, the first lets go of what it held back.';

create or replace function erp_test.assert_bill_in_one_run_suite()
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
    from erp_test.bill_in_one_run_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_BILL_IN_ONE_RUN_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Two open payment runs would stand for the same bill. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_BILL_IN_ONE_RUN_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('bill in one run: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_bill_in_one_run_suite() from public, anon;

comment on function erp_test.assert_bill_in_one_run_suite() is
  'A payment run leaves out a bill or a prepayment another open run already holds (20261006040000).';

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
