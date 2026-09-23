set lock_timeout = '30s';

-- =============================================================================
-- 20260923600000  A control is drawn only where it can be completed
-- -----------------------------------------------------------------------------
-- PR5, M3: node X4 of docs/spec/simplification-review.md.
--
-- The document page drew a button for every move the lifecycle offered the
-- person, and a disabled one where its guard failed. Two things made that a
-- promise the database then broke:
--
--   * public.erp_available_transitions() read every guard against an empty
--     document ('{}'), while erp.transition_document() reads it against the
--     document itself (erp.document_transition_context). Any guard that reads
--     the document said yes on the screen and no at the door. (All 67 seeded
--     guards are `true` today, so nothing showed it yet.)
--   * Approve was drawn for somebody the door would refuse: while the
--     approval waits on somebody else's decision, once it has been refused,
--     and for the person who asked for it. The screen could not know, because
--     the list said nothing about it.
--
-- And Amend was drawn on every line of a committed document, though
-- erp.amendment_allowed() refuses once stock has moved, picking has started
-- or the ledger holds it: nothing in the page's payload said so.
--
-- Now the list reads guards against the document, says which moves the door
-- would refuse and why, and the document's payload says whether it can still
-- be amended. The screens draw only what can be completed and say in one line
-- why nothing else is offered. Hiding a control is still convenience: the
-- database refuses regardless.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. What the door would refuse, said before the press
--
-- Exactly the refusals erp.require_document_approval() makes, in the order it
-- makes them, and nothing it does not. An approver who holds a task on a
-- waiting request is not refused: their press decides it (20260923200000).
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_refusal(p_document_id uuid, p_transition_code text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_chain  text;
  q        erp.approval_request%rowtype;
  v_admin  boolean;
begin
  if p_transition_code is distinct from 'approve' or v_tenant is null then
    return null;
  end if;

  select dt.approval_chain_code into v_chain
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = p_document_id;
  if v_chain is null then
    return null;
  end if;

  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant
     and ar.object_type = 'document'
     and ar.object_id = p_document_id
     and ar.status in ('pending', 'approved', 'rejected')
   order by (ar.status = 'pending') desc, ar.requested_at desc, (ar.status = 'approved') desc
   limit 1;
  if not found then
    return null;
  end if;

  v_admin := erp.approves_as_administrator();

  if q.status = 'pending' then
    if v_admin then
      return null;
    end if;
    if exists (select 1 from erp.approval_task t
                where t.tenant_id = v_tenant and t.approval_request_id = q.id
                  and t.status = 'pending' and t.assignee_user_id = erp.current_principal_id()) then
      -- The press decides the holder's own task, and erp.decide_approval_task()
      -- refuses the person who asked, in a live organisation, whoever holds
      -- the task (found on review).
      if q.requested_by = erp.current_principal_id() and erp.tenant_is_live(v_tenant) then
        return 'CLOVEERP_DOCUMENT_SELF_APPROVAL';
      end if;
      return null;
    end if;
    return 'CLOVEERP_DOCUMENT_APPROVAL_PENDING';
  end if;

  if q.status = 'rejected' then
    return 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED';
  end if;

  if q.requested_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant)
     and not (erp.may_approve_own(q.requested_by, p_document_id)
              and erp.sole_approver_asked(q.id, q.requested_by))
     and exists (select 1 from erp.approval_task t
                  where t.tenant_id = v_tenant and t.approval_request_id = q.id
                    and t.status <> 'skipped')
     and not v_admin then
    return 'CLOVEERP_DOCUMENT_SELF_APPROVAL';
  end if;

  return null;
end $$;

