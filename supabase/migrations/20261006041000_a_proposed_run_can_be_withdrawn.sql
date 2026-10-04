set lock_timeout = '30s';

-- =============================================================================
-- 20261006041000  A proposed run can be withdrawn
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-106). A tester
-- proposed a payment run twice and was left with two proposed runs for the
-- same bills (R-05) and no way to set either aside: the only moves a run has
-- are approve and pay, although erp.payment_proposal_status has held
-- 'cancelled' since runs were built.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Two refusals: withdrawing a run that is approved, paid or withdrawn
--      already, and withdrawing one without saying why.
--   B. erp.withdraw_payment_run(run, reason) and its door
--      public.erp_withdraw_payment_run. It authorises finance.approve_payment
--      on the run's company, the permission that proposes and approves a run,
--      and takes a run that is being put together or proposed, nothing else.
--      The run reads cancelled, and the audit trail keeps who withdrew it and
--      why, beside the change of status the run's own audit records. Its bills
--      are free for the next run (20261006040000). Whoever proposed the run
--      may withdraw it: nothing is paid by withdrawing.
--   C. The door's write allowance, its place in the Finance screen's help,
--      and the words its action says on the Finance screen.
--   D. erp_test.payment_run_withdrawal_suite: withdrawn, a run is neither
--      approved nor paid and its bill comes back on the next run; no reason,
--      an approved run, a paid run, and somebody who may not approve
--      payments are each refused.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No run is withdrawn here. The testers' duplicate run on live is withdrawn
-- with this door by the migration that clears the testers' records. An
-- approved run is still paid or left as it is; withdrawing it would undo a
-- second person's approval on one signature.
--
-- On production: a function, its door and their registrations are added. No
-- table is altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE',
  'Withdrawing a payment run that is approved, paid, or withdrawn already.',
  'An approved run is what a second person agreed to pay, and a paid one has moved money; neither is set aside by one person.',
  'Only a run waiting for its approver can be withdrawn. Pay an approved run from Pay, and propose a new run for anything it did not pay.');

