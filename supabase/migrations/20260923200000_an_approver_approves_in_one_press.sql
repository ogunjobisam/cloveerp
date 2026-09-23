set lock_timeout = '30s';

-- =============================================================================
-- 20260923200000  An approver approves in one press
-- -----------------------------------------------------------------------------
-- PR4, M4: node P5 of docs/spec/simplification-review.md, as PR4's decision 4
-- set it: the target flow's six steps are a walk by three different people,
-- not a relabelled strip, and an approver who is not an administrator
-- approves in one press as an administrator already does.
--
-- ── ONE PRESS ────────────────────────────────────────────────────────────────
--
-- An approver who is not an administrator pressed Approve on a document
-- waiting for them and was refused (CLOVEERP_DOCUMENT_APPROVAL_PENDING): they
-- had to open My approvals, decide their task, come back and press Approve
-- again. Now pressing Approve decides their own pending tasks first, through
-- erp.approve_my_document_tasks() and so erp.decide_approval_task(), with
-- every check it makes (the requester does not decide their own request; the
-- task must be theirs). Only a person the Approve move is offered to, and
-- permitted, has their tasks decided this way; anybody else is refused as
-- before, and learns nothing new.
--
--   * Their decision completes the request: the document is approved, in the
--     same press.
--   * Somebody else's decision is still needed: their decision is kept and the
--     document stays where it is. erp.transition_document() returns the state
--     it is still in ("decided, still waiting") instead of raising, which
--     rolled their decision back with the refusal.
--
-- Nothing changes for an administrator, whose press already decides every
-- task where the organisation allows it (20260914098000), or for a document
-- whose type has no chain.
--
-- ── SIX ──────────────────────────────────────────────────────────────────────
--
-- erp_test.step_budget_suite() gains the walk the target flow's X1 asked for
-- and never had: in a live organisation, a buyer, an approver who is not an
-- administrator and a receiver press six public doors, and the requisition
-- reads Ordered and the order Closed with nobody pressing anything else.
--
--   1 buyer     create the requisition, submitted as it is made
--   2 approver  approve it (one press)
--   3 buyer     convert it (the order is born approved)
--   4 buyer     issue the order
--   5 receiver  receive against the order, posted as it is made
--   6 buyer     bill from the receipt, registered as it is made
--
-- The screen strip's register count is not lowered: moving buttons deletes no
-- step, and X1's migration (20260921420000) forbids lowering it that way.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- D1. The approver's own tasks, decided on the document
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.decide_own_approval_tasks(p_document_id uuid, p_transition_code text,
                                                         p_reason text default null)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_req    uuid;
  d        erp.document%rowtype;
  v_perm   text;
begin
  -- Only the Approve move, and never for an administrator: their press is
  -- erp.require_document_approval()'s, as it always was.
  if p_transition_code is distinct from 'approve' or erp.approves_as_administrator() then
    return false;
  end if;

  select q.id into v_req
    from erp.approval_request q
   where q.tenant_id = v_tenant and q.object_type = 'document'
     and q.object_id = p_document_id and q.status = 'pending'
   order by q.requested_at desc
   limit 1;
  if v_req is null
     or not exists (select 1 from erp.approval_task t
                     where t.tenant_id = v_tenant and t.approval_request_id = v_req
                       and t.status = 'pending' and t.assignee_user_id = v_me) then
    return false;
  end if;

  -- Only for a person the move is offered to and whose guard passes: anybody
  -- else is refused by the move itself, as before, and has nothing decided.
  if not exists (
       select 1 from erp.available_transitions('document', p_document_id,
                       erp.document_transition_context(p_document_id, 'approve')) at
        where at.transition_code = 'approve' and at.guard_passes) then
    return false;
  end if;

  -- Authorised as the move is, before anything is decided (found on review):
  -- the entry point, a restricted or suspended organisation and the access
  -- log all apply to one press as they do to the move itself.
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  select t.required_permission into v_perm
    from erp.object_state os
    join erp.transition t
      on t.state_machine_version_id = os.state_machine_version_id
     and t.from_state_id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id and t.code = 'approve'
   limit 1;
  if v_perm is not null then
    perform erp.authorise(v_perm, d.entity_id, d.site_id, null, 'document', p_document_id);
  end if;

  -- The approver's note goes on their decision, which is where it is kept
  -- when the document does not move.
  perform erp.approve_my_document_tasks(p_document_id, coalesce(nullif(btrim(p_reason), ''), 'Approved on the document'));

  -- Still waiting on somebody else: their decision stands, the document stays.
  return exists (select 1 from erp.approval_request q
                  where q.tenant_id = v_tenant and q.id = v_req and q.status = 'pending');