comment on function erp.transition_refusal(uuid, text) is
  'The refusal erp.transition_document() would raise for this move before it is '
  'pressed (20260923600000): the approval refusals erp.require_document_approval() '
  'makes, in its order. Null when the door would take it, or when the refusal is '
  'one this does not predict; the door refuses regardless.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C2. The list reads guards against the document, and says what is refused
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_available_transitions(p_document_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  -- A document this organisation does not hold has no moves, as before: the
  -- context raises on it, and a stale link reads "no such document", not an
  -- error (found on review).
  if not exists (select 1 from erp.document d
                  where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id) then
    return '[]'::jsonb;
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'code', t.transition_code, 'name', t.name, 'to_state', t.to_state,
             'guard_passes', coalesce(t.guard_passes, true),
             'permitted', t.permitted, 'is_automatic', t.is_automatic,
             'refused', erp.transition_refusal(p_document_id, t.transition_code))), '[]'::jsonb)
      from erp.available_transitions('document', p_document_id,
             erp.document_transition_context(p_document_id, null)) t);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C3. The document says whether it can still be amended
-- ─────────────────────────────────────────────────────────────────────────────

do $amend$
declare
  v_sig constant text := 'public.erp_document(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    'lineage', coalesce(($o$;
  v_new constant text := $n$    -- Whether a committed line can still be amended, and if not why
    -- (20260923600000): the page draws Amend only where it can be.
    'amendment', (select jsonb_build_object('allowed', a.allowed, 'cut_off', a.cut_off,
                                            'detail', a.detail)
                    from erp.amendment_allowed(p_document_id) a
                   where exists (select 1 from erp.document d
                                  where d.tenant_id = erp.current_tenant_id()
                                    and d.id = p_document_id)),
    'lineage', coalesce(($n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % lineage anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$amend$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C4. The proof: erp_test.completable_controls_suite
--
-- What the list and the payload say is what the door does. A non-live
-- organisation with the demonstration's configuration, undone at the end.
-- ─────────────────────────────────────────────────────────────────────────────

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
    -- rightly refuses to change, so the fixture writes it with the guards on
    -- configuration paused for this one statement; the suite's undo takes it
    -- back with everything else.
    perform set_config('session_replication_role', 'replica', true);
    update erp.transition t set guard = '{">": [{"var": "total_minor"}, 100000]}'::jsonb
      from erp.state_machine_version v, erp.state_machine m
     where t.state_machine_version_id = v.id and v.state_machine_id = m.id
       and m.tenant_id = v_tenant and m.code = 'purchase_order' and t.code = 'send';
    perform set_config('session_replication_role', 'origin', true);
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
    perform set_config('session_replication_role', 'replica', true);
    update erp.transition t set guard = 'true'::jsonb
      from erp.state_machine_version v, erp.state_machine m
     where t.state_machine_version_id = v.id and v.state_machine_id = m.id
       and m.tenant_id = v_tenant and m.code = 'purchase_order' and t.code = 'send';
    perform set_config('session_replication_role', 'origin', true);
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
    perform set_config('session_replication_role', 'origin', true);
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

create or replace function erp_test.assert_completable_controls_suite()
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
    from erp_test.completable_controls_suite() s;
  if v_total <> 6 then
    raise exception 'CLOVEERP_COMPLETABLE_CONTROLS_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_COMPLETABLE_CONTROLS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A control drawn for a move the door refuses is a promise the database breaks. Read the case that failed.';
  end if;
end;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- C5. The words the page says instead of a button
--
-- Rendered through ui() from src/components/erp/available-transitions.ts, so
-- a tenant can rename them like any other screen string.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). ' || v.why
  from (values
    ('Waiting on somebody else''s approval.',
     'Said on a document instead of Approve, when the approval waits on a decision the person cannot make (20260923600000).'),
    ('The approval asked for was refused. Send it back to draft to change what was refused.',
     'Said instead of Approve on a document whose approval was refused.'),
    ('You asked for this approval, so somebody else gives it.',
     'Said instead of Approve to the person who asked for the approval.'),
    ('Some moves wait on a condition this document does not meet yet.',
     'Said once when a move is not drawn because its guard fails against the document.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

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
