set lock_timeout = '30s';

-- =============================================================================
-- 20261006060000  A decided request moves its document
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-09). A purchase order
-- approved under "Decide an approval waiting on me" stayed Pending approval:
-- the request read approved, the task read approved, and the order waited for
-- somebody to open it and press Approve as well. The same from the link in
-- the approval email, for a sales order and for a requisition, and the same
-- for a refusal, which left the document waiting instead of sending it back.
--
-- erp.decide_approval_task() settles what the request was about through
-- erp.settle_approval_outcome(), which moves a count, a transfer order and a
-- stock adjustment and nothing else. An order or a requisition was only ever
-- moved by the press on the document, which decides the presser's own tasks
-- first (erp.decide_own_approval_tasks) and then makes the move.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.carry_decision_to_document(task): once the task a person has just
--      decided has decided its request, a purchase order, a sales order or a
--      requisition waiting on that request is approved or sent back to draft
--      by the approve or reject its lifecycle version declares out of where it
--      waits (pending_approval for an order, submitted for a requisition), as
--      a move derived from the request and named in erp.deriving_move, with
--      the approver's note as its reason. Only by the request that governs the
--      document, the newest; never over a document changed since it was asked
--      for, which stays for the person who presses Approve to be told why. A
--      move the approver may not make in full (a confirmed sales order posts,
--      and the posting asks for finance.post) is undone and the decision
--      stands: the document waits for the press on it, as before.
--   B. The two places a person decides a task away from the document call it:
--      public.erp_decide_approval (My approvals and the task form) and
--      erp.redeem_email_action (the link in the email).
--   C. erp.derived_move_fact() reads the same fact again, with the document's
--      state locked, for these three types as it does for a transfer order.
--   D. erp_test.decided_request_moves_document_suite, and erp_test.grant_suite,
--      whose walk through the doors pressed Approve after deciding the
--      order's task, now asks that the decision approved it.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- erp.decide_approval_task() itself is unchanged. The routines that decide
-- tasks and then press the move on the document go on doing so: the press on
-- the document (erp.decide_own_approval_tasks), an administrator's press
-- (erp.require_document_approval), and the demonstration's history, which
-- runs on live with every merge. A commercial quote keeps its own door,
-- erp.approve_quote(), which the vendor console presses after the decision.
-- Who may decide a task is unchanged: the assignee, never the person who
-- asked once the organisation is live, and the discount and credit steps only
-- with their permissions. The move takes its authority from the decided
-- request, as a transfer order's has since 20260928200000; the log says so.
--
-- On production: two functions are replaced, one door is rewritten in
-- plpgsql with the same arguments and answer, and one routine is added. No
-- table is altered and no row is changed. Nothing is stranded today (checked
-- on live, 4 October), so nothing is moved here.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The move
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.carry_decision_to_document(p_task_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_task   erp.approval_task%rowtype;
  q        erp.approval_request%rowtype;
  v_move   text;
  v_to     text;
begin
  -- The decision the caller has just made (20261006060000), and only once it
  -- has decided its request: a task approved while another step still waits
  -- moves nothing.
  select * into v_task
    from erp.approval_task t
   where t.tenant_id = v_tenant and t.id = p_task_id;
  if not found
     or v_task.decided_by is distinct from erp.current_principal_id()
     or v_task.status::text not in ('approved', 'rejected') then
    return null;
  end if;

  select * into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.id = v_task.approval_request_id;
  if q.object_type is distinct from 'document' or q.status::text not in ('approved', 'rejected') then
    return null;
  end if;
  v_move := case when q.status::text = 'approved' then 'approve' else 'reject' end;

  -- A purchase order, a sales order or a requisition, waiting on this
  -- request and no later one, where its version declares the move out of the
  -- state it stands in. An approval is not carried onto a document changed
  -- since it was asked for: it stays, and the press on it says why.
  if not exists (select 1
                   from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = v_tenant and d.id = q.object_id and not d.is_cancelled
                    and dt.base_type_code in ('purchase_order', 'sales_order', 'requisition'))
     or exists (select 1 from erp.approval_request q2
                 where q2.tenant_id = v_tenant and q2.object_type = 'document'
                   and q2.object_id = q.object_id and q2.id <> q.id
                   and (q2.status = 'pending' or q2.requested_at > q.requested_at))
     or not erp.document_declares_move(q.object_id, v_move)
     or (v_move = 'approve' and coalesce(erp.document_changed_since_request(q.id), false)) then
    return null;
  end if;

  -- Named immediately before the move and cleared after, as
  -- erp.settle_approval_outcome() names a transfer order's.
  perform set_config('erp.deriving_move', q.object_id::text || ':' || v_move, true);
  begin
    v_to := erp.transition_document(q.object_id, v_move,
              coalesce(nullif(btrim(v_task.comment), ''),
                       case v_move when 'approve' then 'Approved under My approvals'
                                   else 'Rejected under My approvals' end));
  exception when insufficient_privilege or check_violation then
    -- The approver may decide the request and still not make all the move
    -- commits: a confirmed sales order posts, and the posting asks for
    -- finance.post. The decision stands, the move is undone with this block,
    -- and the document waits for the press on it, which says why, as every
    -- decided document did before.
    v_to := null;
  end;
  perform set_config('erp.deriving_move', '', true);
  return v_to;
end;
$$;

revoke all on function erp.carry_decision_to_document(uuid) from public, anon;

comment on function erp.carry_decision_to_document(uuid) is
  'A purchase order, sales order or requisition moves with the request the caller''s decision has just decided '
  '(20261006060000, J-09): approved, or sent back to draft, by the approve or reject its lifecycle declares from '
  'where it waits, as a move derived from erp.approval_request, with the approver''s note as its reason. Only by '
  'the newest request, and never over a document changed since it was asked for. A move refused to the approver '
  '(a permission the move needs beyond the decision, or a refusal of what it commits) is undone and the decision '
  'stands, the document waiting for the press on it as before. Called by public.erp_decide_approval and '
  'erp.redeem_email_action after erp.decide_approval_task(). Answers the state the document moved to, or null.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The two places a person decides a task away from the document
-- ─────────────────────────────────────────────────────────────────────────────

do $door$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'public.erp_decide_approval(uuid,boolean,text)'::regprocedure);
begin
  if strpos(v_src, '20261006060000') > 0 then
    raise notice 'public.erp_decide_approval already carries its decision; left as it is';
    return;
  end if;
  if md5(v_src) <> 'a9e6491d8f50d5fd48f5a846d9cd8803' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_decide_approval is not the body 20261006060000 expects (md5 %)', md5(v_src);
  end if;