end $$;

comment on function erp.decide_own_approval_tasks(uuid, text, text) is
  'Approve pressed by an approver who is not an administrator (20260923200000): '
  'decides their own pending tasks on the document through '
  'erp.approve_my_document_tasks(), and returns true when the request still '
  'waits on somebody else, so erp.transition_document() keeps the decision and '
  'leaves the document where it is.';

do $one_press$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
$o$;
  v_new constant text := $n$  -- An approver who is not an administrator approves in one press
  -- (20260923200000): their own tasks are decided first. If somebody else's
  -- decision is still needed, theirs is kept and the document stays where it
  -- is, rather than the refusal below rolling their decision back with it.
  if erp.decide_own_approval_tasks(p_document_id, p_transition_code, p_reason) then
    return erp.object_current_state('document', p_document_id);
  end if;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % engine anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$one_press$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D2. The suites one press changes the answer for
--
-- approval_hold_suite pressed Approve as the second administrator, who holds
-- the order's task, to show a pending document is not approved. One press
-- decides that task now, which is the point. The case is kept for the person
-- it is about: the first administrator may approve and holds no task, and is
-- refused while it is pending. Still seventeen cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $hold$
declare
  v_sig constant text := 'erp_test.approval_hold_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    -- Pending: not approved, even by somebody who may approve.
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin
      perform erp.transition_document(v_po, 'approve');
    exception when others then
      v_pending_err := left(sqlerrm, 200);
    end;
$o$;
  v_new constant text := $n$    -- Pending: not approved, even by somebody who may approve, when the
    -- task is somebody else's. The second administrator holds it, and their
    -- press would decide it (20260923200000); the first holds none.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      perform erp.transition_document(v_po, 'approve');
    exception when others then
      v_pending_err := left(sqlerrm, 200);
    end;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % pending anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$hold$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D3. The walk
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- D3. The six presses, walked by three people
--
-- erp_test.six_step_walk() provisions a live organisation of its own, sets it
-- up as the Configuration screen would, and has three people who are not
-- administrators press the six public doors of the target flow:
--
--   1 buyer     public.erp_create_document_full(requisition, ..., 'auto')
--   2 approver  public.erp_transition_document(requisition, 'approve')
--   3 buyer     public.erp_convert_document(requisition)
--   4 buyer     public.erp_transition_document(order, 'send'), which issues it
--   5 receiver  public.erp_create_receipt_from_order(order, null, 'post')
--   6 buyer     public.erp_bill_from_receipt(receipt, ...)
--
-- and then, in the same organisation, the press that decides and still
-- waits: a requisition above the threshold asks for two decisions, the
-- first approver's press keeps theirs and leaves the requisition where it
-- is, and the second approver's press approves it.
--
-- The chain as erp_configure_procurement() installs it names one role for
-- both of its steps, and nothing stops one holder deciding both: one press
-- by the first approver would approve it outright (measured as
-- installed_chain below, on a requisition). So the wait is measured on a
-- purchase order whose chain's second step asks a role only the second
-- approver holds, a chain version made and activated in the bootstrap
-- window as a fixture: a request that genuinely waits on somebody else.
--
-- Everything it does is undone by a private exception before it returns: the
-- organisation, its people and its documents never outlive the call.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.six_step_walk()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c_undo   constant text := 'CLOVEERP_SIX_STEP_WALK_UNDO';
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code   text;
  -- The people, by the subject their session carries.
  a1       uuid := gen_random_uuid();   -- the first administrator, who sets up
  a2       uuid := gen_random_uuid();   -- the second, who approves the changes
  s_buyer  uuid := gen_random_uuid();
  s_appr   uuid := gen_random_uuid();
  s_appr2  uuid := gen_random_uuid();   -- the second approver, for the wait
  s_recv   uuid := gen_random_uuid();
  -- Their principals.
  p_buyer  uuid;
  p_appr   uuid;
  p_appr2  uuid;
  p_recv   uuid;
  r        record;
  res      jsonb;
  v_tok_a2 text;
  v_tok_b  text;
  v_tok_ap text;
  v_tok_a3 text;
  v_tok_rc text;
  v_role   uuid;
  v_frole  uuid;
  v_ver    uuid;
  v_ver2   uuid;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_ctrl  uuid;
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_item   uuid;
  v_lines  jsonb;
  -- The walk.
  v_steps  jsonb := '[]'::jsonb;
  v_subs   uuid[] := '{}';
  v_block  text;
  v_rq     uuid;
  v_po     uuid;
  v_grn    uuid;
  v_bill   uuid;
  v_born   boolean;
  v_rq_state   text;
  v_po_state   text;
  v_grn_state  text;
  v_bill_state text;
  v_chain_roles text[];
  v_seats  jsonb;
  v_admins integer;
  -- The wait.
  v_rq2    uuid;
  v_req2   uuid;
  v_wblock text;
  v_first_state   text;
  v_first_task    text;
  v_first_kept    integer;
  v_first_note    text;
  v_req_after     text;
  v_rq2_after     text;
  v_second_state  text;
  v_req_final     text;
  v_steps2        integer;
  v_rq3           uuid;
  v_one_state     text;
  v_one_tasks     integer;
  v_one_deciders  integer;
  v_out    jsonb;
