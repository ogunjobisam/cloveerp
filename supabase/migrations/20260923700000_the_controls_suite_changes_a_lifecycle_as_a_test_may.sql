set lock_timeout = '30s';

-- =============================================================================
-- 20260923700000  The controls suite changes a lifecycle as a test may
-- -----------------------------------------------------------------------------
-- PR5, M3's repair. erp_test.completable_controls_suite (20260923600000)
-- gave the purchase order's Send a guard by pausing triggers with
-- session_replication_role, which only a superuser may set. The build does
-- not run as one, and refused it:
--
--   permission denied to set parameter "session_replication_role"
--
-- The suite now does it the way the configuration allows: in its own
-- organisation, which is not live, the Send's version is taken out of force
-- for the one edit and put back (erp_test.set_send_guard, which refuses a live
-- organisation). Nothing else in the suite changes, and it keeps six cases.
-- =============================================================================

create or replace function erp_test.set_send_guard(p_tenant uuid, p_guard jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_version uuid;
begin
  if erp.tenant_is_live(p_tenant) then
    raise exception 'CLOVEERP_SUITE_NOT_LIVE_ONLY: a fixture changes a lifecycle only in an organisation that is not live';
  end if;
  select v.id into v_version
    from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
   where m.tenant_id = p_tenant and m.code = 'purchase_order' and v.status = 'active';
  update erp.state_machine_version set status = 'draft' where id = v_version;
  update erp.transition set guard = p_guard
   where state_machine_version_id = v_version and code = 'send';
  update erp.state_machine_version set status = 'active' where id = v_version;
end $$;

comment on function erp_test.set_send_guard(uuid, jsonb) is
  'Test fixture (20260923700000): gives the purchase order''s Send a guard in an '
  'organisation that is not live, by taking its version out of force for the one '
  'edit. Refuses a live organisation.';

create or replace function erp_test.completable_controls_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  a_admin  uuid := gen_random_uuid();
  a_ok     uuid := gen_random_uuid();
  v_demo   jsonb;
  v_entity uuid; v_site uuid; v_uom uuid; v_sup uuid; v_item uuid; v_role uuid; v_uid uuid; v_tok text;
  v_po uuid; v_small uuid; v_line uuid; v_g uuid;
  v_list jsonb; v_list2 jsonb; v_doc jsonb; v_doc2 jsonb; v_msg text; v_x text;
  f_approve jsonb; f_send jsonb;
begin
  begin
    select p.tenant_id, p.admin_user_id, p.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzctrl', 'Completable Controls Suite', 'admin@zzctrl.test', 'Controls Admin') p;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a_admin, 'admin@zzctrl.test'), (a_ok, 'ok@zzctrl.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.claim_invitation(v_token);
    v_demo := erp.ensure_demo_configuration(v_tenant, v_admin);
    v_entity := (v_demo ->> 'entity_id')::uuid;
    v_site := (v_demo ->> 'site_id')::uuid;

    select u.id into v_uom from erp.uom u
     where u.tenant_id = v_tenant and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZCSUP', 'Controls Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZCWID', 'Controls Suite Widget', v_uom, 'active') returning id into v_item;

    -- An order approver who is not an administrator and not the chain's
    -- role: they may press Approve, and hold no task on anything.
    insert into erp.role (tenant_id, code, name) values (v_tenant, 'zz_order_approver', 'Order approver')
    returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (v_tenant, v_role, 'procurement.approve'), (v_tenant, v_role, 'procurement.read');
    select i.app_user_id, i.token into v_uid, v_tok from erp.invite_principal('ok@zzctrl.test', 'Order Approver') i;
    perform erp.grant_role(v_uid, 'zz_order_approver', null, null, 'the completable controls suite', null, null, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_ok)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);

    -- An order above the approval threshold, waiting on its approvers.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_po, v_item, 1, 5000000, 'a large order');
    perform erp.transition_document(v_po, 'submit', null);

    -- 1. The approver who holds no task is told the move would be refused,
    --    and the door agrees.
    perform set_config('request.jwt.claims', json_build_object('sub', a_ok)::text, true);
    v_list := public.erp_available_transitions(v_po);
    select e into f_approve from jsonb_array_elements(v_list) e where e ->> 'code' = 'approve';
    begin
      perform erp.transition_document(v_po, 'approve', null);
      v_msg := 'approved';
    exception when others then v_msg := split_part(sqlerrm, ':', 1); end;
    return query select 'Approve on an order waiting on somebody else''s decision is said to be refused, as the door refuses it',
      (f_approve ->> 'permitted')::boolean and f_approve ->> 'refused' = 'CLOVEERP_DOCUMENT_APPROVAL_PENDING'
      and v_msg = 'CLOVEERP_DOCUMENT_APPROVAL_PENDING',
      format('listed %s; the door said %s', f_approve, v_msg);

    -- 2. The administrator, whose press decides it, is not.
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_list := public.erp_available_transitions(v_po);
    select e into f_approve from jsonb_array_elements(v_list) e where e ->> 'code' = 'approve';
    return query select 'the same move is offered to the administrator, whose press decides the approval',
      (f_approve ->> 'permitted')::boolean and f_approve ->> 'refused' is null,
      format('listed %s', f_approve);

    -- 3. A guard that reads the document is read against the document.
    v_small := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_small, v_item, 1, 1000, 'a small order');
    perform erp.transition_document(v_small, 'submit', null);
    if erp.object_current_state('document', v_small) = 'pending_approval' then
      perform erp.transition_document(v_small, 'approve', null);
    end if;
    -- A guard that reads the document, on Send. The version is in force and
    -- rightly refuses to change, so this organisation, which is not live,
    -- takes it out of force for the one edit and puts it back; the suite's
    -- undo takes all of it back with everything else.
    perform erp_test.set_send_guard(v_tenant, '{">": [{"var": "total_minor"}, 100000]}'::jsonb);
    v_list := public.erp_available_transitions(v_small);
    select e into f_send from jsonb_array_elements(v_list) e where e ->> 'code' = 'send';
    begin
      perform erp.transition_document(v_small, 'send', null);
      v_msg := 'sent';
    exception when others then v_msg := split_part(sqlerrm, ':', 1); end;
    update erp.document_line set unit_price_minor = 500000, net_minor = 500000
     where tenant_id = v_tenant and document_id = v_small;
    v_list2 := public.erp_available_transitions(v_small);
    return query select 'a guard that reads the document fails on the list where it fails at the door, and passes where it passes',
      (f_send ->> 'guard_passes')::boolean = false and v_msg = 'CLOVEERP_TRANSITION_GUARD_FAILED'
      and exists (select 1 from jsonb_array_elements(v_list2) e
                   where e ->> 'code' = 'send' and (e ->> 'guard_passes')::boolean),
      format('small: %s, the door said %s; large: %s', f_send, v_msg,
             (select e from jsonb_array_elements(v_list2) e where e ->> 'code' = 'send'));

    -- 4. The document says whether it can still be amended, as the door does.
    perform erp_test.set_send_guard(v_tenant, 'true'::jsonb);
    perform erp.transition_document(v_small, 'send', null);
    select dl.id into v_line from erp.document_line dl where dl.tenant_id = v_tenant and dl.document_id = v_small;
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_line, 1, null);
    v_doc := public.erp_document(v_g);
    perform erp.transition_document(v_g, 'post', null);
    v_doc2 := public.erp_document(v_g);
    begin
      perform erp.amend_document_line((select dl.id from erp.document_line dl
                                        where dl.tenant_id = v_tenant and dl.document_id = v_g limit 1),
                                      2, 'more');
      v_x := 'amended';
    exception when others then v_x := split_part(sqlerrm, ':', 1); end;
    return query select 'the document says whether a line can still be amended, and why not once stock has moved',
      (v_doc -> 'amendment' ->> 'allowed')::boolean
      and (v_doc2 -> 'amendment' ->> 'allowed')::boolean = false
      and v_doc2 -> 'amendment' ->> 'cut_off' = 'stock_has_moved'
      and v_x = 'CLOVEERP_PAST_AMENDMENT_CUT_OFF',
      format('before posting %s; after %s; the door said %s', v_doc -> 'amendment', v_doc2 -> 'amendment', v_x);

    -- 5. A document the organisation does not hold reads as not there, not
    --    as an error: a stale link says so (found on review).
    v_x := gen_random_uuid()::text;
    begin
      v_doc := public.erp_document(v_x::uuid);
      v_list := public.erp_available_transitions(v_x::uuid);
      v_msg := null;
    exception when others then v_msg := left(sqlerrm, 120); end;
    return query select 'a document the organisation does not hold has no moves and no amendment, and raises nothing',
      v_msg is null and v_list = '[]'::jsonb and v_doc -> 'document' = 'null'::jsonb
      and v_doc -> 'amendment' = 'null'::jsonb,
      coalesce(v_msg, format('moves %s; document %s; amendment %s', v_list, v_doc -> 'document', v_doc -> 'amendment'));

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzctrl')
            and not exists (select 1 from auth.users u where u.id in (a_admin, a_ok));
  detail := 'the organisation, its configuration and its documents rolled back';
  return next;
end;
$$;


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