select erp.register_refusal('CLOVEERP_WITHDRAWAL_NEEDS_A_REASON',
  'Withdrawing a payment run without saying why.',
  'Whoever approves the next run, and the auditor, read why this one was set aside.',
  'Say why the run is withdrawn, such as that it repeats another run.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The routine and its door
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.withdraw_payment_run(p_proposal_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pp       erp.payment_proposal%rowtype;
  v_actor  uuid := erp.current_principal_id();
  v_kind   erp.principal_kind;
  v_label  text;
  v_lines  integer;
begin
  -- A run nobody has approved, set aside with a reason (20261006041000). Its
  -- bills are then free for the next run, which leaves out only what a run
  -- being put together, proposed or approved holds (20261006040000).
  select * into pp from erp.payment_proposal x
   where x.tenant_id = v_tenant and x.id = p_proposal_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PAYMENT_PROPOSAL: no payment run %', p_proposal_id
      using errcode = '23503', hint = 'Choose the run from the list of payment runs.';
  end if;

  perform erp.authorise('finance.approve_payment', pp.entity_id, null, null,
                        'payment_proposal', p_proposal_id);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_WITHDRAWAL_NEEDS_A_REASON: withdrawing % needs a reason', pp.reference
      using errcode = '23514',
            hint = 'Say why the run is withdrawn, such as that it repeats another run.';
  end if;

  if pp.status not in ('draft', 'proposed') then
    raise exception 'CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE: % is %', pp.reference, pp.status
      using errcode = '23514',
            hint = 'Only a run waiting for its approver can be withdrawn. Pay an approved run from Pay, and propose a new run for anything it did not pay.';
  end if;

  update erp.payment_proposal
     set status = 'cancelled', updated_at = now()
   where tenant_id = v_tenant and id = p_proposal_id;

  select count(*) into v_lines
    from erp.payment_proposal_line l
   where l.tenant_id = v_tenant and l.payment_proposal_id = p_proposal_id;

  -- Who withdrew it and why, where an auditor reads it. The run's own audit
  -- records the change of status; this records the reason, which the run
  -- has no column for.
  if v_actor is not null then
    select u.kind, u.display_name into v_kind, v_label from erp.app_user u where u.id = v_actor;
  end if;
  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action, object_schema, object_type,
    object_id, object_key, entity_id, after_state, reason, correlation_id, source)
  values (
    v_tenant, v_actor, coalesce(v_kind, 'service'), coalesce(v_label, 'system'), 'execute',
    'erp', 'payment_proposal', p_proposal_id, pp.reference, pp.entity_id,
    jsonb_build_object('withdrawn', pp.reference, 'was', pp.status, 'status', 'cancelled',
                       'lines_released', v_lines, 'total_minor', pp.total_minor),
    btrim(p_reason), erp.current_correlation_id(), erp.current_source());

  return jsonb_build_object('proposal_id', p_proposal_id, 'reference', pp.reference,
                            'status', 'cancelled', 'lines_released', v_lines);
end;
$$;

revoke all on function erp.withdraw_payment_run(uuid, text) from public, anon;

comment on function erp.withdraw_payment_run(uuid, text) is
  'Withdraws a payment run that is being put together or proposed, with a reason kept in the audit trail, so its bills '
  'are free for the next run (20261006041000). Authorises finance.approve_payment; an approved or paid run is refused.';

create or replace function public.erp_withdraw_payment_run(p_proposal_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.withdraw_payment_run(p_proposal_id, p_reason) $$;

revoke all on function public.erp_withdraw_payment_run(uuid, text) from public, anon;
grant execute on function public.erp_withdraw_payment_run(uuid, text) to authenticated, service_role;

comment on function public.erp_withdraw_payment_run(uuid, text) is
  'Withdraws a proposed payment run, with a reason, so its bills go on the next run (20261006041000). '
  'Authorises finance.approve_payment.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Its registrations and its words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_withdraw_payment_run', 'erp.withdraw_payment_run',
   'Withdraws a payment run that is being put together or proposed, with a reason kept in the audit trail; authorises finance.approve_payment and refuses a run that is approved or paid.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/finance', array['erp_withdraw_payment_run']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Withdrawing a proposed payment run (20261006041000).'
  from (values
    ('Withdraw a payment run'),
    ('For a run nobody has approved yet, such as one that repeats another. Its bills go on the next run. An approved or paid run cannot be withdrawn.'),
    ('Why it is withdrawn')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.payment_run_withdrawal_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_supp uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_bill uuid;
  v_run1 uuid; v_run2 uuid;
  v_out  jsonb;
  v_err  text; v_err2 text; v_err3 text;
  v_st   text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with two administrators, a buyer and a bill owed';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzprw-' || v_tag, 'Payment Run Withdrawal Suite',
      'admin@zzprw-' || v_tag || '.test', 'Withdrawal Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzprw-' || v_tag || '.test'),
           (a2, 'second@zzprw-' || v_tag || '.test'),
           (s_buy, 'buyer@zzprw-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@zzprw-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('buyer@zzprw-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id into v_entity from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPRWCOAT', 'Withdrawn Coat', v_uom, 'active') returning id into v_item;
    v_supp := erp_test.cash_payment_supplier('ZPRWSUP');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_supp, 10, 1000, 'ZPRW1');
    select l.id into v_pol from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
    v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    v_bill := erp.bill_from_receipt(v_grn, 'ZPRW-BILL-1', current_date, current_date + 30, true);

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the door is allowed to write, gated, in the Finance screen''s help, and its two refusals and three words are registered';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_withdraw_payment_run' and a.gate = 'erp.withdraw_payment_run')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance' and 'erp_withdraw_payment_run' = any (h.actions))
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE', 'CLOVEERP_WITHDRAWAL_NEEDS_A_REASON')
                  and coalesce(f.next_action, '') <> '') = 2
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en'
                  and x.key in (erp_ref.ui_key('Withdraw a payment run'), erp_ref.ui_key('Why it is withdrawn'))) = 2;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. A proposed run is withdrawn, by whoever proposed it ──────────────
    v_step := 'a run proposed, and withdrawn by its proposer with a reason';
    v_run1 := erp.propose_payment_run(current_date, null, interval '60 days');
    v_out := public.erp_withdraw_payment_run(v_run1, '  It repeats the run proposed this morning ');
    v_cases := v_cases + 1;
    case_name := 'a proposed run is withdrawn by whoever proposed it: it reads cancelled, and the audit trail keeps who withdrew it and why';
    passed := v_state is null
          and v_out ->> 'status' = 'cancelled'
          and (v_out ->> 'lines_released')::integer >= 1
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run1) = 'cancelled'
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = rb.tenant_id and ae.object_type = 'payment_proposal'
                         and ae.object_id = v_run1 and ae.action = 'execute'
                         and ae.reason = 'It repeats the run proposed this morning'
                         and ae.actor_id = erp.current_principal_id());
    detail := coalesce(v_state, left(v_out::text, 300));
    return next;

    -- ── 3. Withdrawn, it is neither approved nor paid ───────────────────────
    v_step := 'approving and paying the withdrawn run';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin perform erp.approve_payment_run(v_run1); v_err := 'approved';
    exception when others then v_err := sqlerrm; end;
    begin perform erp.pay_payment_run(v_run1); v_err2 := 'paid';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_withdraw_payment_run(v_run1, 'again'); v_err3 := 'withdrawn twice';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a withdrawn run is neither approved, nor paid, nor withdrawn a second time';
    passed := v_state is null
          and v_err like 'CLOVEERP_PAYMENT_NOT_PROPOSED%'
          and v_err2 like 'CLOVEERP_PAYMENT_NOT_APPROVED%'
          and v_err3 like 'CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE%'
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run1) = 'cancelled';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3));
    return next;

    -- ── 4. Its bill comes back on the next run ──────────────────────────────
    v_step := 'a new run once the first is withdrawn';
    v_run2 := erp.propose_payment_run(current_date, null, interval '60 days');
    v_cases := v_cases + 1;
    case_name := 'the bill the withdrawn run held comes back on the next run proposed';
    passed := v_state is null
          and exists (select 1 from erp.payment_proposal_line l
                       where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run2
                         and l.document_id = v_bill and not l.is_held);
    detail := coalesce(v_state, format('%s line(s) of the new run name the bill',
      (select count(*) from erp.payment_proposal_line l
        where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run2 and l.document_id = v_bill)));
    return next;

    -- ── 5. Not without a reason, and not by a buyer ─────────────────────────
    v_step := 'withdrawing the new run with no reason, and as a buyer';
    v_err := null; v_err2 := null;
    begin perform public.erp_withdraw_payment_run(v_run2, '   '); v_err := 'withdrawn';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin perform public.erp_withdraw_payment_run(v_run2, 'a buyer tidying up'); v_err2 := 'withdrawn';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a run is not withdrawn without a reason, nor by somebody who may not approve payments; it stays proposed';
    passed := v_state is null
          and v_err like 'CLOVEERP_WITHDRAWAL_NEEDS_A_REASON%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED%'
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run2) = 'proposed';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2));
    return next;

    -- ── 6. Approved, it is not withdrawn ────────────────────────────────────
    v_step := 'the new run approved by the second administrator, then withdrawn';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_run2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_err := null;
    begin perform public.erp_withdraw_payment_run(v_run2, 'changed our mind'); v_err := 'withdrawn';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an approved run is not withdrawn: a second person agreed to pay it';
    passed := v_state is null
          and v_err like 'CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE%'
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run2) = 'approved';
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 7. Paid, it is not withdrawn ────────────────────────────────────────
    v_step := 'the approved run paid, then withdrawn';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.pay_payment_run(v_run2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_err := null;
    begin perform public.erp_withdraw_payment_run(v_run2, 'paid by mistake'); v_err := 'withdrawn';
    exception when others then v_err := sqlerrm; end;
    v_st := erp.object_current_state('document', v_bill);
    v_cases := v_cases + 1;
    case_name := 'a paid run is not withdrawn, and the bill it paid stays paid';
    passed := v_state is null
          and v_err like 'CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE%'
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run2) = 'paid'
          and v_st = 'paid';
    detail := coalesce(v_state, concat_ws(' / ', v_err, 'the bill is ' || v_st));
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
    raise exception 'CLOVEERP_PAYMENT_RUN_WITHDRAWAL_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.payment_run_withdrawal_suite() from public, anon;

comment on function erp_test.payment_run_withdrawal_suite() is
  'A proposed run can be withdrawn (20261006041000): withdrawn with a reason it is neither approved nor paid and its '
  'bill comes back; no reason, an approved run, a paid run and a buyer are each refused.';

create or replace function erp_test.assert_payment_run_withdrawal_suite()
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
    from erp_test.payment_run_withdrawal_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PAYMENT_RUN_WITHDRAWAL_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A payment run could be withdrawn when it should not, or not when it should. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_PAYMENT_RUN_WITHDRAWAL_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('payment run withdrawal: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_payment_run_withdrawal_suite() from public, anon;

comment on function erp_test.assert_payment_run_withdrawal_suite() is
  'A payment run waiting for its approver can be withdrawn with a reason; an approved or paid one cannot (20261006041000).';

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