begin
  begin
    v_code := 'zzwalk-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Six step walk', 'admin@' || v_code || '.test', 'Walk Admin');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp_test.administrator_approval_off(r.tenant_id);

    -- The approver role, which is tenant data and so made in the bootstrap
    -- window a fixture is allowed: approves purchases and reads them, and
    -- nothing else.
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_walk_approver', 'Walk approver', 'active')
    returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (r.tenant_id, v_role, 'procurement.approve'),
      (r.tenant_id, v_role, 'procurement.read'),
      (r.tenant_id, v_role, 'reporting.read');
    -- And a second approving role, asked for the wait below.
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_walk_finance', 'Walk finance approver', 'active')
    returning id into v_frole;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (r.tenant_id, v_frole, 'procurement.approve'),
      (r.tenant_id, v_frole, 'procurement.read'),
      (r.tenant_id, v_frole, 'reporting.read');
    perform erp_test.close_bootstrap_window(r.tenant_id);

    -- The people, each given their role by the first administrator.
    res := public.erp_invite_principal('second@' || v_code || '.test', 'Second Admin');
    v_tok_a2 := res ->> 'token';
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('buyer@' || v_code || '.test', 'Bea Buyer');
    p_buyer := (res ->> 'app_user_id')::uuid; v_tok_b := res ->> 'token';
    perform erp.grant_role(p_buyer, 'purchasing', null, null, 'buys');
    res := public.erp_invite_principal('approver@' || v_code || '.test', 'Abe Approver');
    p_appr := (res ->> 'app_user_id')::uuid; v_tok_ap := res ->> 'token';
    perform erp.grant_role(p_appr, 'zz_walk_approver', null, null, 'approves purchases');
    res := public.erp_invite_principal('approver2@' || v_code || '.test', 'Ada Approver');
    p_appr2 := (res ->> 'app_user_id')::uuid; v_tok_a3 := res ->> 'token';
    perform erp.grant_role(p_appr2, 'zz_walk_approver', null, null, 'approves purchases too');
    perform erp.grant_role(p_appr2, 'zz_walk_finance', null, null, 'approves large purchases');
    res := public.erp_invite_principal('receiver@' || v_code || '.test', 'Rex Receiver');
    p_recv := (res ->> 'app_user_id')::uuid; v_tok_rc := res ->> 'token';
    perform erp.grant_role(p_recv, 'warehouse', null, null, 'receives');

    -- Installed as the Configuration screen installs it, naming the approver
    -- role now that somebody holds it. Live, so the other administrator
    -- approves and promotes each change.
    cs_fin := erp.configure_finance();
    select (d ->> 'lifecycle_change_set_id')::uuid, (d ->> 'controls_change_set_id')::uuid
      into cs_proc, cs_ctrl
      from public.erp_configure_procurement(1000000, 'zz_walk_approver') d;

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok_a2);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_ctrl);
    perform erp.promote_change_set(cs_ctrl);

    perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
    perform erp.claim_invitation(v_tok_b);
    perform set_config('request.jwt.claims', json_build_object('sub', s_appr)::text, true);
    perform erp.claim_invitation(v_tok_ap);
    perform set_config('request.jwt.claims', json_build_object('sub', s_appr2)::text, true);
    perform erp.claim_invitation(v_tok_a3);
    perform set_config('request.jwt.claims', json_build_object('sub', s_recv)::text, true);
    perform erp.claim_invitation(v_tok_rc);

    -- The fixture for the wait: a new version of the order chain, the same
    -- but for its second step, which asks the finance role only the second
    -- approver holds. A version in force is not changed, so one is made and
    -- activated, in the bootstrap window. The requisition chain, which the
    -- walk asks, is left as installed.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    select v.id into v_ver
      from erp.approval_chain c
      join erp.approval_chain_version v
        on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id and v.status = 'active'
     where c.tenant_id = r.tenant_id and c.code = 'purchase_order_value';
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status,
                                            effective_from, material_fields, value_field,
                                            tolerance_pct, tolerance_absolute, note)
    select v.tenant_id, v.approval_chain_id,
           (select max(v2.version) + 1 from erp.approval_chain_version v2
             where v2.tenant_id = v.tenant_id and v2.approval_chain_id = v.approval_chain_id),
           'draft', v.effective_from, v.material_fields, v.value_field,
           v.tolerance_pct, v.tolerance_absolute, 'six step walk: the finance step asks somebody else'
      from erp.approval_chain_version v where v.id = v_ver
    returning id into v_ver2;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, description,
                                   approver_kind, role_id, app_user_id, min_approvals, condition,
                                   escalate_after, escalate_to_role_id, escalate_to_user_id,
                                   allow_delegation, approver_source)
    select s.tenant_id, v_ver2, s.seq, s.code, s.name, s.description,
           s.approver_kind, case when s.seq = 2 then v_frole else s.role_id end, s.app_user_id,
           s.min_approvals, s.condition, s.escalate_after, s.escalate_to_role_id,
           s.escalate_to_user_id, s.allow_delegation, s.approver_source
      from erp.approval_step s
     where s.tenant_id = r.tenant_id and s.approval_chain_version_id = v_ver;
    perform erp.activate_approval_chain_version(v_ver2, null);
    perform erp_test.close_bootstrap_window(r.tenant_id);

    -- Master data, as a fixture.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

    select array_agg(distinct ro.code order by ro.code) into v_chain_roles
      from erp.approval_chain c
      join erp.approval_chain_version v
        on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id and v.status = 'active'
      join erp.approval_step s on s.tenant_id = v.tenant_id and s.approval_chain_version_id = v.id
      join erp.role ro on ro.tenant_id = s.tenant_id and ro.id = s.role_id
     where c.tenant_id = r.tenant_id;
    select jsonb_object_agg(x.who, erp.person_seat(x.p)) into v_seats
      from (values ('buyer', p_buyer), ('approver', p_appr), ('approver2', p_appr2),
                   ('receiver', p_recv)) x(who, p);
    select count(*) into v_admins
      from erp.organisation_administrators() a
     where a.app_user_id in (p_buyer, p_appr, p_appr2, p_recv);

    -- ─────────────────────────────────────────────────────────────────────
    -- The six presses. Each is made in the session of the person named, and
    -- recorded with what the door returned; the first refusal is recorded
    -- and the walk stops there.
    -- ─────────────────────────────────────────────────────────────────────
    v_lines := jsonb_build_array(jsonb_build_object(
                 'item_id', v_item, 'quantity', 10, 'unit_price_minor', 5000,
                 'description', 'Ten widgets'));

    -- 1. The buyer asks for ten widgets from the supplier, to the site.
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
      res := public.erp_create_document_full('requisition', v_sup, v_site, null, null, null, v_lines, 'auto');
      v_rq := (res ->> 'document_id')::uuid;
      v_steps := v_steps || jsonb_build_object('step', 1, 'door', 'erp_create_document_full',
                   'person', 'buyer', 'result', res);
      v_subs := v_subs || s_buyer;
    exception when others then
      v_block := format('1 buyer erp_create_document_full: %s', left(sqlerrm, 300));
    end;

    -- 2. The approver approves it, in one press.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_appr)::text, true);
        res := public.erp_transition_document(v_rq, 'approve', null);
        v_steps := v_steps || jsonb_build_object('step', 2, 'door', 'erp_transition_document',
                     'move', 'approve', 'person', 'approver', 'result', res);
        v_subs := v_subs || s_appr;
      exception when others then
        v_block := format('2 approver erp_transition_document(approve): %s', left(sqlerrm, 300));
      end;
    end if;

    -- 3. The buyer converts it; the order is born approved.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
        res := public.erp_convert_document(v_rq, null, null, null, null);
        v_po := (res ->> 'document_id')::uuid;
        v_born := coalesce((res ->> 'born_approved')::boolean, false);
        v_steps := v_steps || jsonb_build_object('step', 3, 'door', 'erp_convert_document',
                     'person', 'buyer', 'result', res);
        v_subs := v_subs || s_buyer;
      exception when others then
        v_block := format('3 buyer erp_convert_document: %s', left(sqlerrm, 300));
      end;
    end if;

    -- 4. The buyer issues the order to the supplier: the order's move is
    -- called send.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
        res := public.erp_transition_document(v_po, 'send', null);
        v_steps := v_steps || jsonb_build_object('step', 4, 'door', 'erp_transition_document',
                     'move', 'send', 'person', 'buyer', 'result', res);
        v_subs := v_subs || s_buyer;
      exception when others then
        v_block := format('4 buyer erp_transition_document(send): %s', left(sqlerrm, 300));
      end;
    end if;

    -- 5. The receiver receives everything outstanding, posted as it is made.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_recv)::text, true);
        res := public.erp_create_receipt_from_order(v_po, null, 'post');
        v_grn := coalesce((res ->> 'document_id')::uuid, (res ->> 'receipt_id')::uuid);
        v_steps := v_steps || jsonb_build_object('step', 5, 'door', 'erp_create_receipt_from_order',
                     'person', 'receiver', 'result', res);
        v_subs := v_subs || s_recv;
      exception when others then
        v_block := format('5 receiver erp_create_receipt_from_order(post): %s', left(sqlerrm, 300));
      end;
    end if;

    -- 6. The buyer bills from the receipt; the bill is registered.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
        res := public.erp_bill_from_receipt(v_grn, 'INV-' || v_hex, current_date,
                                            current_date + 30, null, null);
        v_bill := (res ->> 'document_id')::uuid;
        v_steps := v_steps || jsonb_build_object('step', 6, 'door', 'erp_bill_from_receipt',
                     'person', 'buyer', 'result', res);
        v_subs := v_subs || s_buyer;
      exception when others then
        v_block := format('6 buyer erp_bill_from_receipt: %s', left(sqlerrm, 300));
      end;
    end if;

    -- Read back by the administrator, who can see all of it.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_rq_state   := erp.object_current_state('document', v_rq);
    v_po_state   := erp.object_current_state('document', v_po);
    v_grn_state  := erp.object_current_state('document', v_grn);
    v_bill_state := erp.object_current_state('document', v_bill);

    -- ─────────────────────────────────────────────────────────────────────
    -- Decided, still waiting.
    -- ─────────────────────────────────────────────────────────────────────
    begin
      -- The chain as installed: above the threshold both steps ask the
      -- approver role, and the first approver's one press decides both.
      perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
      res := public.erp_create_document_full('requisition', v_sup, v_site, null, null, null,
               jsonb_build_array(jsonb_build_object(
                 'item_id', v_item, 'quantity', 300, 'unit_price_minor', 5000,
                 'description', 'Three hundred widgets')), 'auto');
      v_rq3 := (res ->> 'document_id')::uuid;
      perform set_config('request.jwt.claims', json_build_object('sub', s_appr)::text, true);
      v_one_state := public.erp_transition_document(v_rq3, 'approve', null) ->> 'state';
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select count(*), count(distinct t.decided_by) into v_one_tasks, v_one_deciders
        from erp.approval_task t
        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
       where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_rq3
         and t.status = 'approved';


      -- An order above the threshold: the buyer's step, asked of the approver
      -- role, then the finance step, asked of the second approver alone.
      perform set_config('request.jwt.claims', json_build_object('sub', s_buyer)::text, true);
      res := public.erp_create_document_full('purchase_order', v_sup, v_site, null, null, null,
               jsonb_build_array(jsonb_build_object(
                 'item_id', v_item, 'quantity', 300, 'unit_price_minor', 5000,
                 'description', 'Three hundred widgets')), 'auto');
      v_rq2 := (res ->> 'document_id')::uuid;

      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select q.id into v_req2
        from erp.approval_request q
       where q.tenant_id = r.tenant_id and q.object_type = 'document'
         and q.object_id = v_rq2 and q.status = 'pending';
      select count(distinct s.seq) into v_steps2
        from erp.approval_request q
        join erp.approval_step s
          on s.tenant_id = q.tenant_id and s.approval_chain_version_id = q.approval_chain_version_id
       where q.tenant_id = r.tenant_id and q.id = v_req2;

      perform set_config('request.jwt.claims', json_build_object('sub', s_appr)::text, true);
      v_first_state := public.erp_transition_document(v_rq2, 'approve', 'Within budget for Q3') ->> 'state';

      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select string_agg(distinct t.status::text, ',' order by t.status::text) into v_first_task
        from erp.approval_task t
       where t.tenant_id = r.tenant_id and t.approval_request_id = v_req2
         and t.decided_by = p_appr;
      select count(*), max(t.comment) into v_first_kept, v_first_note
        from erp.approval_task t
       where t.tenant_id = r.tenant_id and t.approval_request_id = v_req2
         and t.status = 'approved';
      select q.status::text into v_req_after
        from erp.approval_request q where q.tenant_id = r.tenant_id and q.id = v_req2;
      v_rq2_after := erp.object_current_state('document', v_rq2);

      perform set_config('request.jwt.claims', json_build_object('sub', s_appr2)::text, true);
      v_second_state := public.erp_transition_document(v_rq2, 'approve', null) ->> 'state';

      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select q.status::text into v_req_final
        from erp.approval_request q where q.tenant_id = r.tenant_id and q.id = v_req2;
    exception when others then
      v_wblock := left(sqlerrm, 300);
    end;

    v_out := jsonb_build_object(
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', v_admins,
      'seats', v_seats,
      'chain_roles', to_jsonb(v_chain_roles),
      'requisition_state', v_rq_state,
      'order_state', v_po_state,
      'receipt_state', v_grn_state,
      'born_approved', coalesce(v_born, false),
      'bill_state', v_bill_state,
      'blocked', v_block,
      'steps', v_steps,
      'waiting', jsonb_build_object(
        'chain_steps', v_steps2,
        'first_press_state', v_first_state,
        'first_task_status', v_first_task,
        'approved_tasks_after_first', v_first_kept,
        'first_note', v_first_note,
        'request_after_first', v_req_after,
        'document_after_first', v_rq2_after,
        'second_press_state', v_second_state,
        'request_after_second', v_req_final,
        'blocked', v_wblock),
      'installed_chain', jsonb_build_object(
        'one_press_state', v_one_state,
        'approved_tasks', v_one_tasks,
        'deciders', v_one_deciders));

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$$;