end
$door$;

create or replace function public.erp_decide_approval(p_task_id uuid, p_approve boolean, p_comment text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_status erp.approval_status;
begin
  v_status := erp.decide_approval_task(p_task_id, p_approve, p_comment);
  -- And what the request was about moves with it (20261006060000).
  perform erp.carry_decision_to_document(p_task_id);
  return jsonb_build_object('status', v_status);
end;
$$;

comment on function public.erp_decide_approval(uuid, boolean, text) is
  'Decides an approval task assigned to the caller (erp.decide_approval_task), and a purchase order, sales order '
  'or requisition whose request that decides moves with it (erp.carry_decision_to_document, 20261006060000).';

do $email$
declare
  v_sig  constant text := 'erp.redeem_email_action(text,boolean,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  update erp.approval_task t
     set decided_via = 'email'
   where t.tenant_id = v_tenant and t.id = v_task.id and t.decided_by = v_actor
     and t.decided_via = 'desk';
$o$;
  v_new  constant text := $n$  update erp.approval_task t
     set decided_via = 'email'
   where t.tenant_id = v_tenant and t.id = v_task.id and t.decided_by = v_actor
     and t.decided_via = 'desk';

  -- And what the request was about moves with it, as it does from My
  -- approvals (20261006060000).
  perform erp.carry_decision_to_document(v_task.id);
$n$;
begin
  if strpos(v_src, '20261006060000') > 0 then
    raise notice '% already carries its decision; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'fee441a08d57dc530f93cc7f2cb72dc8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$email$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The fact, read again with the document's state locked
-- ─────────────────────────────────────────────────────────────────────────────

do $fact$
declare
  v_sig  constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           when dt.base_type_code in ('transfer_order', 'adjustment') and p_transition_code in ('approve', 'reject')
            and erp.object_current_state('document', p_object_id) = 'pending_approval'
$o$;
  v_new  constant text := $n$           -- And a purchase order, a sales order and a requisition, asked for by
           -- erp.carry_decision_to_document() (20261006060000), by the move
           -- their version declares out of where they wait: a requisition
           -- waits in submitted.
           when dt.base_type_code in ('transfer_order', 'adjustment', 'purchase_order', 'sales_order', 'requisition')
            and p_transition_code in ('approve', 'reject')
            and case when dt.base_type_code in ('transfer_order', 'adjustment')
                     then erp.object_current_state('document', p_object_id) = 'pending_approval'
                     else erp.document_declares_move(p_object_id, p_transition_code) end
$n$;
begin
  if strpos(v_src, '20261006060000') > 0 then
    raise notice '% already derives an order''s approval; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a2e317edc39114cb07c90f1fa70d38b2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$fact$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

-- The grant suite walks the spine through the doors as authenticated, and
-- pressed Approve after deciding the order's task through the door. Decided,
-- the order is now approved with its request, so the walk asks that instead.
do $grant_suite$
declare
  v_sig  constant text := 'erp_test.grant_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        perform public.erp_decide_approval(v_task, true, 'grant suite');
      end loop;
      perform public.erp_transition_document(v_po, 'approve', 'grant suite');
$o$;
  v_new  constant text := $n$        perform public.erp_decide_approval(v_task, true, 'grant suite');
      end loop;
      -- Decided through the door, it is approved with its request
      -- (20261006060000).
      if erp.object_current_state('document', v_po) is distinct from 'approved' then
        raise exception 'the order decided through the door stands %',
          coalesce(erp.object_current_state('document', v_po), 'nowhere');
      end if;
$n$;
begin
  if strpos(v_src, '20261006060000') > 0 then
    raise notice '% already expects the decided order approved; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '64ca9bf85d550fdb64aaca29e9cd698a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006060000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$grant_suite$;

create or replace function erp_test.decided_request_moves_document_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();   -- buys and sells, and asks
  a2       uuid := gen_random_uuid();   -- approves
  r        record;
  res      jsonb;
  v_second uuid;
  v_tok    text;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_ctrl  uuid;
  cs_sales uuid;
  v_step   text := 'starting';
  v_state  text;
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_cust   uuid;
  v_item   uuid;
  v_doc    uuid;
  v_task   uuid;
  v_req    uuid;
  v_out    jsonb;
  v_err    text;
  v_to     text;
  v_mail   text;
  v_log    record;
  v_po1 text; v_po1_log text; v_po1_ok boolean;
  v_so  text; v_so_err text;
  v_rq  text; v_rq_err text;
  v_po2 text; v_po2_req text; v_po2_reason text;
  v_rq2 text; v_po3 text; v_mail_err text;
  v_po4 text; v_po4_derived boolean;
  v_po5_after text; v_po5_req text; v_po5 text;
begin
  begin
    -- ── A live organisation, two administrators, procurement and sales ──────
    v_step := 'a live organisation is provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-carry-' || v_hex, 'Decided request suite',
      'admin@zz-carry-' || v_hex || '.test', 'Carry Admin');
    insert into auth.users (id, email)
    values (a1, 'admin@zz-carry-' || v_hex || '.test'),
           (a2, 'second@zz-carry-' || v_hex || '.test');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    -- Two-person approval is what this organisation proves.
    perform erp_test.administrator_approval_off(r.tenant_id);
    res := public.erp_invite_principal('second@zz-carry-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'finance, procurement and sales are installed';
    cs_fin := erp.configure_finance();
    select (d ->> 'lifecycle_change_set_id')::uuid, (d ->> 'controls_change_set_id')::uuid
      into cs_proc, cs_ctrl
      from public.erp_configure_procurement(1000000, 'purchasing') d;
    cs_sales := (public.erp_configure_sales(15, 'sales') ->> 'change_set_id')::uuid;

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_ctrl);
    perform erp.promote_change_set(cs_ctrl);
    perform erp.approve_change_set(cs_sales);
    perform erp.promote_change_set(cs_sales);
    -- Each is given their roles by the other: nobody changes their own once
    -- the organisation is live.
    perform erp.grant_role(r.admin_user_id, 'purchasing', null, null, 'buys');
    perform erp.grant_role(r.admin_user_id, 'sales', null, null, 'sells');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(v_second, 'purchasing', null, null, 'approves orders');
    perform erp.grant_role(v_second, 'sales', null, null, 'approves sales');

    v_step := 'the things the documents name';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 1000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

    -- ── 1. A purchase order approved under My approvals ────────────────────
    v_step := 'a purchase order is approved under My approvals';
    v_doc := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_doc, v_item, 10, 5000, 'Ten widgets');
    perform erp.transition_document(v_doc, 'submit');
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second;
    select g.outcome, g.err_message into v_out, v_err
      from erp_test.email_action_door_as(a2, 'erp_decide_approval', null, true, 'Agreed by the approver', v_task) g;
    v_po1 := erp.object_current_state('document', v_doc);
    select l.transition_code, l.reason, l.actor_id, l.guard_data -> 'derived' ->> 'fact' as fact into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_doc
       and l.transition_code = 'approve';
    v_po1_ok := v_err is null and v_out ->> 'status' = 'approved'
            and v_log.transition_code = 'approve' and v_log.fact = 'erp.approval_request'
            and v_log.reason = 'Agreed by the approver' and v_log.actor_id = v_second;
    v_po1_log := format('%s %s by the approver %s, fact %s, reason %s',
                        v_log.transition_code, coalesce(v_err, v_out::text), v_log.actor_id = v_second,
                        v_log.fact, v_log.reason);

    v_cases := v_cases + 1;
    case_name := 'a purchase order approved under My approvals stands approved, moved by its request with the approver''s note';
    passed := v_state is null and v_task is not null and v_po1 = 'approved' and v_po1_ok;
    detail := coalesce(v_state, format('the order is %s; %s', v_po1, v_po1_log));
    return next;

    -- ── 2. A sales order the same way ──────────────────────────────────────
    v_step := 'a sales order is approved under My approvals';
    -- Above the value its sales manager step asks about.
    v_doc := erp.open_document('sales_order', v_cust, null, v_site);
    perform erp.add_document_line(v_doc, v_item, 20, 9900, 'Twenty widgets');
    perform erp.transition_document(v_doc, 'submit');
    v_task := null;
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second
     order by t.seq, t.id
     limit 1;
    select g.err_message into v_so_err
      from erp_test.email_action_door_as(a2, 'erp_decide_approval', null, true, 'Terms agreed', v_task) g;
    v_so := erp.object_current_state('document', v_doc);

    v_cases := v_cases + 1;
    case_name := 'a sales order approved under My approvals is confirmed';
    passed := v_state is null and v_task is not null and v_so_err is null and v_so = 'confirmed';
    detail := coalesce(v_state, format('the order is %s; %s', v_so, coalesce(v_so_err, 'decided')));
    return next;

    -- ── 3. A requisition, which waits in submitted ─────────────────────────
    v_step := 'a requisition is approved under My approvals';
    v_doc := erp.open_document('requisition', v_sup);
    perform erp.add_document_line(v_doc, v_item, 1, 5000, 'One widget');
    perform erp.transition_document(v_doc, 'submit');
    v_task := null;
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second;
    select g.err_message into v_rq_err
      from erp_test.email_action_door_as(a2, 'erp_decide_approval', null, true, null, v_task) g;
    v_rq := erp.object_current_state('document', v_doc);

    v_cases := v_cases + 1;
    case_name := 'a requisition approved under My approvals is approved, from submitted';
    passed := v_state is null and v_task is not null and v_rq_err is null and v_rq = 'approved';
    detail := coalesce(v_state, format('the requisition is %s; %s', v_rq, coalesce(v_rq_err, 'decided')));
    return next;

    -- ── 4. A refusal sends the order back ──────────────────────────────────
    v_step := 'a purchase order is refused under My approvals';
    v_doc := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_doc, v_item, 2, 5000, 'Two widgets');
    perform erp.transition_document(v_doc, 'submit');
    v_task := null;
    select t.id, q.id into v_task, v_req
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second;
    select g.err_message into v_err
      from erp_test.email_action_door_as(a2, 'erp_decide_approval', null, false, 'Not this quarter', v_task) g;
    v_po2 := erp.object_current_state('document', v_doc);
    select q.status::text into v_po2_req from erp.approval_request q where q.id = v_req;
    select l.reason into v_po2_reason
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_doc
       and l.transition_code = 'reject';

    v_cases := v_cases + 1;
    case_name := 'a purchase order refused under My approvals goes back to draft, with the reason';
    passed := v_state is null and v_err is null and v_po2 = 'draft' and v_po2_req = 'rejected'
          and v_po2_reason = 'Not this quarter';
    detail := coalesce(v_state, format('the order is %s, its request %s, the move''s reason %s; %s',
                                       v_po2, v_po2_req, v_po2_reason, coalesce(v_err, 'decided')));
    return next;

    -- ── 5. From the link in the email ──────────────────────────────────────
    v_step := 'a requisition is approved from the link in the email';
    v_doc := erp.open_document('requisition', v_sup);
    perform erp.add_document_line(v_doc, v_item, 3, 5000, 'Three widgets');
    perform erp.transition_document(v_doc, 'submit');
    v_task := null;
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second;
    select g.minted_token into v_mail from erp_test.email_action_mint(r.tenant_id, v_second, v_task) g;
    select g.err_message into v_mail_err
      from erp_test.email_action_door_as(a2, 'erp_decide_approval_from_email', v_mail, true, null) g;
    v_rq2 := erp.object_current_state('document', v_doc);

    v_step := 'a purchase order is refused from the link in the email';
    v_doc := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_doc, v_item, 3, 5000, 'Three widgets');
    perform erp.transition_document(v_doc, 'submit');
    v_task := null;
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second;
    select g.minted_token into v_mail from erp_test.email_action_mint(r.tenant_id, v_second, v_task) g;
    select coalesce(v_mail_err, g.err_message) into v_mail_err
      from erp_test.email_action_door_as(a2, 'erp_decide_approval_from_email', v_mail, false, 'Wrong supplier') g;
    v_po3 := erp.object_current_state('document', v_doc);

    v_cases := v_cases + 1;
    case_name := 'from the link in the email, a requisition is approved and a refused order goes back to draft';
    passed := v_state is null and v_mail_err is null and v_rq2 = 'approved' and v_po3 = 'draft';
    detail := coalesce(v_state, format('the requisition is %s, the order %s; %s', v_rq2, v_po3,
                                       coalesce(v_mail_err, 'both decided')));
    return next;

    -- ── 6. The approver's press on the document is still one press ─────────
    v_step := 'the approver presses Approve on the order';
    v_doc := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_doc, v_item, 4, 5000, 'Four widgets');
    perform erp.transition_document(v_doc, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_po4 := erp.transition_document(v_doc, 'approve', 'Pressed on the order');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select coalesce(l.guard_data, '{}'::jsonb) ? 'derived' into v_po4_derived
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_doc
       and l.transition_code = 'approve';

    v_cases := v_cases + 1;
    case_name := 'the approver pressing Approve on the order still approves it in one press, as their own move';
    passed := v_state is null and v_po4 = 'approved' and v_po4_derived is false;
    detail := coalesce(v_state, format('the press gave %s; the move derived %s', v_po4, v_po4_derived));
    return next;

    -- ── 7. A routine that decides and then presses keeps its press ─────────
    v_step := 'a task is decided by the routine, then the order is pressed';
    v_doc := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_doc, v_item, 5, 5000, 'Five widgets');
    perform erp.transition_document(v_doc, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_task := null;
    select t.id, q.id into v_task, v_req
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_doc
       and t.status = 'pending' and t.assignee_user_id = v_second;
    perform erp.decide_approval_task(v_task, true, 'decided by the routine');
    v_po5_after := erp.object_current_state('document', v_doc);
    select q.status::text into v_po5_req from erp.approval_request q where q.id = v_req;
    v_po5 := erp.transition_document(v_doc, 'approve', 'pressed after');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'a task decided by a routine that goes on to press, as the demonstration''s history does, leaves the move to its press';
    passed := v_state is null and v_po5_after = 'pending_approval' and v_po5_req = 'approved' and v_po5 = 'approved';
    detail := coalesce(v_state, format('decided, the order stood %s with its request %s; pressed, %s',
                                       v_po5_after, v_po5_req, v_po5));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DECIDED_REQUEST_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.decided_request_moves_document_suite() from public, anon;

comment on function erp_test.decided_request_moves_document_suite() is
  'A decided request moves its document (20261006060000, J-09): a purchase order, a sales order and a requisition '
  'decided under My approvals or from the email link are approved, or sent back to draft with the reason, by a '
  'move derived from the request; the approver''s press on the document is still one press, and a routine that '
  'decides and then presses keeps its press.';

create or replace function erp_test.assert_decided_request_moves_document_suite()
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
    from erp_test.decided_request_moves_document_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DECIDED_REQUEST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An order or requisition decided away from its page did not move with its request. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_DECIDED_REQUEST_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('decided request moves its document: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_decided_request_moves_document_suite() from public, anon;

comment on function erp_test.assert_decided_request_moves_document_suite() is
  'An order or requisition decided under My approvals or from the email link moves with its request '
  '(20261006060000).';

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