comment on function erp_test.six_step_walk() is
  'The target flow''s six steps as a walk by three people who are not '
  'administrators (PR4 decision 4, 20260923200000): in a live organisation of '
  'its own, a buyer, an approver and a receiver press the six public doors, '
  'and one requisition above the threshold is approved by two approvers in a '
  'press each. Returns what each press returned and the states read after; '
  'everything it made is undone before it returns.';

-- ─────────────────────────────────────────────────────────────────────────────
-- The step budget suite, with the walk
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp_test.step_budget_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  c_expected constant integer := 8;
  v_cases   integer := 0;
  v_n       integer;
  v_bad     integer;
  v_detail  text;
  v_verdict text;
  v_total   integer;
  v_nolist  integer;
  v_walk    jsonb;
  v_wait    jsonb;
begin
  -- ── 1. Something is declared, and each cycle belongs somewhere ────────────
  select count(*) into v_n from erp_meta.flow_budget;
  select count(*), string_agg(b.flow_code, ', ' order by b.flow_code)
    into v_bad, v_detail
    from erp_meta.flow_budget b
   where not exists (select 1 from erp_ref.module m where m.code = b.module_code);

  v_cases := v_cases + 1;
  case_name := 'every cycle that declares a step budget belongs to a part of the product that exists';
  passed := coalesce(v_n > 0 and v_bad = 0, false);
  detail := format('%s cycle(s) declared; %s naming nothing%s', v_n, v_bad,
                   coalesce(': ' || v_detail, ''));
  return next;

  -- ── 2. Nothing is over its budget ─────────────────────────────────────────
  select count(*), string_agg(format('%s: %s', r.flow_code, r.detail), '; ' order by r.flow_code)
    into v_bad, v_detail
    from erp.flow_step_budget_report() r
   where r.verdict <> 'within';

  v_cases := v_cases + 1;
  case_name := 'no cycle costs more user actions than the budget declared for it';
  passed := coalesce(v_bad = 0, false);
  detail := coalesce(v_detail, format('%s cycle(s), all inside their budgets',
                                      (select count(*) from erp_meta.flow_budget)));
  return next;

  -- ── 3. A budget is a number somebody meant ────────────────────────────────
  select count(*), string_agg(format('%s (budget %s, %s action(s), %s step(s))',
                                     b.flow_code, b.budget, b.decision_steps, b.stages),
                              '; ' order by b.flow_code)
    into v_bad, v_detail
    from erp_meta.flow_budget b
   where b.budget < 1 or b.decision_steps < 1 or b.stages < 1
      or length(btrim(b.rationale)) < 40;

  v_cases := v_cases + 1;
  case_name := 'every declared budget is at least one action, over at least one step, with a reason written beside it';
  passed := coalesce(v_bad = 0, false);
  detail := coalesce(v_detail, 'every cycle declares a budget, a cost and a reason');
  return next;

  -- ── 4. It refuses a cycle that has gained a step ──────────────────────────
  --
  -- Falsified rather than believed. The report is handed one cycle inflated
  -- past its budget and the verdict is read back: a check that cannot be made
  -- to fail is a check nobody can trust when it passes.
  select r.verdict into v_verdict
    from erp.flow_step_budget_report(array[
           (select format('%s|%s|%s|%s', b.flow_code, b.budget + 1, b.stages, b.stages_without_a_list)
              from erp_meta.flow_budget b order by b.flow_code limit 1)]) r
   where r.flow_code = (select b.flow_code from erp_meta.flow_budget b order by b.flow_code limit 1);

  v_cases := v_cases + 1;
  case_name := 'a cycle that has gained an action beyond its budget is refused, which is how anyone knows the check can fail at all';
  passed := coalesce(v_verdict = 'over_budget', false);
  detail := format('one more action than the budget allows reads as %L', coalesce(v_verdict, '(nothing)'));
  return next;

  -- ── 5. It refuses a cycle nobody declared ─────────────────────────────────
  select r.verdict into v_verdict
    from erp.flow_step_budget_report(array['zznosuchcycle|3|3|0']) r
   where r.flow_code = 'zznosuchcycle';

  v_cases := v_cases + 1;
  case_name := 'a cycle the screens draw and nobody declared a budget for is refused rather than ignored';
  passed := coalesce(v_verdict = 'not_declared', false);
  detail := format('a cycle no register names reads as %L', coalesce(v_verdict, '(nothing)'));
  return next;

  -- ── 6. The steps that count nothing are counted ───────────────────────────
  select sum(b.stages), sum(b.stages_without_a_list) into v_total, v_nolist
    from erp_meta.flow_budget b;

  v_cases := v_cases + 1;
  case_name := 'the steps that keep no list of their own are counted, so the repair has a number rather than a memory';
  passed := coalesce(v_nolist is not null and v_total is not null and v_nolist <= v_total, false);
  detail := format('%s of %s step(s) across %s cycle(s) keep no list, so nothing can be counted at them',
                   v_nolist, v_total, (select count(*) from erp_meta.flow_budget));
  return next;

  -- ── 7. The cycle, walked ──────────────────────────────────────────────────
  --
  -- Counted by pressing, not by reading the screens (20260923200000): three
  -- people who are not administrators, six public doors, and the documents
  -- read back where the cycle leaves them.
  v_walk := erp_test.six_step_walk();
  v_wait := v_walk -> 'waiting';

  v_cases := v_cases + 1;
  case_name := 'the procurement cycle is walked by three people in six presses, and the requisition reads ordered and the order closed';
  passed := coalesce(v_walk ->> 'blocked' is null
            and (v_walk ->> 'presses')::integer = 6
            and (v_walk ->> 'people')::integer = 3
            and (v_walk ->> 'administrators_pressing')::integer = 0
            and (v_walk ->> 'born_approved')::boolean
            and v_walk ->> 'requisition_state' = 'ordered'
            and v_walk ->> 'order_state' = 'closed', false);
  detail := coalesce('blocked at ' || (v_walk ->> 'blocked') || '; ', '')
            || format('%s press(es) by %s people (%s of them administrators); born approved %s; the requisition reads %s, the order %s, the receipt %s, the bill %s',
                      coalesce(v_walk ->> 'presses', '0'), coalesce(v_walk ->> 'people', '0'),
                      coalesce(v_walk ->> 'administrators_pressing', 'an unknown number'),
                      coalesce(v_walk ->> 'born_approved', 'false'),
                      coalesce(v_walk ->> 'requisition_state', 'nothing'),
                      coalesce(v_walk ->> 'order_state', 'nothing'),
                      coalesce(v_walk ->> 'receipt_state', 'nothing'),
                      coalesce(v_walk ->> 'bill_state', 'nothing'));
  return next;

  -- ── 8. One press for an approver, and a decision kept ─────────────────────
  v_cases := v_cases + 1;
  case_name := 'an approver who is not an administrator approves in one press, and a decision that leaves somebody else to decide is kept with its note';
  passed := coalesce(v_walk ->> 'blocked' is null and v_wait ->> 'blocked' is null
            and v_walk -> 'steps' -> 1 ->> 'person' = 'approver'
            and v_walk -> 'steps' -> 1 -> 'result' ->> 'state' = 'approved'
            and v_walk -> 'seats' ->> 'approver' = 'full'
            and (v_wait ->> 'chain_steps')::integer = 2
            and v_wait ->> 'first_press_state' = 'pending_approval'
            and v_wait ->> 'document_after_first' = 'pending_approval'
            and v_wait ->> 'first_task_status' = 'approved'
            and (v_wait ->> 'approved_tasks_after_first')::integer = 1
            and v_wait ->> 'first_note' = 'Within budget for Q3'
            and v_wait ->> 'request_after_first' = 'pending'
            and v_wait ->> 'second_press_state' = 'approved'
            and v_wait ->> 'request_after_second' = 'approved', false);
  detail := coalesce('blocked at ' || (v_walk ->> 'blocked') || '; ', '')
            || coalesce('the wait blocked: ' || (v_wait ->> 'blocked') || '; ', '')
            || format('the approver''s one press gave %s; above the threshold (%s step(s)) the first approver''s press gave %s, their task %s, the request %s; the second approver''s press gave %s, the request %s',
                      coalesce(v_walk -> 'steps' -> 1 -> 'result' ->> 'state', 'nothing'),
                      coalesce(v_wait ->> 'chain_steps', '?'),
                      coalesce(v_wait ->> 'first_press_state', 'nothing'),
                      coalesce(v_wait ->> 'first_task_status', 'undecided'),
                      coalesce(v_wait ->> 'request_after_first', 'nowhere'),
                      coalesce(v_wait ->> 'second_press_state', 'nothing'),
                      coalesce(v_wait ->> 'request_after_second', 'nowhere'));
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_STEP_BUDGET_SUITE_SHRANK: % case(s), expected %', v_cases, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION erp_test.assert_step_budget_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  c_expected constant integer := 8;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _step_budget on commit drop as
    select * from erp_test.step_budget_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _step_budget;
  drop table _step_budget;
  if v_fail > 0 then
    raise exception E'CLOVEERP_STEP_BUDGET_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_STEP_BUDGET_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a cycle declares what it costs in steps: %s/%s cases passed', v_all, v_all);
end;
$function$;


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
